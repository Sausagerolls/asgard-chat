import Foundation

/// The decrypted body of a message (`content_json` in docs/PROTOCOL.md).
public struct MessageContent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, media, voice, videoNote = "video_note", location, liveLocation = "live_location", poll, vote, event, rsvp
        case reaction, edit, delete, sticker, gif, contact, callKey = "call_key", callKeyRequest = "call_key_request", historyKey = "history_key", systemNote = "system_note"
    }

    public var v = 1
    public var type: Kind
    public var text: String?
    public var markdown: Bool?
    public var entities: [Entity]?
    public var replyTo: UUID?
    public var target: UUID?
    public var emoji: String?
    public var attachments: [Attachment]?
    public var poll: Poll?
    public var vote: Vote?
    public var event: Event?
    public var rsvp: RSVP?
    public var location: Location?
    public var linkPreviews: [LinkPreview]?
    public var callKey: CallKey?
    /// Recovery key for message history, sent only to the user's own devices.
    public var historyKey: Data?
    public var forwarded: Bool?
    public var silent: Bool?
    public var pinned: Bool?

    enum CodingKeys: String, CodingKey {
        case v, type, text, markdown, entities, target, emoji, attachments, poll, vote, event, rsvp, location, forwarded, silent, pinned
        case replyTo = "reply_to", linkPreviews = "link_previews", callKey = "call_key", historyKey = "history_key"
    }

    public init(type: Kind, text: String? = nil) {
        self.type = type
        self.text = text
    }

    public static func text(_ s: String, replyTo: UUID? = nil) -> Self {
        var c = Self(type: .text, text: s)
        c.replyTo = replyTo
        return c
    }

    public static func reaction(_ emoji: String, to target: UUID) -> Self {
        var c = Self(type: .reaction)
        c.emoji = emoji
        c.target = target
        return c
    }

    public struct Entity: Codable, Hashable, Sendable {
        public var kind: String // mention, mention_all, url, bold, italic, code, spoiler
        public var userID: UUID?
        public var range: [Int]
        enum CodingKeys: String, CodingKey { case kind, range, userID = "user_id" }
        public init(kind: String, userID: UUID? = nil, range: [Int]) { self.kind = kind; self.userID = userID; self.range = range }
    }

    public struct Attachment: Codable, Hashable, Sendable {
        public var mediaID: UUID
        public var mime: String
        public var size: Int
        public var name: String?
        public var key: Data
        public var digest: Data
        public var width: Int?
        public var height: Int?
        public var durationMS: Int?
        public var waveform: Data?
        public var blurhash: String?
        public var thumbnail: Data?
        public var viewOnce: Bool?

        enum CodingKeys: String, CodingKey {
            case mime, size, name, key, digest, width, height, waveform, blurhash, thumbnail
            case mediaID = "media_id", durationMS = "duration_ms", viewOnce = "view_once"
        }

        public init(mediaID: UUID, mime: String, size: Int, name: String? = nil, key: Data, digest: Data, width: Int? = nil, height: Int? = nil,
                    durationMS: Int? = nil, waveform: Data? = nil, thumbnail: Data? = nil, viewOnce: Bool? = nil) {
            self.mediaID = mediaID; self.mime = mime; self.size = size; self.name = name; self.key = key; self.digest = digest
            self.width = width; self.height = height; self.durationMS = durationMS; self.waveform = waveform; self.thumbnail = thumbnail
            self.viewOnce = viewOnce
        }

        public var isImage: Bool { mime.hasPrefix("image/") }
        public var isVideo: Bool { mime.hasPrefix("video/") }
        public var isAudio: Bool { mime.hasPrefix("audio/") }
    }

    public struct Poll: Codable, Hashable, Sendable {
        public struct Option: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var text: String
            public init(id: String, text: String) { self.id = id; self.text = text }
        }
        public var question: String
        public var options: [Option]
        public var multiple: Bool
        public var anonymous: Bool
        public var closesAt: Date?
        enum CodingKeys: String, CodingKey { case question, options, multiple, anonymous, closesAt = "closes_at" }
        public init(question: String, options: [Option], multiple: Bool = false, anonymous: Bool = false, closesAt: Date? = nil) {
            self.question = question; self.options = options; self.multiple = multiple; self.anonymous = anonymous; self.closesAt = closesAt
        }
    }

    public struct Vote: Codable, Hashable, Sendable {
        public var optionIDs: [String]
        enum CodingKeys: String, CodingKey { case optionIDs = "option_ids" }
        public init(optionIDs: [String]) { self.optionIDs = optionIDs }
    }

    public struct Event: Codable, Hashable, Sendable {
        public var title: String
        public var startsAt: Date
        public var endsAt: Date?
        public var location: String?
        public var notes: String?
        enum CodingKeys: String, CodingKey { case title, location, notes, startsAt = "starts_at", endsAt = "ends_at" }
        public init(title: String, startsAt: Date, endsAt: Date? = nil, location: String? = nil, notes: String? = nil) {
            self.title = title; self.startsAt = startsAt; self.endsAt = endsAt; self.location = location; self.notes = notes
        }
    }

    public struct RSVP: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Sendable, CaseIterable { case yes, no, maybe }
        public var status: Status
        public init(status: Status) { self.status = status }
    }

    public struct Location: Codable, Hashable, Sendable {
        public var lat: Double
        public var lon: Double
        public var accuracy: Double?
        public var name: String?
        public var liveUntil: Date?
        enum CodingKeys: String, CodingKey { case lat, lon, accuracy, name, liveUntil = "live_until" }
        public init(lat: Double, lon: Double, accuracy: Double? = nil, name: String? = nil, liveUntil: Date? = nil) {
            self.lat = lat; self.lon = lon; self.accuracy = accuracy; self.name = name; self.liveUntil = liveUntil
        }
    }

    public struct LinkPreview: Codable, Hashable, Sendable {
        public var url: String
        public var title: String?
        public var description: String?
        public var image: Data?
        public init(url: String, title: String? = nil, description: String? = nil, image: Data? = nil) {
            self.url = url; self.title = title; self.description = description; self.image = image
        }
    }

    public struct CallKey: Codable, Hashable, Sendable {
        public var room: String
        public var key: Data
        public init(room: String, key: Data) { self.room = room; self.key = key }
    }
}
