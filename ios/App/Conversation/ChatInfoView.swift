import AsgardKit
import PhotosUI
import SwiftData
import SwiftUI

struct ChatInfoView: View {
    let conversationID: UUID
    @Environment(ChatEngine.self) private var engine
    @Environment(CallManager.self) private var calls
    @Environment(\.dismiss) private var dismiss
    @State private var members: [Member] = []
    @State private var editing = false
    @State private var addPeople = false
    @State private var confirmLeave = false
    @State private var showSafety = false
    @State private var webhooks: [WebhookInfo] = []
    @State private var newHookURL: String?
    @State private var photo: PhotosPickerItem?

    var stored: StoredConversation? { engine.storedConversation(conversationID) }
    var conversation: Conversation? { stored?.conversation }
    var perms: Permissions { conversation?.me?.permissions ?? [] }
    var isDM: Bool { conversation?.kind == .dm }

    var body: some View {
        List {
            header
            actions
            if let d = conversation?.description, !d.isEmpty, !isDM {
                Section("About") { Text(d) }
            }
            if isDM, let p = conversation?.peer, !p.bio.isEmpty {
                Section("Bio") { Text(p.bio) }
            }
            Section {
                NavigationLink { SharedMediaView(conversationID: conversationID) } label: { Label("Media, links and files", systemImage: "photo.on.rectangle.angled") }
                NavigationLink { StarredView(conversationID: conversationID) } label: { Label("Starred messages", systemImage: "star") }
            }
            settingsSection
            if !isDM && conversation?.kind != .saved { membersSection }
            if perms.contains(.manageWebhooks) && !isDM && conversation?.kind != .saved { webhookSection }
            Section {
                if isDM {
                    Button { showSafety = true } label: { Label("Verify safety number", systemImage: "checkmark.shield") }
                }
                Label("Messages and calls are end-to-end encrypted. Only people in this chat can read them.", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            dangerSection
        }
        .navigationTitle(isDM ? "Contact info" : "Chat info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if perms.contains(.editInfo) && !isDM { Button("Edit") { editing = true } }
        }
        .task { await load() }
        .sheet(isPresented: $editing) { EditConversationSheet(conversationID: conversationID) }
        .sheet(isPresented: $addPeople) {
            AddMembersSheet(existing: Set(members.map(\.id))) { ids in Task { try? await engine.addMembers(ids, to: conversationID); await load() } }
        }
        .sheet(isPresented: $showSafety) { SafetyNumberView(conversationID: conversationID) }
        .alert("Webhook created", isPresented: Binding(get: { newHookURL != nil }, set: { if !$0 { newHookURL = nil } })) {
            Button("Copy URL") { UIPasteboard.general.string = newHookURL }
            Button("Done", role: .cancel) {}
        } message: {
            Text("POST JSON {\"text\": \"…\"} to this URL. It's shown only once.\n\n\(newHookURL ?? "")")
        }
        .confirmationDialog(conversation?.kind == .saved ? "" : "Leave \(stored?.title ?? "")?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { try? await engine.leave(conversationID); dismiss() } }
        }
    }

    var header: some View {
        Section {
            VStack(spacing: 10) {
                if let stored { stored.avatar(engine: engine, size: 110) }
                Text(stored?.title ?? "").font(.title2.bold()).multilineTextAlignment(.center)
                if isDM, let p = conversation?.peer {
                    Text("@" + p.username).foregroundStyle(.secondary)
                } else if let c = conversation {
                    Text("\(c.kind == .channel ? "Channel" : c.kind == .community ? "Community" : "Group") · \(c.memberCount) \(c.kind == .channel ? "subscribers" : "members")")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    var actions: some View {
        Section {
            GlassEffectContainer {
                HStack(spacing: 10) {
                    if isDM || conversation?.kind == .group, engine.callsAvailable {
                        ActionTile(icon: "phone.fill", title: "Audio") { Task { await calls.start(conversationID, video: false) } }
                        ActionTile(icon: "video.fill", title: "Video") { Task { await calls.start(conversationID, video: true) } }
                    }
                    ActionTile(icon: stored?.isMuted == true ? "bell.slash.fill" : "bell.fill", title: stored?.isMuted == true ? "Unmute" : "Mute") {
                        Task { await engine.setPrefs(conversationID, stored?.isMuted == true ? .init(unmute: true) : .init(mutedUntil: .distantFuture)) }
                    }
                    if !isDM && perms.contains(.addMembers) {
                        ActionTile(icon: "person.badge.plus", title: "Add") { addPeople = true }
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder var settingsSection: some View {
        Section("Settings") {
            Picker(selection: Binding(get: { conversation?.disappearingSeconds ?? 0 }, set: { v in
                Task { try? await engine.update(conversationID, .init(disappearingSeconds: v)) }
            })) {
                Text("Off").tag(0)
                Text("5 minutes").tag(300)
                Text("1 hour").tag(3600)
                Text("24 hours").tag(86400)
                Text("7 days").tag(7 * 86400)
                Text("90 days").tag(90 * 86400)
            } label: { Label("Disappearing messages", systemImage: "timer") }
                .disabled(!perms.contains(.editInfo) && !isDM)
            if !isDM && perms.contains(.editInfo) && conversation?.kind != .saved {
                Picker(selection: Binding(get: { conversation?.slowModeSeconds ?? 0 }, set: { v in
                    Task { try? await engine.update(conversationID, .init(slowModeSeconds: v)) }
                })) {
                    Text("Off").tag(0); Text("10s").tag(10); Text("30s").tag(30); Text("1m").tag(60); Text("5m").tag(300); Text("1h").tag(3600)
                } label: { Label("Slow mode", systemImage: "tortoise") }
                Toggle(isOn: Binding(get: { conversation?.isPublic ?? false }, set: { v in Task { try? await engine.update(conversationID, .init(isPublic: v)) } })) {
                    Label("Discoverable on server", systemImage: "globe")
                }
                if conversation?.kind == .group || conversation?.kind == .community {
                    NavigationLink { PermissionsView(conversationID: conversationID) } label: { Label("Member permissions", systemImage: "lock.shield") }
                }
            }
            Picker(selection: Binding(get: { stored?.wallpaper ?? "" }, set: { stored?.wallpaper = $0; try? engine.context.save() })) {
                Text("Default").tag("")
                ForEach(Wallpaper.allCases) { Text($0.title).tag($0.rawValue) }
            } label: { Label("Wallpaper", systemImage: "photo.artframe") }
            Toggle(isOn: Binding(get: { stored?.locked ?? false }, set: { v in
                Task {
                    if await AppLock.authenticate(reason: v ? "Lock this chat" : "Unlock this chat") { stored?.locked = v; try? engine.context.save() }
                }
            })) { Label("Lock chat with Face ID", systemImage: "faceid") }
        }
    }

    var membersSection: some View {
        Section("\(members.count) members") {
            if perms.contains(.addMembers) {
                Button { addPeople = true } label: { Label("Add members", systemImage: "person.badge.plus") }
            }
            ForEach(members) { m in
                HStack {
                    UserRow(user: m.user, subtitle: m.user.id == engine.myID ? "You" : nil)
                    if m.role >= .moderator {
                        Text(m.role.rawValue.capitalized).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.2), in: .capsule)
                    }
                }
                .contextMenu { memberMenu(m) }
                .swipeActions {
                    if canManage(m) {
                        Button(role: .destructive) { Task { try? await engine.removeMember(m.user.id, from: conversationID); await load() } } label: { Label("Remove", systemImage: "person.badge.minus") }
                    }
                }
            }
        }
    }

    func canManage(_ m: Member) -> Bool {
        let myRole = conversation?.me?.role ?? .member
        return perms.contains(.manageMembers) && m.user.id != engine.myID && myRole > m.role
    }

    @ViewBuilder func memberMenu(_ m: Member) -> some View {
        if m.user.id != engine.myID {
            Button { Task { if let id = try? await engine.openDM(with: m.user.id) { AppServices.shared.router.openConversation = id } } } label: {
                Label("Message", systemImage: "message")
            }
        }
        if canManage(m) {
            let myRole = conversation?.me?.role ?? .member
            ForEach([MemberRole.admin, .moderator, .member].filter { $0 < myRole && $0 != m.role }, id: \.self) { r in
                Button { Task { try? await engine.setRole(r, for: m.user.id, in: conversationID); await load() } } label: {
                    Label("Make \(r.rawValue)", systemImage: r == .admin ? "crown" : r == .moderator ? "shield" : "person")
                }
            }
            if myRole == .owner {
                Button { Task { try? await engine.setRole(.owner, for: m.user.id, in: conversationID); await load() } } label: { Label("Transfer ownership", systemImage: "key") }
            }
            Button(role: .destructive) { Task { try? await engine.removeMember(m.user.id, from: conversationID); await load() } } label: { Label("Remove", systemImage: "person.badge.minus") }
        }
    }

    var webhookSection: some View {
        Section {
            ForEach(webhooks) { h in
                Label(h.name, systemImage: "link")
                    .swipeActions { Button(role: .destructive) { Task { await deleteHook(h) } } label: { Label("Delete", systemImage: "trash") } }
            }
            Button { Task { await createHook() } } label: { Label("Add webhook", systemImage: "plus") }
        } header: { Text("Webhooks") } footer: {
            Text("Webhooks let services like Home Assistant post here. The server encrypts their messages, so it can read this chat while a webhook exists.")
        }
    }

    var dangerSection: some View {
        Section {
            if isDM, let peer = conversation?.peer {
                Button(role: .destructive) {
                    nonisolated struct Body: Encodable, Sendable { var blocked = true }
                    Task { try? await engine.api?.call("PUT", "/contacts/\(peer.id.lower)", body: Body()); engine.banner = "Blocked \(peer.displayName)" }
                } label: { Label("Block \(peer.displayName)", systemImage: "hand.raised") }
            }
            Button(role: .destructive) { engine.clearHistory(conversationID) } label: { Label("Clear chat on this device", systemImage: "trash") }
            if !isDM && conversation?.kind != .saved {
                Button(role: .destructive) { confirmLeave = true } label: { Label("Leave", systemImage: "rectangle.portrait.and.arrow.right") }
            }
            if conversation?.me?.role == .owner && !isDM && conversation?.kind != .saved {
                Button(role: .destructive) { Task { try? await engine.deleteConversation(conversationID); dismiss() } } label: { Label("Delete for everyone", systemImage: "trash.fill") }
            }
        }
    }

    func load() async {
        members = await engine.members(conversationID)
        if perms.contains(.manageWebhooks), let api = engine.api {
            webhooks = (try? await api.send("GET", "/conversations/\(conversationID.lower)/webhooks")) ?? []
        }
    }

    func createHook() async {
        guard let api = engine.api else { return }
        nonisolated struct Body: Encodable, Sendable { var name = "Webhook" }
        if let h: WebhookInfo = try? await api.send("POST", "/conversations/\(conversationID.lower)/webhooks", body: Body()) {
            newHookURL = h.url
            await load()
        }
    }

    func deleteHook(_ h: WebhookInfo) async {
        try? await engine.api?.call("DELETE", "/conversations/\(conversationID.lower)/webhooks/\(h.id.lower)")
        await load()
    }
}

nonisolated struct WebhookInfo: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var url: String?
}

struct ActionTile: View {
    let icon: String
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }
}

struct EditConversationSheet: View {
    let conversationID: UUID
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var about = ""
    @State private var photo: PhotosPickerItem?
    @State private var avatar: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $photo, matching: .images) {
                        HStack {
                            if let avatar { Image(uiImage: avatar).resizable().scaledToFill().frame(width: 60, height: 60).clipShape(Circle()) }
                            Text("Change photo")
                        }
                    }
                    TextField("Name", text: $title)
                    TextField("Description", text: $about, axis: .vertical)
                }
            }
            .navigationTitle("Edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            try? await engine.update(conversationID, .init(title: title, description: about), avatar: avatar?.jpegData(compressionQuality: 0.85))
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                title = engine.conversation(conversationID)?.title ?? ""
                about = engine.conversation(conversationID)?.description ?? ""
            }
            .onChange(of: photo) { _, item in
                Task { if let d = try? await item?.loadTransferable(type: Data.self) { avatar = UIImage(data: d)?.squareThumbnail(512) } }
            }
        }
    }
}

struct PermissionsView: View {
    let conversationID: UUID
    @Environment(ChatEngine.self) private var engine
    @State private var perms = Permissions()

    let items: [(Permissions, String, String)] = [
        (.send, "Send messages", "text.bubble"), (.sendMedia, "Send media", "photo"), (.addMembers, "Add members", "person.badge.plus"),
        (.pin, "Pin messages", "pin"), (.editInfo, "Edit chat info", "pencil"), (.startCalls, "Start calls", "phone"),
        (.mentionAll, "Mention @all", "at"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(items, id: \.1) { p, title, icon in
                    Toggle(isOn: Binding(get: { perms.contains(p) }, set: { if $0 { perms.insert(p) } else { perms.remove(p) } })) {
                        Label(title, systemImage: icon)
                    }
                }
            } footer: { Text("What regular members can do. Admins and moderators always can.") }
        }
        .navigationTitle("Permissions")
        .onAppear { perms = Permissions(rawValue: engine.conversation(conversationID)?.memberPermissions ?? 0) }
        .onDisappear { Task { try? await engine.update(conversationID, .init(memberPermissions: perms.rawValue)) } }
    }
}

struct AddMembersSheet: View {
    let existing: Set<UUID>
    var onAdd: ([UUID]) -> Void
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var users: [User] = []
    @State private var selected: Set<UUID> = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(users.filter { !existing.contains($0.id) }) { u in
                Button { if selected.contains(u.id) { selected.remove(u.id) } else { selected.insert(u.id) } } label: {
                    HStack { UserRow(user: u); Image(systemName: selected.contains(u.id) ? "checkmark.circle.fill" : "circle") }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query)
            .task(id: query) { users = await engine.searchUsers(query) }
            .navigationTitle("Add members")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { onAdd(Array(selected)); dismiss() }.disabled(selected.isEmpty) }
            }
        }
    }
}

struct SafetyNumberView: View {
    let conversationID: UUID
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 56)).foregroundStyle(Brand.aurora)
                Text("Compare these numbers with \(engine.conversation(conversationID)?.peer?.displayName ?? "your contact") in person or on a call. If they match, nobody is intercepting your messages.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text(number).font(.title2.monospaced().bold()).multilineTextAlignment(.center).lineSpacing(8)
                    .padding().glassEffect(.regular, in: .rect(cornerRadius: 20))
                if let img = QRCode.image(number) {
                    Image(uiImage: img).interpolation(.none).resizable().frame(width: 180, height: 180).padding().background(.white, in: .rect(cornerRadius: 16))
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Safety number")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await compute() }
        }
    }

    func compute() async {
        guard let api = engine.api, let me = engine.myID, let peer = engine.conversation(conversationID)?.peer else {
            number = "12345 67890 12345 67890 12345 67890"
            return
        }
        let mine = (try? await api.devices(of: me)) ?? []
        let theirs = (try? await api.devices(of: peer.id)) ?? []
        number = SafetyNumber.compute(userA: me, keysA: mine.map(\.signingKey), userB: peer.id, keysB: theirs.map(\.signingKey))
    }
}

struct SharedMediaView: View {
    let conversationID: UUID
    @Query private var messages: [StoredMessage]
    @State private var tab = 0
    @State private var viewer: MediaViewerItem?

    init(conversationID: UUID) {
        self.conversationID = conversationID
        _messages = Query(filter: #Predicate<StoredMessage> { $0.conversationID == conversationID && !$0.wasDeleted }, sort: \StoredMessage.sortKey, order: .reverse)
    }

    var media: [StoredMessage] { messages.filter { $0.content?.attachments?.contains { $0.isImage || $0.isVideo } == true && !$0.viewOnce } }
    var files: [StoredMessage] { messages.filter { $0.content?.type == .media && $0.content?.attachments?.contains { !$0.isImage && !$0.isVideo } == true } }
    var links: [StoredMessage] { messages.filter { $0.content?.linkPreviews?.isEmpty == false } }

    var body: some View {
        VStack {
            Picker("", selection: $tab) { Text("Media").tag(0); Text("Files").tag(1); Text("Links").tag(2) }.pickerStyle(.segmented).padding(.horizontal)
            ScrollView {
                switch tab {
                case 0:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(media) { m in
                            if let a = m.content?.attachments?.first(where: { $0.isImage || $0.isVideo }) {
                                AttachmentThumb(attachment: a).onTapGesture { viewer = MediaViewerItem(message: m, index: 0) }
                            }
                        }
                    }
                case 1:
                    LazyVStack(alignment: .leading) {
                        ForEach(files) { m in ForEach(Array((m.content?.attachments ?? []).enumerated()), id: \.offset) { FileRow(attachment: $0.element, mine: false) } }
                    }
                    .padding()
                default:
                    LazyVStack {
                        ForEach(links) { m in if let lp = m.content?.linkPreviews?.first { LinkPreviewCard(preview: lp, mine: false) } }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Shared")
        .fullScreenCover(item: $viewer) { MediaViewer(message: $0.message, startIndex: $0.index) }
    }
}

struct StarredView: View {
    let conversationID: UUID?
    @Query private var messages: [StoredMessage]
    @State private var session: ChatSession

    init(conversationID: UUID?) {
        self.conversationID = conversationID
        if let conversationID {
            _messages = Query(filter: #Predicate<StoredMessage> { $0.isStarred && $0.conversationID == conversationID }, sort: \StoredMessage.sentAt, order: .reverse)
        } else {
            _messages = Query(filter: #Predicate<StoredMessage> { $0.isStarred }, sort: \StoredMessage.sentAt, order: .reverse)
        }
        _session = State(initialValue: ChatSession(conversationID: conversationID ?? UUID()))
    }

    var body: some View {
        List(messages) { m in
            MessageBubble(message: m, grouping: .single, isGroup: true).listRowBackground(Color.clear)
        }
        .environment(session)
        .overlay { if messages.isEmpty { ContentUnavailableView("No starred messages", systemImage: "star", description: Text("Long-press a message and tap Star.")) } }
        .navigationTitle("Starred")
    }
}
