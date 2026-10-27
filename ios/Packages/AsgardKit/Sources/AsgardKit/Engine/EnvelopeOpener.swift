import Foundation

/// Decrypts envelopes. Shared by the app engine and the notification extension.
public struct EnvelopeOpener: Sendable {
    public enum Outcome: Sendable {
        case content(MessageContent, verified: Bool)
        case system(JSONValue)
        case undecryptable
    }

    public let keys: DeviceKeys
    public init(keys: DeviceKeys) { self.keys = keys }

    public func open(_ env: Envelope, signingKey: Data?) -> Outcome {
        if env.kind == "system", let sys = env.system { return .system(sys) }
        guard let ct = env.ciphertext, let wk = env.wrappedKey, let dev = env.senderDeviceID else { return .undecryptable }
        let aad = E2EE.aad(conversation: env.conversationID, senderDevice: dev, clientID: env.clientID)
        guard let key = try? E2EE.unwrap(wk, identity: keys.identity, clientID: env.clientID),
              let pt = try? E2EE.open(ct, key: key, aad: aad),
              let content = try? JSONDecoder().decode(MessageContent.self, from: pt) else { return .undecryptable }
        let verified = signingKey.map { E2EE.verify($0, aad: aad, ciphertext: ct, signature: env.signature ?? Data()) } ?? false
        return .content(content, verified: verified)
    }
}

/// Persistent cache of device signing keys, shared with extensions.
public enum SigningKeyCache {
    static let key = "signingKeys"

    public static func get(_ device: UUID) -> Data? {
        (AppGroup.defaults.dictionary(forKey: key) as? [String: Data])?[device.lower]
    }

    public static func put(_ devices: [DeviceInfo]) {
        var all = (AppGroup.defaults.dictionary(forKey: key) as? [String: Data]) ?? [:]
        for d in devices { all[d.id.lower] = d.signingKey }
        AppGroup.defaults.set(all, forKey: key)
    }
}

/// Human-readable text for a system event.
public enum SystemText {
    public static func describe(_ sys: JSONValue, name: (UUID?) -> String) -> String {
        let actor = name(sys["actor_id"]?.string.flatMap(UUID.init))
        let subject = name(sys["user_id"]?.string.flatMap(UUID.init))
        switch sys["event"]?.string {
        case "created": return "\(actor) created \"\(sys["title"]?.string ?? "this chat")\""
        case "joined": return "\(actor) joined"
        case "left": return "\(actor) left"
        case "members_added":
            let n = sys["user_ids"]?.array?.count ?? 0
            let names = sys["user_ids"]?.array?.compactMap { $0.string.flatMap(UUID.init) }.map { name($0) } ?? []
            return n <= 3 ? "\(actor) added \(names.formatted(.list(type: .and)))" : "\(actor) added \(n) people"
        case "member_removed": return "\(actor) removed \(subject)"
        case "member_updated": return "\(actor) made \(subject) \(sys["role"]?.string ?? "a member")"
        case "webhook_added": return "\(actor) added the webhook \"\(sys["name"]?.string ?? "")\""
        case "updated":
            if let changes = sys["changes"] {
                if let t = changes["title"]?.string { return "\(actor) renamed the chat to \"\(t)\"" }
                if case .number(let secs)? = changes["disappearing_seconds"] {
                    return secs == 0 ? "\(actor) turned off disappearing messages"
                        : "\(actor) set messages to disappear after \(Duration.seconds(secs).formatted(.units(allowed: [.weeks, .days, .hours, .minutes], width: .wide)))"
                }
                if changes["avatar_media_id"] != nil { return "\(actor) changed the chat photo" }
                if changes["description"] != nil { return "\(actor) changed the description" }
                if case .number(let secs)? = changes["slow_mode_seconds"] {
                    return secs == 0 ? "\(actor) turned off slow mode" : "\(actor) turned on slow mode"
                }
            }
            return "\(actor) updated the chat"
        default: return "Chat updated"
        }
    }
}
