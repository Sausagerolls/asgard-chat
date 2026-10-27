import Foundation

/// Chat summary the app writes to the app group for widgets and controls.
nonisolated struct WidgetSnapshot: Codable {
    struct Chat: Codable, Identifiable, Hashable {
        var id: UUID
        var title: String
        var preview: String
        var unread: Int
        var date: Date
        var kind: String
        var peerID: UUID?
    }
    var unread: Int
    var chats: [Chat]

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.giantmushroom.asgardchat")?.appending(path: "widget.json")
    }

    func save() {
        guard let url = Self.url, let d = try? JSONEncoder().encode(self) else { return }
        try? d.write(to: url, options: .atomic)
    }

    static func load() -> WidgetSnapshot {
        guard let url, let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: d) else {
            return WidgetSnapshot(unread: 3, chats: [
                .init(id: UUID(), title: "Thor", preview: "I'm bringing the goats 🐐", unread: 2, date: .now, kind: "dm"),
                .init(id: UUID(), title: "Aesir Council", preview: "Valhalla. Better mead.", unread: 1, date: .now, kind: "group"),
                .init(id: UUID(), title: "Freya", preview: "Voice message", unread: 0, date: .now, kind: "dm"),
                .init(id: UUID(), title: "Heimdall", preview: "Someone is approaching…", unread: 0, date: .now, kind: "dm"),
            ])
        }
        return s
    }
}
