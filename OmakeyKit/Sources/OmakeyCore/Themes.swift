import OmakeyProtocol

/// One color scheme, after an Omarchy theme. Colors are 0xRRGGBB.
public struct Theme: Equatable, Sendable {
    public let id: String
    public let name: String
    public let light: Bool
    public let bg: UInt32
    public let surface: UInt32
    public let key: UInt32
    public let keyMod: UInt32
    public let keyAccent: UInt32
    public let accent: UInt32
    public let layer: UInt32
    public let fg: UInt32
    public let fgDim: UInt32
    public let fgOnAccent: UInt32
    public let ok: UInt32
    public let warn: UInt32
    public let error: UInt32

    public var keyFkey: UInt32 { keyMod }
}

/// The app's themes (`Palette.kt`), and the one that follows the computer.
public enum Themes {
    public static let all: [Theme] = [
        Theme(id: "tokyo-night", name: "Tokyo Night", light: false,
              bg: 0x1A1B26, surface: 0x24283B, key: 0x2A2F45, keyMod: 0x1F2335,
              keyAccent: 0x3D59A1, accent: 0x7AA2F7, layer: 0xBB9AF7,
              fg: 0xC0CAF5, fgDim: 0x565F89, fgOnAccent: 0xE0E6FF,
              ok: 0x9ECE6A, warn: 0xE0AF68, error: 0xF7768E),
        Theme(id: "catppuccin", name: "Catppuccin", light: false,
              bg: 0x1E1E2E, surface: 0x292C3C, key: 0x363A4F, keyMod: 0x24273A,
              keyAccent: 0x45588A, accent: 0x89B4FA, layer: 0xCBA6F7,
              fg: 0xCDD6F4, fgDim: 0x6C7086, fgOnAccent: 0xE6ECFF,
              ok: 0xA6E3A1, warn: 0xF9E2AF, error: 0xF38BA8),
        Theme(id: "gruvbox", name: "Gruvbox", light: false,
              bg: 0x282828, surface: 0x32302F, key: 0x3C3836, keyMod: 0x2E2C2B,
              keyAccent: 0x7A5F24, accent: 0xD8A657, layer: 0xD3869B,
              fg: 0xEBDBB2, fgDim: 0x7C6F64, fgOnAccent: 0xFBF1C7,
              ok: 0xB8BB26, warn: 0xFE8019, error: 0xFB4934),
        Theme(id: "nord", name: "Nord", light: false,
              bg: 0x2E3440, surface: 0x3B4252, key: 0x434C5E, keyMod: 0x363D4B,
              keyAccent: 0x5E81AC, accent: 0x88C0D0, layer: 0xB48EAD,
              fg: 0xECEFF4, fgDim: 0x7B88A1, fgOnAccent: 0xF2F6FA,
              ok: 0xA3BE8C, warn: 0xEBCB8B, error: 0xBF616A),
        Theme(id: "everforest", name: "Everforest", light: false,
              bg: 0x2D353B, surface: 0x343F44, key: 0x3D484D, keyMod: 0x30393E,
              keyAccent: 0x56704C, accent: 0xA7C080, layer: 0xD699B6,
              fg: 0xD3C6AA, fgDim: 0x7A8478, fgOnAccent: 0xF0EEDB,
              ok: 0xA7C080, warn: 0xDBBC7F, error: 0xE67E80),
        Theme(id: "kanagawa", name: "Kanagawa", light: false,
              bg: 0x1F1F28, surface: 0x2A2A37, key: 0x363646, keyMod: 0x252532,
              keyAccent: 0x2D4F67, accent: 0x7E9CD8, layer: 0x957FB8,
              fg: 0xDCD7BA, fgDim: 0x727169, fgOnAccent: 0xEAE6D0,
              ok: 0x98BB6C, warn: 0xE6C384, error: 0xE46876),
        Theme(id: "rose-pine", name: "Rosé Pine", light: false,
              bg: 0x191724, surface: 0x1F1D2E, key: 0x26233A, keyMod: 0x1D1B2C,
              keyAccent: 0x524073, accent: 0xC4A7E7, layer: 0xEBBCBA,
              fg: 0xE0DEF4, fgDim: 0x6E6A86, fgOnAccent: 0xF2E9FF,
              ok: 0x9CCFD8, warn: 0xF6C177, error: 0xEB6F92),
        Theme(id: "matte-black", name: "Matte Black", light: false,
              bg: 0x121212, surface: 0x1C1C1C, key: 0x262626, keyMod: 0x1A1A1A,
              keyAccent: 0x5A3A10, accent: 0xE68E0D, layer: 0xB0A090,
              fg: 0xEAEAEA, fgDim: 0x6B6B6B, fgOnAccent: 0xFFF1DC,
              ok: 0x8FB573, warn: 0xE68E0D, error: 0xD35F5F),
        Theme(id: "catppuccin-latte", name: "Catppuccin Latte", light: true,
              bg: 0xEFF1F5, surface: 0xE6E9EF, key: 0xFFFFFF, keyMod: 0xDCE0E8,
              keyAccent: 0x1E66F5, accent: 0x1E66F5, layer: 0x8839EF,
              fg: 0x4C4F69, fgDim: 0x8C8FA1, fgOnAccent: 0xFFFFFF,
              ok: 0x40A02B, warn: 0xDF8E1D, error: 0xD20F39),
    ]

    /// The theme id that follows the computer's Omarchy theme.
    public static let fromComputerId = "computer"
    public static let defaultId = "tokyo-night"

    public static func byId(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }

    /// The computer's theme, or the default until one arrives. Omarchy gives
    /// a background, a foreground and named colors; keys and surfaces are
    /// mixed from those, a step towards the foreground (or white, on light).
    public static func fromComputer(_ d: DesktopTheme?) -> Theme {
        guard let t = d else {
            let b = all[0]
            return Theme(id: fromComputerId, name: "From computer", light: b.light, bg: b.bg, surface: b.surface, key: b.key,
                         keyMod: b.keyMod, keyAccent: b.keyAccent, accent: b.accent, layer: b.layer, fg: b.fg, fgDim: b.fgDim,
                         fgOnAccent: b.fgOnAccent, ok: b.ok, warn: b.warn, error: b.error)
        }
        let bg = t.color("background")
        let fg = t.color("foreground")
        let accent = t.color("accent")
        let white: UInt32 = 0xFFFFFF
        return Theme(
            id: fromComputerId, name: prettyName(t.name), light: t.light,
            bg: bg,
            surface: mix(bg, fg, t.light ? 0.05 : 0.07),
            key: t.light ? mix(bg, white, 0.75) : mix(bg, fg, 0.12),
            keyMod: mix(bg, fg, t.light ? 0.09 : 0.05),
            keyAccent: t.light ? accent : mix(bg, accent, 0.45),
            accent: accent,
            layer: t.color("magenta"),
            fg: fg,
            fgDim: t.color("muted"),
            fgOnAccent: t.light ? white : mix(white, accent, 0.12),
            ok: t.color("green"),
            warn: t.color("yellow"),
            error: t.color("red")
        )
    }

    /// "tokyo-night" as Omarchy shows it: "Tokyo Night".
    public static func prettyName(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// [a] moved [t] of the way to [b], per channel.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Float) -> UInt32 {
        func ch(_ shift: UInt32) -> UInt32 {
            let v = Float((a >> shift) & 0xFF) * (1 - t) + Float((b >> shift) & 0xFF) * t
            return UInt32(min(max(Int(v), 0), 255))
        }
        return ch(16) << 16 | ch(8) << 8 | ch(0)
    }
}

/// Touchpad speed presets for common developer monitors. The pointer moves in
/// the desktop's logical pixels, so what matters is the logical width: a 4K
/// screen at 1.5× scaling behaves like a 1440p one. The value is roughly
/// proportional to that width, so one swipe across the pad covers a similar
/// share of any screen (the desktop's pointer acceleration does the rest).
public enum PointerPresets {
    public struct Preset: Equatable, Sendable {
        public let name: String
        public let detail: String
        public let sensitivity: Float
    }

    public static let all = [
        Preset(name: "Laptop", detail: "13–16″ laptop, about 1920 wide after scaling", sensitivity: 0.8),
        Preset(name: "1080p", detail: "24″ 1920×1080, or 4K at 2× scaling", sensitivity: 0.85),
        Preset(name: "1440p", detail: "27″ 2560×1440, or 4K at 1.5× scaling", sensitivity: 1.1),
        Preset(name: "Ultrawide 1440p", detail: "34″ 3440×1440", sensitivity: 1.45),
        Preset(name: "4K unscaled", detail: "32″+ 3840×2160 at 100%", sensitivity: 1.6),
        Preset(name: "Super ultrawide", detail: "49″ 5120×1440, or two 1440p side by side", sensitivity: 2.1),
        Preset(name: "Triple 1080p", detail: "three 1920×1080 side by side", sensitivity: 2.4),
    ]

    public static let `default` = all.first { $0.name == "1440p" }!
    /// The chip's name once the slider moved.
    public static let custom = "Custom"
}
