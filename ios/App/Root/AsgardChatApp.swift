import AsgardKit
import Intents
import SwiftData
import SwiftUI

@main
struct AsgardChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appearance = Appearance()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppServices.shared.engine)
                .environment(AppServices.shared.calls)
                .environment(AppServices.shared.router)
                .environment(appearance)
                .modelContainer(AppServices.shared.engine.container)
                .preferredColorScheme(appearance.theme.scheme)
                .tint(appearance.accent.color)
                .dynamicTypeSize(Appearance.typeSize(for: appearance.textScale))
                .onOpenURL { AppServices.shared.router.open($0) }
                .onContinueUserActivity("INSendMessageIntent") { AppServices.shared.router.handle($0) }
                .onContinueUserActivity("INStartCallIntent") { AppServices.shared.router.handle($0) }
                .task { await AppServices.shared.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            AppServices.shared.scenePhaseChanged(phase)
        }
    }
}

/// Long-lived app objects, reachable from UIKit delegates (CarPlay, push, CallKit).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let engine: ChatEngine
    let calls: CallManager
    let router = Router()
    let lock = AppLock()

    private init() {
        let container: ModelContainer
        do {
            container = try LocalStore.container()
        } catch {
            // A corrupt store should never brick the app: start fresh.
            try? FileManager.default.removeItem(at: AppGroup.containerURL.appending(path: "Asgard.store"))
            container = (try? LocalStore.container()) ?? (try! LocalStore.container(inMemory: true))
        }
        engine = ChatEngine(container: container, demo: ProcessInfo.processInfo.arguments.contains("-demo"))
        calls = CallManager(engine: engine)
        engine.onIncomingCall = { [weak calls] call in calls?.reportIncoming(call) }
        engine.onCallEnded = { [weak calls] conv in calls?.remoteEnded(conv) }
    }

    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        await engine.start()
        #if DEBUG
        // Screenshots: -signIn <server> <username> <password> on a fresh install.
        let launch = ProcessInfo.processInfo.arguments
        if engine.phase != .ready, let i = launch.firstIndex(of: "-signIn"), i + 3 < launch.count, let url = URL(string: launch[i + 1]) {
            try? await engine.signIn(server: url, username: launch[i + 2], password: launch[i + 3], deviceName: "Simulator")
        }
        #endif
        if engine.phase == .ready && !engine.isDemo { PushRegistrar.shared.register() }
        Notifications.registerCategories()
        // UI testing / screenshots: -openChat <uuid>, -tab <calls|settings>
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-openChat"), i + 1 < args.count { router.openConversation = UUID(uuidString: args[i + 1]) }
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count {
            router.selectedTab = ["people": .people, "calls": .calls, "settings": .settings][args[i + 1]] ?? .chats
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            engine.foreground()
            lock.appBecameActive()
        case .background:
            lock.appEnteredBackground()
            WidgetBridge.reload(engine: engine)
        default:
            break
        }
    }
}

/// Deep links and navigation requests from outside the view tree.
@MainActor
@Observable
final class Router {
    var selectedTab: AppTab = .chats
    var openConversation: UUID?
    var pendingInvite: String?
    var pendingLink: (host: String, code: String)?
    var composeTo: UUID?

    func open(_ url: URL) {
        // asgard://chat/<id>, asgard://link?host=..&code=.., https://host/invite/CODE
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.scheme == "asgard" {
            switch url.host() {
            case "chat": openConversation = parts.first.flatMap(UUID.init(uuidString:)); selectedTab = .chats
            case "link":
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let host = q.first(where: { $0.name == "host" })?.value, let code = q.first(where: { $0.name == "code" })?.value {
                    pendingLink = (host, code)
                }
            case "compose": composeTo = parts.first.flatMap(UUID.init(uuidString:)); selectedTab = .chats
            default: break
            }
        } else if parts.first == "invite", parts.count > 1 {
            pendingInvite = parts[1]
            AppGroup.defaults.set("https://\(url.host() ?? "")", forKey: "lastServer")
        } else if parts.first == "c", parts.count > 1 {
            openConversation = UUID(uuidString: parts[1])
        }
    }

    func handle(_ activity: NSUserActivity) {
        let intent = activity.interaction?.intent
        if let id = (intent as? INSendMessageIntent)?.conversationIdentifier.flatMap(UUID.init(uuidString:)) {
            openConversation = id
            selectedTab = .chats
        } else if let start = intent as? INStartCallIntent, let handle = start.contacts?.first?.personHandle?.value,
                  let conv = UUID(uuidString: handle) {
            Task { await AppServices.shared.calls.start(conv, video: start.callCapability == .videoCall) }
        }
    }
}

enum AppTab: Hashable { case chats, people, calls, settings, search }
