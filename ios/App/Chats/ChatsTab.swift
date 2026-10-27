import AsgardKit
import SwiftData
import SwiftUI

enum ChatFolder: Hashable, Identifiable {
    case all, unread, people, groups, channels, communities, custom(String)
    var id: String { title }
    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .people: "People"
        case .groups: "Groups"
        case .channels: "Channels"
        case .communities: "Communities"
        case .custom(let s): s
        }
    }

    func includes(_ c: StoredConversation) -> Bool {
        switch self {
        case .all: true
        case .unread: c.unread > 0 || c.markedUnread
        case .people: c.kind == .dm || c.kind == .saved
        case .groups: c.kind == .group
        case .channels: c.kind == .channel
        case .communities: c.kind == .community || c.communityID != nil
        case .custom(let s): c.folder == s
        }
    }
}

struct ChatsTab: View {
    @Environment(Router.self) private var router
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ChatListView(path: $path)
                .navigationDestination(for: UUID.self) { ChatView(conversationID: $0) }
                .navigationDestination(for: CommunityRoute.self) { CommunityView(communityID: $0.id, path: $path) }
                .navigationDestination(for: ArchivedRoute.self) { _ in ArchivedChatsView(path: $path) }
        }
        .onChange(of: router.openConversation, initial: true) { _, id in
            guard let id else { return }
            path = NavigationPath()
            path.append(id)
            router.openConversation = nil
        }
    }
}

struct CommunityRoute: Hashable { var id: UUID }
struct ArchivedRoute: Hashable {}

struct ChatListView: View {
    @Binding var path: NavigationPath
    @Environment(ChatEngine.self) private var engine
    @Environment(Router.self) private var router
    @Query(sort: [SortDescriptor(\StoredConversation.sortDate, order: .reverse)]) private var all: [StoredConversation]
    @State private var folder: ChatFolder = .all
    @State private var search = ""
    @State private var searchResults: [StoredMessage] = []
    @State private var showNewChat = false
    @AppStorage("customFolders") private var customFoldersRaw = ""

    var customFolders: [String] { customFoldersRaw.split(separator: "|").map(String.init) }

    var visible: [StoredConversation] {
        all.filter { c in
            !c.archived && folder.includes(c) && (folder == .communities || c.kind != .community || folder == .all)
                && (search.isEmpty || c.title.localizedCaseInsensitiveContains(search))
        }
        .sorted { a, b in a.pinned != b.pinned ? a.pinned : a.sortDate > b.sortDate }
    }

    var archivedCount: Int { all.filter(\.archived).count }

    var body: some View {
        List {
            if search.isEmpty {
                StoriesStrip()
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                FolderBar(selection: $folder, custom: customFolders)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                if archivedCount > 0 && folder == .all {
                    NavigationLink(value: ArchivedRoute()) {
                        Label("Archived", systemImage: "archivebox").badge(archivedCount)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            ForEach(visible) { c in
                Button {
                    if c.kind == .community { path.append(CommunityRoute(id: c.id)) } else { path.append(c.id) }
                } label: {
                    ChatRow(conversation: c)
                }
                .buttonStyle(.plain)
                .listRowBackground(c.pinned ? Color.accentColor.opacity(0.06) : Color.clear)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if c.unread > 0 || c.markedUnread {
                        Button { engine.markRead(c.id) } label: { Label("Read", systemImage: "message.badge.filled.fill") }.tint(.blue)
                    } else {
                        Button { engine.markUnread(c.id) } label: { Label("Unread", systemImage: "message.badge") }.tint(.blue)
                    }
                    Button { Task { await engine.setPrefs(c.id, .init(pinned: !c.pinned)) } } label: {
                        Label(c.pinned ? "Unpin" : "Pin", systemImage: c.pinned ? "pin.slash.fill" : "pin.fill")
                    }.tint(.orange)
                }
                .swipeActions(edge: .trailing) {
                    if c.kind != .saved {
                        Button { Task { await engine.setPrefs(c.id, .init(archived: true)) } } label: { Label("Archive", systemImage: "archivebox.fill") }.tint(.indigo)
                    }
                    Button {
                        Task { await engine.setPrefs(c.id, c.isMuted ? .init(unmute: true) : .init(mutedUntil: .distantFuture)) }
                    } label: {
                        Label(c.isMuted ? "Unmute" : "Mute", systemImage: c.isMuted ? "bell.fill" : "bell.slash.fill")
                    }.tint(.gray)
                }
                .contextMenu {
                    ChatRowMenu(conversation: c, customFolders: customFolders)
                } preview: {
                    ChatPreview(conversationID: c.id).frame(width: 340, height: 460)
                }
            }
            if !search.isEmpty && !searchResults.isEmpty {
                Section("Messages") {
                    ForEach(searchResults) { m in
                        Button { path.append(m.conversationID) } label: { MessageSearchRow(message: m, query: search) }.buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AuroraBackground(intensity: 0.35))
        .overlay {
            if visible.isEmpty && search.isEmpty {
                ContentUnavailableView {
                    Label(folder == .all ? "No chats yet" : "Nothing in \(folder.title)", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a conversation with someone on your server.")
                } actions: {
                    Button("New chat") { showNewChat = true }.buttonStyle(.glassProminent)
                }
            }
        }
        .navigationTitle("Chats")
        .searchable(text: $search, prompt: "Search chats and messages")
        .onChange(of: search) { _, q in searchMessages(q) }
        .refreshable { await engine.refreshAll() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button { all.forEach { engine.markRead($0.id) } } label: { Label("Read all", systemImage: "checkmark.message") }
                    Menu("New folder") { FolderEditor(raw: $customFoldersRaw) }
                } label: { Image(systemName: "ellipsis") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewChat = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New chat")
            }
        }
        .sheet(isPresented: $showNewChat) {
            NewChatSheet { id in
                showNewChat = false
                path.append(id)
            }
        }
        .onChange(of: router.composeTo) { _, id in
            if let id { path.append(id); router.composeTo = nil }
        }
    }

    func searchMessages(_ q: String) {
        let needle = q.lowercased()
        guard needle.count >= 2 else { searchResults = []; return }
        var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.searchText.contains(needle) }, sortBy: [SortDescriptor(\.sentAt, order: .reverse)])
        d.fetchLimit = 40
        searchResults = (try? engine.context.fetch(d)) ?? []
    }
}

struct FolderEditor: View {
    @Binding var raw: String
    @State private var name = ""
    var body: some View {
        ForEach(["Family", "Work", "Friends", "Gaming"], id: \.self) { n in
            Button(n) { add(n) }
        }
    }
    func add(_ n: String) {
        var set = raw.split(separator: "|").map(String.init)
        if !set.contains(n) { set.append(n) }
        raw = set.joined(separator: "|")
    }
}

struct FolderBar: View {
    @Binding var selection: ChatFolder
    var custom: [String]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach([ChatFolder.all, .unread, .people, .groups, .channels, .communities] + custom.map(ChatFolder.custom)) { f in
                        Button { withAnimation(.snappy) { selection = f } } label: {
                            Text(f.title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 7)
                                .foregroundStyle(selection == f ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(selection == f ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct ChatRow: View {
    let conversation: StoredConversation
    @Environment(ChatEngine.self) private var engine

    var typingText: String? {
        guard let t = engine.typing[conversation.id], let (user, state) = t.first else { return nil }
        let who = conversation.kind == .dm ? "" : engine.name(user) + " "
        switch state.state {
        case "recording": return who + "is recording audio…"
        case "uploading": return who + "is sending a file…"
        default: return conversation.kind == .dm ? "typing…" : who + "is typing…"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            conversation.avatar(engine: engine, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if conversation.kind == .channel { Image(systemName: "megaphone.fill").font(.caption).foregroundStyle(.secondary) }
                    Text(conversation.title.isEmpty ? "Chat" : conversation.title).font(.headline).lineLimit(1)
                    if conversation.conversation?.peer?.isBot == true {
                        Text("BOT").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.secondary.opacity(0.2), in: .capsule)
                    }
                    if conversation.isMuted { Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary) }
                    if (conversation.conversation?.disappearingSeconds ?? 0) > 0 { Image(systemName: "timer").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    if let d = conversation.previewDate ?? Optional(conversation.sortDate) {
                        Text(d.chatListStamp).font(.caption).foregroundStyle(conversation.unread > 0 && !conversation.isMuted ? Color.accentColor : .secondary)
                    }
                }
                HStack(alignment: .top, spacing: 4) {
                    Group {
                        if let typingText {
                            Text(typingText).foregroundStyle(Color.accentColor).italic()
                        } else if !conversation.draft.isEmpty {
                            (Text("Draft: ").foregroundStyle(.red) + Text(conversation.draft).foregroundStyle(.secondary))
                        } else {
                            previewText.foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline).lineLimit(2)
                    Spacer(minLength: 4)
                    if conversation.pinned && conversation.unread == 0 { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).rotationEffect(.degrees(45)) }
                    if conversation.unread > 0 || conversation.markedUnread {
                        Text(conversation.unread > 0 ? "\(conversation.unread)" : " ")
                            .font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                            .background(conversation.isMuted ? AnyShapeStyle(.gray) : AnyShapeStyle(Color.accentColor), in: .capsule)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    var previewText: Text {
        let p = conversation.previewText.isEmpty ? (conversation.kind == .channel ? "Channel created" : "No messages yet") : conversation.previewText
        if let s = conversation.previewSenderID, conversation.kind != .dm && conversation.kind != .saved || s == engine.myID {
            return Text(engine.name(s) + ": ").foregroundStyle(.primary) + Text(p)
        }
        return Text(p)
    }
}

struct ChatRowMenu: View {
    let conversation: StoredConversation
    let customFolders: [String]
    @Environment(ChatEngine.self) private var engine

    var body: some View {
        Button { Task { await engine.setPrefs(conversation.id, .init(pinned: !conversation.pinned)) } } label: {
            Label(conversation.pinned ? "Unpin" : "Pin", systemImage: "pin")
        }
        Button { conversation.unread > 0 ? engine.markRead(conversation.id) : engine.markUnread(conversation.id) } label: {
            Label(conversation.unread > 0 ? "Mark as read" : "Mark as unread", systemImage: "message.badge")
        }
        Menu {
            Button("1 hour") { mute(3600) }
            Button("8 hours") { mute(8 * 3600) }
            Button("1 week") { mute(7 * 86400) }
            Button("Always") { Task { await engine.setPrefs(conversation.id, .init(mutedUntil: .distantFuture)) } }
            if conversation.isMuted { Button("Unmute") { Task { await engine.setPrefs(conversation.id, .init(unmute: true)) } } }
        } label: { Label("Mute", systemImage: "bell.slash") }
        if !customFolders.isEmpty {
            Menu {
                ForEach(customFolders, id: \.self) { f in
                    Button { Task { await engine.setPrefs(conversation.id, .init(folder: conversation.folder == f ? "" : f)) } } label: {
                        if conversation.folder == f { Label(f, systemImage: "checkmark") } else { Text(f) }
                    }
                }
            } label: { Label("Add to folder", systemImage: "folder") }
        }
        Button { Task { await engine.setPrefs(conversation.id, .init(archived: !conversation.archived)) } } label: {
            Label(conversation.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
        }
        if conversation.kind != .saved {
            Divider()
            Button(role: .destructive) { engine.clearHistory(conversation.id) } label: { Label("Clear history", systemImage: "trash") }
        }
    }

    func mute(_ s: TimeInterval) { Task { await engine.setPrefs(conversation.id, .init(mutedUntil: .now.addingTimeInterval(s))) } }
}

/// Peek preview for the context menu.
struct ChatPreview: View {
    let conversationID: UUID
    @Query private var messages: [StoredMessage]
    @Environment(Appearance.self) private var appearance

    init(conversationID: UUID) {
        self.conversationID = conversationID
        var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationID == conversationID }, sortBy: [SortDescriptor(\.sortKey, order: .reverse)])
        d.fetchLimit = 12
        _messages = Query(d)
    }

    var body: some View {
        ZStack {
            ChatWallpaper(wallpaper: appearance.wallpaper, animated: false)
            VStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(messages.reversed()) { m in
                    MessageBubble(message: m, grouping: .single, isGroup: false, compact: true)
                }
            }
            .padding(8)
        }
    }
}

struct MessageSearchRow: View {
    let message: StoredMessage
    let query: String
    @Environment(ChatEngine.self) private var engine
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(engine.storedConversation(message.conversationID)?.title ?? "").font(.subheadline.bold())
                Spacer()
                Text(message.sentAt.chatListStamp).font(.caption).foregroundStyle(.secondary)
            }
            Text(engine.name(message.senderUserID) + ": " + (message.content?.text ?? ChatEngine.preview(message.content ?? .text(""))))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

struct ArchivedChatsView: View {
    @Binding var path: NavigationPath
    @Query(filter: #Predicate<StoredConversation> { $0.archived }, sort: \StoredConversation.sortDate, order: .reverse) private var archived: [StoredConversation]
    @Environment(ChatEngine.self) private var engine
    var body: some View {
        List(archived) { c in
            Button { path.append(c.id) } label: { ChatRow(conversation: c) }.buttonStyle(.plain)
                .swipeActions { Button("Unarchive") { Task { await engine.setPrefs(c.id, .init(archived: false)) } }.tint(.indigo) }
        }
        .listStyle(.plain)
        .navigationTitle("Archived")
    }
}

extension Date {
    var chatListStamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: self, to: .now).day, days < 7 { return formatted(.dateTime.weekday(.wide)) }
        return formatted(date: .numeric, time: .omitted)
    }
}
