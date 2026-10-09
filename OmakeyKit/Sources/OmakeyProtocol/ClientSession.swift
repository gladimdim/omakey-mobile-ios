/// The client half of PROTOCOL.md as a socket-free state machine: it builds
/// the datagrams to send and digests the ones received. The transport owns
/// timing and the socket. Not thread-safe: the transport guards it with its
/// own lock, so packet counters go out in the order they were assigned.
public final class ClientSession {
    public enum Result: Equatable {
        /// Handshake finished; the server is called [hostName].
        /// [btAddress]: where to reach the computer over Bluetooth, "AA:BB:…"; nil without
        /// Bluetooth. Part of the protocol; the iOS app has no Bluetooth and ignores it.
        case connected(hostName: String, sessionId: UInt32, features: Int, btAddress: String?)
        /// [leds]: the computer's lock lights (`Ack.ledCaps`, …), or nil when it doesn't say.
        /// [theme]: the desktop's theme, in the first few ACKs and after it changes.
        case acked(pingMs: Int, leds: Int?, theme: DesktopTheme?)
        case rejected
        /// The clipboard transfer ended; `clip` has none now.
        case clipDone(ClipTransfer.Outcome)
    }

    private let host: HostRecord
    private let phoneName: String
    private let platform: UInt8
    public let keys: KeyState
    private let random: RandomBytes
    private let deviceAead: Aead
    private var clientRandom: [UInt8] = []

    public private(set) var connected = false
    public private(set) var sessionId: UInt32 = 0
    private var c2s: Aead?
    private var s2c: Aead?
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0

    /// The clipboard transfer under way (PROTOCOL.md, CLIP); a new one replaces it.
    public var clip: ClipTransfer?

    /// [platform] is `Wire.platformIOS` in the app; the test vectors were made with Android's.
    public init(host: HostRecord, phoneName: String, keys: KeyState, platform: UInt8 = Wire.platformIOS, random: RandomBytes = SecureRandom()) {
        self.host = host
        self.phoneName = phoneName
        self.platform = platform
        self.keys = keys
        self.random = random
        deviceAead = Aead(key: host.key)
        restart()
    }

    /// Drop the session and start a new handshake.
    public func restart() {
        clientRandom = random.bytes(Wire.randomLen)
        connected = false
        sessionId = 0
        c2s = nil
        s2c = nil
        sendCounter = 0
        recvCounter = 0
        // The desktop forgets it with the session.
        clip?.restart()
    }

    public func helloPacket() -> [UInt8] {
        let nonce = random.bytes(Wire.nonceLen)
        let body = Hello(clientRandom: clientRandom, name: phoneName, platform: platform).encode()
        return Wire.seal(type: Wire.hello, deviceId: host.deviceId, nonce: nonce, aead: deviceAead, plaintext: body)
    }

    public func inputPacket(clientTimeMs: UInt32) -> [UInt8]? {
        guard let aead = c2s else { return nil }
        sendCounter += 1
        let nonce = Wire.counterNonce(sessionId: sessionId, counter: sendCounter)
        return Wire.seal(type: Wire.input, deviceId: host.deviceId, nonce: nonce, aead: aead, plaintext: keys.buildInput(clientTimeMs: clientTimeMs).encode())
    }

    /// The clipboard transfer's next CLIP, when one is due at [nowMs].
    public func clipPacket(nowMs: Int64) -> [UInt8]? {
        guard let aead = c2s, let body = clip?.body(nowMs: nowMs) else { return nil }
        sendCounter += 1
        return Wire.seal(type: Wire.clip, deviceId: host.deviceId, nonce: Wire.counterNonce(sessionId: sessionId, counter: sendCounter), aead: aead, plaintext: body)
    }

    /// Ends a clipboard transfer the desktop stopped answering; its outcome, or nil.
    public func clipExpired(nowMs: Int64) -> ClipTransfer.Outcome? {
        guard clip?.expired(nowMs: nowMs) == true else { return nil }
        clip = nil
        return .failed(status: ClipTransfer.gaveUp)
    }

    public func byePacket() -> [UInt8]? {
        guard let aead = c2s else { return nil }
        sendCounter += 1
        return Wire.seal(type: Wire.bye, deviceId: host.deviceId, nonce: Wire.counterNonce(sessionId: sessionId, counter: sendCounter), aead: aead, plaintext: [])
    }

    /// Digest one received datagram; nil when it's not for us or doesn't
    /// verify. A valid new WELCOME is only taken when [claim] agrees (another
    /// transport may already be typing for this phone); otherwise nothing
    /// changes, the shared `keys` included.
    public func receive(_ data: [UInt8], nowMs: UInt32, claim: () -> Bool = { true }) -> Result? {
        guard let p = Packet.parse(data), p.deviceId == host.deviceId else { return nil }
        switch p.type {
        case Wire.welcome: return onWelcome(p, claim)
        case Wire.ack: return onAck(p, nowMs)
        case Wire.clipReply: return onClipReply(p)
        case Wire.reject: return !connected && p.body.count >= 1 ? .rejected : nil
        default: return nil
        }
    }

    private func onWelcome(_ p: Packet, _ claim: () -> Bool) -> Result? {
        guard let plain = p.open(deviceAead), let w = Welcome.decode(plain), w.clientRandom == clientRandom else { return nil }
        // A duplicate WELCOME for the session we already have.
        if connected && w.sessionId == sessionId { return nil }
        if !claim() { return nil }
        clip?.restart()
        let k = SessionKeys.derive(deviceKey: host.key, clientRandom: clientRandom, serverRandom: w.serverRandom)
        c2s = Aead(key: k.clientToServer)
        s2c = Aead(key: k.serverToClient)
        sessionId = w.sessionId
        sendCounter = 0
        recvCounter = 0
        connected = true
        keys.resetSession()
        return .connected(hostName: w.name, sessionId: w.sessionId, features: w.features, btAddress: w.btAddress.map(PairingURI.btAddress))
    }

    private func onAck(_ p: Packet, _ nowMs: UInt32) -> Result? {
        guard let aead = s2c, p.sessionId == sessionId, p.counter > recvCounter,
              let plain = p.open(aead), let ack = Ack.decode(plain)
        else { return nil }
        recvCounter = p.counter
        keys.ack(ack.lastEseq)
        return .acked(pingMs: Int(Int32(bitPattern: nowMs &- ack.clientTimeMs)), leds: ack.leds, theme: ack.theme)
    }

    private func onClipReply(_ p: Packet) -> Result? {
        guard let aead = s2c, p.sessionId == sessionId, p.counter > recvCounter,
              let plain = p.open(aead), let reply = Clip.decode(plain, reply: true)
        else { return nil }
        recvCounter = p.counter
        guard let outcome = clip?.onReply(reply) else { return nil }
        clip = nil
        return .clipDone(outcome)
    }
}
