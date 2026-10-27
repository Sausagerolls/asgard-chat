import CryptoKit
import SwiftData
import Foundation

/// Progress of message history sync on this device.
public struct HistoryState: Sendable, Equatable {
    /// Server says history sync is on for this account (nil = not checked yet).
    public var enabled: Bool?
    /// This device holds the recovery key.
    public var hasKey = false
    public var working = false
    public var progress: String?
    public var lastError: String?
}

/// A 32-byte recovery key, written as 13 groups of 4 Crockford base32
/// characters (no I, L, O or U, so it is hard to mistype).
public struct RecoveryKey: Sendable, Equatable {
    public let bytes: Data
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public init(bytes: Data) { self.bytes = bytes }

    public static func generate() -> RecoveryKey {
        RecoveryKey(bytes: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }

    public var formatted: String {
        var bits = 0, value = 0, out: [Character] = []
        for b in bytes {
            value = (value << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(Self.alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(Self.alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map { String(out[$0..<min($0 + 4, out.count)]) }.joined(separator: "-")
    }

    public init?(_ text: String) {
        var bits = 0, value = 0, out = Data()
        for ch in text.uppercased() {
            let c: Character = switch ch { case "O": "0"; case "I", "L": "1"; default: ch }
            guard let i = Self.alphabet.firstIndex(of: c) else {
                if ch == "-" || ch == " " { continue }
                return nil
            }
            value = (value << 5) | i
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        guard out.count == 32 else { return nil }
        bytes = out
    }

    /// The history device's keys are derived from the recovery key, so every
    /// device holding it (and nobody else) can open history envelopes.
    public var deviceKeys: DeviceKeys {
        let ikm = SymmetricKey(data: bytes)
        let salt = Data("asgard-history-v1".utf8)
        let id = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("identity".utf8), outputByteCount: 32)
        let sg = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("signing".utf8), outputByteCount: 32)
        return try! DeviceKeys(identityRaw: id.withUnsafeBytes { Data($0) }, signingRaw: sg.withUnsafeBytes { Data($0) })
    }
}

extension ChatEngine {
    struct HistoryStatus: Decodable, Sendable {
        var enabled: Bool
        var identity_key: Data?
        var messages: Int?
    }

    var storedRecoveryKey: RecoveryKey? { accountStore.loadSecret("history").map(RecoveryKey.init(bytes:)) }

    /// Shows the key so the user can write it down again (callers gate this behind Face ID / Touch ID).
    public func recoveryKeyForDisplay() -> String? { storedRecoveryKey?.formatted }

    public func refreshHistoryStatus() async {
        guard let api, !isDemo else { return }
        guard let st: HistoryStatus = try? await api.send("GET", "/me/history") else { return }
        history.enabled = st.enabled
        let local = storedRecoveryKey
        if let local, st.enabled, local.deviceKeys.identityPublic != st.identity_key {
            // Another device replaced the recovery key; the old one is useless now.
            accountStore.deleteSecret("history")
        }
        history.hasKey = st.enabled && storedRecoveryKey != nil
    }

    /// Turns history sync on with a fresh recovery key, which the caller shows to the user.
    public func enableHistory() async throws -> String {
        guard let api else { throw APIError.offline }
        let key = RecoveryKey.generate()
        let k = key.deviceKeys
        struct Body: Encodable, Sendable { var identity_key: Data; var signing_key: Data }
        let _: HistoryStatus = try await api.send("PUT", "/me/history", body: Body(identity_key: k.identityPublic, signing_key: k.signingPublic))
        accountStore.saveSecret(key.bytes, "history")
        history.enabled = true
        history.hasKey = true
        deviceCache = [:]
        Task { await backfillHistory(); await shareHistoryKey() }
        return key.formatted
    }

    /// Restores with a typed-in recovery key (e.g. after losing every device).
    public func restoreHistory(_ text: String) async throws {
        guard let api else { throw APIError.offline }
        guard let key = RecoveryKey(text) else {
            throw APIError(status: 0, code: "bad_key", message: "That doesn't look like a recovery key. It's 13 groups of 4 letters and numbers.")
        }
        let st: HistoryStatus = try await api.send("GET", "/me/history")
        guard st.enabled else { throw APIError(status: 0, code: "history_off", message: "Message history sync isn't turned on for this account.") }
        guard key.deviceKeys.identityPublic == st.identity_key else {
            throw APIError(status: 0, code: "wrong_key", message: "That recovery key doesn't match this account.")
        }
        accountStore.saveSecret(key.bytes, "history")
        history.enabled = true
        history.hasKey = true
        await importHistory()
    }

    public func disableHistory() async throws {
        try await api?.call("DELETE", "/me/history")
        accountStore.deleteSecret("history")
        history = HistoryState(enabled: false)
        deviceCache = [:]
    }

    var historyCursorKey: String { "historyCursor-" + (account?.deviceID.lower ?? "none") }

    /// Downloads and decrypts everything wrapped for the history device.
    public func importHistory() async {
        guard let api, let key = storedRecoveryKey, !history.working else { return }
        let keys = key.deviceKeys
        history.working = true
        history.lastError = nil
        defer { history.working = false; history.progress = nil }
        var cursor = Int64(AppGroup.defaults.integer(forKey: historyCursorKey))
        var count = 0
        while true {
            struct Page: Decodable, Sendable { var envelopes: [Envelope]; var next_cursor: Int64; var more: Bool }
            guard let page: Page = try? await api.send("GET", "/me/history/messages", query: [.init(name: "after", value: String(cursor))]) else {
                history.lastError = "Couldn't download history. It will retry later."
                return
            }
            await prefetchSigningKeys(page.envelopes)
            for env in page.envelopes { process(env, live: false, countUnread: false, openWith: keys) }
            try? context.save()
            count += page.envelopes.count
            history.progress = "Restored \(count) messages…"
            cursor = page.next_cursor
            AppGroup.defaults.set(Int(cursor), forKey: historyCursorKey)
            if !page.more { break }
        }
    }

    /// Re-wraps keys of messages sent before history sync was on, so the
    /// history device can open them too. Each device does this once.
    public func backfillHistory() async {
        guard let api, let keys, let rk = storedRecoveryKey, let device = myDeviceID else { return }
        let flag = "historyBackfill-" + device.lower + "-" + rk.deviceKeys.identityPublic.base64EncodedString().prefix(8)
        guard !AppGroup.defaults.bool(forKey: flag) else { return }
        let historyPublic = rk.deviceKeys.identityPublic
        struct Item: Encodable, Sendable { var message_id: UUID; var wrapped_key: Data }
        struct Body: Encodable, Sendable { var items: [Item] }
        struct Out: Decodable, Sendable { var added: Int }
        var batch: [Item] = []
        var total = 0
        func flush() async {
            guard !batch.isEmpty else { return }
            if let out: Out = try? await api.send("POST", "/me/history/backfill", body: Body(items: batch)) { total += out.added }
            batch.removeAll()
            history.progress = "Backing up \(total) older messages…"
        }
        let convs = (try? context.fetch(FetchDescriptor<StoredConversation>())) ?? []
        for c in convs where c.kind != .community {
            var before: Int64?
            while true {
                guard let envs = try? await api.history(c.id, before: before, limit: 200), !envs.isEmpty else { break }
                for env in envs {
                    guard let wk = env.wrappedKey, let k = try? E2EE.unwrap(wk, identity: keys.identity, clientID: env.clientID),
                          let wrapped = try? E2EE.wrap(k, for: historyPublic, clientID: env.clientID) else { continue }
                    batch.append(Item(message_id: env.id, wrapped_key: wrapped))
                    if batch.count >= 500 { await flush() }
                }
                before = envs.map(\.seq).min()
                if envs.count < 200 { break }
            }
        }
        await flush()
        history.progress = nil
        AppGroup.defaults.set(true, forKey: flag)
    }

    /// Sends the recovery key to this account's other devices through the
    /// end-to-end encrypted Saved Messages chat (only the user's own devices
    /// are in it). Called when a new device is linked.
    public func shareHistoryKey() async {
        guard let key = storedRecoveryKey else { return }
        let all = (try? context.fetch(FetchDescriptor<StoredConversation>())) ?? []
        guard let saved = all.first(where: { $0.kind == .saved }) else { return }
        var c = MessageContent(type: .historyKey)
        c.historyKey = key.bytes
        deviceCache[saved.id] = nil
        _ = try? await deliver(c, kind: "control", to: saved.id)
    }

    func receivedHistoryKey(_ data: Data?, from env: Envelope) async {
        guard let data, env.senderUserID == myID, env.senderDeviceID != myDeviceID, storedRecoveryKey == nil else { return }
        let key = RecoveryKey(bytes: data)
        guard let api, let st: HistoryStatus = try? await api.send("GET", "/me/history"),
              st.enabled, key.deviceKeys.identityPublic == st.identity_key else { return }
        accountStore.saveSecret(key.bytes, "history")
        history.enabled = true
        history.hasKey = true
        await importHistory()
    }
}
