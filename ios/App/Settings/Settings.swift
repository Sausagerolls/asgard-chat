import AsgardKit
import PhotosUI
import SwiftData
import SwiftUI
import UserNotifications

struct SettingsTab: View {
    @Environment(ChatEngine.self) private var engine
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ProfileEditor() } label: {
                        HStack(spacing: 14) {
                            AvatarView(id: engine.myID, name: engine.me?.displayName ?? "", mediaID: engine.me?.avatarMediaID, size: 64)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(engine.me?.displayName ?? "").font(.title3.bold())
                                Text("@" + (engine.me?.username ?? "")).foregroundStyle(.secondary)
                                if let bio = engine.me?.bio, !bio.isEmpty { Text(bio).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    NavigationLink { AppearanceSettings() } label: { SettingsLabel("Appearance", "paintbrush.fill", .purple) }
                    NavigationLink { PrivacySettings() } label: { SettingsLabel("Privacy & security", "lock.fill", .blue) }
                    NavigationLink { NotificationSettings() } label: { SettingsLabel("Notifications", "bell.badge.fill", .red) }
                    NavigationLink { ChatSettings() } label: { SettingsLabel("Chats", "bubble.left.and.bubble.right.fill", .green) }
                    NavigationLink { DevicesView() } label: { SettingsLabel("Devices", "laptopcomputer.and.iphone", .orange) }
                    NavigationLink { HistorySettingsView() } label: { SettingsLabel("Message history", "clock.arrow.circlepath", .indigo) }
                    NavigationLink { StorageSettings() } label: { SettingsLabel("Storage & data", "externaldrive.fill", .teal) }
                    NavigationLink { StarredView(conversationID: nil) } label: { SettingsLabel("Starred messages", "star.fill", .yellow) }
                }
                if engine.me?.isAdmin == true {
                    Section("Server") {
                        NavigationLink { AdminView() } label: { SettingsLabel("Server admin", "server.rack", .indigo) }
                    }
                }
                Section {
                    NavigationLink { AboutView() } label: { SettingsLabel("About Asgard", "info.circle.fill", .gray) }
                    if engine.isDemo {
                        Label("Demo mode — nothing is sent anywhere", systemImage: "theatermasks").foregroundStyle(.secondary)
                    }
                    Button(engine.isDemo ? "Leave demo" : "Sign out", role: .destructive) { confirmSignOut = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AuroraBackground(intensity: 0.35))
            .navigationTitle("Settings")
            .confirmationDialog("Sign out of this device?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await engine.signOut() } }
            } message: {
                Text("This device's keys are deleted. Messages stored here are removed. Your other devices keep working.")
            }
        }
    }
}

struct SettingsLabel: View {
    let title: String, icon: String, color: Color
    init(_ title: String, _ icon: String, _ color: Color) { self.title = title; self.icon = icon; self.color = color }
    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(color.gradient, in: .rect(cornerRadius: 8))
        }
    }
}

struct ProfileEditor: View {
    @Environment(ChatEngine.self) private var engine
    @State private var name = ""
    @State private var bio = ""
    @State private var photo: PhotosPickerItem?
    @State private var avatar: UIImage?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            if let avatar { Image(uiImage: avatar).resizable().scaledToFill().frame(width: 120, height: 120).clipShape(Circle()) }
                            else { AvatarView(id: engine.myID, name: name, mediaID: engine.me?.avatarMediaID, size: 120) }
                            Image(systemName: "camera.circle.fill").font(.title).symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor)
                        }
                    }
                    Text("@" + (engine.me?.username ?? "")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            Section("Name") { TextField("Name", text: $name) }
            Section("Bio") { TextField("A few words about you", text: $bio, axis: .vertical) }
        }
        .navigationTitle("Profile")
        .toolbar {
            Button("Save") {
                saving = true
                Task {
                    try? await engine.updateProfile(displayName: name, bio: bio, avatar: avatar?.jpegData(compressionQuality: 0.85))
                    saving = false
                    Haptics.success()
                }
            }
            .disabled(saving)
        }
        .onAppear { name = engine.me?.displayName ?? ""; bio = engine.me?.bio ?? "" }
        .onChange(of: photo) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { avatar = UIImage(data: d)?.squareThumbnail(640) } }
        }
    }
}

struct AppearanceSettings: View {
    @Environment(Appearance.self) private var appearance

    var body: some View {
        @Bindable var a = appearance
        Form {
            Section {
                PreviewBubbles().frame(height: 170).listRowInsets(EdgeInsets())
            }
            Section("Theme") {
                Picker("Theme", selection: $a.theme) {
                    Text("Dark").tag(ThemeChoice.dark); Text("Light").tag(ThemeChoice.light); Text("System").tag(ThemeChoice.system)
                }
                .pickerStyle(.segmented)
            }
            Section("Accent") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(AccentChoice.allCases) { c in
                            Button { a.accent = c } label: {
                                VStack(spacing: 6) {
                                    Circle().fill(c.fill).frame(width: 40, height: 40)
                                        .overlay(Circle().stroke(Color.primary, lineWidth: a.accent == c ? 3 : 0).padding(-4))
                                    Text(c.title).font(.caption2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            Section("Bubbles") {
                Picker("Style", selection: $a.bubbles) { ForEach(BubbleStyle.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            }
            Section("Chat wallpaper") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Wallpaper.allCases) { w in
                            Button { a.wallpaper = w } label: {
                                ChatWallpaper(wallpaper: w, animated: false).frame(width: 70, height: 120).clipShape(.rect(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: a.wallpaper == w ? 3 : 0))
                                    .overlay(alignment: .bottom) { Text(w.title).font(.caption2.bold()).padding(4).foregroundStyle(.white) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Toggle("Animated backgrounds", isOn: $a.animatedBackgrounds)
                Toggle("Message animations", isOn: $a.messageAnimations)
            }
            Section("Text size") {
                Slider(value: $a.textScale, in: 0.8...1.3, step: 0.05) { Text("Text size") } minimumValueLabel: { Text("A").font(.caption) } maximumValueLabel: { Text("A").font(.title3) }
            }
            Section("App icon") {
                AppIconPicker()
            }
        }
        .navigationTitle("Appearance")
    }
}

struct PreviewBubbles: View {
    @Environment(Appearance.self) private var appearance
    var body: some View {
        ZStack {
            ChatWallpaper(wallpaper: appearance.wallpaper, animated: appearance.animatedBackgrounds)
            VStack(spacing: 6) {
                HStack { Text("Hail! Feast at sundown? 🍯").padding(10).background(.regularMaterial, in: BubbleShape(mine: false, tail: appearance.bubbles == .tailed, style: appearance.bubbles)); Spacer() }
                HStack { Spacer(); Text("Wouldn't miss it ⚡️").padding(10).foregroundStyle(.white).background(appearance.accent.fill, in: BubbleShape(mine: true, tail: appearance.bubbles == .tailed, style: appearance.bubbles)) }
            }
            .padding()
        }
    }
}

struct AppIconPicker: View {
    var body: some View {
        HStack(spacing: 16) {
            Image("BrandMark").resizable().frame(width: 60, height: 60).background(AuroraBackground(animated: false)).clipShape(.rect(cornerRadius: 14))
            Text("Asgard follows your Home Screen style: light, dark, tinted or clear.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct PrivacySettings: View {
    @Environment(ChatEngine.self) private var engine
    @AppStorage("linkPreviews") private var linkPreviews = true
    @AppStorage("screenSecurity") private var screenSecurity = false
    @State private var hideLastSeen = false
    @State private var readReceipts = true
    @State private var typing = true
    @State private var whoCanAdd = "everyone"
    @State private var lockEnabled = AppServices.shared.lock.enabled
    @State private var grace = AppServices.shared.lock.graceSeconds
    @State private var blocked: [ContactRow] = []

    nonisolated struct ContactRow: Codable, Identifiable, Sendable { var user: User; var nickname: String; var blocked: Bool; var id: UUID { user.id } }

    var body: some View {
        Form {
            Section {
                Toggle("Show last seen & online", isOn: Binding(get: { !hideLastSeen }, set: { hideLastSeen = !$0; save("hide_last_seen", .bool(!$0)) }))
                Toggle("Read receipts", isOn: Binding(get: { readReceipts }, set: { readReceipts = $0; save("read_receipts", .bool($0)) }))
                Toggle("Typing indicators", isOn: Binding(get: { typing }, set: { typing = $0; save("typing_indicators", .bool($0)) }))
                Picker("Who can add me to groups", selection: Binding(get: { whoCanAdd }, set: { whoCanAdd = $0; save("who_can_add", .string($0)) })) {
                    Text("Everyone").tag("everyone"); Text("My contacts").tag("contacts")
                }
            } header: { Text("Who sees what") } footer: { Text("If you turn off read receipts, you won't see other people's either.") }
            Section {
                Toggle("Lock Asgard with Face ID", isOn: Binding(get: { lockEnabled }, set: { v in
                    Task { if await AppLock.authenticate(reason: "Change app lock") { lockEnabled = v; AppServices.shared.lock.enabled = v } }
                }))
                if lockEnabled {
                    Picker("Require after", selection: Binding(get: { grace }, set: { grace = $0; AppServices.shared.lock.graceSeconds = $0 })) {
                        Text("Immediately").tag(0.0); Text("1 minute").tag(60.0); Text("15 minutes").tag(900.0); Text("1 hour").tag(3600.0)
                    }
                }
                Toggle("Hide content in app switcher", isOn: $screenSecurity)
                Toggle("Generate link previews", isOn: $linkPreviews)
            } header: { Text("Security") } footer: { Text("Link previews are made on your device, so the server never sees the links you send.") }
            Section("Blocked") {
                if blocked.isEmpty { Text("No one").foregroundStyle(.secondary) }
                ForEach(blocked) { c in
                    UserRow(user: c.user).swipeActions {
                        Button("Unblock") { Task { try? await engine.api?.call("DELETE", "/contacts/\(c.user.id.lower)"); await load() } }
                    }
                }
            }
            Section {
                Label("Messages, media, calls, reactions and polls are end-to-end encrypted with keys that never leave your devices.", systemImage: "lock.shield.fill")
                    .font(.footnote)
            }
        }
        .navigationTitle("Privacy & security")
        .task { await load() }
    }

    func load() async {
        let s = engine.me?.settings ?? [:]
        hideLastSeen = s["hide_last_seen"]?.bool ?? false
        readReceipts = s["read_receipts"]?.bool ?? true
        typing = s["typing_indicators"]?.bool ?? true
        whoCanAdd = s["who_can_add"]?.string ?? "everyone"
        let all: [ContactRow] = (try? await engine.api?.send("GET", "/contacts")) ?? []
        blocked = all.filter(\.blocked)
    }

    func save(_ key: String, _ value: JSONValue) {
        Task { try? await engine.updateProfile(settings: [key: value]) }
    }
}

struct NotificationSettings: View {
    @State private var status: UNAuthorizationStatus = .notDetermined
    @AppStorage("notifPreview") private var preview = true
    @AppStorage("notifSound") private var sound = true
    @AppStorage("inAppBanners") private var inApp = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: status == .authorized ? "On" : status == .denied ? "Off" : "Not set")
                if status != .authorized {
                    Button("Turn on notifications") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound, .providesAppNotificationSettings])
                            await refresh()
                            if status == .denied, let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
                        }
                    }
                }
            }
            Section {
                Toggle("Show message preview", isOn: $preview)
                Toggle("Sounds", isOn: $sound)
                Toggle("In-app banners", isOn: $inApp)
            } footer: {
                Text("Pushes from your server contain only encrypted data. This iPhone decrypts them to show who wrote and what they said.")
            }
            Section {
                Text("Mute individual chats from the chat list or chat info. Focus filters let you choose which chat folders can notify you during each Focus.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notifications")
        .task { await refresh() }
    }

    func refresh() async { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
}

struct ChatSettings: View {
    @AppStorage("enterToSend") private var enterToSend = false
    @AppStorage("doubleTapReaction") private var doubleTap = "❤️"
    @AppStorage("autoDownloadWifi") private var autoWifi = true
    @AppStorage("autoDownloadCellular") private var autoCell = true
    @AppStorage("customFolders") private var customFolders = ""
    @State private var newFolder = ""

    var body: some View {
        Form {
            Section("Typing") {
                Toggle("Return key sends", isOn: $enterToSend)
                Picker("Double-tap reaction", selection: $doubleTap) { ForEach(["❤️", "👍", "😂", "🔥", "⚡️"], id: \.self) { Text($0).tag($0) } }
            }
            Section("Chat folders") {
                ForEach(customFolders.split(separator: "|").map(String.init), id: \.self) { f in Text(f) }
                    .onDelete { idx in
                        var list = customFolders.split(separator: "|").map(String.init)
                        list.remove(atOffsets: idx)
                        customFolders = list.joined(separator: "|")
                    }
                HStack {
                    TextField("New folder", text: $newFolder)
                    Button("Add") {
                        let n = newFolder.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty else { return }
                        customFolders = (customFolders.split(separator: "|").map(String.init) + [n]).joined(separator: "|")
                        newFolder = ""
                    }
                }
            }
            Section("Auto-download media") {
                Toggle("On Wi-Fi", isOn: $autoWifi)
                Toggle("On mobile data", isOn: $autoCell)
            }
        }
        .navigationTitle("Chats")
    }
}

struct DevicesView: View {
    @Environment(ChatEngine.self) private var engine
    @State private var devices: [DeviceInfo] = []
    @State private var showLink = false

    var body: some View {
        List {
            Section {
                Button { showLink = true } label: { Label("Link a device", systemImage: "qrcode") }
            } footer: { Text("Use your iPad, Mac, Android phone or browser. Each device has its own encryption keys.") }
            Section("Your devices") {
                ForEach(devices) { d in
                    HStack {
                        Image(systemName: icon(d.platform)).font(.title2).frame(width: 36)
                        VStack(alignment: .leading) {
                            Text(d.name?.isEmpty == false ? d.name! : d.platform?.capitalized ?? "Device").font(.headline)
                            Text(d.current == true ? "This device" : "Active " + (d.lastActiveAt ?? d.createdAt).formatted(.relative(presentation: .named)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if d.current != true {
                            Button(role: .destructive) { Task { try? await engine.api?.call("DELETE", "/me/devices/\(d.id.lower)"); await load() } } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Devices")
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showLink, onDismiss: { Task { await load() } }) { LinkNewDeviceSheet() }
    }

    func icon(_ p: String?) -> String {
        switch p {
        case "ipados": "ipad"
        case "macos": "laptopcomputer"
        case "watchos": "applewatch"
        case "android": "smartphone"
        case "wearos": "applewatch.side.right"
        case "web": "globe"
        case "admin": "server.rack"
        default: "iphone"
        }
    }

    func load() async { devices = (try? await engine.api?.send("GET", "/me/devices")) ?? [] }
}

struct LinkNewDeviceSheet: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var link: LinkCode?
    @State private var linkedName: String?
    nonisolated struct LinkCode: Codable, Sendable { var code: String; var expires_at: Date; var uri: String }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let linkedName {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(Brand.teal)
                    Text("\(linkedName) is linked").font(.title2.bold())
                } else if let link {
                    Text("Scan with your new device").font(.title3.bold())
                    if let img = QRCode.image(link.uri) {
                        Image(uiImage: img).interpolation(.none).resizable().frame(width: 240, height: 240).padding(16).background(.white, in: .rect(cornerRadius: 24))
                    }
                    Text(link.code).font(.title3.monospaced().bold())
                    Text("Expires ") + Text(link.expires_at, style: .relative)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(.top, 30)
            .navigationTitle("Link a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                link = try? await engine.api?.send("POST", "/devices/link")
                engine.onDeviceLinked = { name in withAnimation { linkedName = name }; Haptics.success() }
            }
        }
    }
}

struct StorageSettings: View {
    @Environment(ChatEngine.self) private var engine
    @State private var cacheBytes: Int64 = 0
    @State private var messageCount = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("Media cache", value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                LabeledContent("Messages on this device", value: "\(messageCount)")
                Button("Clear media cache", role: .destructive) { MediaCache.clear(); refresh() }
            } footer: { Text("Clearing the cache keeps your messages. Media downloads again when you open it.") }
        }
        .navigationTitle("Storage & data")
        .onAppear(perform: refresh)
    }

    func refresh() {
        cacheBytes = MediaCache.totalBytes
        messageCount = (try? engine.context.fetchCount(FetchDescriptor<StoredMessage>())) ?? 0
    }
}

struct AboutView: View {
    @Environment(ChatEngine.self) private var engine
    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image("BrandMark").resizable().scaledToFit().frame(width: 96)
                    Text("Asgard Chat").font(.title2.bold())
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            Section("Server") {
                LabeledContent("Name", value: engine.serverInfo?.name ?? "—")
                LabeledContent("Address", value: engine.account?.serverURL.host() ?? (engine.isDemo ? "Demo" : "—"))
                LabeledContent("Version", value: engine.serverInfo?.version ?? "—")
            }
            Section("Encryption") {
                Text("Each message gets a fresh key, wrapped for every device in the chat with X25519, sealed with ChaCha20-Poly1305 and signed with Ed25519. Protocol v1 is open source; MLS (RFC 9420) is planned.")
                    .font(.footnote)
                Link("Source code", destination: URL(string: "https://github.com/Sausagerolls/asgard-chat")!)
            }
        }
        .navigationTitle("About")
    }
}
