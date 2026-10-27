import Foundation
import SwiftData

public enum MessageStatus: String, Codable, Sendable {
    case sending, sent, delivered, read, failed, received
}

/// A displayable message (kind msg or system). Reactions, edits, votes and
/// pins are folded into their target row as they arrive.
@Model
public final class StoredMessage {
    /// Server id once sent; the client id while sending. Not unique-constrained
    /// because it changes on confirmation; rows are deduplicated in code.
    public var id: UUID
    public var clientID: UUID
    public var conversationID: UUID
    public var seq: Int64
    public var sortKey: Double
    public var senderUserID: UUID?
    public var senderDeviceID: UUID?
    public var sentAt: Date
    public var expiresAt: Date?
    public var statusRaw: String
    public var contentData: Data?
    public var systemData: Data?
    public var threadRootID: UUID?
    public var replyCount: Int = 0
    public var wasDeleted: Bool = false
    public var editedAt: Date?
    public var reactionsData: Data?
    public var votesData: Data?
    public var rsvpData: Data?
    public var viewOnce: Bool = false
    public var viewedOnce: Bool = false
    public var decryptFailed: Bool = false
    public var unverified: Bool = false
    public var isPinned: Bool = false
    public var isStarred: Bool = false
    public var searchText: String = ""
    public var errorMessage: String?

    public init(id: UUID, clientID: UUID, conversationID: UUID, seq: Int64, sortKey: Double, senderUserID: UUID?, senderDeviceID: UUID?,
                sentAt: Date, status: MessageStatus, content: MessageContent?, threadRootID: UUID? = nil) {
        self.id = id
        self.clientID = clientID
        self.conversationID = conversationID
        self.seq = seq
        self.sortKey = sortKey
        self.senderUserID = senderUserID
        self.senderDeviceID = senderDeviceID
        self.sentAt = sentAt
        self.statusRaw = status.rawValue
        self.threadRootID = threadRootID
        self.content = content
    }

    public var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .sent }
        set { statusRaw = newValue.rawValue }
    }

    public var content: MessageContent? {
        get { contentData.flatMap { try? JSONDecoder().decode(MessageContent.self, from: $0) } }
        set {
            contentData = try? JSONEncoder().encode(newValue)
            searchText = (newValue?.text ?? newValue?.poll?.question ?? newValue?.event?.title ?? newValue?.attachments?.first?.name ?? "").lowercased()
        }
    }

    public var system: JSONValue? {
        get { systemData.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
        set { systemData = try? JSONEncoder().encode(newValue) }
    }

    /// emoji -> user ids, in first-reaction order.
    public var reactions: [Reaction] {
        get { reactionsData.flatMap { try? JSONDecoder().decode([Reaction].self, from: $0) } ?? [] }
        set { reactionsData = try? JSONEncoder().encode(newValue) }
    }

    /// user id -> option ids
    public var votes: [String: [String]] {
        get { votesData.flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:] }
        set { votesData = try? JSONEncoder().encode(newValue) }
    }

    public var rsvps: [String: String] {
        get { rsvpData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
        set { rsvpData = try? JSONEncoder().encode(newValue) }
    }

    public var isSystem: Bool { systemData != nil }
}

public struct Reaction: Codable, Hashable, Sendable, Identifiable {
    public var emoji: String
    public var userIDs: [UUID]
    public var id: String { emoji }
    public init(emoji: String, userIDs: [UUID]) { self.emoji = emoji; self.userIDs = userIDs }
}

@Model
public final class StoredConversation {
    @Attribute(.unique) public var id: UUID
    public var payload: Data
    public var kindRaw: String
    public var title: String
    public var sortDate: Date
    public var pinned: Bool
    public var archived: Bool
    public var unread: Int
    public var folder: String
    public var mutedUntil: Date?
    public var previewText: String = ""
    public var previewSenderID: UUID?
    public var previewDate: Date?
    public var draft: String = ""
    public var wallpaper: String = ""
    public var locked: Bool = false
    public var markedUnread: Bool = false
    public var communityID: UUID?

    public init(_ c: Conversation) {
        id = c.id
        payload = Data()
        kindRaw = c.kind.rawValue
        title = c.title
        sortDate = c.lastMessageAt ?? c.createdAt
        pinned = false
        archived = false
        unread = 0
        folder = ""
        update(from: c)
    }

    public func update(from c: Conversation) {
        payload = (try? Coding.encoder.encode(c)) ?? payload
        kindRaw = c.kind.rawValue
        title = c.kind == .dm ? (c.peer?.displayName ?? c.title) : c.title
        sortDate = max(c.lastMessageAt ?? c.createdAt, previewDate ?? .distantPast)
        pinned = c.me?.pinned ?? false
        archived = c.me?.archived ?? false
        unread = c.unread
        folder = c.me?.folder ?? ""
        mutedUntil = c.me?.mutedUntil
        communityID = c.communityID
    }

    public var conversation: Conversation? { try? Coding.decoder.decode(Conversation.self, from: payload) }
    public var kind: ConversationKind { ConversationKind(rawValue: kindRaw) ?? .group }
    public var isMuted: Bool { (mutedUntil ?? .distantPast) > .now }
}

@Model
public final class StoredUser {
    @Attribute(.unique) public var id: UUID
    public var payload: Data
    public var displayName: String
    public var username: String

    public init(_ u: User) {
        id = u.id
        payload = (try? Coding.encoder.encode(u)) ?? Data()
        displayName = u.displayName
        username = u.username
    }

    public func update(_ u: User) {
        payload = (try? Coding.encoder.encode(u)) ?? payload
        displayName = u.displayName
        username = u.username
    }

    public var user: User? { try? Coding.decoder.decode(User.self, from: payload) }
}

/// An edit/reaction/vote whose target has not arrived yet.
@Model
public final class PendingOp {
    @Attribute(.unique) public var id: UUID
    public var targetID: UUID
    public var kind: String
    public var senderUserID: UUID?
    public var contentData: Data?
    public var sentAt: Date

    public init(id: UUID, targetID: UUID, kind: String, senderUserID: UUID?, content: MessageContent?, sentAt: Date) {
        self.id = id; self.targetID = targetID; self.kind = kind; self.senderUserID = senderUserID
        self.contentData = try? JSONEncoder().encode(content); self.sentAt = sentAt
    }
}

@Model
public final class StoredCall {
    @Attribute(.unique) public var id: UUID
    public var conversationID: UUID
    public var startedAt: Date
    public var duration: TimeInterval
    public var video: Bool
    public var outgoing: Bool
    public var missed: Bool

    public init(id: UUID = UUID(), conversationID: UUID, startedAt: Date = .now, duration: TimeInterval = 0, video: Bool, outgoing: Bool, missed: Bool = false) {
        self.id = id; self.conversationID = conversationID; self.startedAt = startedAt; self.duration = duration
        self.video = video; self.outgoing = outgoing; self.missed = missed
    }
}

public enum LocalStore {
    public static let schema = Schema([StoredMessage.self, StoredConversation.self, StoredUser.self, PendingOp.self, StoredCall.self])

    /// Shared with the notification and share extensions through the app group.
    public static func container(inMemory: Bool = false) throws -> ModelContainer {
        let config = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: AppGroup.containerURL.appending(path: "Asgard.store"), allowsSave: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
