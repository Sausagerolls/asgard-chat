import AsgardKit
import CoreImage.CIFilterBuiltins
import SwiftData
import SwiftUI
import WidgetKit

enum Haptics {
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func send() { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.8) }
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

enum QRCode {
    static func image(_ string: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(string.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Writes a small snapshot of recent chats for the widgets, then reloads them.
enum WidgetBridge {
    @MainActor static func reload(engine: ChatEngine) {
        let d = FetchDescriptor<StoredConversation>(sortBy: [SortDescriptor(\.sortDate, order: .reverse)])
        let convs = ((try? engine.context.fetch(d)) ?? []).filter { !$0.archived && $0.kind != .community }
        let snapshot = WidgetSnapshot(
            unread: convs.reduce(0) { $0 + ($1.isMuted ? 0 : $1.unread) },
            chats: convs.prefix(8).map { c in
                WidgetSnapshot.Chat(id: c.id, title: c.title, preview: UserDefaults.standard.object(forKey: "notifPreview") as? Bool ?? true ? c.previewText : "",
                                    unread: c.unread, date: c.previewDate ?? c.sortDate, kind: c.kind.rawValue, peerID: c.conversation?.peer?.id)
            })
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

struct GlobalSearchView: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var people: [User] = []
    @State private var messages: [StoredMessage] = []
    @Query(sort: [SortDescriptor(\StoredConversation.sortDate, order: .reverse)]) private var chats: [StoredConversation]

    var body: some View {
        NavigationStack {
            List {
                let matchingChats = chats.filter { !query.isEmpty && $0.title.localizedCaseInsensitiveContains(query) }
                if !matchingChats.isEmpty {
                    Section("Chats") { ForEach(matchingChats) { c in Button { open(c.id) } label: { ChatRow(conversation: c) }.buttonStyle(.plain) } }
                }
                if !people.isEmpty {
                    Section("People") {
                        ForEach(people) { u in
                            Button { Task { if let id = try? await engine.openDM(with: u.id) { open(id) } } } label: { UserRow(user: u) }.buttonStyle(.plain)
                        }
                    }
                }
                if !messages.isEmpty {
                    Section("Messages") {
                        ForEach(messages) { m in Button { open(m.conversationID) } label: { MessageSearchRow(message: m, query: query) }.buttonStyle(.plain) }
                    }
                }
            }
            .overlay { if query.isEmpty { ContentUnavailableView("Search Asgard", systemImage: "magnifyingglass", description: Text("Find chats, people on your server and messages on this device.")) } }
            .navigationTitle("Search")
            .searchable(text: $query)
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(200))
                people = query.isEmpty ? [] : await engine.searchUsers(query)
                let needle = query.lowercased()
                if needle.count >= 2 {
                    var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.searchText.contains(needle) }, sortBy: [SortDescriptor(\.sentAt, order: .reverse)])
                    d.fetchLimit = 50
                    messages = (try? engine.context.fetch(d)) ?? []
                } else { messages = [] }
            }
        }
    }

    func open(_ id: UUID) {
        router.selectedTab = .chats
        router.openConversation = id
    }
}
