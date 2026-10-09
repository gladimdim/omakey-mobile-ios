import CryptoKit
import Foundation

/// Everything a phone keeps about one paired computer.
public struct HostRecord: Equatable, Codable, Sendable {
    public var hostId: String
    public var name: String
    public var addresses: [String]
    public var port: Int
    public var deviceId: [UInt8]
    public var key: [UInt8]
    /// The computer's Bluetooth adapter, "AA:BB:CC:DD:EE:FF": part of the protocol
    /// (Android's Bluetooth fallback), parsed and kept; the iOS app has no Bluetooth.
    public var btAddress: String?

    public init(hostId: String, name: String, addresses: [String], port: Int, deviceId: [UInt8], key: [UInt8], btAddress: String? = nil) {
        self.hostId = hostId
        self.name = name
        self.addresses = addresses
        self.port = port
        self.deviceId = deviceId
        self.key = key
        self.btAddress = btAddress
    }

    public var deviceIdHex: String { Hex.encode(deviceId) }

    /// A short code for the pairing key, "ABCD-1234": the first 4 bytes of
    /// SHA-256(key). omakeyd shows the same code under its QR code, so a
    /// pairing link that didn't come from your computer can be told apart.
    public var fingerprint: String {
        let h = Hex.encode(Array(SHA256.hash(data: key)).prefix(4)).uppercased()
        return String(h.prefix(4)) + "-" + String(h.suffix(4))
    }
}

public struct PairingError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public init(_ message: String) { self.message = message }
}

/// Parses `omakey://pair?v=1&h=<host id>&n=<name>&a=<ip>,<ip>&p=<port>&d=<device id>&k=<key>[&b=<bt address>]`.
public enum PairingURI {
    public static func parse(_ text: String) throws -> HostRecord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URLComponents(string: trimmed) else { throw PairingError("Not a pairing link") }
        guard u.scheme == "omakey", u.host == "pair" else { throw PairingError("Not an omakey pairing link") }
        guard let raw = u.percentEncodedQuery else { throw PairingError("Pairing link has no data") }
        guard let q = query(raw) else { throw PairingError("Not a pairing link") }

        guard q["v"] == "1" else { throw PairingError("Unsupported pairing version \(q["v"] ?? "null"); update the app") }
        guard let hostId = q["h"]?.lowercased(), Hex.isHex(hostId, bytes: 8) else { throw PairingError("Bad host id") }
        guard let d = q["d"], Hex.isHex(d, bytes: 8), let deviceId = Hex.decode(d) else { throw PairingError("Bad device id") }
        guard let key = Base64URL.decode(q["k"] ?? ""), key.count == 32 else { throw PairingError("Bad key") }
        guard let port = q["p"].flatMap({ Int($0) }), (1...65535).contains(port) else { throw PairingError("Bad port") }
        let addresses = (q["a"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(isIPv4)
        if addresses.isEmpty { throw PairingError("Pairing link has no addresses") }
        let name = q["n"].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? hostId
        let bt = q["b"].flatMap { Hex.isHex($0, bytes: 6) ? Hex.decode($0) : nil }.map(btAddress)

        return HostRecord(hostId: hostId, name: name, addresses: addresses, port: port, deviceId: deviceId, key: key, btAddress: bt)
    }

    /// Six address bytes as Android writes them: "AA:BB:CC:DD:EE:FF".
    public static func btAddress(_ b: [UInt8]) -> String {
        b.map { Hex.encode([$0]).uppercased() }.joined(separator: ":")
    }

    /// A dotted IPv4 address with no leading zeros, as PROTOCOL.md's `a` lists them.
    public static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard (1...3).contains(p.count), p.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
            if p.count > 1 && p.first == "0" { return false }
            return Int(p)! <= 255
        }
    }

    /// The query as `java.net.URLDecoder` reads it (`+` is a space), so links
    /// decode the same on both phones. Nil on a broken escape.
    private static func query(_ raw: String) -> [String: String]? {
        var out = [String: String]()
        for part in raw.split(separator: "&") where !part.isEmpty {
            let (k, v): (Substring, Substring)
            if let i = part.firstIndex(of: "=") {
                (k, v) = (part[..<i], part[part.index(after: i)...])
            } else {
                (k, v) = (part, "")
            }
            guard let key = decode(k), let value = decode(v) else { return nil }
            out[key] = value
        }
        return out
    }

    private static func decode(_ s: Substring) -> String? {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
