import Foundation
import OmakeyCore
import OmakeyProtocol
import UIKit

/// Settings and the small things screens remember, in UserDefaults.
@MainActor
final class AppSettings {
    private let d: UserDefaults

    init(_ defaults: UserDefaults = .standard) {
        d = defaults
    }

    private func bool(_ key: String, default value: Bool) -> Bool { d.object(forKey: key) as? Bool ?? value }

    var themeId: String {
        get { d.string(forKey: "theme") ?? Themes.defaultId }
        set { d.set(newValue, forKey: "theme") }
    }

    /// The Omarchy theme of the computer typed on last, for the "From computer" theme.
    var desktopTheme: DesktopTheme? {
        get { d.data(forKey: "desktopTheme").flatMap { try? JSONDecoder().decode(DesktopTheme.self, from: $0) } }
        set { d.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "desktopTheme") }
    }

    /// The computer `desktopTheme` came from.
    var desktopThemeFrom: String? {
        get { d.string(forKey: "desktopThemeFrom") }
        set { d.set(newValue, forKey: "desktopThemeFrom") }
    }

    /// The strip of typed text above the keyboard. On unless turned off.
    var typedText: Bool {
        get { bool("typedText", default: true) }
        set { d.set(newValue, forKey: "typedText") }
    }

    /// Trackpad-style haptics on the touchpad and keys. On unless turned off.
    var haptics: Bool {
        get { bool("haptics", default: true) }
        set { d.set(newValue, forKey: "haptics") }
    }

    /// The name the computer shows for this phone. iOS tells apps only
    /// "iPhone" without a restricted entitlement, so it's a setting.
    var phoneName: String {
        get {
            let s = d.string(forKey: "phoneName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s.isEmpty ? UIDevice.current.name : s
        }
        set { d.set(newValue, forKey: "phoneName") }
    }

    /// Sticky keys on the keyboard (⇧ in its top bar).
    var sticky: Bool {
        get { bool("sticky", default: false) }
        set { d.set(newValue, forKey: "sticky") }
    }

    /// Each computer keeps its own pointer speed: their monitors differ.
    func pointerSpeed(for target: String) -> (sensitivity: Float, preset: String) {
        let p = PointerPresets.default
        let s = d.object(forKey: "sens:\(target)") != nil ? d.float(forKey: "sens:\(target)") : p.sensitivity
        return (s, d.string(forKey: "preset:\(target)") ?? p.name)
    }

    func setPointerSpeed(_ sensitivity: Float, preset: String, for target: String) {
        d.set(sensitivity, forKey: "sens:\(target)")
        d.set(preset, forKey: "preset:\(target)")
    }

    /// Portrait mode's key pages remember where they were left: digits at first.
    var stripPage: Int {
        get { d.integer(forKey: "stripPage") }
        set { d.set(newValue, forKey: "stripPage") }
    }

    /// Portrait mode's upper key row, as arranged: key codes, 0 for an empty slot.
    var stripSlots: [Int] {
        get { (d.string(forKey: "stripSlots") ?? "").split(separator: ",", omittingEmptySubsequences: false).map { Int($0) ?? 0 } }
        set { d.set(newValue.map(String.init).joined(separator: ","), forKey: "stripSlots") }
    }

    /// SHA-256 of the text the phone and the computer last swapped, so Paste
    /// can tell whether the phone's clipboard has something newer. Only the
    /// hash is kept, never the text.
    var lastSwapped: String? {
        get { d.string(forKey: "clipLast") }
        set { d.set(newValue, forKey: "clipLast") }
    }

    /// `UIPasteboard.changeCount` when the two last swapped: unchanged means nothing new, without reading it.
    var lastSwappedChange: Int? {
        get { d.object(forKey: "clipChange") as? Int }
        set { d.set(newValue, forKey: "clipChange") }
    }
}
