import ActivityKit
import Foundation

/// Live Activity for an ongoing call (Dynamic Island + Lock Screen).
nonisolated struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var connectedAt: Date?
        var muted: Bool
        var video: Bool
        var participants: Int
    }
    var conversationID: String
    var title: String
}
