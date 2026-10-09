import CryptoKit
import Foundation

/// HKDF-SHA256 (RFC 5869), written out so it matches the daemon step by step.
public enum HKDF256 {
    private static let hashLen = 32

    public static func extract(salt: [UInt8], ikm: [UInt8]) -> [UInt8] {
        // RFC 5869: an absent salt is HashLen zero bytes.
        let key = SymmetricKey(data: salt.isEmpty ? [UInt8](repeating: 0, count: hashLen) : salt)
        return Array(HMAC<SHA256>.authenticationCode(for: ikm, using: key))
    }

    public static func expand(prk: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        precondition((1...255 * hashLen).contains(length), "bad HKDF length \(length)")
        let key = SymmetricKey(data: prk)
        var out = [UInt8]()
        out.reserveCapacity(length)
        var t = [UInt8]()
        var counter: UInt8 = 1
        while out.count < length {
            var mac = HMAC<SHA256>(key: key)
            mac.update(data: t)
            mac.update(data: info)
            mac.update(data: [counter])
            t = Array(mac.finalize())
            out.append(contentsOf: t.prefix(length - out.count))
            counter &+= 1
        }
        return out
    }

    public static func derive(ikm: [UInt8], salt: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        expand(prk: extract(salt: salt, ikm: ikm), info: info, length: length)
    }
}

/// AES-256-GCM with a 16-byte tag: the ciphertext is followed by the tag.
public struct Aead: Sendable {
    private let key: SymmetricKey

    public init(key: [UInt8]) {
        precondition(key.count == 32, "AES-256 key must be 32 bytes")
        self.key = SymmetricKey(data: key)
    }

    public func seal(nonce: [UInt8], aad: [UInt8], plaintext: [UInt8]) -> [UInt8] {
        // A 12-byte nonce and a 32-byte key can't fail.
        let box = try! AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return Array(box.ciphertext) + Array(box.tag)
    }

    /// The plaintext, or nil when it doesn't authenticate.
    public func open<C: Collection>(nonce: [UInt8], aad: [UInt8], sealed: C) -> [UInt8]? where C.Element == UInt8 {
        let bytes = Array(sealed)
        guard bytes.count >= Wire.tagLen,
              let n = try? AES.GCM.Nonce(data: nonce),
              let box = try? AES.GCM.SealedBox(nonce: n, ciphertext: bytes.dropLast(Wire.tagLen), tag: bytes.suffix(Wire.tagLen)),
              let plain = try? AES.GCM.open(box, using: key, authenticating: aad)
        else { return nil }
        return Array(plain)
    }
}

/// The two per-session keys from PROTOCOL.md.
public struct SessionKeys: Sendable {
    public let clientToServer: [UInt8]
    public let serverToClient: [UInt8]

    private static let infoC2S = Array("omakey v1 c2s".utf8)
    private static let infoS2C = Array("omakey v1 s2c".utf8)

    public static func derive(deviceKey: [UInt8], clientRandom: [UInt8], serverRandom: [UInt8]) -> SessionKeys {
        let prk = HKDF256.extract(salt: clientRandom + serverRandom, ikm: deviceKey)
        return SessionKeys(
            clientToServer: HKDF256.expand(prk: prk, info: infoC2S, length: 32),
            serverToClient: HKDF256.expand(prk: prk, info: infoS2C, length: 32)
        )
    }
}

/// Where the protocol's random bytes come from; tests hand out fixed ones.
public protocol RandomBytes: AnyObject {
    func bytes(_ count: Int) -> [UInt8]
}

/// The system's cryptographically secure generator.
public final class SecureRandom: RandomBytes, Sendable {
    public init() {}

    public func bytes(_ count: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) }
    }
}
