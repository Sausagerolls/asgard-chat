import SwiftUI

/// Asgard's visual language: Bifröst aurora on a night sky.
enum Brand {
    static let night = Color(red: 0.031, green: 0.043, blue: 0.122)
    static let navy = Color(red: 0.078, green: 0.094, blue: 0.220)
    static let violet = Color(red: 0.545, green: 0.361, blue: 0.965)
    static let teal = Color(red: 0.176, green: 0.831, blue: 0.749)
    static let gold = Color(red: 0.984, green: 0.749, blue: 0.141)

    static let aurora = LinearGradient(colors: [violet, Color(red: 0.36, green: 0.55, blue: 0.94), teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let bifrost = LinearGradient(colors: [violet, teal, gold], startPoint: .leading, endPoint: .trailing)
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case aurora, violet, teal, gold, rose, ember, frost, moss
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .aurora, .violet: Brand.violet
        case .teal: Brand.teal
        case .gold: Brand.gold
        case .rose: Color(red: 0.957, green: 0.447, blue: 0.714)
        case .ember: Color(red: 0.976, green: 0.451, blue: 0.086)
        case .frost: Color(red: 0.376, green: 0.647, blue: 0.980)
        case .moss: Color(red: 0.204, green: 0.827, blue: 0.600)
        }
    }

    /// Fill for outgoing bubbles and primary buttons.
    var fill: AnyShapeStyle {
        switch self {
        case .aurora: AnyShapeStyle(Brand.aurora)
        default: AnyShapeStyle(LinearGradient(colors: [color, color.mix(with: .black, by: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    var title: String { rawValue.capitalized }
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

enum BubbleStyle: String, CaseIterable, Identifiable {
    case rounded, tailed, minimal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum Wallpaper: String, CaseIterable, Identifiable {
    case aurora, stars, dusk, fjord, plain
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Appearance preferences, persisted per device.
@Observable
final class Appearance {
    var theme: ThemeChoice { didSet { save() } }
    var accent: AccentChoice { didSet { save() } }
    var bubbles: BubbleStyle { didSet { save() } }
    var wallpaper: Wallpaper { didSet { save() } }
    var textScale: Double { didSet { save() } }
    var animatedBackgrounds: Bool { didSet { save() } }
    var messageAnimations: Bool { didSet { save() } }

    init() {
        let d = UserDefaults.standard
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .dark
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .aurora
        bubbles = BubbleStyle(rawValue: d.string(forKey: "bubbles") ?? "") ?? .tailed
        wallpaper = Wallpaper(rawValue: d.string(forKey: "wallpaper") ?? "") ?? .aurora
        textScale = d.object(forKey: "textScale") as? Double ?? 1
        animatedBackgrounds = d.object(forKey: "animatedBackgrounds") as? Bool ?? true
        messageAnimations = d.object(forKey: "messageAnimations") as? Bool ?? true
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(theme.rawValue, forKey: "theme")
        d.set(accent.rawValue, forKey: "accent")
        d.set(bubbles.rawValue, forKey: "bubbles")
        d.set(wallpaper.rawValue, forKey: "wallpaper")
        d.set(textScale, forKey: "textScale")
        d.set(animatedBackgrounds, forKey: "animatedBackgrounds")
        d.set(messageAnimations, forKey: "messageAnimations")
    }
}

extension View {
    /// Card-like glass panel used across settings and sheets.
    func glassCard(cornerRadius: CGFloat = 22) -> some View {
        padding(16).glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

extension Color {
    /// Stable pleasant color for an id (avatars, sender names).
    static func identity(_ id: UUID?) -> Color {
        let palette: [Color] = [Brand.violet, Brand.teal, Brand.gold, .pink, .orange, Color(red: 0.38, green: 0.65, blue: 0.98), .mint, .indigo, .red, .cyan]
        guard let id else { return .gray }
        let h = id.uuid.0 ^ id.uuid.5 ^ id.uuid.10 ^ id.uuid.15
        return palette[Int(h) % palette.count]
    }
}
