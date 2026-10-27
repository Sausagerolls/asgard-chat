import AsgardKit
import SwiftData
import SwiftUI
import Translation

/// Shared state for one open conversation (reply/edit targets, selection, search).
@MainActor
@Observable
final class ChatSession {
    let conversationID: UUID
    var replyTo: StoredMessage?
    var editing: StoredMessage?
    var reacting: StoredMessage?
    var infoFor: StoredMessage?
    var forwarding: [StoredMessage] = []
    var viewer: MediaViewerItem?
    var threadRoot: StoredMessage?
    var translateText: String?
    var searching = false
    var searchQuery = ""
    var selecting = false
    var selected: Set<UUID> = []
    var scrollTarget: UUID?
    var highlight: UUID?

    init(conversationID: UUID) { self.conversationID = conversationID }

    func jump(to id: UUID) {
        scrollTarget = id
        highlight = id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if highlight == id { highlight = nil }
        }
    }
}

struct MediaViewerItem: Identifiable {
    let id = UUID()
    let message: StoredMessage
    let index: Int
}

struct ChatView: View {
    let conversationID: UUID
    @Environment(ChatEngine.self) private var engine
    @Environment(CallManager.self) private var calls
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @State private var session: ChatSession
    @State private var showInfo = false
    @State private var unlocked = false
    @State private var summary: String?
    @State private var summarizing = false
    @Query private var pinned: [StoredMessage]

    init(conversationID: UUID) {
        self.conversationID = conversationID
        _session = State(initialValue: ChatSession(conversationID: conversationID))
        _pinned = Query(filter: #Predicate<StoredMessage> { $0.conversationID == conversationID && $0.isPinned }, sort: \StoredMessage.sortKey, order: .reverse)
    }

    var stored: StoredConversation? { engine.storedConversation(conversationID) }
    var conversation: Conversation? { stored?.conversation }
    var locked: Bool { stored?.locked == true && !unlocked }

    var body: some View {
        ZStack {
            ChatWallpaper(wallpaper: Wallpaper(rawValue: stored?.wallpaper ?? "") ?? appearance.wallpaper, animated: appearance.animatedBackgrounds)
            if locked {
                LockedChatView { unlocked = true }
            } else {
                MessageList(conversationID: conversationID, kind: stored?.kind ?? .group)
                    .safeAreaInset(edge: .top, spacing: 0) { topInsets }
                    .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            }
        }
        .environment(session)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $showInfo) { ChatInfoView(conversationID: conversationID) }
        .sheet(item: Binding(get: { session.reacting }, set: { session.reacting = $0 })) { m in
            EmojiPickerSheet { emoji in Task { await engine.react(emoji, to: m) }; session.reacting = nil }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { session.infoFor }, set: { session.infoFor = $0 })) { m in
            MessageInfoSheet(message: m).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { !session.forwarding.isEmpty }, set: { if !$0 { session.forwarding = [] } })) {
            ForwardSheet(messages: session.forwarding) { session.forwarding = []; session.selecting = false; session.selected = [] }
        }
        .sheet(item: Binding(get: { session.threadRoot }, set: { session.threadRoot = $0 })) { root in
            ThreadView(root: root).environment(session)
        }
        .fullScreenCover(item: Binding(get: { session.viewer }, set: { session.viewer = $0 })) { item in
            MediaViewer(message: item.message, startIndex: item.index)
        }
        .translationPresentation(isPresented: Binding(get: { session.translateText != nil }, set: { if !$0 { session.translateText = nil } }),
                                 text: session.translateText ?? "")
        .onAppear {
            engine.activeConversation = conversationID
            engine.markRead(conversationID)
        }
        .onDisappear {
            if engine.activeConversation == conversationID { engine.activeConversation = nil }
            engine.setTyping(conversationID, state: "stopped")
        }
        .task { await engine.loadOlder(conversationID) }
        .task { readMarks() }
    }

    func readMarks() {
        Task { _ = await engine.members(conversationID) }
    }

    @ViewBuilder var topInsets: some View {
        VStack(spacing: 6) {
            if let p = pinned.first {
                PinnedBanner(message: p, count: pinned.count) { session.jump(to: p.id) }
            }
            if conversation?.hasServerBot == true {
                Label("A server webhook is in this chat. Your server can read messages here.", systemImage: "exclamationmark.shield")
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular.tint(.orange.opacity(0.3)), in: .capsule)
            }
            if let summary {
                CatchUpCard(text: summary) { withAnimation { self.summary = nil } }
            } else if (stored?.unread ?? 0) >= 5 || summarizing {
                Button { Task { await catchUp() } } label: {
                    Label(summarizing ? "Catching up…" : "Catch me up", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .disabled(summarizing || !Intelligence.isAvailable)
                .opacity(Intelligence.isAvailable ? 1 : 0)
            }
            if session.searching { ChatSearchBar() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    @ViewBuilder var bottomBar: some View {
        if session.selecting {
            SelectionBar()
        } else if let c = conversation, c.kind == .channel, !(c.me?.permissions.contains(.send) ?? false) {
            ChannelFooter(conversation: c)
        } else {
            Composer(conversationID: conversationID)
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button { showInfo = true } label: { ChatHeader(conversationID: conversationID) }.buttonStyle(.plain)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let c = conversation, c.kind == .dm || c.kind == .group {
                Button { Task { await calls.start(conversationID, video: true) } } label: { Image(systemName: "video") }
                    .accessibilityLabel("Video call")
                Button { Task { await calls.start(conversationID, video: false) } } label: { Image(systemName: "phone") }
                    .accessibilityLabel("Voice call")
            }
            Menu {
                Button { withAnimation { session.searching.toggle() } } label: { Label("Search", systemImage: "magnifyingglass") }
                Button { session.selecting = true } label: { Label("Select messages", systemImage: "checkmark.circle") }
                Button { showInfo = true } label: { Label("Chat info", systemImage: "info.circle") }
            } label: { Image(systemName: "ellipsis") }
        }
    }

    func catchUp() async {
        summarizing = true
        defer { summarizing = false }
        let conv = conversationID
        var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationID == conv }, sortBy: [SortDescriptor(\.sortKey, order: .reverse)])
        d.fetchLimit = max(20, min(120, (stored?.unread ?? 0) + 10))
        let msgs = ((try? engine.context.fetch(d)) ?? []).reversed().compactMap { m -> String? in
            guard let t = m.content?.text, !t.isEmpty else { return nil }
            return "\(engine.name(m.senderUserID)): \(t)"
        }
        let result = await Intelligence.summarize(chat: stored?.title ?? "chat", lines: msgs)
        withAnimation { summary = result }
    }
}

struct ChatHeader: View {
    let conversationID: UUID
    @Environment(ChatEngine.self) private var engine

    var body: some View {
        let sc = engine.storedConversation(conversationID)
        HStack(spacing: 8) {
            if let sc { sc.avatar(engine: engine, size: 34) }
            VStack(alignment: .leading, spacing: 0) {
                Text(sc?.title ?? "").font(.headline).lineLimit(1)
                Text(subtitle(sc)).font(.caption).foregroundStyle(isTyping ? Color.accentColor : .secondary).lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.default, value: subtitle(sc))
    }

    var isTyping: Bool { !(engine.typing[conversationID]?.isEmpty ?? true) }

    func subtitle(_ sc: StoredConversation?) -> String {
        guard let sc, let c = sc.conversation else { return "" }
        if let t = engine.typing[conversationID], let first = t.first {
            let what = first.value.state == "recording" ? "recording audio" : first.value.state == "uploading" ? "sending a file" : "typing"
            return c.kind == .dm ? "\(what)…" : t.count > 1 ? "\(t.count) people are typing…" : "\(engine.name(first.key)) is \(what)…"
        }
        switch c.kind {
        case .dm:
            guard let peer = c.peer else { return "" }
            if peer.isBot { return "bot" }
            let p = engine.presence[peer.id]
            if p?.online ?? peer.online { return "online" }
            if let seen = p?.lastSeen ?? peer.lastSeenAt { return "last seen " + seen.formatted(.relative(presentation: .named)) }
            return "@" + peer.username
        case .channel: return "\(c.memberCount) subscribers"
        case .saved: return "Notes to self"
        default:
            let online = 0
            return "\(c.memberCount) members" + (online > 0 ? ", \(online) online" : "")
        }
    }
}

struct PinnedBanner: View {
    let message: StoredMessage
    let count: Int
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Capsule().fill(Color.accentColor).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(count > 1 ? "Pinned message · \(count)" : "Pinned message").font(.caption.bold()).foregroundStyle(Color.accentColor)
                    Text(message.content.map(ChatEngine.preview) ?? "").font(.subheadline).lineLimit(1)
                }
                Spacer()
                Image(systemName: "pin.fill").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }
}

struct CatchUpCard: View {
    let text: String
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Summary", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(Brand.aurora)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.caption.bold()) }.buttonStyle(.plain)
            }
            Text(text).font(.subheadline)
            Text("Generated on this iPhone. Nothing left your device.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct ChannelFooter: View {
    let conversation: Conversation
    @Environment(ChatEngine.self) private var engine
    var body: some View {
        let muted = (conversation.me?.mutedUntil ?? .distantPast) > .now
        Button {
            Task { await engine.setPrefs(conversation.id, muted ? .init(unmute: true) : .init(mutedUntil: .distantFuture)) }
        } label: {
            Label(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.glass)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}

struct LockedChatView: View {
    var onUnlock: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(Brand.aurora)
            Text("This chat is locked").font(.title3.bold())
            Button("Unlock with Face ID") {
                Task { if await AppLock.authenticate(reason: "Unlock this chat") { onUnlock() } }
            }
            .buttonStyle(.glassProminent)
        }
        .task { if await AppLock.authenticate(reason: "Unlock this chat") { onUnlock() } }
    }
}

struct ChatSearchBar: View {
    @Environment(ChatSession.self) private var session
    @Environment(ChatEngine.self) private var engine
    @State private var results: [StoredMessage] = []
    @State private var index = 0

    var body: some View {
        @Bindable var session = session
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search in chat", text: $session.searchQuery).submitLabel(.search)
            if !results.isEmpty {
                Text("\(index + 1) of \(results.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { step(1) } label: { Image(systemName: "chevron.up") }
                Button { step(-1) } label: { Image(systemName: "chevron.down") }
            }
            Button("Done") { withAnimation { session.searching = false; session.searchQuery = "" } }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .onChange(of: session.searchQuery) { _, q in
            let needle = q.lowercased()
            let conv = session.conversationID
            guard needle.count >= 2 else { results = []; return }
            results = (try? engine.context.fetch(FetchDescriptor<StoredMessage>(
                predicate: #Predicate { $0.conversationID == conv && $0.searchText.contains(needle) }, sortBy: [SortDescriptor(\.sortKey, order: .reverse)]))) ?? []
            index = 0
            if let first = results.first { session.jump(to: first.id) }
        }
    }

    func step(_ d: Int) {
        guard !results.isEmpty else { return }
        index = (index + d + results.count) % results.count
        session.jump(to: results[index].id)
    }
}

struct SelectionBar: View {
    @Environment(ChatSession.self) private var session
    @Environment(ChatEngine.self) private var engine

    var selectedMessages: [StoredMessage] {
        session.selected.compactMap { id in
            (try? engine.context.fetch(FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.clientID == id })))?.first
        }.sorted { $0.sortKey < $1.sortKey }
    }

    var body: some View {
        HStack {
            Button("Cancel") { session.selecting = false; session.selected = [] }
            Spacer()
            Text("\(session.selected.count) selected").font(.headline)
            Spacer()
            Button { UIPasteboard.general.string = selectedMessages.compactMap { $0.content?.text }.joined(separator: "\n") } label: { Image(systemName: "doc.on.doc") }
            Button { session.forwarding = selectedMessages } label: { Image(systemName: "arrowshape.turn.up.right") }
            Button(role: .destructive) {
                selectedMessages.forEach(engine.deleteForMe)
                session.selected = []
                session.selecting = false
            } label: { Image(systemName: "trash") }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12).padding(.bottom, 6)
        .disabled(session.selected.isEmpty && false)
    }
}
