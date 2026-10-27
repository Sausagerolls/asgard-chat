import AppIntents
import AsgardKit
import SwiftData
import SwiftUI

/// A conversation exposed to Shortcuts, Siri and Spotlight.
struct ConversationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chat"
    static let defaultQuery = ConversationQuery()
    var id: UUID
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct ConversationQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [ConversationEntity] {
        identifiers.compactMap { id in AppServices.shared.engine.storedConversation(id).map { ConversationEntity(id: $0.id, title: $0.title) } }
    }

    @MainActor func entities(matching string: String) async throws -> [ConversationEntity] {
        try await suggestedEntities().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    @MainActor func suggestedEntities() async throws -> [ConversationEntity] {
        let d = FetchDescriptor<StoredConversation>(sortBy: [SortDescriptor(\.sortDate, order: .reverse)])
        return ((try? AppServices.shared.engine.context.fetch(d)) ?? []).filter { $0.kind != .community }.prefix(30).map { ConversationEntity(id: $0.id, title: $0.title) }
    }
}

struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Asgard message"
    static let description = IntentDescription("Sends an end-to-end encrypted message.")
    @Parameter(title: "Chat") var chat: ConversationEntity
    @Parameter(title: "Message") var text: String

    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$text) to \(\.$chat)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let engine = AppServices.shared.engine
        if engine.phase == .loading { await engine.start() }
        let row = await engine.send(.text(text), to: chat.id)
        return .result(dialog: row.status == .failed ? "Couldn't send. I'll retry when you're online." : "Sent to \(chat.title).")
    }
}

struct OpenConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Asgard chat"
    static let openAppWhenRun = true
    @Parameter(title: "Chat") var chat: ConversationEntity

    @MainActor func perform() async throws -> some IntentResult {
        AppServices.shared.router.openConversation = chat.id
        return .result()
    }
}

struct StartCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Call on Asgard"
    static let openAppWhenRun = true
    @Parameter(title: "Chat") var chat: ConversationEntity
    @Parameter(title: "Video", default: false) var video: Bool

    @MainActor func perform() async throws -> some IntentResult {
        await AppServices.shared.calls.start(chat.id, video: video)
        return .result()
    }
}

struct UnreadCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Asgard unread count"
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let n = ((try? AppServices.shared.engine.context.fetch(FetchDescriptor<StoredConversation>())) ?? []).reduce(0) { $0 + ($1.isMuted ? 0 : $1.unread) }
        return .result(value: n, dialog: n == 0 ? "You're all caught up." : "You have \(n) unread messages.")
    }
}

/// Focus filter: choose which chat folders can notify during a Focus.
struct AsgardFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Asgard chats"
    static let description: IntentDescription? = IntentDescription("Only show chats from selected folders during this Focus.")
    @Parameter(title: "Allowed folder", default: "Work") var folder: String
    @Parameter(title: "Allow direct messages", default: true) var allowDMs: Bool

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Folder: \(folder)") }

    func perform() async throws -> some IntentResult {
        AppGroup.defaults.set(folder, forKey: "focusFolder")
        AppGroup.defaults.set(allowDMs, forKey: "focusAllowDMs")
        return .result()
    }
}

struct AsgardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendMessageIntent(), phrases: ["Send a message with \(.applicationName)", "Message \(\.$chat) on \(.applicationName)"],
                    shortTitle: "Send message", systemImageName: "paperplane.fill")
        AppShortcut(intent: OpenConversationIntent(), phrases: ["Open \(\.$chat) in \(.applicationName)"], shortTitle: "Open chat", systemImageName: "bubble.left.fill")
        AppShortcut(intent: StartCallIntent(), phrases: ["Call \(\.$chat) on \(.applicationName)"], shortTitle: "Call", systemImageName: "phone.fill")
        AppShortcut(intent: UnreadCountIntent(), phrases: ["Do I have \(.applicationName) messages"], shortTitle: "Unread", systemImageName: "envelope.badge")
    }
}
