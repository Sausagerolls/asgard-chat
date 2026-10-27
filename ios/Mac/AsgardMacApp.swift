import AppKit
import AsgardKit
import SwiftData
import SwiftUI
import UserNotifications

/// Asgard for Mac: a native desktop client sharing AsgardKit (sync, crypto,
/// storage) with the iPhone app, with its own desktop interface.
@main
struct AsgardMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var services = MacServices.shared

    var body: some Scene {
        Window("Asgard", id: "main") {
            MacRootView()
                .environment(services.engine)
                .environment(services.appearance)
                .environment(services.calls)
                .environment(services.nav)
                .modelContainer(services.engine.container)
                .preferredColorScheme(services.appearance.theme.scheme)
                .tint(services.appearance.accent.color)
                .frame(minWidth: 820, minHeight: 520)
                .task { await services.start() }
                .onOpenURL { services.nav.handle($0) }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands { AsgardCommands(nav: services.nav, engine: services.engine) }

        Window("Call", id: "call") {
            MacCallWindow()
                .environment(services.engine)
                .environment(services.appearance)
                .environment(services.calls)
                .preferredColorScheme(.dark)
                .frame(minWidth: 520, minHeight: 380)
        }
        .defaultSize(width: 860, height: 600)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        Settings {
            MacSettingsView()
                .environment(services.engine)
                .environment(services.appearance)
                .modelContainer(services.engine.container)
                .preferredColorScheme(services.appearance.theme.scheme)
                .tint(services.appearance.accent.color)
        }

        MenuBarExtra {
            MenuBarChats()
                .environment(services.engine)
                .environment(services.nav)
                .modelContainer(services.engine.container)
        } label: {
            MenuBarLabel(engine: services.engine)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
@Observable
final class MacServices {
    static let shared = MacServices()
    let engine: ChatEngine
    let appearance = Appearance()
    let calls: MacCallManager
    let nav = MacNavigator()
    private var started = false

    init() {
        let demo = ProcessInfo.processInfo.arguments.contains("-demo")
        let container = (try? LocalStore.container(inMemory: demo)) ?? (try! LocalStore.container(inMemory: true))
        engine = ChatEngine(container: container, demo: demo)
        calls = MacCallManager(engine: engine)
    }

    func start() async {
        guard !started else { return }
        started = true
        engine.onIncomingMessage = { [weak self] row in self?.notify(row) }
        engine.onIncomingCall = { [weak self] call in self?.calls.ring(call) }
        engine.onCallEnded = { [weak self] conv in self?.calls.remoteEnded(conv) }
        await engine.start()
        if engine.phase == .ready, !engine.isDemo { MacNotifications.requestAndRegister() }
        updateBadge()
    }

    /// Desktop notification unless the user is already looking at that chat.
    func notify(_ row: StoredMessage) {
        updateBadge()
        let sc = engine.storedConversation(row.conversationID)
        if sc?.isMuted == true { return }
        if NSApp.isActive && nav.selection == row.conversationID { return }
        let content = UNMutableNotificationContent()
        let sender = engine.name(row.senderUserID)
        content.title = sc?.kind == .dm ? sender : (sc?.title ?? "Asgard")
        let text = row.content.map(ChatEngine.preview) ?? "New message"
        content.body = sc?.kind == .dm ? text : "\(sender): \(text)"
        content.sound = .default
        content.threadIdentifier = row.conversationID.lower
        content.categoryIdentifier = MacNotifications.messageCategory
        content.userInfo = ["c": row.conversationID.lower, "m": row.id.lower]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: row.id.lower, content: content, trigger: nil))
    }

    func updateBadge() {
        let all = (try? engine.context.fetch(FetchDescriptor<StoredConversation>())) ?? []
        let n = all.reduce(0) { $0 + ($1.isMuted || $1.archived ? 0 : $1.unread) }
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }
}

/// Which chat the main window shows, shared with menus and notifications.
@MainActor
@Observable
final class MacNavigator {
    var folder: MacFolder = .all
    var selection: UUID?
    var showInspector = false
    var showNewChat = false
    var searching = false
    var composeFocus = 0

    func open(_ conv: UUID) {
        selection = conv
        NSApp.activate()
    }

    func handle(_ url: URL) {
        guard url.scheme == "asgard" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host() == "chat", let id = parts.first.flatMap(UUID.init(uuidString:)) { open(id) }
        if url.host() == "compose" { showNewChat = true }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MacNotifications.registerCategories()
        #if DEBUG
        // UI checks: -openChat <uuid> opens a chat after launch.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-openChat"), i + 1 < args.count, let id = UUID(uuidString: args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { MacServices.shared.nav.selection = id } }
        }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await MacServices.shared.engine.registerPush(token: deviceToken, voipToken: nil) }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { @MainActor in await MacServices.shared.engine.syncNow() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let conv = (info["c"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        await MainActor.run {
            let services = MacServices.shared
            if response.actionIdentifier == MacNotifications.reply, let text = (response as? UNTextInputNotificationResponse)?.userText, !text.isEmpty {
                Task { _ = await services.engine.send(.text(text), to: conv); services.engine.markRead(conv); services.updateBadge() }
            } else if response.actionIdentifier == MacNotifications.markRead {
                services.engine.markRead(conv)
                services.updateBadge()
            } else {
                services.nav.open(conv)
            }
        }
    }
}

enum MacNotifications {
    static let reply = "REPLY", markRead = "MARK_READ", messageCategory = "MESSAGE"

    static func registerCategories() {
        let reply = UNTextInputNotificationAction(identifier: reply, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let read = UNNotificationAction(identifier: markRead, title: "Mark as Read", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: messageCategory, actions: [reply, read], intentIdentifiers: [])])
    }

    @MainActor static func requestAndRegister() {
        Task {
            let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            if ok { NSApp.registerForRemoteNotifications() }
        }
    }
}

struct AsgardCommands: Commands {
    let nav: MacNavigator
    let engine: ChatEngine
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat…") { nav.showNewChat = true }.keyboardShortcut("n")
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Chats") { nav.searching = true }.keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandMenu("Chat") {
            Button("Show Info") { nav.showInspector.toggle() }.keyboardShortcut("i")
                .disabled(nav.selection == nil)
            Button("Mark as Read") { if let id = nav.selection { engine.markRead(id) } }.keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(nav.selection == nil)
            Divider()
            Button("Write Message") { nav.composeFocus += 1 }.keyboardShortcut("l")
            Divider()
            ForEach(Array(MacFolder.builtIn.enumerated()), id: \.offset) { i, f in
                Button(f.title) { nav.folder = f }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command])
            }
        }
        CommandGroup(after: .windowArrangement) {
            Button("Call Window") { openWindow(id: "call") }.keyboardShortcut("0", modifiers: [.command, .shift])
        }
    }
}

struct MenuBarLabel: View {
    let engine: ChatEngine
    @Query private var convs: [StoredConversation]
    init(engine: ChatEngine) { self.engine = engine }
    var body: some View {
        let n = convs.reduce(0) { $0 + ($1.isMuted || $1.archived ? 0 : $1.unread) }
        if n > 0 { Label("\(n)", systemImage: "bubble.left.and.bubble.right.fill") } else { Image(systemName: "bubble.left.and.bubble.right") }
    }
}

/// Recent chats from the menu bar.
struct MenuBarChats: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(MacNavigator.self) private var nav
    @Environment(\.openWindow) private var openWindow
    @Query(sort: [SortDescriptor(\StoredConversation.sortDate, order: .reverse)]) private var convs: [StoredConversation]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
            ForEach(convs.filter { !$0.archived && $0.kind != .community }.prefix(8)) { c in
                Button {
                    openWindow(id: "main")
                    nav.open(c.id)
                } label: {
                    HStack(spacing: 10) {
                        c.avatar(engine: engine, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.title).font(.callout.weight(c.unread > 0 ? .semibold : .regular)).lineLimit(1)
                            Text(c.previewText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if c.unread > 0 { UnreadBadge(count: c.unread, muted: c.isMuted) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 4)
            Button("Open Asgard") { openWindow(id: "main"); NSApp.activate() }.buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 8)
        }
        .frame(width: 300)
    }
}
