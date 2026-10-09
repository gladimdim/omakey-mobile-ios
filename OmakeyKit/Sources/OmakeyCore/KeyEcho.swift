import Foundation
import OmakeyProtocol

/// Key labels by code, from keycodes.json: what a key says on a keyboard.
public enum KeyNames {
    public static let labels: [Int: String] = {
        var labels: [Int: String] = [:]
        if let root = try? JSONSerialization.jsonObject(with: Data(BundledSpec.keycodesJSON().utf8)) as? [String: Any],
           let keys = root["keys"] as? [[String: Any]] {
            for k in keys {
                guard let code = (k["code"] as? NSNumber)?.intValue, labels[code] == nil else { continue }
                let name = k["name"] as? String ?? "code \(code)"
                labels[code] = (k["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name.replacingOccurrences(of: "KEY_", with: "")
            }
        }
        labels[Wire.btnLeft] = "left click"
        labels[Wire.btnRight] = "right click"
        labels[Wire.btnMiddle] = "middle click"
        return labels
    }()

    public static func label(_ code: Int) -> String { labels[code] ?? "code \(code)" }
}

/// What a computer shows for the keys it gets, for the demo computer:
/// characters as typed ("k", or "K" with Shift or Caps Lock, in the layout
/// the phone asked for), "Ctrl+C" for a shortcut, a key that types no
/// character by its name ("Enter"), and a modifier pressed and let go on
/// its own by its name too ("Super").
public struct KeyEcho: Sendable {
    private var layout = KeyLayouts.us
    /// Modifiers down.
    private var held: Set<Int> = []
    private var capsLock = false
    /// The modifier pressed with nothing else since: it's shown when let go.
    private var alone: Int?

    public init() {}

    /// The phone asked the computer to read its keys with this layout.
    public mutating func setLayout(_ xkb: String) {
        if let l = KeyLayouts.named(xkb) { layout = l }
    }

    /// Everything let go at once.
    public mutating func releaseAll() {
        held.removeAll()
        alone = nil
    }

    /// A key went down or up: what the computer would show for it, if anything.
    public mutating func key(_ code: Int, down: Bool) -> String? {
        if UsKeys.modifiers.contains(code) {
            if down {
                held.insert(code)
                alone = code
                return nil
            }
            held.remove(code)
            defer { alone = nil }
            return alone == code ? KeyEcho.modifier(code) : nil
        }
        guard down else { return nil }
        alone = nil
        if code == KeyEcho.keyCapsLock { capsLock.toggle() }
        let shift = held.contains(42) || held.contains(54)
        let shortcut = held.contains { $0 != 42 && $0 != 54 }
        if !shortcut, let c = typed(code, shift: shift) { return c }
        let mods = KeyEcho.order.filter { m in held.contains { KeyEcho.modifier($0) == m } }
        return (mods + [KeyNames.label(code)]).joined(separator: "+")
    }

    private func typed(_ code: Int, shift: Bool) -> String? {
        if code == UsKeys.keySpace { return "␣" }
        guard var c = layout.char(code, shift: shift), !c.isWhitespace else { return nil }
        // Caps Lock shifts letters only, as on the computer.
        if capsLock, c.isLetter, let other = layout.char(code, shift: !shift) { c = other }
        return String(c)
    }

    private static let keyCapsLock = 58
    private static let order = ["Super", "Ctrl", "Alt", "AltGr", "Shift"]

    private static func modifier(_ code: Int) -> String {
        switch code {
        case 29, 97: "Ctrl"
        case 42, 54: "Shift"
        case 56: "Alt"
        case 100: "AltGr"
        default: "Super"
        }
    }
}
