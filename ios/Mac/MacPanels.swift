import AppKit
import AsgardKit
import SwiftData
import SwiftUI
import UserNotifications

/// Inspector: who's in the chat, shared media, and chat settings.
struct MacChatInfo: View {
    let conversationID: UUID
    @Environment(ChatEngine.self) private var engine
    @Environment(MacNavigator.self) private var nav
    @State private var members: [Member] = []
    @State private var title = ""
    @State private var addPeople = false
    @State private var confirmLeave = false
    @Query private var pinned: [StoredMessage]

    init(conversationID: UUID) {
        self.conversationID = conversationID
        _pinned = Query(filter: #Predicate<StoredMessage> { $0.conversationID == conversationID && $0.isPinned }, sort: \StoredMessage.sortKey, order: .reverse)
    }

    var stored: StoredConversation? { engine.storedConversation(conversationID) }
    var myRole: MemberRole { stored?.conversation?.me?.role ?? .member }
    var canManage: Bool { myRole >= .admin }

    var body: some View {
        let c = stored?.conversation
        Form {
            Section {
                VStack(spacing: 8) {
                    if let stored { stored.avatar(engine: engine, size: 84) }
                    if canManage && stored?.kind != .dm {
                        TextField("Name", text: $title).multilineTextAlignment(.center).font(.title3.bold()).textFieldStyle(.plain)
                            .onSubmit { Task { try? await engine.update(conversationID, .init(title: title)) } }
                    } else {
                        Text(stored?.title ?? "").font(.title3.bold())
                    }
                    if let d = c?.description, !d.isEmpty { Text(d).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    if let peer = c?.peer { Text("@" + peer.username).foregroundStyle(.secondary) }
                    Label("End-to-end encrypted", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { m in
                        Text(m.content.map(ChatEngine.preview) ?? "").lineLimit(2).font(.callout)
                    }
                }
            }
            Section("Notifications") {
                Toggle("Mute", isOn: Binding(get: { stored?.isMuted ?? false }, set: { on in
                    Task { await engine.setPrefs(conversationID, on ? .init(mutedUntil: .distantFuture) : .init(unmute: true)) }
                }))
            }
            if stored?.kind != .dm && stored?.kind != .saved {
                Section {
                    ForEach(members) { m in
                        HStack(spacing: 8) {
                            AvatarView(id: m.user.id, name: m.user.displayName, mediaID: m.user.avatarMediaID, size: 26,
                                       online: engine.presence[m.user.id]?.online ?? m.user.online)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(m.user.id == engine.myID ? "You" : m.user.displayName).lineLimit(1)
                                if m.role != .member && m.role != .subscriber { Text(m.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                        .contextMenu { memberMenu(m) }
                    }
                } header: {
                    HStack {
                        Text("\(c?.memberCount ?? members.count) Members")
                        Spacer()
                        if canManage || c?.kind == .group { Button("Add…") { addPeople = true }.buttonStyle(.link) }
                    }
                }
            }
            Section {
                if stored?.kind != .dm {
                    Button("Leave", role: .destructive) { confirmLeave = true }
                }
                Button("Clear History on This Mac", role: .destructive) { engine.clearHistory(conversationID) }
            }
        }
        .formStyle(.grouped)
        .task(id: conversationID) {
            title = stored?.title ?? ""
            members = await engine.members(conversationID)
        }
        .sheet(isPresented: $addPeople) {
            MacUserPicker(title: "Add Members", exclude: Set(members.map(\.user.id))) { ids in
                Task { try? await engine.addMembers(ids, to: conversationID); members = await engine.members(conversationID) }
            }
        }
        .confirmationDialog("Leave \(stored?.title ?? "this chat")?", isPresented: $confirmLeave) {
            Button("Leave", role: .destructive) {
                Task { try? await engine.leave(conversationID); nav.selection = nil; nav.showInspector = false }
            }
        }
    }

    @ViewBuilder func memberMenu(_ m: Member) -> some View {
        if m.user.id != engine.myID {
            Button("Message") { Task { if let id = try? await engine.openDM(with: m.user.id) { nav.open(id) } } }
            if canManage && m.role < myRole {
                Divider()
                ForEach([MemberRole.member, .moderator, .admin], id: \.self) { r in
                    Button("Make \(r.rawValue.capitalized)") { Task { try? await engine.setRole(r, for: m.user.id, in: conversationID); members = await engine.members(conversationID) } }
                        .disabled(r == m.role)
                }
                Button("Remove from Chat", role: .destructive) {
                    Task { try? await engine.removeMember(m.user.id, from: conversationID); members = await engine.members(conversationID) }
                }
            }
        }
    }
}

/// Searches people on the server.
struct MacUserPicker: View {
    let title: String
    var exclude: Set<UUID> = []
    var multiple = true
    var onDone: ([UUID]) -> Void
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [User] = []
    @State private var picked: [User] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            TextField("Search by name or username", text: $query).textFieldStyle(.roundedBorder)
            if multiple && !picked.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(picked) { u in
                            Button { picked.removeAll { $0.id == u.id } } label: { Label(u.displayName, systemImage: "xmark.circle.fill") }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            List(results.filter { !exclude.contains($0.id) && $0.id != engine.myID }) { u in
                Button {
                    if multiple {
                        if picked.contains(where: { $0.id == u.id }) { picked.removeAll { $0.id == u.id } } else { picked.append(u) }
                    } else { onDone([u.id]); dismiss() }
                } label: {
                    HStack {
                        AvatarView(id: u.id, name: u.displayName, mediaID: u.avatarMediaID, size: 28)
                        VStack(alignment: .leading) { Text(u.displayName); Text("@" + u.username).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if picked.contains(where: { $0.id == u.id }) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if multiple { Button("Done") { onDone(picked.map(\.id)); dismiss() }.keyboardShortcut(.defaultAction).disabled(picked.isEmpty) }
            }
        }
        .padding(20)
        .frame(width: 440, height: 480)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200))
            results = await engine.searchUsers(query)
        }
    }
}

struct MacNewChatSheet: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(MacNavigator.self) private var nav
    @Environment(\.dismiss) private var dismiss
    enum Kind: String, CaseIterable, Identifiable { case dm = "Message", group = "Group", channel = "Channel"; var id: String { rawValue } }
    @State private var kind: Kind = .dm
    @State private var name = ""
    @State private var picking = false
    @State private var members: [UUID] = []
    @State private var error: String?

    var body: some View {
        if kind == .dm {
            VStack(spacing: 0) {
                Picker("", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 20)
                MacUserPicker(title: "New Message", multiple: false) { ids in
                    guard let id = ids.first else { return }
                    Task { if let conv = try? await engine.openDM(with: id) { nav.open(conv) } }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                TextField(kind == .group ? "Group name" : "Channel name", text: $name).textFieldStyle(.roundedBorder).font(.title3)
                Text(kind == .group ? "Everyone can chat and drop into the voice room." : "Only admins post; subscribers react, comment and join the voice room.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Add People… (\(members.count))") { picking = true }
                if let error { Text(error).foregroundStyle(.red) }
                Spacer()
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Create") {
                        Task {
                            do {
                                let id = try await engine.create(kind: kind == .group ? .group : .channel, title: name, members: members)
                                nav.open(id)
                                dismiss()
                            } catch { self.error = (error as? APIError)?.message ?? error.localizedDescription }
                        }
                    }
                    .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 440, height: 300)
            .sheet(isPresented: $picking) { MacUserPicker(title: "Add People", exclude: Set(members)) { members += $0 } }
        }
    }
}

struct MacSettingsView: View {
    var body: some View {
        TabView {
            Tab("Account", systemImage: "person.crop.circle") { MacAccountSettings() }
            Tab("Appearance", systemImage: "paintbrush") { MacAppearanceSettings() }
            Tab("Notifications", systemImage: "bell.badge") { MacNotificationSettings() }
            Tab("Devices", systemImage: "laptopcomputer.and.iphone") { MacDevicesSettings() }
            Tab("History", systemImage: "clock.arrow.circlepath") { HistorySettingsView() }
        }
        .frame(width: 560, height: 460)
    }
}

struct MacAccountSettings: View {
    @Environment(ChatEngine.self) private var engine
    @State private var name = ""
    @State private var bio = ""
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AvatarView(id: engine.myID, name: engine.me?.displayName ?? "", mediaID: engine.me?.avatarMediaID, size: 64)
                    VStack(alignment: .leading) {
                        Text(engine.me?.displayName ?? "").font(.title3.bold())
                        Text("@" + (engine.me?.username ?? "")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change Photo…") { pickPhoto() }
                }
            }
            Section("Profile") {
                TextField("Name", text: $name)
                TextField("Bio", text: $bio)
                Button("Save") { Task { try? await engine.updateProfile(displayName: name, bio: bio) } }
            }
            Section("Server") {
                LabeledContent("Address", value: engine.account?.serverURL.host() ?? (engine.isDemo ? "Demo" : "—"))
                if engine.me?.isAdmin == true, let url = engine.account?.serverURL.appending(path: "admin") {
                    Link("Open Server Admin", destination: url)
                }
            }
            Section {
                Button(engine.isDemo ? "Leave Demo" : "Sign Out of This Mac", role: .destructive) { confirmSignOut = true }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = engine.me?.displayName ?? ""; bio = engine.me?.bio ?? "" }
        .confirmationDialog("Sign out of this Mac?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await engine.signOut() } }
        } message: { Text("This Mac's keys and stored messages are deleted. Your other devices keep working.") }
    }

    func pickPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url), let data = img.jpegData(maxSide: 640) else { return }
        Task { try? await engine.updateProfile(avatar: data) }
    }
}

struct MacAppearanceSettings: View {
    @Environment(Appearance.self) private var appearance
    var body: some View {
        @Bindable var a = appearance
        Form {
            Picker("Theme", selection: $a.theme) { Text("Dark").tag(ThemeChoice.dark); Text("Light").tag(ThemeChoice.light); Text("System").tag(ThemeChoice.system) }
                .pickerStyle(.segmented)
            LabeledContent("Accent") {
                HStack {
                    ForEach(AccentChoice.allCases) { c in
                        Button { a.accent = c } label: {
                            Circle().fill(c.fill).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.primary, lineWidth: a.accent == c ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain).help(c.title)
                    }
                }
            }
            Picker("Bubbles", selection: $a.bubbles) { ForEach(BubbleStyle.allCases) { Text($0.title).tag($0) } }
            Picker("Wallpaper", selection: $a.wallpaper) { ForEach(Wallpaper.allCases) { Text($0.title).tag($0) } }
            Toggle("Animated backgrounds", isOn: $a.animatedBackgrounds)
            Toggle("Message animations", isOn: $a.messageAnimations)
        }
        .formStyle(.grouped)
    }
}

struct MacNotificationSettings: View {
    @State private var status = "…"
    var body: some View {
        Form {
            LabeledContent("Notifications", value: status)
            Button("Open System Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
            Text("While Asgard is open it notifies you itself, decrypting on this Mac. When it's closed, your server needs an Apple push key (Server Admin › Notifications).")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task {
            let s = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            status = s == .authorized ? "On" : s == .denied ? "Off" : "Not set"
        }
    }
}

struct MacDevicesSettings: View {
    @Environment(ChatEngine.self) private var engine
    @State private var devices: [DeviceInfo] = []
    var body: some View {
        Form {
            ForEach(devices) { d in
                HStack {
                    Image(systemName: d.platform == "macos" ? "laptopcomputer" : d.platform == "android" ? "smartphone" : d.platform == "ipados" ? "ipad" : "iphone")
                        .frame(width: 24)
                    VStack(alignment: .leading) {
                        Text(d.name?.isEmpty == false ? d.name! : (d.platform ?? "Device").capitalized)
                        Text(d.current == true ? "This Mac" : "Active " + (d.lastActiveAt ?? d.createdAt).formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if d.current != true {
                        Button("Remove", role: .destructive) { Task { try? await engine.api?.call("DELETE", "/me/devices/\(d.id.lower)"); await load() } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    func load() async { devices = (try? await engine.api?.send("GET", "/me/devices")) ?? [] }
}
