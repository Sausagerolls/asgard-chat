import AsgardKit
import SwiftData
import SwiftUI

enum MacFolder: Hashable, Identifiable {
    case all, unread, people, groups, channels, archived, custom(String), community(UUID)
    static let builtIn: [MacFolder] = [.all, .unread, .people, .groups, .channels]
    var id: String { title + (communityID?.lower ?? "") }
    var communityID: UUID? { if case .community(let id) = self { id } else { nil } }

    var title: String {
        switch self {
        case .all: "All Chats"
        case .unread: "Unread"
        case .people: "People"
        case .groups: "Groups"
        case .channels: "Channels"
        case .archived: "Archived"
        case .custom(let s): s
        case .community: "Community"
        }
    }

    var shortTitle: String { self == .all ? "All" : title }

    var icon: String {
        switch self {
        case .all: "bubble.left.and.bubble.right"
        case .unread: "envelope.badge"
        case .people: "person.2"
        case .groups: "person.3"
        case .channels: "megaphone"
        case .archived: "archivebox"
        case .custom: "folder"
        case .community: "person.3.sequence"
        }
    }

    func includes(_ c: StoredConversation) -> Bool {
        if case .archived = self { return c.archived }
        if c.archived { return false }
        switch self {
        case .all: return c.kind != .community
        case .unread: return c.unread > 0 || c.markedUnread
        case .people: return c.kind == .dm || c.kind == .saved
        case .groups: return c.kind == .group
        case .channels: return c.kind == .channel
        case .custom(let s): return c.folder == s
        case .community(let id): return c.communityID == id
        case .archived: return false
        }
    }
}

struct MacRootView: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(MacCallManager.self) private var calls
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch engine.phase {
            case .loading:
                ZStack { AuroraBackground(); ProgressView().controlSize(.large) }
            case .signedOut:
                MacOnboarding()
            case .ready:
                MacMainView()
            }
        }
        .onChange(of: calls.active != nil) { _, on in if on { openWindow(id: "call") } }
        .sheet(item: Binding(get: { calls.ringing }, set: { calls.ringing = $0 })) { call in IncomingCallSheet(call: call) }
    }
}

struct MacMainView: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(MacNavigator.self) private var nav
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView(columnVisibility: $columns) {
            MacChatList()
                .navigationSplitViewColumnWidth(min: 290, ideal: 340, max: 460)
        } detail: {
            if let id = nav.selection, engine.storedConversation(id) != nil {
                MacChatView(conversationID: id)
                    .id(id)
                    .inspector(isPresented: $nav.showInspector) {
                        MacChatInfo(conversationID: id)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                    }
            } else {
                MacEmptyDetail()
            }
        }
        .sheet(isPresented: $nav.showNewChat) { MacNewChatSheet() }
        .overlay(alignment: .bottom) {
            if let banner = engine.banner {
                Text(banner).padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 24)
                    .task { try? await Task.sleep(for: .seconds(4)); engine.banner = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: engine.banner)
    }
}

struct MacEmptyDetail: View {
    @Environment(MacNavigator.self) private var nav
    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.6)
            VStack(spacing: 14) {
                Image("BrandMark").resizable().scaledToFit().frame(width: 96)
                Text("Asgard").font(.largeTitle.bold())
                Text("Pick a chat, or start a new one.").foregroundStyle(.secondary)
                Button { nav.showNewChat = true } label: { Label("New Chat", systemImage: "square.and.pencil").padding(.horizontal, 6) }
                    .buttonStyle(.glassProminent).controlSize(.large)
                Text("⌘N new chat · ⌘1–5 folders · ⌘I chat info · ⌘L write").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

struct MacAccountBar: View {
    @Environment(ChatEngine.self) private var engine
    var body: some View {
        SettingsLink {
            bar.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Profile and Settings (⌘,)")
        .padding(8)
    }

    var bar: some View {
        HStack(spacing: 10) {
            AvatarView(id: engine.myID, name: engine.me?.displayName ?? "", mediaID: engine.me?.avatarMediaID, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(engine.me?.displayName ?? "").font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(engine.connection == .connected || engine.isDemo ? Brand.teal : .orange).frame(width: 6, height: 6)
                    Text(engine.isDemo ? "Demo" : engine.connection == .connected ? (engine.account?.serverURL.host() ?? "") : "Connecting…")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "gearshape").foregroundStyle(.secondary)
        }
        .padding(10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }
}

struct MacChatList: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(MacNavigator.self) private var nav
    @Query(sort: [SortDescriptor(\StoredConversation.sortDate, order: .reverse)]) private var all: [StoredConversation]
    @State private var search = ""
    @State private var messageHits: [StoredMessage] = []
    @State private var showHistory = false

    var visible: [StoredConversation] {
        all.filter { nav.folder.includes($0) && $0.kind != .community && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
            .sorted { a, b in a.pinned != b.pinned ? a.pinned : a.sortDate > b.sortDate }
    }

    var body: some View {
        @Bindable var nav = nav
        let live = all.filter { !engine.voiceParticipants($0.id).isEmpty }
        List(selection: $nav.selection) {
            if search.isEmpty && !live.isEmpty {
                Section("Live Now") {
                    ForEach(live) { c in
                        HStack {
                            Label(c.title, systemImage: "speaker.wave.2.fill").foregroundStyle(Brand.teal).lineLimit(1)
                            Spacer()
                            FacePileMini(people: engine.voiceParticipants(c.id))
                        }
                        .tag(c.id)
                    }
                }
            }
            ForEach(visible) { c in
                MacChatRow(conversation: c)
                    .tag(c.id)
                    .contextMenu { MacChatMenu(conversation: c) }
            }
            if !messageHits.isEmpty {
                Section("Messages") {
                    ForEach(messageHits) { m in
                        Button { nav.open(m.conversationID) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(engine.storedConversation(m.conversationID)?.title ?? "").font(.caption.weight(.semibold))
                                Text(m.content?.text ?? "").lineLimit(2).font(.callout)
                                Text(m.sentAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HistoryNudge { showHistory = true }.padding(.horizontal, 10).padding(.top, 6)
                MacFolderBar(all: all)
            }
        }
        .sheet(isPresented: $showHistory) { NavigationStack { HistorySettingsView(showsDone: true) }.frame(width: 540, height: 600) }
        .safeAreaInset(edge: .bottom, spacing: 0) { MacAccountBar() }
        .overlay {
            if visible.isEmpty && messageHits.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No chats here" : "No results", systemImage: nav.folder.icon)
            }
        }
        .searchable(text: $search, isPresented: $nav.searching, placement: .sidebar, prompt: "Search chats and messages")
        .task(id: search) {
            let needle = search.lowercased()
            guard needle.count >= 2 else { messageHits = []; return }
            try? await Task.sleep(for: .milliseconds(200))
            var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.searchText.contains(needle) }, sortBy: [SortDescriptor(\.sentAt, order: .reverse)])
            d.fetchLimit = 30
            messageHits = (try? engine.context.fetch(d)) ?? []
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { nav.showNewChat = true } label: { Image(systemName: "square.and.pencil") }.help("New Chat (⌘N)")
            }
        }
        .onChange(of: nav.selection) { _, id in if let id { engine.markRead(id); MacServices.shared.updateBadge() } }
    }
}

/// Folder chips at the top of the single sidebar.
struct MacFolderBar: View {
    let all: [StoredConversation]
    @Environment(ChatEngine.self) private var engine
    @Environment(MacNavigator.self) private var nav
    @AppStorage("customFolders") private var customFoldersRaw = ""

    var body: some View {
        let communities = all.filter { $0.kind == .community && !$0.archived }
        let folders = MacFolder.builtIn + customFoldersRaw.split(separator: "|").map { MacFolder.custom(String($0)) }
            + communities.map { MacFolder.community($0.id) } + [.archived]
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(folders) { f in
                    let selected = nav.folder == f
                    let n = all.filter { f.includes($0) && !$0.isMuted }.reduce(0) { $0 + $1.unread }
                    Button { withAnimation(.snappy) { nav.folder = f } } label: {
                        HStack(spacing: 4) {
                            Text(f.communityID.flatMap { engine.storedConversation($0)?.title } ?? f.shortTitle)
                            if n > 0 { Text("\(n)").font(.caption2.weight(.bold)).monospacedDigit().opacity(0.8) }
                        }
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.secondary.opacity(0.14)), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

struct FacePileMini: View {
    let people: [VoiceParticipant]
    var body: some View {
        HStack(spacing: -6) {
            ForEach(people.prefix(3)) { p in AvatarView(id: p.userID, name: p.name, size: 18).overlay(Circle().stroke(.background, lineWidth: 1.5)) }
        }
    }
}

struct MacChatRow: View {
    let conversation: StoredConversation
    @Environment(ChatEngine.self) private var engine

    var body: some View {
        let c = conversation
        HStack(spacing: 10) {
            c.avatar(engine: engine, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if c.kind == .channel { Image(systemName: "megaphone.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(c.title.isEmpty ? "Chat" : c.title).font(.headline).lineLimit(1)
                    if c.isMuted { Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary) }
                    if c.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    if case let n = engine.voiceParticipants(c.id).count, n > 0 {
                        Label("\(n)", systemImage: "speaker.wave.2.fill").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Brand.teal.gradient, in: .capsule)
                    }
                    Text((c.previewDate ?? c.sortDate).macListStamp).font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    Group {
                        if let typing = typingText {
                            Text(typing).italic().foregroundStyle(Color.accentColor)
                        } else if !c.draft.isEmpty {
                            Text("Draft: ").foregroundStyle(.red) + Text(c.draft).foregroundStyle(.secondary)
                        } else {
                            Text(previewSender + c.previewText).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout).lineLimit(2)
                    Spacer(minLength: 4)
                    if c.unread > 0 || c.markedUnread { UnreadBadge(count: c.unread, muted: c.isMuted) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    var previewSender: String {
        guard conversation.kind != .dm, let s = conversation.previewSenderID else { return "" }
        return (s == engine.myID ? "You" : engine.name(s)) + ": "
    }

    var typingText: String? {
        guard let t = engine.typing[conversation.id], let (user, _) = t.first else { return nil }
        return conversation.kind == .dm ? "typing…" : engine.name(user) + " is typing…"
    }
}

struct UnreadBadge: View {
    let count: Int
    var muted = false
    var body: some View {
        Text(count > 0 ? "\(count)" : " ").font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .frame(minWidth: 20)
            .background(muted ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.accentColor), in: .capsule)
    }
}

struct MacChatMenu: View {
    let conversation: StoredConversation
    @Environment(ChatEngine.self) private var engine
    @AppStorage("customFolders") private var customFoldersRaw = ""

    var body: some View {
        let c = conversation
        Button(c.unread > 0 ? "Mark as Read" : "Mark as Unread") { c.unread > 0 ? engine.markRead(c.id) : engine.markUnread(c.id); MacServices.shared.updateBadge() }
        Button(c.pinned ? "Unpin" : "Pin") { Task { await engine.setPrefs(c.id, .init(pinned: !c.pinned)) } }
        Menu("Mute") {
            if c.isMuted { Button("Unmute") { Task { await engine.setPrefs(c.id, .init(unmute: true)) } } }
            Button("For 1 hour") { Task { await engine.setPrefs(c.id, .init(mutedUntil: .now.addingTimeInterval(3600))) } }
            Button("For 8 hours") { Task { await engine.setPrefs(c.id, .init(mutedUntil: .now.addingTimeInterval(8 * 3600))) } }
            Button("Forever") { Task { await engine.setPrefs(c.id, .init(mutedUntil: .distantFuture)) } }
        }
        Menu("Move to Folder") {
            Button("None") { Task { await engine.setPrefs(c.id, .init(folder: "")) } }
            ForEach(customFoldersRaw.split(separator: "|").map(String.init), id: \.self) { f in
                Button(f) { Task { await engine.setPrefs(c.id, .init(folder: f)) } }
            }
        }
        Button(c.archived ? "Unarchive" : "Archive") { Task { await engine.setPrefs(c.id, .init(archived: !c.archived)) } }
        Divider()
        Button("Clear History on This Mac", role: .destructive) { engine.clearHistory(c.id) }
    }
}

extension Date {
    var macListStamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if let d = cal.dateComponents([.day], from: self, to: .now).day, d < 7 { return formatted(.dateTime.weekday(.wide)) }
        return formatted(date: .numeric, time: .omitted)
    }
}
