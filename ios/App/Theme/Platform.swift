import SwiftUI

// Small shims so the theme compiles for both the iOS and the native macOS app.
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage

extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}

extension Color {
    static var platformBackground: Color { Color(nsColor: .windowBackgroundColor) }
}
#else
import UIKit
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}

extension Color {
    static var platformBackground: Color { Color(uiColor: .systemBackground) }
}
#endif
