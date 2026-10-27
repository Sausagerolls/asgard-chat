import Foundation

// Wire types for the Asgard REST API (docs/PROTOCOL.md). Binary fields are
// base64 strings in JSON, which `Data` decodes natively.

public struct User: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var username: String
    public var displayName: String
    public var bio: String
    public var avatarMediaID: UUID?
    public var isAdmin: Bool
    public var isBot: Bool
    public var serverBot: Bool
    public var online: Bool
    public var lastSeenAt: Date?
    public var createdAt: Date
    public var settings: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id, username, bio, online, settings
        case displayName = "display_name", avatarMediaID = "avatar_media_id", isAdmin = "is_admin", isBot = "is_bot"
        case serverBot = "server_bot", lastSeenAt = "last_seen_at", createdAt = "created_at"
    }

    public init(id: UUID, username: String, displayName: String, bio: String = "", avatarMediaID: UUID? = nil, isAdmin: Bool = false,
                isBot: Bool = false, serverBot: Bool = false, online: Bool = false, lastSeenAt: Date? = nil, createdAt: Date = .now) {
        self.id = id; self.username = username; self.displayName = displayName; self.bio = bio; self.avatarMediaID = avatarMediaID
        self.isAdmin = isAdmin; self.isBot = isBot; self.serverBot = serverBot; self.online = online; self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
    }
}

public struct DeviceInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var userID: UUID
    public var name: String?
    public var platform: String?
    public var identityKey: Data
    public var signingKey: Data
    public var createdAt: Date
    public var lastActiveAt: Date?
    public var current: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, platform, current
        case userID = "user_id", identityKey = "identity_key", signingKey = "signing_key", createdAt = "created_at", lastActiveAt = "last_active_at"
    }
}

public struct Session: Codable, Sendable {
    public var token: String
    public var user: User
    public var deviceID: UUID
    enum CodingKeys: String, CodingKey { case token, user, deviceID = "device_id" }
}

public struct ServerInfo: Codable, Sendable {
    public struct Features: Codable, Sendable {
        public var calls, push, media, bots, communities, channels: Bool
        public var serverBots: Bool
        public var voiceRooms: Bool?
        enum CodingKeys: String, CodingKey {
            case calls, push, media, bots, communities, channels
            case serverBots = "server_bots", voiceRooms = "voice_rooms"
        }
    }
    public var name: String
    public var version: String
    public var `protocol`: Int
    public var openRegistration: Bool
    public var features: Features
    public var maxUploadBytes: Int64
    public var livekitURL: String
    public var pushRelay: PushRelay?

    public struct PushRelay: Codable, Sendable {
        public var url: String
        public var serverID: String
        enum CodingKeys: String, CodingKey { case url, serverID = "server_id" }
    }
    enum CodingKeys: String, CodingKey {
        case name, version, `protocol`, features
        case openRegistration = "open_registration", maxUploadBytes = "max_upload_bytes", livekitURL = "livekit_url", pushRelay = "push_relay"
    }
}

public enum ConversationKind: String, Codable, Sendable, CaseIterable {
    case dm, group, channel, community, saved

    /// Groups and channels have an always-open voice room.
    public var hasVoiceRoom: Bool { self == .group || self == .channel }
}

public enum MemberRole: String, Codable, Sendable, CaseIterable, Comparable {
    case subscriber, member, moderator, admin, owner
    var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public struct Permissions: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public static let send = Self(rawValue: 1 << 0)
    public static let sendMedia = Self(rawValue: 1 << 1)
    public static let addMembers = Self(rawValue: 1 << 2)
    public static let pin = Self(rawValue: 1 << 3)
    public static let editInfo = Self(rawValue: 1 << 4)
    public static let deleteOthers = Self(rawValue: 1 << 5)
    public static let manageMembers = Self(rawValue: 1 << 6)
    public static let manageWebhooks = Self(rawValue: 1 << 7)
    public static let startCalls = Self(rawValue: 1 << 8)
    public static let mentionAll = Self(rawValue: 1 << 9)
    public static let bypassSlowMode = Self(rawValue: 1 << 10)
}

public struct MyMembership: Codable, Hashable, Sendable {
    public var role: MemberRole
    public var permissions: Permissions
    public var mutedUntil: Date?
    public var pinned: Bool
    public var archived: Bool
    public var folder: String
    public var readSeq: Int64
    enum CodingKeys: String, CodingKey {
        case role, permissions, pinned, archived, folder
        case mutedUntil = "muted_until", readSeq = "read_seq"
    }
}

public struct Conversation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ConversationKind
    public var communityID: UUID?
    public var title: String
    public var description: String
    public var avatarMediaID: UUID?
    public var createdBy: UUID?
    public var createdAt: Date
    public var lastSeq: Int64
    public var lastMessageAt: Date?
    public var disappearingSeconds: Int
    public var slowModeSeconds: Int
    public var memberPermissions: Int64
    public var isPublic: Bool
    public var memberCount: Int
    public var hasServerBot: Bool
    public var unread: Int
    public var me: MyMembership?
    public var peer: User?
    public var lastMessage: Envelope?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, description, unread, me, peer
        case communityID = "community_id", avatarMediaID = "avatar_media_id", createdBy = "created_by", createdAt = "created_at"
        case lastSeq = "last_seq", lastMessageAt = "last_message_at", disappearingSeconds = "disappearing_seconds"
        case slowModeSeconds = "slow_mode_seconds", memberPermissions = "member_permissions", isPublic = "is_public"
        case memberCount = "member_count", hasServerBot = "has_server_bot", lastMessage = "last_message"
    }
}

public struct Member: Codable, Hashable, Identifiable, Sendable {
    public var user: User
    public var role: MemberRole
    public var joinedAt: Date
    public var readSeq: Int64
    public var id: UUID { user.id }
    enum CodingKeys: String, CodingKey { case user, role, joinedAt = "joined_at", readSeq = "read_seq" }
}

public struct Envelope: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var conversationID: UUID
    public var seq: Int64
    public var clientID: UUID
    public var kind: String
    public var targetID: UUID?
    public var threadRootID: UUID?
    public var senderUserID: UUID?
    public var senderDeviceID: UUID?
    public var alg: String
    public var ciphertext: Data?
    public var signature: Data?
    public var system: JSONValue?
    public var wrappedKey: Data?
    public var sentAt: Date
    public var expiresAt: Date?
    public var viewOnce: Bool
    public var deleted: Bool
    public var cursor: Int64?

    enum CodingKeys: String, CodingKey {
        case id, seq, kind, alg, ciphertext, signature, system, deleted, cursor
        case conversationID = "conversation_id", clientID = "client_id", targetID = "target_id", threadRootID = "thread_root_id"
        case senderUserID = "sender_user_id", senderDeviceID = "sender_device_id", wrappedKey = "wrapped_key"
        case sentAt = "sent_at", expiresAt = "expires_at", viewOnce = "view_once"
    }
}

public struct SyncPage: Codable, Sendable {
    public var envelopes: [Envelope]
    public var nextCursor: Int64
    public var more: Bool
    enum CodingKeys: String, CodingKey { case envelopes, more, nextCursor = "next_cursor" }
}

public struct SendRequest: Codable, Sendable {
    public var clientID: UUID
    public var kind: String
    public var targetID: UUID?
    public var threadRootID: UUID?
    public var ciphertext: Data
    public var signature: Data
    public var alg = "fanout-v1"
    public var keys: [String: Data]
    public var expiresIn: Int?
    public var sendAt: Date?
    public var viewOnce: Bool

    enum CodingKeys: String, CodingKey {
        case kind, ciphertext, signature, alg, keys
        case clientID = "client_id", targetID = "target_id", threadRootID = "thread_root_id"
        case expiresIn = "expires_in", sendAt = "send_at", viewOnce = "view_once"
    }
}

public struct Invite: Codable, Hashable, Identifiable, Sendable {
    public var code: String
    public var note: String
    public var maxUses: Int
    public var uses: Int
    public var makeAdmin: Bool
    public var expiresAt: Date?
    public var createdAt: Date
    public var url: String
    public var id: String { code }
    enum CodingKeys: String, CodingKey {
        case code, note, uses, url
        case maxUses = "max_uses", makeAdmin = "make_admin", expiresAt = "expires_at", createdAt = "created_at"
    }
}

public struct CallJoin: Codable, Sendable {
    public var url: String
    public var token: String
    public var room: String
    public var joinedExisting: Bool
    enum CodingKeys: String, CodingKey { case url, token, room, joinedExisting = "joined_existing" }
}

public struct AdminStats: Codable, Sendable {
    public var users, bots, devices, conversations, messages: Int
    public var mediaBytes, databaseBytes: Int64
    public var onlineUsers, onlineDevices: Int
    public var version: String
    public var pushEnabled, callsEnabled: Bool
    enum CodingKeys: String, CodingKey {
        case users, bots, devices, conversations, messages, version
        case mediaBytes = "media_bytes", databaseBytes = "database_bytes"
        case onlineUsers = "online_users", onlineDevices = "online_devices", pushEnabled = "push_enabled", callsEnabled = "calls_enabled"
    }
}

public struct AdminUser: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var username: String
    public var displayName: String
    public var isAdmin: Bool
    public var isBot: Bool
    public var online: Bool
    public var disabled: Bool
    public var deviceCount: Int
    public var storageUsed: Int64
    public var storageQuota: Int64
    public var createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, username, online, disabled
        case displayName = "display_name", isAdmin = "is_admin", isBot = "is_bot", deviceCount = "device_count"
        case storageUsed = "storage_used", storageQuota = "storage_quota", createdAt = "created_at"
    }
}

public struct APIErrorBody: Codable, Sendable {
    public struct Inner: Codable, Sendable {
        public var code: String
        public var message: String
        public var details: JSONValue?
    }
    public var error: Inner
}

/// Minimal JSON value for free-form fields (system events, settings).
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

/// Someone in a conversation's always-open voice room.
public struct VoiceParticipant: Codable, Hashable, Identifiable, Sendable {
    public var userID: UUID
    public var deviceID: UUID
    public var name: String
    public var muted: Bool
    public var video: Bool
    public var joinedAt: Date
    public var id: UUID { deviceID }
    enum CodingKeys: String, CodingKey { case name, muted, video, userID = "user_id", deviceID = "device_id", joinedAt = "joined_at" }
    public init(userID: UUID, deviceID: UUID, name: String, muted: Bool, video: Bool, joinedAt: Date) {
        self.userID = userID; self.deviceID = deviceID; self.name = name; self.muted = muted; self.video = video; self.joinedAt = joinedAt
    }
}

public struct VoiceRoomState: Codable, Sendable {
    public var conversationID: UUID
    public var room: String
    public var participants: [VoiceParticipant]
    enum CodingKeys: String, CodingKey { case room, participants, conversationID = "conversation_id" }
}

public struct VoiceJoin: Codable, Sendable {
    public var url: String
    public var token: String
    public var room: String
    public var first: Bool
    public var participants: [VoiceParticipant]
}
