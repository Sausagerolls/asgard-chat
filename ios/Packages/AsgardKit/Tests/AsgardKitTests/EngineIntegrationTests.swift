import Foundation
import SwiftData
import Testing
@testable import AsgardKit

/// Runs two ChatEngines against a real server.
///
///     ASGARD_TEST_SERVER=http://127.0.0.1:8089 ASGARD_TEST_INVITE=XXXX-XXXX-XXXX swift test --filter Engine
@MainActor
@Suite(.serialized) struct EngineIntegrationTests {
    let server = ProcessInfo.processInfo.environment["ASGARD_TEST_SERVER"].flatMap(URL.init(string:))
    let invite = ProcessInfo.processInfo.environment["ASGARD_TEST_INVITE"]

    func makeEngine() throws -> ChatEngine {
        let e = ChatEngine(container: try LocalStore.container(inMemory: true))
        e.accountStore = .memory()
        return e
    }

    func waitFor(_ what: String, timeout: Double = 8, _ cond: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !cond() {
            if Date.now > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func messages(_ e: ChatEngine, _ conv: UUID) -> [StoredMessage] {
        (try? e.context.fetch(FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationID == conv }, sortBy: [SortDescriptor(\.sortKey)]))) ?? []
    }

    @Test func twoUsersChat() async throws {
        guard let server, let invite else { return }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let odin = try makeEngine(), thor = try makeEngine()
        try await odin.signUp(server: server, invite: invite, username: "odin\(suffix)", displayName: "Odin", password: "valhalla-rising-1", deviceName: "test")
        #expect(odin.phase == .ready)

        // Odin is the first user, so he's admin and can mint an invite for Thor.
        let inv: Invite = try await odin.api!.send("POST", "/admin/invites", body: ["max_uses": 1])
        try await thor.signUp(server: server, invite: inv.code, username: "thor\(suffix)", displayName: "Thor", password: "mjolnir-hammer-1", deviceName: "test")

        let dm = try await odin.openDM(with: thor.myID!)
        await odin.send(.text("Hail, Thor ⚡️"), to: dm)
        let sent = messages(odin, dm).last { !$0.isSystem }
        #expect(sent?.status == .sent)
        #expect(sent?.seq ?? 0 > 0)

        try await waitFor("thor receives") { messages(thor, dm).contains { $0.content?.text == "Hail, Thor ⚡️" } }
        let received = try #require(messages(thor, dm).first { $0.content?.text == "Hail, Thor ⚡️" })
        #expect(!received.unverified)
        #expect(thor.storedConversation(dm)?.unread == 1)

        // Reaction and edit flow back to Odin.
        await thor.react("🔥", to: received)
        try await waitFor("odin sees reaction") { sent?.reactions.first?.emoji == "🔥" }
        await odin.edit(sent!, text: "Hail, Thor! ⚡️")
        try await waitFor("thor sees edit") { received.content?.text == "Hail, Thor! ⚡️" && received.editedAt != nil }

        // Encrypted attachment round trip.
        let bytes = Data((0..<200_000).map { UInt8($0 % 256) })
        await odin.sendFiles([.init(data: bytes, mime: "application/octet-stream", name: "runes.bin")], to: dm)
        try await waitFor("thor gets file") { messages(thor, dm).contains { $0.content?.attachments?.first?.name == "runes.bin" } }
        let fileMsg = try #require(messages(thor, dm).first { $0.content?.attachments?.first?.name == "runes.bin" })
        MediaCache.remove(fileMsg.content!.attachments![0].mediaID)
        let downloaded = try await thor.attachmentData(fileMsg.content!.attachments![0])
        #expect(downloaded == bytes)

        // Delete for everyone.
        await odin.deleteForEveryone(sent!)
        try await waitFor("thor sees delete") { received.wasDeleted }

        // Read receipts.
        thor.markRead(dm)
        try await waitFor("odin sees read") { odin.status(of: messages(odin, dm).last { $0.content?.attachments != nil }!) == .read }

        // A fresh device for Thor gets new messages (fan-out refresh after 409).
        let thor2 = try makeEngine()
        try await thor2.signIn(server: server, username: "thor\(suffix)", password: "mjolnir-hammer-1", deviceName: "ipad")
        await odin.send(.text("Both your devices?"), to: dm)
        try await waitFor("thor2 receives") { messages(thor2, dm).contains { $0.content?.text == "Both your devices?" } }
        try await waitFor("thor1 receives") { messages(thor, dm).contains { $0.content?.text == "Both your devices?" } }

        await odin.signOut()
        await thor.signOut()
        await thor2.signOut()
    }
}

@MainActor
@Suite(.serialized) struct HistorySyncTests {
    let server = ProcessInfo.processInfo.environment["ASGARD_TEST_SERVER"].flatMap(URL.init(string:))
    let invite = ProcessInfo.processInfo.environment["ASGARD_TEST_INVITE"]

    func makeEngine() throws -> ChatEngine {
        let e = ChatEngine(container: try LocalStore.container(inMemory: true))
        e.accountStore = .memory()
        return e
    }

    func texts(_ e: ChatEngine, _ conv: UUID) -> [String] {
        ((try? e.context.fetch(FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationID == conv }, sortBy: [SortDescriptor(\.sortKey)]))) ?? [])
            .compactMap { $0.content?.text }
    }

    func waitFor(_ what: String, timeout: Double = 10, _ cond: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !cond() {
            if Date.now > deadline { Issue.record("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func recoveryKeyFormat() throws {
        let k = RecoveryKey.generate()
        #expect(k.formatted.split(separator: "-").count == 13)
        #expect(RecoveryKey(k.formatted) == k)
        #expect(RecoveryKey(k.formatted.lowercased().replacingOccurrences(of: "-", with: " ")) == k)
        #expect(RecoveryKey("not a key") == nil)
        #expect(k.deviceKeys.identityPublic == RecoveryKey(bytes: k.bytes).deviceKeys.identityPublic)
    }

    @Test func newDevicesSeeHistory() async throws {
        guard let server, let invite else { return }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let odin = try makeEngine(), thor = try makeEngine()
        try await odin.signUp(server: server, invite: invite, username: "odin\(suffix)", displayName: "Odin", password: "valhalla-rising-1", deviceName: "phone")
        try await thor.signUp(server: server, invite: invite, username: "thor\(suffix)", displayName: "Thor", password: "mjolnir-hammer-1", deviceName: "phone")
        let dm = try await odin.openDM(with: thor.myID!)

        // Sent before history sync existed: covered by backfill.
        await thor.send(.text("Before the key"), to: dm)
        try await waitFor("odin gets first") { texts(odin, dm).contains("Before the key") }

        let shown = try await odin.enableHistory()
        try await waitFor("backfill") { !odin.history.working && odin.history.progress == nil }
        try await Task.sleep(for: .seconds(1))
        await thor.send(.text("After the key"), to: dm)
        try await waitFor("odin gets second") { texts(odin, dm).contains("After the key") }

        // Lost every device: sign in fresh and type the recovery key.
        let fresh = try makeEngine()
        try await fresh.signIn(server: server, username: "odin\(suffix)", password: "valhalla-rising-1", deviceName: "new phone")
        await fresh.refreshConversations()
        await #expect(throws: APIError.self) { try await fresh.restoreHistory(RecoveryKey.generate().formatted) }
        try await fresh.restoreHistory(shown)
        #expect(texts(fresh, dm).contains("Before the key"))
        #expect(texts(fresh, dm).contains("After the key"))

        // Linking a device hands it the key automatically.
        struct Link: Decodable { var code: String }
        let link: Link = try await odin.api!.send("POST", "/devices/link")
        let linked = try makeEngine()
        try await linked.claimDeviceLink(server: server, code: link.code, deviceName: "mac")
        await linked.refreshConversations()
        try await waitFor("linked device restores", timeout: 20) { texts(linked, dm).contains("Before the key") && texts(linked, dm).contains("After the key") }
        #expect(linked.history.hasKey)
    }
}
