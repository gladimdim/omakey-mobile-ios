import OmakeyCore
import SwiftUI
import UIKit

extension Color {
    /// 0xRRGGBB.
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

extension UIColor {
    /// 0xRRGGBB.
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

/// The colors every screen draws with, from the chosen theme.
struct Palette {
    let theme: Theme

    var bg: Color { Color(rgb: theme.bg) }
    var surface: Color { Color(rgb: theme.surface) }
    var key: Color { Color(rgb: theme.key) }
    var keyMod: Color { Color(rgb: theme.keyMod) }
    var keyAccent: Color { Color(rgb: theme.keyAccent) }
    var accent: Color { Color(rgb: theme.accent) }
    var layer: Color { Color(rgb: theme.layer) }
    var fg: Color { Color(rgb: theme.fg) }
    var fgDim: Color { Color(rgb: theme.fgDim) }
    var fgOnAccent: Color { Color(rgb: theme.fgOnAccent) }
    var ok: Color { Color(rgb: theme.ok) }
    var warn: Color { Color(rgb: theme.warn) }
    var error: Color { Color(rgb: theme.error) }
    var colorScheme: ColorScheme { theme.light ? .light : .dark }
}

extension Font {
    /// Every screen is set in the monospaced face, as on Android.
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .system(size: size, weight: bold ? .bold : .regular, design: .monospaced)
    }
}

extension UIFont {
    static func mono(_ size: CGFloat, bold: Bool = false) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}
