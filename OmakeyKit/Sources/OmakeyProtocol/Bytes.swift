import Foundation

/// Big-endian writing and reading for the wire format (PROTOCOL.md: all
/// integers are big-endian).
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 64) {
        bytes.reserveCapacity(capacity)
    }

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(v >> 8))
        bytes.append(UInt8(v & 0xFF))
    }

    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }

    mutating func u64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((v >> UInt64(shift)) & 0xFF)) }
    }

    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }

    mutating func append<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
}

/// Reads fields in order; running out throws, which every decoder turns into `nil`.
struct ByteReader {
    struct Short: Error {}

    private let bytes: [UInt8]
    private(set) var position: Int

    init<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        self.bytes = Array(bytes)
        position = 0
    }

    var remaining: Int { bytes.count - position }
    var hasRemaining: Bool { remaining > 0 }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw Short() }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw Short() }
        defer { position += 2 }
        return UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1])
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw Short() }
        defer { position += 4 }
        return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[position + $1]) }
    }

    mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw Short() }
        defer { position += 8 }
        return (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[position + $1]) }
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw Short() }
        defer { position += n }
        return Array(bytes[position..<position + n])
    }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, remaining >= n else { throw Short() }
        position += n
    }
}

public enum Hex {
    private static let digits = Array("0123456789abcdef".utf8)

    public static func encode<C: Collection>(_ b: C) -> String where C.Element == UInt8 {
        var out = [UInt8]()
        out.reserveCapacity(b.count * 2)
        for x in b {
            out.append(digits[Int(x >> 4)])
            out.append(digits[Int(x & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Nil for an odd length or a non-hex character.
    public static func decode(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    /// Exactly [bytes] bytes of hex, either case.
    public static func isHex(_ s: String, bytes: Int) -> Bool {
        s.utf8.count == bytes * 2 && s.utf8.allSatisfy { nibble($0) != nil }
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// Base64url without padding, as the pairing link and layout links use it.
public enum Base64URL {
    public static func encode(_ b: [UInt8]) -> String {
        var s = Data(b).base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// Nil when it isn't base64url (the standard alphabet's `+` and `/` included).
    public static func decode(_ s: String) -> [UInt8]? {
        var t = s
        while t.hasSuffix("=") { t.removeLast() }
        guard !t.contains("+"), !t.contains("/"), !t.contains("=") else { return nil }
        t = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if t.count % 4 == 1 { return nil }
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t).map { Array($0) }
    }
}

/// [s] as UTF-8, cut at a character boundary to at most [maxBytes].
func truncateUTF8(_ s: String, _ maxBytes: Int) -> [UInt8] {
    var out = [UInt8]()
    for scalar in s.unicodeScalars {
        let encoded = Array(String(scalar).utf8)
        if out.count + encoded.count > maxBytes { break }
        out.append(contentsOf: encoded)
    }
    return out
}

