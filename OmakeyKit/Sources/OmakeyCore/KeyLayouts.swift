/// One key stroke for a character: the key, and whether Shift is held.
public struct KeyStroke: Equatable, Sendable {
    public let code: Int
    public let shift: Bool

    public init(_ code: Int, shift: Bool) {
        self.code = code
        self.shift = shift
    }
}

/// What each Linux key code types on a US layout, and back: the phone's
/// keyboard sends characters, the computer wants keys. Covers printable
/// ASCII plus Enter and Tab.
public enum UsKeys {
    public static let keyEsc = 1
    public static let keyBackspace = 14
    public static let keyTab = 15
    public static let keyEnter = 28
    public static let keyLeftCtrl = 29
    public static let keyLeftShift = 42
    public static let keyLeftAlt = 56
    public static let keySpace = 57
    public static let keyHome = 102
    public static let keyUp = 103
    public static let keyPageUp = 104
    public static let keyLeft = 105
    public static let keyRight = 106
    public static let keyEnd = 107
    public static let keyDown = 108
    public static let keyPageDown = 109
    public static let keyInsert = 110
    public static let keyDelete = 111
    public static let keyLeftMeta = 125

    /// Ctrl, Shift, Alt and Super, left and right.
    public static let modifiers: Set<Int> = [29, 97, 42, 54, 56, 100, 125, 126]

    /// Code to (unshifted, shifted) character.
    public static let printable: [Int: (Character, Character)] = {
        var m = [Int: (Character, Character)]()
        let shiftedDigits = Array("!@#$%^&*()")
        for (i, c) in "1234567890".enumerated() { m[2 + i] = (c, shiftedDigits[i]) }
        m[12] = ("-", "_"); m[13] = ("=", "+")
        for (i, c) in "qwertyuiop".enumerated() { m[16 + i] = (c, Character(c.uppercased())) }
        m[26] = ("[", "{"); m[27] = ("]", "}")
        for (i, c) in "asdfghjkl".enumerated() { m[30 + i] = (c, Character(c.uppercased())) }
        m[39] = (";", ":"); m[40] = ("'", "\""); m[41] = ("`", "~"); m[43] = ("\\", "|")
        for (i, c) in "zxcvbnm".enumerated() { m[44 + i] = (c, Character(c.uppercased())) }
        m[51] = (",", "<"); m[52] = (".", ">"); m[53] = ("/", "?")
        m[keySpace] = (" ", " ")
        return m
    }()

    static let byChar: [Character: KeyStroke] = {
        var m = [Character: KeyStroke]()
        for (code, chars) in printable.sorted(by: { $0.key < $1.key }) {
            if m[chars.1] == nil { m[chars.1] = KeyStroke(code, shift: true) }
            m[chars.0] = KeyStroke(code, shift: false)
        }
        m["\n"] = KeyStroke(keyEnter, shift: false)
        m["\t"] = KeyStroke(keyTab, shift: false)
        return m
    }()

    /// The key and whether it needs Shift; nil for a character a US keyboard can't type.
    public static func forChar(_ c: Character) -> KeyStroke? { byChar[c] }
}

/// A computer keyboard layout the phone types with: its xkb name, and which
/// key (and Shift) gives each character. The computer reads Omakey's keys
/// with the layout the phone asks for (INPUT `layout`), so what arrives is
/// what was typed on the phone, whatever layout the computer itself is on.
public struct KeyLayout: Sendable {
    public let xkb: String
    private let chars: [Character: KeyStroke]

    init(xkb: String, chars: [Character: KeyStroke]) {
        self.xkb = xkb
        self.chars = chars
    }

    public func forChar(_ c: Character) -> KeyStroke? { chars[c] }
}

public enum KeyLayouts {
    public static let us = KeyLayout(xkb: "us", chars: UsKeys.byChar)

    /// Ukrainian, xkb `ua` (its default variant): ЙЦУКЕН.
    public static let ua: KeyLayout = {
        var m = [Character: KeyStroke]()
        func row(_ first: Int, _ letters: String) {
            for (i, c) in letters.enumerated() {
                m[c] = KeyStroke(first + i, shift: false)
                m[Character(c.uppercased())] = KeyStroke(first + i, shift: true)
            }
        }
        row(16, "йцукенгшщзхї")
        row(30, "фівапролджє")
        row(44, "ячсмитьбю")
        m["ґ"] = KeyStroke(43, shift: false); m["Ґ"] = KeyStroke(43, shift: true)
        m["'"] = KeyStroke(41, shift: false); m["ʼ"] = KeyStroke(41, shift: true)
        // Digits and the punctuation ua has, so they don't switch layouts mid-word.
        for (i, c) in "1234567890".enumerated() { m[c] = KeyStroke(2 + i, shift: false) }
        for (i, c) in "!\"№;%:?*()".enumerated() { m[c] = KeyStroke(2 + i, shift: true) }
        m["-"] = KeyStroke(12, shift: false); m["_"] = KeyStroke(12, shift: true)
        m["="] = KeyStroke(13, shift: false); m["+"] = KeyStroke(13, shift: true)
        m["."] = KeyStroke(53, shift: false); m[","] = KeyStroke(53, shift: true)
        m[" "] = KeyStroke(UsKeys.keySpace, shift: false)
        m["\n"] = KeyStroke(UsKeys.keyEnter, shift: false)
        m["\t"] = KeyStroke(UsKeys.keyTab, shift: false)
        return KeyLayout(xkb: "ua", chars: m)
    }()

    /// The phone keyboard's language, first choice first: Ukrainian puts ua before us.
    public static func preferred(_ languageTag: String?) -> [KeyLayout] {
        languageTag?.lowercased().hasPrefix("uk") == true ? [ua, us] : [us, ua]
    }

    /// The layout and key for [c]: [current] when it has it (no switching), else the first of [preferred] that does.
    public static func pick(_ c: Character, current: String?, preferred: [KeyLayout]) -> (layout: KeyLayout, stroke: KeyStroke)? {
        if let l = preferred.first(where: { $0.xkb == current }), let s = l.forChar(c) { return (l, s) }
        for l in preferred {
            if let s = l.forChar(c) { return (l, s) }
        }
        return nil
    }
}
