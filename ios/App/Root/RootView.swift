import AsgardKit
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(CallManager.self) private var calls
    @Environment(Appearance.self) private var appearance

    var body: some View {
        ZStack {
            switch engine.phase {
            case .loading:
                SplashView()
            case .signedOut:
                OnboardingFlow()
                    .transition(.opacity)
            case .ready:
                MainTabView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
            LockOverlay()
        }
        .animation(.smooth(duration: 0.4), value: engine.phase)
        .fullScreenCover(item: Binding(get: { calls.presentedCall }, set: { calls.presentedCall = $0 })) { call in
            CallScreen(call: call)
        }
        .overlay(alignment: .top) { BannerView() }
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            AuroraBackground()
            Image("BrandMark").resizable().scaledToFit().frame(width: 140)
                .shadow(color: Brand.violet.opacity(0.5), radius: 30)
        }
    }
}

/// Transient banner for engine messages ("Scheduled for…", errors).
struct BannerView: View {
    @Environment(ChatEngine.self) private var engine

    var body: some View {
        if let text = engine.banner {
            Text(text)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { engine.banner = nil }
                }
                .onTapGesture { withAnimation { engine.banner = nil } }
        }
    }
}

struct MainTabView: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(Router.self) private var router
    @Query(filter: #Predicate<StoredConversation> { !$0.archived }) private var conversations: [StoredConversation]

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab("Chats", systemImage: "bubble.left.and.text.bubble.right.fill", value: .chats) {
                ChatsTab()
            }
            .badge(conversations.reduce(0) { $0 + ($1.isMuted ? 0 : $1.unread) })

            if engine.callsAvailable {
                Tab("Calls", systemImage: "phone.fill", value: .calls) {
                    CallsTab()
                }
            }

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsTab()
            }

            Tab(value: .search, role: .search) {
                GlobalSearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: showAccessory) {
            if let call = AppServices.shared.calls.active {
                OngoingCallAccessory(call: call)
            } else {
                ConnectionAccessory()
            }
        }
    }
}

extension MainTabView {
    var showAccessory: Bool {
        AppServices.shared.calls.active != nil || (engine.connection != .connected && !engine.isDemo)
    }
}

struct ConnectionAccessory: View {
    @Environment(ChatEngine.self) private var engine
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(engine.connection == .connecting ? "Connecting…" : "Waiting for network…").font(.subheadline)
        }
        .frame(maxWidth: .infinity)
    }
}
