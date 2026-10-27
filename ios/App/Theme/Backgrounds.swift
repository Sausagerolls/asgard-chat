import SwiftUI

/// Drifting aurora: a mesh gradient whose control points and colours move
/// like curtains of light, over a twinkling night sky.
struct AuroraBackground: View {
    var animated = true
    var intensity: Double = 1
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Settings › Appearance › Animated backgrounds (shared by iOS and Mac).
    @AppStorage("animatedBackgrounds") private var setting = true

    var body: some View {
        let moving = animated && setting && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { context in
            let t = moving ? context.date.timeIntervalSinceReferenceDate : 0
            MeshGradient(width: 3, height: 3, points: points(t), colors: colors(t))
                .overlay(StarField(time: t).opacity(scheme == .dark ? 0.9 : 0))
        }
        .ignoresSafeArea()
    }

    private var base: Color { scheme == .dark ? Brand.night : Color(red: 0.96, green: 0.95, blue: 1) }

    private func colors(_ t: Double) -> [Color] {
        // Each band breathes on its own slow rhythm.
        let pv = 0.75 + 0.25 * sin(t * 0.45), pt = 0.7 + 0.3 * sin(t * 0.37 + 2), pg = 0.6 + 0.4 * sin(t * 0.29 + 4)
        let v = Brand.violet.opacity(0.6 * intensity * pv), te = Brand.teal.opacity(0.42 * intensity * pt), g = Brand.gold.opacity(0.22 * intensity * pg)
        let n = scheme == .dark ? Brand.navy : Color(red: 0.92, green: 0.90, blue: 1)
        return [v.mix(with: base, by: 0.15), base, te.mix(with: base, by: 0.4),
                base, n.mix(with: Brand.violet.opacity(0.4 * intensity), by: 0.2 + 0.15 * sin(t * 0.3)), base,
                te.mix(with: base, by: 0.55), g.mix(with: base, by: 0.5), v.mix(with: base, by: 0.35)]
    }

    private func points(_ t: Double) -> [SIMD2<Float>] {
        let s = { (phase: Double, speed: Double, amp: Double) in Float(0.5 + amp * sin(t * speed + phase)) }
        return [[0, 0], [s(0, 0.33, 0.32), 0], [1, 0],
                [0, s(1.3, 0.27, 0.3)], [s(2.1, 0.41, 0.28), s(0.7, 0.36, 0.28)], [1, s(2.6, 0.3, 0.3)],
                [0, 1], [s(3.4, 0.29, 0.32), 1], [1, 1]]
    }
}

struct StarField: View {
    var time: Double = 0
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 7)
            for _ in 0..<80 {
                let x = rng.next() * size.width, y = rng.next() * size.height * 0.7
                let r = 0.4 + rng.next() * 1.3
                let base = 0.15 + rng.next() * 0.5, phase = rng.next() * 6.28, speed = 0.6 + rng.next() * 1.6
                let twinkle = base * (0.55 + 0.45 * sin(time * speed + phase))
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(.white.opacity(twinkle)))
            }
        }
        .allowsHitTesting(false)
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 33) / Double(1 << 31)
    }
}

/// Chat wallpaper behind the message list.
struct ChatWallpaper: View {
    let wallpaper: Wallpaper
    var animated: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch wallpaper {
        case .aurora:
            AuroraBackground(animated: animated, intensity: 0.7)
        case .stars:
            ZStack {
                (scheme == .dark ? Brand.night : Color(red: 0.95, green: 0.95, blue: 0.99)).ignoresSafeArea()
                TimelineView(.animation(minimumInterval: 1 / 15, paused: !animated)) { c in
                    StarField(time: animated ? c.date.timeIntervalSinceReferenceDate : 0)
                }
                .ignoresSafeArea()
            }
        case .dusk:
            LinearGradient(colors: [Color(red: 0.20, green: 0.10, blue: 0.35), Color(red: 0.55, green: 0.25, blue: 0.35), Color(red: 0.95, green: 0.55, blue: 0.30)],
                           startPoint: .top, endPoint: .bottom).opacity(scheme == .dark ? 1 : 0.45).ignoresSafeArea()
        case .fjord:
            LinearGradient(colors: [Color(red: 0.05, green: 0.15, blue: 0.25), Color(red: 0.10, green: 0.35, blue: 0.45), Color(red: 0.55, green: 0.75, blue: 0.80)],
                           startPoint: .top, endPoint: .bottom).opacity(scheme == .dark ? 1 : 0.45).ignoresSafeArea()
        case .plain:
            Color.platformBackground.ignoresSafeArea()
        }
    }
}
