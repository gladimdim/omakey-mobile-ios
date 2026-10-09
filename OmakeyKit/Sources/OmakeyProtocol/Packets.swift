import Foundation

/// Constants from PROTOCOL.md. All integers on the wire are big-endian.
public enum Wire {
    /// WELCOME feature bit: the server has a virtual mouse for the touchpad.
    public static let featurePointer = 1
    /// WELCOME feature bit: the server takes CLIP, for the clipboard.
    public static let featureClipboard = 2
    /// Length of the INPUT pointer trailer after its length byte.
    public static let pointerLen = 8
    public static let btnLeft = 0x110
    public static let btnRight = 0x111
    public static let btnMiddle = 0x112

    public static let magic0: UInt8 = 0x4F // 'O'
    public static let magic1: UInt8 = 0x4B // 'K'
    public static let version: UInt8 = 1
    public static let headerLen = 24
    public static let nonceLen = 12
    public static let tagLen = 16
    public static let idLen = 8
    public static let randomLen = 16
    public static let maxDatagram = 1200
    public static let defaultPort = 47800
    public static let serviceType = "_omakey._udp"
    public static let maxEvents = 32
    public static let maxNameBytes = 64

    public static let hello: UInt8 = 1
    public static let welcome: UInt8 = 2
    public static let input: UInt8 = 3
    public static let ack: UInt8 = 4
    public static let bye: UInt8 = 5
    public static let reject: UInt8 = 6
    public static let clip: UInt8 = 7
    public static let clipReply: UInt8 = 8

    public static let platformAndroid: UInt8 = 1
    public static let platformIOS: UInt8 = 2

    public static let rejectUnknownDevice: UInt8 = 1

    /// Nonce for INPUT/ACK/BYE/CLIP: session id ‖ counter.
    public static func counterNonce(sessionId: UInt32, counter: UInt64) -> [UInt8] {
        var w = ByteWriter(capacity: nonceLen)
        w.u32(sessionId)
        w.u64(counter)
        return w.bytes
    }

    public static func header(type: UInt8, deviceId: [UInt8], nonce: [UInt8]) -> [UInt8] {
        precondition(deviceId.count == idLen && nonce.count == nonceLen)
        return [magic0, magic1, version, type] + deviceId + nonce
    }

    /// Header ‖ AES-GCM(plaintext), with the header as AAD.
    public static func seal(type: UInt8, deviceId: [UInt8], nonce: [UInt8], aead: Aead, plaintext: [UInt8]) -> [UInt8] {
        let h = header(type: type, deviceId: deviceId, nonce: nonce)
        return h + aead.seal(nonce: nonce, aad: h, plaintext: plaintext)
    }

    /// `(int16)(a - b) > 0`: is event sequence [a] newer than [b]?
    public static func eseqNewer(_ a: UInt16, _ b: UInt16) -> Bool {
        Int16(bitPattern: a &- b) > 0
    }
}

/// A parsed packet header; the body is still encrypted.
public struct Packet {
    public let type: UInt8
    public let deviceId: [UInt8]
    public let nonce: [UInt8]
    public let aad: [UInt8]
    public let body: ArraySlice<UInt8>

    public func open(_ aead: Aead) -> [UInt8]? { aead.open(nonce: nonce, aad: aad, sealed: body) }

    /// Session id and counter of a counter nonce.
    public var sessionId: UInt32 { nonce[0..<4].reduce(0) { $0 << 8 | UInt32($1) } }
    public var counter: UInt64 { nonce[4..<12].reduce(0) { $0 << 8 | UInt64($1) } }

    public static func parse(_ data: [UInt8]) -> Packet? {
        guard data.count >= Wire.headerLen + 1, data.count <= Wire.maxDatagram,
              data[0] == Wire.magic0, data[1] == Wire.magic1, data[2] == Wire.version
        else { return nil }
        return Packet(
            type: data[3],
            deviceId: Array(data[4..<12]),
            nonce: Array(data[12..<24]),
            aad: Array(data[0..<24]),
            body: data[Wire.headerLen...]
        )
    }
}

public struct Hello: Equatable {
    public var clientRandom: [UInt8]
    public var name: String
    public var platform: UInt8

    public init(clientRandom: [UInt8], name: String, platform: UInt8) {
        self.clientRandom = clientRandom
        self.name = name
        self.platform = platform
    }

    public func encode() -> [UInt8] {
        let n = truncateUTF8(name, Wire.maxNameBytes)
        var w = ByteWriter()
        w.append(clientRandom)
        w.u8(UInt8(n.count))
        w.append(n)
        w.u8(platform)
        return w.bytes
    }

    public static func decode(_ b: [UInt8]) -> Hello? {
        var r = ByteReader(b)
        guard let cr = try? r.take(Wire.randomLen),
              let len = try? r.u8(), let n = try? r.take(Int(len)),
              let platform = try? r.u8()
        else { return nil }
        return Hello(clientRandom: cr, name: String(decoding: n, as: UTF8.self), platform: platform)
    }
}

public struct Welcome: Equatable {
    public var clientRandom: [UInt8]
    public var serverRandom: [UInt8]
    public var sessionId: UInt32
    public var name: String
    /// `Wire.featurePointer` and friends; 0 from servers that predate them.
    public var features: Int
    /// The server's Bluetooth adapter, 6 bytes; nil when it has none.
    public var btAddress: [UInt8]?

    public init(clientRandom: [UInt8], serverRandom: [UInt8], sessionId: UInt32, name: String, features: Int = 0, btAddress: [UInt8]? = nil) {
        self.clientRandom = clientRandom
        self.serverRandom = serverRandom
        self.sessionId = sessionId
        self.name = name
        self.features = features
        self.btAddress = btAddress
    }

    public func encode() -> [UInt8] {
        let n = truncateUTF8(name, 255)
        var w = ByteWriter()
        w.append(clientRandom)
        w.append(serverRandom)
        w.u32(sessionId)
        w.u8(UInt8(n.count))
        w.append(n)
        w.u8(UInt8(truncatingIfNeeded: features))
        if let btAddress { w.append(btAddress) }
        return w.bytes
    }

    public static func decode(_ b: [UInt8]) -> Welcome? {
        var r = ByteReader(b)
        do {
            let cr = try r.take(Wire.randomLen)
            let sr = try r.take(Wire.randomLen)
            let sid = try r.u32()
            let n = try r.take(Int(try r.u8()))
            let features = r.hasRemaining ? Int(try r.u8()) : 0
            let bt = r.remaining >= 6 ? try r.take(6) : nil
            return Welcome(clientRandom: cr, serverRandom: sr, sessionId: sid, name: String(decoding: n, as: UTF8.self), features: features, btAddress: bt)
        } catch {
            return nil
        }
    }
}

/// One key press (value 1) or release (value 0).
public struct KeyEvent: Equatable, Sendable {
    public var eseq: UInt16
    public var code: UInt16
    public var value: UInt8

    public init(eseq: UInt16, code: UInt16, value: UInt8) {
        self.eseq = eseq
        self.code = code
        self.value = value
    }
}

/// Touchpad motion and scroll since the previous INPUT; scroll in 1/120 of a notch.
public struct Pointer: Equatable, Sendable {
    public var dx: Int16
    public var dy: Int16
    public var wheel: Int16
    public var hwheel: Int16

    public init(dx: Int16, dy: Int16, wheel: Int16, hwheel: Int16) {
        self.dx = dx
        self.dy = dy
        self.wheel = wheel
        self.hwheel = hwheel
    }

    public static let zero = Pointer(dx: 0, dy: 0, wheel: 0, hwheel: 0)
}

public struct Input: Equatable {
    public static let maxLayout = 16

    public var clientTimeMs: UInt32
    public var flags: UInt8
    public var held: [UInt16]
    public var events: [KeyEvent]
    public var pointer: Pointer?
    /// The xkb layout ("us", "ua") the computer should read these keys with,
    /// after the pointer (sent as zeros when there's no motion); nil leaves
    /// the computer's layout alone.
    public var layout: String?

    public init(clientTimeMs: UInt32, flags: UInt8 = 0, held: [UInt16], events: [KeyEvent], pointer: Pointer? = nil, layout: String? = nil) {
        self.clientTimeMs = clientTimeMs
        self.flags = flags
        self.held = held
        self.events = events
        self.pointer = pointer
        self.layout = layout
    }

    public func encode() -> [UInt8] {
        precondition(held.count <= 255 && events.count <= Wire.maxEvents)
        // ASCII, as the daemon reads it; anything else becomes '?'.
        let name = layout.map { l in
            Array(l.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") }.prefix(Input.maxLayout))
        }
        var w = ByteWriter()
        w.u32(clientTimeMs)
        w.u8(flags)
        w.u8(UInt8(held.count))
        for c in held { w.u16(c) }
        w.u8(UInt8(events.count))
        for e in events {
            w.u16(e.eseq)
            w.u16(e.code)
            w.u8(e.value)
        }
        if pointer != nil || name != nil {
            let p = pointer ?? .zero
            w.u8(UInt8(Wire.pointerLen))
            w.i16(p.dx)
            w.i16(p.dy)
            w.i16(p.wheel)
            w.i16(p.hwheel)
        }
        if let name {
            w.u8(UInt8(name.count))
            w.append(name)
        }
        return w.bytes
    }

    public static func decode(_ b: [UInt8]) -> Input? {
        var r = ByteReader(b)
        do {
            let t = try r.u32()
            let flags = try r.u8()
            let held = try (0..<Int(try r.u8())).map { _ in try r.u16() }
            let events = try (0..<Int(try r.u8())).map { _ in
                KeyEvent(eseq: try r.u16(), code: try r.u16(), value: try r.u8())
            }
            var pointer: Pointer?
            var layout: String?
            if r.hasRemaining {
                let len = Int(try r.u8())
                if len >= Wire.pointerLen {
                    pointer = Pointer(dx: try r.i16(), dy: try r.i16(), wheel: try r.i16(), hwheel: try r.i16())
                    try r.skip(len - Wire.pointerLen)
                } else {
                    try r.skip(len)
                }
                if pointer == .zero { pointer = nil }
                if r.hasRemaining {
                    let n = try r.take(Int(try r.u8()))
                    layout = String(decoding: n, as: UTF8.self)
                }
            }
            return Input(clientTimeMs: t, flags: flags, held: held, events: events, pointer: pointer, layout: layout)
        } catch {
            return nil
        }
    }
}

/// The desktop's Omarchy theme from an ACK (PROTOCOL.md, ACK `theme`):
/// [colors] as 0xRRGGBB in `DesktopTheme.keys` order.
public struct DesktopTheme: Equatable, Codable, Sendable {
    public static let keys = [
        "background", "lighter_background", "dark_background", "foreground", "muted", "accent", "selection",
        "red", "yellow", "green", "cyan", "blue", "magenta", "orange",
    ]
    private static let maxName = 32

    public var name: String
    public var light: Bool
    public var colors: [UInt32]

    public init(name: String, light: Bool, colors: [UInt32]) {
        self.name = name
        self.light = light
        self.colors = colors
    }

    /// The color for one of `keys`, as 0xRRGGBB.
    public func color(_ key: String) -> UInt32 {
        colors[DesktopTheme.keys.firstIndex(of: key)!]
    }

    /// `theme_len` then the theme.
    public func encode() -> [UInt8] {
        let n = truncateUTF8(name, DesktopTheme.maxName)
        var body = ByteWriter()
        body.u8(light ? 1 : 0)
        body.u8(UInt8(n.count))
        body.append(n)
        body.u8(UInt8(colors.count))
        for c in colors {
            body.u8(UInt8((c >> 16) & 0xFF))
            body.u8(UInt8((c >> 8) & 0xFF))
            body.u8(UInt8(c & 0xFF))
        }
        return [UInt8(body.bytes.count)] + body.bytes
    }

    /// From the bytes after `leds`; nil when absent, short, or missing colors.
    static func decode(_ r: inout ByteReader) -> DesktopTheme? {
        guard let len = try? r.u8(), len >= 3, let raw = try? r.take(Int(len)) else { return nil }
        var body = ByteReader(raw)
        guard let mode = try? body.u8(), let n = try? body.u8(), body.remaining >= Int(n) + 1,
              let name = try? body.take(Int(n)), let count = try? body.u8(),
              Int(count) >= keys.count, body.remaining >= Int(count) * 3
        else { return nil }
        var colors = [UInt32]()
        for _ in keys {
            guard let rr = try? body.u8(), let g = try? body.u8(), let b = try? body.u8() else { return nil }
            colors.append(UInt32(rr) << 16 | UInt32(g) << 8 | UInt32(b))
        }
        return DesktopTheme(name: String(decoding: name, as: UTF8.self), light: mode == 1, colors: colors)
    }
}

public struct Ack: Equatable {
    public static let ledNum = 1
    public static let ledCaps = 2
    public static let ledScroll = 4

    public var clientTimeMs: UInt32
    public var lastEseq: UInt16
    /// The computer's lock lights; nil from servers that don't send them.
    public var leds: Int?
    public var theme: DesktopTheme?

    public init(clientTimeMs: UInt32, lastEseq: UInt16, leds: Int? = nil, theme: DesktopTheme? = nil) {
        self.clientTimeMs = clientTimeMs
        self.lastEseq = lastEseq
        self.leds = leds
        self.theme = theme
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter()
        w.u32(clientTimeMs)
        w.u16(lastEseq)
        if let leds {
            w.u8(UInt8(truncatingIfNeeded: leds))
            // The theme only follows leds.
            if let theme { w.append(theme.encode()) }
        }
        return w.bytes
    }

    public static func decode(_ b: [UInt8]) -> Ack? {
        var r = ByteReader(b)
        guard let time = try? r.u32(), let eseq = try? r.u16() else { return nil }
        let leds = (try? r.u8()).map(Int.init)
        let theme = leds != nil ? DesktopTheme.decode(&r) : nil
        return Ack(clientTimeMs: time, lastEseq: eseq, leds: leds, theme: theme)
    }
}

/// CLIP and CLIP_REPLY (PROTOCOL.md): one piece of clipboard text between the
/// phone and the desktop. A reply has `status` after `clipId`; a CLIP has none.
public struct Clip: Equatable {
    public static let put = 1
    public static let get = 2
    /// Put: paste once the clipboard is set.
    public static let paste = 1
    /// Get: copy what's selected first.
    public static let copy = 1
    /// The text is a password or the like.
    public static let sensitive = 2

    public static let ok = 0
    public static let working = 1
    public static let empty = 2
    public static let tooLarge = 3
    public static let failed = 4
    public static let unknown = 5

    /// Longest text, in UTF-8 bytes.
    public static let maxText = 65536
    /// Text bytes per packet.
    public static let chunk = 1024

    public var op: Int
    public var clipId: UInt32
    public var status: Int
    public var offset: Int
    public var flags: Int
    public var total: Int
    public var data: [UInt8]

    public init(op: Int, clipId: UInt32, status: Int = Clip.ok, offset: Int = 0, flags: Int = 0, total: Int = 0, data: [UInt8] = []) {
        self.op = op
        self.clipId = clipId
        self.status = status
        self.offset = offset
        self.flags = flags
        self.total = total
        self.data = data
    }

    public func encode(reply: Bool) -> [UInt8] {
        var w = ByteWriter(capacity: 15 + data.count)
        w.u8(UInt8(truncatingIfNeeded: op))
        w.u32(clipId)
        if reply { w.u8(UInt8(truncatingIfNeeded: status)) }
        w.u32(UInt32(truncatingIfNeeded: offset))
        w.u8(UInt8(truncatingIfNeeded: flags))
        w.u32(UInt32(truncatingIfNeeded: total))
        w.append(data)
        return w.bytes
    }

    public static func decode(_ b: [UInt8], reply: Bool) -> Clip? {
        var r = ByteReader(b)
        do {
            let op = Int(try r.u8())
            let id = try r.u32()
            let status = reply ? Int(try r.u8()) : ok
            let offset = Int(try r.u32())
            let flags = Int(try r.u8())
            let total = Int(try r.u32())
            let data = try r.take(min(r.remaining, chunk))
            return Clip(op: op, clipId: id, status: status, offset: offset, flags: flags, total: total, data: data)
        } catch {
            return nil
        }
    }
}
