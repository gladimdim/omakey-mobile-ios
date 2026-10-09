import Foundation

/// Linux key names ↔ codes and default labels, from the studio's keycodes.json.
public struct Keycodes: Sendable {
    private let byName: [String: Int]
    private let labels: [String: String]

    public init(byName: [String: Int], labels: [String: String] = [:]) {
        self.byName = byName
        self.labels = labels
    }

    public func code(_ name: String) -> Int? { byName[name] }

    /// The label a key with this code shows by default: keycodes.json's, else the name without `KEY_`.
    public func label(_ name: String) -> String {
        labels[name] ?? (name.hasPrefix("KEY_") ? String(name.dropFirst(4)) : name)
    }

    public static func parse(_ json: String) throws -> Keycodes {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let keys = root["keys"] as? [[String: Any]]
        else { throw LayoutError("Not a keycodes file") }
        var map = [String: Int]()
        var labels = [String: String]()
        for k in keys {
            guard let name = k["name"] as? String, let code = (k["code"] as? NSNumber)?.intValue else { continue }
            map[name] = code
            if let label = k["label"] as? String, !label.isEmpty { labels[name] = label }
        }
        return Keycodes(byName: map, labels: labels)
    }

    /// Codes the daemon accepts (PROTOCOL.md, "Safety rules").
    public static func allowed(_ code: Int) -> Bool { (1...0xFF).contains(code) || (0x160...0x2BF).contains(code) }
}

public enum KeyStyle: String, Sendable {
    case normal, mod, fkey, accent, space
}

/// A key's behavior on one layer. [code] 0 means the key does nothing there
/// (and shows no label); otherwise [label] is the override's own label or its
/// code's default one (LAYOUT.md, `layers`).
public struct LayerOverride: Sendable, Equatable {
    public let code: Int
    public let codeName: String?
    public let label: String
    /// The entry's own `label`, for the printed Fn legend; nil when it relies on the default.
    public let ownLabel: String?
}

/// A rectangle in layout units.
public struct KeyRect: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let w: Float
    public let h: Float

    public init(x: Float, y: Float, w: Float, h: Float) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public func contains(_ ux: Float, _ uy: Float) -> Bool { ux >= x && ux < x + w && uy >= y && uy < y + h }

    /// This rectangle with a split layout's gap widened by [stretch] units:
    /// rectangles right of [splitAt] move right, ones crossing it get wider.
    public func stretched(splitAt: Float?, stretch: Float) -> KeyRect {
        guard let splitAt, stretch > 0 else { return self }
        let left = x >= splitAt ? x + stretch : x
        let right = x + w > splitAt ? x + w + stretch : x + w
        return KeyRect(x: left, y: y, w: right - left, h: h)
    }
}

public struct LayoutKey: Sendable {
    public let id: String
    public let x: Float
    public let y: Float
    public let w: Float
    public let h: Float
    public let label: String
    public let sub: String?
    /// Base key code, or 0 for a layer key.
    public let code: Int
    public let codeName: String?
    /// Layer this key switches to while held, or nil.
    public let layer: String?
    public let style: KeyStyle
    public let layers: [String: LayerOverride]
    /// Extra rectangles of a shaped key (a U-shaped Enter, say); empty for most keys.
    public let parts: [KeyRect]

    /// The main rectangle (where the label goes) first, then the parts.
    public var rects: [KeyRect] { [KeyRect(x: x, y: y, w: w, h: h)] + parts }
}

public struct Layout: Sendable {
    public let id: String
    public let name: String
    public let author: String?
    public let description: String?
    public let width: Float
    public let height: Float
    public let keys: [LayoutKey]
    /// The original JSON, so imports can be saved as-is.
    public let source: String
    /// Split point in units, or nil. Keys with x >= splitAt are the right
    /// side; the view pins each side to its screen edge.
    public let splitAt: Float?
}

public struct LayoutError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public init(_ message: String) { self.message = message }
}

/// Parses and validates a layout file against LAYOUT.md.
public enum LayoutParser {
    public static let maxBytes = 256 * 1024
    static let maxKeys = 256
    static let maxLabel = 16
    static let maxParts = 8
    /// Deeper JSON is refused before parsing, as on Android.
    static let maxDepth = 32

    public static func parse(_ json: String, keycodes: Keycodes) throws -> Layout {
        if json.utf16.count > maxBytes { throw LayoutError("Layout is larger than 256 KB") }
        if nesting(json) > maxDepth { throw LayoutError("Layout is nested too deeply") }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        } catch {
            throw LayoutError("Not valid JSON: \(error.localizedDescription)")
        }
        guard let root = parsed as? [String: Any] else { throw LayoutError("Not valid JSON: not an object") }

        guard root["format"] as? String == "omakey-layout" else { throw LayoutError("Not an Omakey layout file") }
        let version = root["version"]
        guard let v = number(version), v == 1 else {
            throw LayoutError("Layout version \(version.map { "\($0)" } ?? "null") is not supported; update the app")
        }
        let id = try str(root, "id")
        guard isLayoutId(id) else { throw LayoutError("Bad layout id \"\(id)\"") }
        let name = try str(root, "name")
        if name.isEmpty || name.unicodeScalars.count > 64 { throw LayoutError("Layout name must be 1-64 characters") }
        let width = try num(root, "width")
        let height = try num(root, "height")
        guard width > 0, width <= 64, height > 0, height <= 32 else { throw LayoutError("Bad layout size") }
        let splitAt: Float? = root.keys.contains("splitAt") ? try num(root, "splitAt") : nil
        if let splitAt, !(splitAt > 0 && splitAt < width) { throw LayoutError("splitAt must be inside the layout") }

        guard let arr = root["keys"] as? [Any] else { throw LayoutError("Layout is missing a field: keys") }
        if arr.isEmpty { throw LayoutError("Layout has no keys") }
        if arr.count > maxKeys { throw LayoutError("Layout has more than \(maxKeys) keys") }

        var ids = Set<String>()
        let keys = try arr.map { item -> LayoutKey in
            guard let o = item as? [String: Any] else { throw LayoutError("Layout is missing a field: keys") }
            return try parseKey(o, keycodes, &ids)
        }
        return Layout(id: id, name: name, author: try optStr(root, "author"), description: try optStr(root, "description"),
                      width: width, height: height, keys: keys, source: json, splitAt: splitAt)
    }

    private static func parseKey(_ o: [String: Any], _ keycodes: Keycodes, _ ids: inout Set<String>) throws -> LayoutKey {
        let id = try str(o, "id")
        if id.isEmpty || id.utf16.count > 64 || !ids.insert(id).inserted { throw LayoutError("Duplicate or bad key id \"\(id)\"") }
        let x = try num(o, "x")
        let y = try num(o, "y")
        let w = try num(o, "w")
        let h = try num(o, "h")
        if x < 0 || y < 0 { throw LayoutError("Key \(id) has a negative position") }
        if !(0.25...16).contains(w) || !(0.25...16).contains(h) { throw LayoutError("Key \(id) size must be 0.25-16 units") }

        let label = try checkLabel(try str(o, "label"), id)
        let sub = try optStr(o, "sub").map { try checkLabel($0, id) }
        let codeName = try optStr(o, "code")
        let layer = try optStr(o, "layer")
        if (codeName == nil) == (layer == nil) { throw LayoutError("Key \(id) needs exactly one of code or layer") }
        if let layer, !isLayerName(layer) { throw LayoutError("Key \(id) has a bad layer name") }
        let code = try codeName.map { try resolve($0, keycodes, id) } ?? 0

        let styleName = try optStr(o, "style") ?? "normal"
        guard let style = KeyStyle(rawValue: styleName) else { throw LayoutError("Key \(id) has unknown style \"\(styleName)\"") }

        var layers = [String: LayerOverride]()
        if let lo = try obj(o, "layers") {
            for (lname, value) in lo {
                if !isLayerName(lname) { throw LayoutError("Key \(id) has a bad layer name") }
                guard let entry = value as? [String: Any] else { throw LayoutError("Key \(id) layer \(lname) must be an object") }
                let n = try optStr(entry, "code")
                // LAYOUT.md, "Layers": its own label, else its code's default;
                // no code turns the key off there, blank unless labelled.
                let own = try optStr(entry, "label").map { try checkLabel($0, id) }
                let shown = own ?? (n.map(keycodes.label) ?? "")
                layers[lname] = LayerOverride(code: try n.map { try resolve($0, keycodes, id) } ?? 0, codeName: n, label: shown, ownLabel: own)
            }
        }

        var parts = [KeyRect]()
        if let raw = o["parts"] {
            guard let arr = raw as? [Any] else { throw LayoutError("Key \(id) parts must be a list") }
            if !(1...maxParts).contains(arr.count) { throw LayoutError("Key \(id) must have 1-\(maxParts) parts") }
            for (n, item) in arr.enumerated() {
                guard let p = item as? [String: Any] else { throw LayoutError("Key \(id) part \(n + 1) must be an object") }
                let r = KeyRect(x: try num(p, "x"), y: try num(p, "y"), w: try num(p, "w"), h: try num(p, "h"))
                if r.x < 0 || r.y < 0 || !(0.25...16).contains(r.w) || !(0.25...16).contains(r.h) {
                    throw LayoutError("Key \(id) part \(n + 1) has a bad position or size")
                }
                parts.append(r)
            }
        }
        return LayoutKey(id: id, x: x, y: y, w: w, h: h, label: label, sub: sub, code: code, codeName: codeName,
                         layer: layer, style: style, layers: layers, parts: parts)
    }

    private static func resolve(_ name: String, _ keycodes: Keycodes, _ id: String) throws -> Int {
        guard let code = keycodes.code(name) else { throw LayoutError("Key \(id) uses unknown key code \(name)") }
        if !Keycodes.allowed(code) { throw LayoutError("Key \(id) uses \(name), which can't be sent") }
        return code
    }

    private static func checkLabel(_ s: String, _ id: String) throws -> String {
        if s.unicodeScalars.count > maxLabel { throw LayoutError("Key \(id) label is over \(maxLabel) characters") }
        return s
    }

    // Typed reads: the schema's types, no coercion ("1" is not a number, 7 is not a label).

    /// A JSON number that isn't a boolean (NSNumber holds both).
    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func str(_ o: [String: Any], _ name: String) throws -> String {
        guard let s = o[name] as? String else { throw LayoutError("\"\(name)\" must be text") }
        return s
    }

    private static func optStr(_ o: [String: Any], _ name: String) throws -> String? {
        switch o[name] {
        case nil, is NSNull: return nil
        case let s as String: return s
        default: throw LayoutError("\"\(name)\" must be text")
        }
    }

    private static func num(_ o: [String: Any], _ name: String) throws -> Float {
        guard let d = number(o[name]) else { throw LayoutError("\"\(name)\" must be a number") }
        let f = Float(d)
        guard f.isFinite else { throw LayoutError("\"\(name)\" must be a number") }
        return f
    }

    private static func obj(_ o: [String: Any], _ name: String) throws -> [String: Any]? {
        switch o[name] {
        case nil, is NSNull: return nil
        case let d as [String: Any]: return d
        default: throw LayoutError("\"\(name)\" must be an object")
        }
    }

    /// `^[a-z0-9][a-z0-9-]{0,63}$`
    static func isLayoutId(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...64).contains(b.count), isLower(b[0]) || isDigit(b[0]) else { return false }
        return b.allSatisfy { isLower($0) || isDigit($0) || $0 == UInt8(ascii: "-") }
    }

    /// `^[a-z][a-z0-9]{0,15}$`
    static func isLayerName(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...16).contains(b.count), isLower(b[0]) else { return false }
        return b.allSatisfy { isLower($0) || isDigit($0) }
    }

    private static func isLower(_ c: UInt8) -> Bool { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c) }
    private static func isDigit(_ c: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) }

    /// Deepest nesting of objects and arrays, ignoring brackets inside strings.
    static func nesting(_ json: String) -> Int {
        var depth = 0
        var maxDepth = 0
        var inString = false
        var escaped = false
        for c in json.utf8 {
            if inString {
                if escaped {
                    escaped = false
                } else if c == UInt8(ascii: "\\") {
                    escaped = true
                } else if c == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch c {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                maxDepth = max(maxDepth, depth)
            case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
            default: break
            }
        }
        return maxDepth
    }
}
