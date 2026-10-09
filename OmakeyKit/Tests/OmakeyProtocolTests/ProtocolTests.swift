import Foundation
import Testing
@testable import OmakeyProtocol

struct ProtocolTests {
    private func hex(_ s: String) -> [UInt8] { Hex.decode(s.replacingOccurrences(of: " ", with: ""))! }
    private func randomBytes(_ n: Int) -> [UInt8] { SecureRandom().bytes(n) }

    @Test func hkdfRfc5869Case1() {
        let ikm = [UInt8](repeating: 0x0b, count: 22)
        let salt = hex("000102030405060708090a0b0c")
        let info = hex("f0f1f2f3f4f5f6f7f8f9")
        let prk = HKDF256.extract(salt: salt, ikm: ikm)
        #expect(Hex.encode(prk) == "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
        #expect(Hex.encode(HKDF256.expand(prk: prk, info: info, length: 42))
            == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }

    @Test func counterNonceIsSessionIdThenCounter() {
        #expect(Hex.encode(Wire.counterNonce(sessionId: 0xdeadbeef, counter: 258)) == "deadbeef0000000000000102")
    }

    @Test func sealedPacketRoundTripsAndRejectsTampering() {
        let key = (0..<32).map { UInt8($0) }
        let dev = hex("0102030405060708")
        let nonce = Wire.counterNonce(sessionId: 7, counter: 1)
        let pkt = Wire.seal(type: Wire.input, deviceId: dev, nonce: nonce, aead: Aead(key: key), plaintext: [1, 2, 3])
        #expect(pkt.count == Wire.headerLen + 3 + Wire.tagLen)
        #expect(Hex.encode(pkt.prefix(4)) == "4f4b0103")

        let p = Packet.parse(pkt)!
        #expect(p.type == Wire.input)
        #expect(p.sessionId == 7)
        #expect(p.counter == 1)
        #expect(p.open(Aead(key: key)) == [1, 2, 3])

        // The header is AAD: flipping the type breaks authentication.
        var tampered = pkt
        tampered[3] = Wire.bye
        #expect(Packet.parse(tampered)!.open(Aead(key: key)) == nil)
        #expect(Packet.parse(pkt)!.open(Aead(key: [UInt8](repeating: 0, count: 32))) == nil)
        #expect(Packet.parse([0x4f, 0x4b, 2, 3]) == nil)
    }

    @Test func inputEncodingMatchesSpec() {
        let input = Input(clientTimeMs: 0x01020304, held: [125, 57],
                          events: [KeyEvent(eseq: 9, code: 125, value: 1), KeyEvent(eseq: 10, code: 57, value: 1)])
        let b = input.encode()
        #expect(Hex.encode(b) == "01020304" + "00" + "02" + "007d" + "0039" + "02" + "0009007d01" + "000a003901")
        let back = Input.decode(b)!
        #expect(back.held == [125, 57])
        #expect(back.events == input.events)
    }

    @Test func helloWelcomeAckEncoding() {
        let cr = [UInt8](repeating: 1, count: 16)
        let hello = Hello(clientRandom: cr, name: "Pixel", platform: Wire.platformAndroid).encode()
        #expect(Hex.encode(hello) == Hex.encode(cr) + "05" + Hex.encode(Array("Pixel".utf8)) + "01")
        #expect(Hello.decode(hello)!.name == "Pixel")

        let w = Welcome(clientRandom: cr, serverRandom: [UInt8](repeating: 2, count: 16), sessionId: 42, name: "desk").encode()
        let wd = Welcome.decode(w)!
        #expect(wd.sessionId == 42)
        #expect(wd.name == "desk")

        #expect(Hex.encode(Ack(clientTimeMs: 10, lastEseq: 5).encode()) == "0000000a0005")
    }

    @Test func longNamesAreCutAtCharacterBoundaries() {
        let name = String(repeating: "ж", count: 40) // 80 bytes
        let b = truncateUTF8(name, 64)
        #expect(b.count == 64)
        #expect(String(decoding: b, as: UTF8.self) == String(repeating: "ж", count: 32))
    }

    @Test func eseqComparisonWraps() {
        #expect(Wire.eseqNewer(1, 0))
        #expect(Wire.eseqNewer(0, 65535))
        #expect(Wire.eseqNewer(5, 65530))
        #expect(!Wire.eseqNewer(65530, 5))
        #expect(!Wire.eseqNewer(7, 7))
    }

    @Test func keyStateRefCountsAndAcks() {
        let k = KeyState()
        #expect(k.press(42))
        #expect(!k.press(42)) // second finger on a key with the same code
        #expect(k.press(30))
        #expect(k.held() == [30, 42])
        #expect(!k.release(42))
        #expect(k.release(42))
        #expect(k.held() == [30])

        let input = k.buildInput(clientTimeMs: 0)
        #expect(input.events == [KeyEvent(eseq: 1, code: 42, value: 1), KeyEvent(eseq: 2, code: 30, value: 1), KeyEvent(eseq: 3, code: 42, value: 0)])
        k.ack(2)
        #expect(k.buildInput(clientTimeMs: 0).events == [KeyEvent(eseq: 3, code: 42, value: 0)])
        k.ack(3)
        #expect(!k.hasUnacked)

        k.releaseAll()
        #expect(!k.isHolding)
        #expect(k.buildInput(clientTimeMs: 0).events == [KeyEvent(eseq: 4, code: 30, value: 0)])
    }

    @Test func keyStateKeepsAtMost32Events() {
        let k = KeyState()
        for _ in 0..<20 {
            k.press(30)
            k.release(30)
        }
        let events = k.buildInput(clientTimeMs: 0).events
        #expect(events.count == 32)
        #expect(events.first!.eseq == 9)
        #expect(events.last!.eseq == 40)
    }

    @Test func keyStateSequenceWraps() {
        let k = KeyState()
        for _ in 0..<65535 {
            k.press(30)
            k.release(30)
            k.ack(k.buildInput(clientTimeMs: 0).events.last!.eseq)
        }
        k.press(30) // eseq 65535 * 2 + 1 wraps
        let events = k.buildInput(clientTimeMs: 0).events
        #expect(events.count == 1)
        #expect(Int(events[0].eseq) == (65535 * 2 + 1) & 0xFFFF)
    }

    private let goodKey = (0..<32).map { UInt8(truncatingIfNeeded: $0 * 7) }
    private var goodLink: String {
        "omakey://pair?v=1&h=0011223344556677&n=omarchy%20desk&a=192.168.1.20,100.64.0.7"
            + "&p=47800&d=8899aabbccddeeff&k=" + Base64URL.encode(goodKey)
    }

    @Test func parsesPairingLink() throws {
        let h = try PairingURI.parse(goodLink)
        #expect(h.hostId == "0011223344556677")
        #expect(h.name == "omarchy desk")
        #expect(h.addresses == ["192.168.1.20", "100.64.0.7"])
        #expect(h.port == 47800)
        #expect(h.deviceIdHex == "8899aabbccddeeff")
        #expect(h.key == goodKey)
    }

    @Test func plusInANameIsASpaceAsOnAndroid() throws {
        #expect(try PairingURI.parse(goodLink.replacingOccurrences(of: "omarchy%20desk", with: "my+desk")).name == "my desk")
    }

    @Test func rejectsBadPairingLinks() {
        let bad = [
            "https://example.com",
            goodLink.replacingOccurrences(of: "v=1", with: "v=2"),
            goodLink.replacingOccurrences(of: "h=0011223344556677", with: "h=0011"),
            goodLink.replacingOccurrences(of: "p=47800", with: "p=0"),
            goodLink.replacingOccurrences(of: "a=192.168.1.20,100.64.0.7", with: "a=not-an-ip"),
            String(goodLink[..<goodLink.range(of: "&k=")!.lowerBound]) + "&k=AAAA",
        ]
        for link in bad {
            #expect(throws: PairingError.self, "accepted \(link)") { try PairingURI.parse(link) }
        }
    }

    @Test func ipv4NeedsFourPlainOctets() {
        #expect(PairingURI.isIPv4("10.0.0.2"))
        #expect(PairingURI.isIPv4("255.255.255.255"))
        #expect(!PairingURI.isIPv4("256.1.1.1"))
        #expect(!PairingURI.isIPv4("01.1.1.1"))
        #expect(!PairingURI.isIPv4("1.1.1"))
        #expect(!PairingURI.isIPv4("1.1.1.1.1"))
        #expect(!PairingURI.isIPv4("a.b.c.d"))
    }

    /// A minimal server, written from PROTOCOL.md, drives a full session.
    @Test func clientSessionHandshakeInputAndAck() throws {
        let host = try PairingURI.parse(goodLink)
        let keys = KeyState()
        let client = ClientSession(host: host, phoneName: "Phone", keys: keys)

        // HELLO decrypts with the device key.
        let hp = Packet.parse(client.helloPacket())!
        #expect(hp.type == Wire.hello)
        let hello = Hello.decode(hp.open(Aead(key: host.key))!)!
        #expect(hello.name == "Phone")

        // WELCOME.
        let sr = randomBytes(16)
        let welcome = Wire.seal(type: Wire.welcome, deviceId: host.deviceId, nonce: randomBytes(12), aead: Aead(key: host.key),
                                plaintext: Welcome(clientRandom: hello.clientRandom, serverRandom: sr, sessionId: 99, name: "desk").encode())
        #expect(client.receive(welcome, nowMs: 0) == .connected(hostName: "desk", sessionId: 99, features: 0, btAddress: nil))
        #expect(client.connected)

        // INPUT under Kcs with nonce session ‖ 1.
        let sk = SessionKeys.derive(deviceKey: host.key, clientRandom: hello.clientRandom, serverRandom: sr)
        keys.press(125)
        keys.press(57)
        let ip = Packet.parse(client.inputPacket(clientTimeMs: 1000)!)!
        #expect(ip.sessionId == 99)
        #expect(ip.counter == 1)
        let input = Input.decode(ip.open(Aead(key: sk.clientToServer))!)!
        #expect(input.held == [57, 125])
        #expect(input.events.count == 2)

        // ACK under Ksc.
        let ack = Wire.seal(type: Wire.ack, deviceId: host.deviceId, nonce: Wire.counterNonce(sessionId: 99, counter: 1),
                            aead: Aead(key: sk.serverToClient), plaintext: Ack(clientTimeMs: 1000, lastEseq: 2).encode())
        #expect(client.receive(ack, nowMs: 1007) == .acked(pingMs: 7, leds: nil, theme: nil))
        #expect(!keys.hasUnacked)
        // A replayed ACK is ignored.
        #expect(client.receive(ack, nowMs: 1010) == nil)

        // A WELCOME for some other HELLO is ignored.
        let stray = Wire.seal(type: Wire.welcome, deviceId: host.deviceId, nonce: [UInt8](repeating: 0, count: 12), aead: Aead(key: host.key),
                              plaintext: Welcome(clientRandom: [UInt8](repeating: 0, count: 16), serverRandom: sr, sessionId: 5, name: "x").encode())
        #expect(client.receive(stray, nowMs: 0) == nil)

        #expect(client.byePacket() != nil)
        #expect(client.byePacket()![3] == Wire.bye)
    }

    @Test func pingSurvivesTheClockWrapping() throws {
        let host = try PairingURI.parse(goodLink)
        let client = ClientSession(host: host, phoneName: "Phone", keys: KeyState())
        let hello = Hello.decode(Packet.parse(client.helloPacket())!.open(Aead(key: host.key))!)!
        let sr = randomBytes(16)
        let welcome = Wire.seal(type: Wire.welcome, deviceId: host.deviceId, nonce: randomBytes(12), aead: Aead(key: host.key),
                                plaintext: Welcome(clientRandom: hello.clientRandom, serverRandom: sr, sessionId: 1, name: "desk").encode())
        _ = client.receive(welcome, nowMs: 0)
        let sk = SessionKeys.derive(deviceKey: host.key, clientRandom: hello.clientRandom, serverRandom: sr)
        let ack = Wire.seal(type: Wire.ack, deviceId: host.deviceId, nonce: Wire.counterNonce(sessionId: 1, counter: 1),
                            aead: Aead(key: sk.serverToClient), plaintext: Ack(clientTimeMs: UInt32.max - 2, lastEseq: 0).encode())
        #expect(client.receive(ack, nowMs: 4) == .acked(pingMs: 7, leds: nil, theme: nil))
    }

    @Test func rejectIsReportedOnlyBeforeConnecting() throws {
        let host = try PairingURI.parse(goodLink)
        let client = ClientSession(host: host, phoneName: "Phone", keys: KeyState())
        let reject = Wire.header(type: Wire.reject, deviceId: host.deviceId, nonce: [UInt8](repeating: 0, count: 12)) + [Wire.rejectUnknownDevice]
        #expect(client.receive(reject, nowMs: 0) == .rejected)
    }

    @Test func pointerTrailerIsOptionalAndMotionIsSentOnce() {
        let keys = KeyState()
        #expect(keys.buildInput(clientTimeMs: 1).pointer == nil)
        keys.addMotion(dx: 2.6, dy: -1.4)
        keys.addScroll(v: -50, h: 0)
        let first = keys.buildInput(clientTimeMs: 2)
        #expect(first.pointer == Pointer(dx: 2, dy: -1, wheel: -50, hwheel: 0))
        // Fractions carry over; whole counts are not resent.
        keys.addMotion(dx: 0.5, dy: 0)
        #expect(keys.buildInput(clientTimeMs: 3).pointer == Pointer(dx: 1, dy: 0, wheel: 0, hwheel: 0))
        #expect(keys.buildInput(clientTimeMs: 4).pointer == nil)
        // Round trip, and an old-style packet without a trailer still decodes.
        #expect(Input.decode(first.encode())!.pointer == first.pointer)
        #expect(Input.decode(Input(clientTimeMs: 1, held: [], events: []).encode())!.pointer == nil)
    }

    @Test func welcomeFeaturesDefaultToZeroFromOldServers() {
        let w = Welcome(clientRandom: [UInt8](repeating: 0, count: 16), serverRandom: [UInt8](repeating: 0, count: 16), sessionId: 5, name: "desk", features: Wire.featurePointer)
        let enc = w.encode()
        #expect(Welcome.decode(enc)!.features == Wire.featurePointer)
        #expect(Welcome.decode(Array(enc.dropLast()))!.features == 0)
    }

    @Test func bluetoothAddressComesFromThePairingLinkAndWelcome() throws {
        let link = "omakey://pair?v=1&h=0102030405060708&n=desk&a=192.168.1.5&p=47800"
            + "&d=0909090909090909&k=" + Base64URL.encode([UInt8](repeating: 0, count: 32)) + "&b=1418c368871e"
        #expect(try PairingURI.parse(link).btAddress == "14:18:C3:68:87:1E")
        #expect(try PairingURI.parse(String(link[..<link.range(of: "&b=")!.lowerBound])).btAddress == nil)

        let bt = hex("1418c368871e")
        let zero = [UInt8](repeating: 0, count: 16)
        let w = Welcome(clientRandom: zero, serverRandom: zero, sessionId: 5, name: "desk", features: Wire.featurePointer, btAddress: bt)
        #expect(Welcome.decode(w.encode())!.btAddress == bt)
        #expect(Welcome.decode(Welcome(clientRandom: zero, serverRandom: zero, sessionId: 5, name: "desk", features: 1).encode())!.btAddress == nil)
    }

    @Test func ackCarriesLockLightsWhenTheServerSendsThem() {
        #expect(Ack.decode(Ack(clientTimeMs: 5, lastEseq: 7).encode())!.leds == nil)
        let a = Ack.decode(Ack(clientTimeMs: 5, lastEseq: 7, leds: Ack.ledCaps).encode())!
        #expect(a.lastEseq == 7)
        #expect(a.leds == Ack.ledCaps)
    }

    @Test func aWelcomeThatIsntClaimedChangesNothing() {
        let host = HostRecord(hostId: "0102030405060708", name: "desk", addresses: ["10.0.0.2"], port: 47800,
                              deviceId: [UInt8](repeating: 9, count: 8), key: [UInt8](repeating: 3, count: 32))
        let keys = KeyState()
        let client = ClientSession(host: host, phoneName: "phone", keys: keys)
        keys.press(30) // an event waiting to be acknowledged
        let hello = Hello.decode(Packet.parse(client.helloPacket())!.open(Aead(key: host.key))!)!
        let welcome = Wire.seal(type: Wire.welcome, deviceId: host.deviceId, nonce: [UInt8](repeating: 0, count: 12), aead: Aead(key: host.key),
                                plaintext: Welcome(clientRandom: hello.clientRandom, serverRandom: [UInt8](repeating: 2, count: 16), sessionId: 99, name: "desk").encode())
        #expect(client.receive(welcome, nowMs: 0, claim: { false }) == nil)
        #expect(!client.connected)
        #expect(keys.hasUnacked) // not reset by a WELCOME we didn't take
        #expect(client.receive(welcome, nowMs: 0, claim: { true }) != nil)
        #expect(client.connected)
    }

    @Test func fingerprintIsTheStartOfTheKeysSha256() {
        let h = HostRecord(hostId: "0102030405060708", name: "desk", addresses: ["10.0.0.2"], port: 47800,
                           deviceId: [UInt8](repeating: 0, count: 8), key: [UInt8](repeating: 0, count: 32))
        // SHA-256 of 32 zero bytes starts 66687aad.
        #expect(h.fingerprint == "6668-7AAD")
    }

    @Test func ackCarriesTheDesktopTheme() {
        // As omakeyd writes it: leds, theme_len, light, name, count, RGB × 14.
        let colors = (0..<14).map { UInt32(0x101010 * $0) }
        let body: [UInt8] = [1, 4] + Array("nord".utf8) + [14]
            + colors.flatMap { [UInt8(($0 >> 16) & 0xFF), UInt8(($0 >> 8) & 0xFF), UInt8($0 & 0xFF)] }
        let raw = Ack(clientTimeMs: 5, lastEseq: 7, leds: 2).encode() + [UInt8(body.count)] + body
        let ack = Ack.decode(raw)!
        #expect(ack.leds == 2)
        let t = ack.theme!
        #expect(t.name == "nord")
        #expect(t.light)
        #expect(t.colors == colors)
        // And back.
        #expect(Ack(clientTimeMs: 5, lastEseq: 7, leds: 2, theme: t).encode() == raw)
        // Old servers: no theme. A cut-off one is ignored, not misread.
        #expect(Ack.decode(Ack(clientTimeMs: 5, lastEseq: 7, leds: 2).encode())!.theme == nil)
        #expect(Ack.decode(Array(raw.dropLast()))!.theme == nil)
    }

    @Test func inputCarriesTheLayoutAfterThePointer() {
        let i = Input(clientTimeMs: 9, held: [30], events: [], layout: "ua")
        let back = Input.decode(i.encode())!
        #expect(back.layout == "ua")
        // The pointer went as zeros to make room; no motion, so none read back.
        #expect(back.pointer == nil)
        #expect(i.encode().count - Input(clientTimeMs: 9, held: [30], events: []).encode().count == 1 + Wire.pointerLen + 1 + 2)
        #expect(Input.decode(Input(clientTimeMs: 9, held: [30], events: []).encode())!.layout == nil)
    }
}
