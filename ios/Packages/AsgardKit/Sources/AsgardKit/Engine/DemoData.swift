import Foundation
import SwiftData

/// A self-contained demo world so the app can be explored without a server
/// (simulator, screenshots, App Review).
@MainActor
public enum DemoData {
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    public static let me = User(id: id(1), username: "odin", displayName: "Odin", bio: "All-father. Ravens on speed dial.", isAdmin: true, online: true)
    public static let users: [User] = [
        User(id: id(2), username: "thor", displayName: "Thor", bio: "God of thunder", online: true),
        User(id: id(3), username: "freya", displayName: "Freya", bio: "Seiðr, cats and falcon cloaks", online: false, lastSeenAt: .now.addingTimeInterval(-900)),
        User(id: id(4), username: "loki", displayName: "Loki", bio: "Definitely trustworthy", online: true),
        User(id: id(5), username: "heimdall", displayName: "Heimdall", bio: "Watching the Bifröst 24/7", online: false, lastSeenAt: .now.addingTimeInterval(-7200)),
        User(id: id(6), username: "frigg", displayName: "Frigg", online: false, lastSeenAt: .now.addingTimeInterval(-86_000)),
        User(id: id(7), username: "baldur", displayName: "Baldur", online: true),
        User(id: id(8), username: "ravens_bot", displayName: "Huginn & Muninn", isBot: true, serverBot: true),
    ]

    static func conv(_ n: Int, _ kind: ConversationKind, _ title: String, members: Int, unread: Int = 0, pinned: Bool = false, peer: User? = nil,
                     community: UUID? = nil, disappear: Int = 0, role: MemberRole = .owner, muted: Bool = false, at: Date) -> Conversation {
        Conversation(id: id(100 + n), kind: kind, communityID: community, title: title, description: kind == .channel ? "Official news from Asgard." : "",
                     avatarMediaID: nil, createdBy: me.id, createdAt: at.addingTimeInterval(-86400 * 30), lastSeq: 0, lastMessageAt: at,
                     disappearingSeconds: disappear, slowModeSeconds: 0, memberPermissions: 0b1_0000_1111, isPublic: false, memberCount: members,
                     hasServerBot: n == 3, unread: unread,
                     me: MyMembership(role: role, permissions: Permissions(rawValue: role >= .admin ? (1 << 62) - 1 : 0b1_0000_0011),
                                      mutedUntil: muted ? .distantFuture : nil, pinned: pinned, archived: false, folder: "", readSeq: 0),
                     peer: peer, lastMessage: nil)
    }

    public static func seed(_ engine: ChatEngine) {
        let ctx = engine.context
        engine.demoSetMe(me)
        if ((try? ctx.fetchCount(FetchDescriptor<StoredConversation>())) ?? 0) > 0 { return }
        for u in users { ctx.insert(StoredUser(u)) }
        ctx.insert(StoredUser(me))
        let now = Date.now
        let thor = users[0], freya = users[1], loki = users[2], heimdall = users[3]
        let community = id(110)
        let convs = [
            conv(1, .dm, "", members: 2, unread: 2, pinned: true, peer: thor, at: now.addingTimeInterval(-120)),
            conv(2, .group, "Aesir Council", members: 6, unread: 5, at: now.addingTimeInterval(-600)),
            conv(3, .group, "Bifröst Ops", members: 4, at: now.addingTimeInterval(-3600)),
            conv(4, .dm, "", members: 2, peer: freya, at: now.addingTimeInterval(-5400)),
            conv(5, .dm, "", members: 2, peer: loki, disappear: 3600, at: now.addingTimeInterval(-9000)),
            conv(6, .channel, "Asgard Herald", members: 48, unread: 1, role: .owner, at: now.addingTimeInterval(-20000)),
            conv(7, .saved, "Saved Messages", members: 1, at: now.addingTimeInterval(-40000)),
            conv(8, .dm, "", members: 2, peer: heimdall, muted: true, at: now.addingTimeInterval(-90000)),
            conv(10, .community, "Valhalla", members: 32, at: now.addingTimeInterval(-50000)),
            conv(11, .group, "Mead Hall", members: 30, unread: 3, community: community, role: .member, at: now.addingTimeInterval(-1800)),
            conv(12, .channel, "Feast Announcements", members: 32, community: community, role: .subscriber, at: now.addingTimeInterval(-70000)),
        ]
        for c in convs { ctx.insert(StoredConversation(c)) }

        var seq: Int64 = 0
        func msg(_ conv: Int, _ from: User, _ text: String?, ago: TimeInterval, _ build: ((inout MessageContent) -> Void)? = nil,
                 reactions: [Reaction] = [], configure: ((StoredMessage) -> Void)? = nil) {
            seq += 1
            var c = MessageContent.text(text ?? "")
            build?(&c)
            let row = StoredMessage(id: UUID(), clientID: UUID(), conversationID: id(100 + conv), seq: seq, sortKey: Double(seq), senderUserID: from.id,
                                    senderDeviceID: nil, sentAt: now.addingTimeInterval(-ago), status: from.id == me.id ? .sent : .received, content: c)
            row.reactions = reactions
            configure?(row)
            ctx.insert(row)
            let sc = convs.first { $0.id == id(100 + conv) }
            _ = sc
        }
        func system(_ conv: Int, _ event: [String: JSONValue], ago: TimeInterval) {
            seq += 1
            let row = StoredMessage(id: UUID(), clientID: UUID(), conversationID: id(100 + conv), seq: seq, sortKey: Double(seq), senderUserID: me.id,
                                    senderDeviceID: nil, sentAt: now.addingTimeInterval(-ago), status: .received, content: nil)
            row.system = .object(event)
            ctx.insert(row)
        }

        // Thor
        msg(1, thor, "Father! Mjölnir is making that noise again 🔨", ago: 7200)
        msg(1, me, "Have you tried turning it off and on again?", ago: 7100)
        msg(1, thor, "It doesn't have an off switch. It has a LIGHTNING switch.", ago: 7000, reactions: [Reaction(emoji: "😂", userIDs: [me.id])])
        msg(1, me, "Bring it to the forge tomorrow. Brokkr owes me a favour.", ago: 6900)
        msg(1, thor, "Also, are we still on for the feast on Friday?", ago: 180)
        msg(1, thor, "I'm bringing the goats 🐐🐐", ago: 120)

        // Aesir Council
        system(2, ["event": .string("created"), "title": .string("Aesir Council"), "actor_id": .string(me.id.lower)], ago: 86400 * 3)
        msg(2, freya, "Agenda for tonight: 1) Fenrir's chain budget 2) Who keeps leaving the Bifröst open", ago: 5000)
        msg(2, heimdall, "It wasn't me. I see everything and it wasn't me.", ago: 4800, reactions: [Reaction(emoji: "👀", userIDs: [freya.id, thor.id])])
        msg(2, loki, "Strange. Very strange. Anyway.", ago: 4700, reactions: [Reaction(emoji: "🤨", userIDs: [freya.id, heimdall.id, thor.id, me.id])])
        msg(2, me, nil, ago: 4000, { c in
            c = MessageContent(type: .poll)
            c.poll = .init(question: "Where should we hold the solstice feast?", options: [
                .init(id: "a", text: "Valhalla"), .init(id: "b", text: "Fólkvangr"), .init(id: "c", text: "Bilskírnir"),
            ])
        }, configure: { $0.votes = [thor.id.lower: ["a"], freya.id.lower: ["b"], heimdall.id.lower: ["a"], me.id.lower: ["a"]] })
        msg(2, freya, nil, ago: 3000, { c in
            c = MessageContent(type: .event)
            c.event = .init(title: "Council meeting", startsAt: now.addingTimeInterval(3600 * 5), endsAt: now.addingTimeInterval(3600 * 7), location: "Gladsheim")
        }, configure: { $0.rsvps = [me.id.lower: "yes", thor.id.lower: "yes", loki.id.lower: "maybe"] })
        msg(2, thor, "I vote Valhalla. Better mead.", ago: 900)
        msg(2, loki, "Fólkvangr has better views of the frost giants' border. Just saying.", ago: 600)

        // Bifröst Ops with bot
        msg(3, users[6], "🌈 Bifröst status: **open**. 3 crossings in the last hour.", ago: 4000, { $0.markdown = true })
        msg(3, heimdall, "Thanks ravens. Keep an eye on the eastern approach.", ago: 3700)

        // Freya
        msg(4, freya, "Did you see the aurora last night? The whole sky was violet and gold.", ago: 6000)
        msg(4, me, "Bifröst was showing off again ✨", ago: 5600, reactions: [Reaction(emoji: "❤️", userIDs: [freya.id])])
        msg(4, freya, nil, ago: 5400, { c in
            c = MessageContent(type: .voice)
            c.attachments = [.init(mediaID: id(900), mime: "audio/mp4", size: 48_000, key: Data(), digest: Data(), durationMS: 14_000,
                                   waveform: Data((0..<64).map { i in UInt8(60 + Int(80 * abs(sin(Double(i) / 4)))) }))]
        })

        // Loki, disappearing
        system(5, ["event": .string("updated"), "actor_id": .string(loki.id.lower), "changes": .object(["disappearing_seconds": .number(3600)])], ago: 10000)
        msg(5, loki, "Delete this after reading. Actually it will delete itself 😉", ago: 9000, configure: { $0.expiresAt = now.addingTimeInterval(1800) })

        // Herald channel
        msg(6, me, "📣 The Bifröst will be closed for maintenance on Thursday from 02:00 to 04:00. Ravens will carry urgent messages.", ago: 20000,
            reactions: [Reaction(emoji: "👍", userIDs: [thor.id, freya.id, heimdall.id]), Reaction(emoji: "🌈", userIDs: [freya.id])])

        // Saved messages
        msg(7, me, "Remember: ask Mímir about the well subscription renewal", ago: 40000)

        // Heimdall
        msg(8, heimdall, "Someone is approaching from Jötunheimr. Should I let them in?", ago: 90000)

        // Valhalla community
        msg(11, users[5], "Welcome to the Mead Hall! Introduce yourselves 🍯", ago: 50000)
        msg(11, users[4], "Baldur here. Fan of sunlight and not being hit by mistletoe.", ago: 2000)
        msg(11, thor, "Arm wrestling tournament at sundown!", ago: 1800)

        for c in convs {
            let cid = c.id
            if let sc = (try? ctx.fetch(FetchDescriptor<StoredConversation>(predicate: #Predicate { $0.id == cid })))?.first,
               let last = (try? ctx.fetch(FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationID == cid }, sortBy: [SortDescriptor(\.seq, order: .reverse)])))?.first {
                sc.previewText = last.content.map(ChatEngine.preview) ?? (last.system.map { SystemText.describe($0, name: engine.name) } ?? "")
                sc.previewSenderID = last.senderUserID
                sc.previewDate = last.sentAt
                sc.pinned = c.me?.pinned ?? false
            }
        }
        ctx.insert(StoredCall(conversationID: id(101), startedAt: now.addingTimeInterval(-3600 * 3), duration: 734, video: true, outgoing: false))
        ctx.insert(StoredCall(conversationID: id(104), startedAt: now.addingTimeInterval(-3600 * 20), duration: 0, video: false, outgoing: false, missed: true))
        ctx.insert(StoredCall(conversationID: id(102), startedAt: now.addingTimeInterval(-3600 * 30), duration: 2210, video: false, outgoing: true))
        try? ctx.save()
    }

    static let replies = ["Ha! Indeed.", "By my beard, yes.", "I'll tell the ravens.", "Sounds like a plan ⚡️", "Give me a moment, fighting a frost giant.", "🌈🌈🌈"]

    static func autoReply(to row: StoredMessage, engine: ChatEngine) {
        guard let sc = engine.storedConversation(row.conversationID), sc.kind == .dm, let peer = sc.conversation?.peer else { return }
        let conv = row.conversationID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            engine.demoTyping(conv, user: peer.id, on: true)
            try? await Task.sleep(for: .seconds(2))
            engine.demoTyping(conv, user: peer.id, on: false)
            let reply = StoredMessage(id: UUID(), clientID: UUID(), conversationID: conv, seq: engine.maxSeq(conv) + 1, sortKey: Double(engine.maxSeq(conv) + 1),
                                      senderUserID: peer.id, senderDeviceID: nil, sentAt: .now, status: .received, content: .text(replies.randomElement()!))
            engine.context.insert(reply)
            engine.demoMarkRead(conv, user: peer.id, seq: row.seq)
            engine.touchPreview(conv, text: reply.content?.text ?? "", sender: peer.id, at: .now)
            if engine.activeConversation != conv { sc.unread += 1 }
            try? engine.context.save()
        }
    }

    static func dm(with user: UUID, engine: ChatEngine) -> UUID {
        let all = (try? engine.context.fetch(FetchDescriptor<StoredConversation>())) ?? []
        if let existing = all.first(where: { $0.kind == .dm && $0.conversation?.peer?.id == user }) { return existing.id }
        let peer = users.first { $0.id == user }
        let c = conv(Int.random(in: 200...9999), .dm, "", members: 2, peer: peer, at: .now)
        engine.context.insert(StoredConversation(c))
        try? engine.context.save()
        return c.id
    }

    static func create(kind: ConversationKind, title: String, members: [UUID], engine: ChatEngine) -> UUID {
        let c = conv(Int.random(in: 200...9999), kind, title, members: members.count + 1, at: .now)
        engine.context.insert(StoredConversation(c))
        let row = StoredMessage(id: UUID(), clientID: UUID(), conversationID: c.id, seq: 1, sortKey: 1, senderUserID: me.id, senderDeviceID: nil,
                                sentAt: .now, status: .received, content: nil)
        row.system = .object(["event": .string("created"), "title": .string(title), "actor_id": .string(me.id.lower)])
        engine.context.insert(row)
        try? engine.context.save()
        return c.id
    }

    static func members(_ conv: UUID, engine: ChatEngine) -> [Member] {
        guard let c = engine.conversation(conv) else { return [] }
        if let peer = c.peer { return [Member(user: me, role: .member, joinedAt: .now, readSeq: 0), Member(user: peer, role: .member, joinedAt: .now, readSeq: 0)] }
        let roles: [MemberRole] = [.admin, .moderator, .member, .member, .member, .member, .member]
        return [Member(user: me, role: .owner, joinedAt: .now, readSeq: 0)] + users.prefix(max(1, min(users.count, c.memberCount - 1))).enumerated().map {
            Member(user: $0.element, role: roles[$0.offset % roles.count], joinedAt: .now, readSeq: 0)
        }
    }
}

extension ChatEngine {
    func demoSetMe(_ u: User) { me = u }

    func demoTyping(_ conv: UUID, user: UUID, on: Bool) {
        typing[conv, default: [:]][user] = on ? TypingState(state: "typing", at: .now) : nil
    }

    func demoMarkRead(_ conv: UUID, user: UUID, seq: Int64) {
        readMarks[conv, default: [:]][user] = seq
    }
}
