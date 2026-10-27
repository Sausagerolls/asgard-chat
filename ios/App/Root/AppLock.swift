import LocalAuthentication
import SwiftUI

/// Optional Face ID lock for the whole app, with a grace period.
@MainActor
@Observable
final class AppLock {
    var isLocked = false
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "appLock") }
        set { UserDefaults.standard.set(newValue, forKey: "appLock") }
    }
    var graceSeconds: Double {
        get { UserDefaults.standard.object(forKey: "appLockGrace") as? Double ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "appLockGrace") }
    }
    private var backgroundedAt: Date?

    init() { isLocked = UserDefaults.standard.bool(forKey: "appLock") }

    func appEnteredBackground() { backgroundedAt = .now }

    func appBecameActive() {
        guard enabled else { isLocked = false; return }
        if let t = backgroundedAt, Date.now.timeIntervalSince(t) > graceSeconds { isLocked = true }
        backgroundedAt = nil
        if isLocked { Task { await unlock() } }
    }

    func unlock() async {
        let ok = await Self.authenticate(reason: "Unlock Asgard")
        if ok { withAnimation { isLocked = false } }
    }

    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

struct LockOverlay: View {
    var body: some View {
        let lock = AppServices.shared.lock
        if lock.isLocked {
            ZStack {
                AuroraBackground()
                VStack(spacing: 24) {
                    Image("BrandMark").resizable().scaledToFit().frame(width: 96)
                    Text("Asgard is locked").font(.title2.bold())
                    Button { Task { await lock.unlock() } } label: {
                        Label("Unlock", systemImage: "faceid").font(.headline).padding(.horizontal, 24).padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .transition(.opacity)
        }
    }
}
