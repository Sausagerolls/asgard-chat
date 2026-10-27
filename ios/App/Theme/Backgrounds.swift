import SwiftUI

/// Slowly drifting aurora: a mesh gradient over the night sky.
struct AuroraBackground: View {
    var animated = true
    var intensity: Double = 1
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated || reduceMotion)) { context in
            let t = animated && !reduceMotion ? context.date.timeIntervalSinceReferenceDate : 0
            MeshGradient(width: 3, height: 3, points: points(t), colors: colors)
                .overlay(StarField().opacity(scheme == .dark ? 0.9 : 0))
        }
        .ignoresSafeArea()
    }

    private var base: Color { scheme == .dark ? Brand.night : Color(red: 0.96, green: 0.95, blue: 1) }

    private var colors: [Color] {
        let v = Brand.violet.opacity(0.55 * intensity), t = Brand.teal.opacity(0.35 * intensity), g = Brand.gold.opacity(0.18 * intensity)
        let n = scheme == .dark ? Brand.navy : Color(red: 0.92, green: 0.90, blue: 1)
        return [v.mix(with: base, by: 0.2), base, t.mix(with: base, by: 0.5),
                base, n, base,
                base, g.mix(with: base, by: 0.6), t.mix(with: base, by: 0.3)]
    }

    private func points(_ t: Double) -> [SIMD2<Float>] {
        let s = { (p: Double, a: Double) in Float(0.5 + a * sin(t * 0.18 + p)) }
        return [[0, 0], [s(0, 0.25), 0], [1, 0],
                [0, s(1.3, 0.2)], [s(2.1, 0.18), s(0.7, 0.18)], [1, s(2.6, 0.2)],
                [0, 1], [s(3.4, 0.25), 1], [1, 1]]
    }
}

struct StarField: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 7)
            for _ in 0..<70 {
                let x = rng.next() * size.width, y = rng.next() * size.height * 0.7
                let r = 0.4 + rng.next() * 1.3
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.15 + rng.next() * 0.5)))
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
                StarField().ignoresSafeArea()
            }
        case .dusk:
            LinearGradient(colors: [Color(red: 0.20, green: 0.10, blue: 0.35), Color(red: 0.55, green: 0.25, blue: 0.35), Color(red: 0.95, green: 0.55, blue: 0.30)],
                           startPoint: .top, endPoint: .bottom).opacity(scheme == .dark ? 1 : 0.45).ignoresSafeArea()
        case .fjord:
            LinearGradient(colors: [Color(red: 0.05, green: 0.15, blue: 0.25), Color(red: 0.10, green: 0.35, blue: 0.45), Color(red: 0.55, green: 0.75, blue: 0.80)],
                           startPoint: .top, endPoint: .bottom).opacity(scheme == .dark ? 1 : 0.45).ignoresSafeArea()
        case .plain:
            Color(uiColor: .systemBackground).ignoresSafeArea()
        }
    }
}
