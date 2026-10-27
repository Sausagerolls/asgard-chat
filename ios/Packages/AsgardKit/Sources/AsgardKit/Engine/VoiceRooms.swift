import Foundation

/// Always-open voice/video rooms for groups, channels and communities.
/// See "Voice rooms" in docs/PROTOCOL.md.
extension ChatEngine {
    public static func voiceRoomName(_ conv: UUID) -> String { "voice-" + conv.lower }

    public func voiceParticipants(_ conv: UUID) -> [VoiceParticipant] { voiceRooms[conv] ?? [] }

    public func refreshVoiceRooms() async {
        guard let api, !isDemo else { return }
        guard let rooms: [VoiceRoomState] = try? await api.send("GET", "/voice") else { return }
        voiceRooms = Dictionary(rooms.filter { !$0.participants.isEmpty }.map { ($0.conversationID, $0.participants) }, uniquingKeysWith: { a, _ in a })
    }

    public func refreshVoiceRoom(_ conv: UUID) async {
        guard let api, !isDemo else { return }
        guard let st: VoiceRoomState = try? await api.send("GET", "/conversations/\(conv.lower)/voice") else { return }
        voiceRooms[conv] = st.participants.isEmpty ? nil : st.participants
    }

    /// Joins the room and makes sure this device ends up with the media key:
    /// the first joiner creates and shares it, later joiners ask for it.
    public func joinVoice(_ conv: UUID, muted: Bool, video: Bool) async throws -> (join: VoiceJoin, key: Data?) {
        guard let api else { throw APIError.offline }
        struct Body: Encodable, Sendable { var muted: Bool; var video: Bool }
        let join: VoiceJoin = try await api.send("POST", "/conversations/\(conv.lower)/voice/join", body: Body(muted: muted, video: video))
        voiceRooms[conv] = join.participants
        currentVoiceRoom = conv
        if join.first {
            let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            CallKeyStore.shared.put(room: join.room, key: key)
            await sendVoiceKey(key, room: join.room, to: conv)
            return (join, key)
        }
        // Ask until someone in the room answers (they may still be connecting).
        for attempt in 0..<40 {
            if let key = CallKeyStore.shared.key(for: join.room) { return (join, key) }
            if attempt % 12 == 0 {
                var c = MessageContent(type: .callKeyRequest)
                c.callKey = .init(room: join.room, key: Data())
                _ = try? await deliver(c, kind: "control", to: conv)
            }
            await syncNow()
            try? await Task.sleep(for: .milliseconds(250))
        }
        return (join, nil)
    }

    public func updateVoice(_ conv: UUID, muted: Bool? = nil, video: Bool? = nil) async {
        struct Body: Encodable, Sendable { var muted: Bool?; var video: Bool? }
        try? await api?.call("POST", "/conversations/\(conv.lower)/voice/update", body: Body(muted: muted, video: video))
    }

    public func leaveVoice(_ conv: UUID) async {
        if currentVoiceRoom == conv { currentVoiceRoom = nil }
        try? await api?.call("POST", "/conversations/\(conv.lower)/voice/leave")
        if let me = myDeviceID {
            voiceRooms[conv]?.removeAll { $0.deviceID == me }
            if voiceRooms[conv]?.isEmpty == true { voiceRooms[conv] = nil }
        }
    }

    func sendVoiceKey(_ key: Data, room: String, to conv: UUID) async {
        var c = MessageContent(type: .callKey)
        c.callKey = .init(room: room, key: key)
        _ = try? await deliver(c, kind: "control", to: conv)
    }

    /// Encrypted signalling between devices: key shares and key requests.
    func handleControl(_ env: Envelope, content: MessageContent, live: Bool) {
        switch content.type {
        case .callKey:
            CallKeyStore.shared.put(room: content.callKey?.room, key: content.callKey?.key)
        case .historyKey:
            Task { await receivedHistoryKey(content.historyKey, from: env) }
        case .callKeyRequest:
            // Only live requests matter; the earliest other participant answers.
            guard live, let room = content.callKey?.room, let conv = currentVoiceRoom, room == Self.voiceRoomName(conv),
                  env.senderDeviceID != myDeviceID, let key = CallKeyStore.shared.key(for: room) else { return }
            let others = voiceParticipants(conv).filter { $0.deviceID != env.senderDeviceID }
            guard others.first?.deviceID == myDeviceID else { return }
            Task { await sendVoiceKey(key, room: room, to: conv) }
        default:
            break
        }
    }
}
