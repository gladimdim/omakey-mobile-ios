import Foundation
@testable import OmakeyNet
import OmakeyProtocol

/// The server side of PROTOCOL.md on 127.0.0.1, enough to drive a link:
/// HELLO → WELCOME, INPUT → ACK, BYE, CLIP put → CLIP_REPLY, and REJECT for
/// a device it doesn't know. Knobs make it misbehave the ways a network does.
final class FakeOmakeyd: @unchecked Sendable {
    let host: HostRecord
    var endpoint: Endpoint { socket.localEndpoint }

    private let socket: UDPSocket
    private let lock = NSLock()
    private var running = true
    private let finished = DispatchSemaphore(value: 0)

    // Knobs, set by tests (under the lock).
    private var _features = Wire.featurePointer
    private var _known = true
    private var _silent = false
    private var _ackLeds: Int?
    private var _theme: DesktopTheme?
    private var _dropAcks = 0

    // What arrived (under the lock).
    private var _hellos: [Hello] = []
    private var _inputs: [Input] = []
    private var _byes = 0
    private var _clips: [Clip] = []

    private var c2s: Aead?
    private var s2c: Aead?
    private var sessionId: UInt32 = 0
    private var sendCounter: UInt64 = 0
    private var lastEseq: UInt16 = 0
    private var clipText: [UInt8] = []

    init(name: String = "test desk") throws {
        socket = try UDPSocket(bindTo: .loopback())
        let port = Int(socket.localEndpoint.port)
        host = HostRecord(hostId: "a0a1a2a3a4a5a6a7", name: name, addresses: ["127.0.0.1"], port: port,
                          deviceId: [1, 2, 3, 4, 5, 6, 7, 8], key: (0..<32).map { UInt8($0) })
        let t = Thread { [self] in
            serve(name)
            finished.signal()
        }
        t.start()
    }

    func stop() {
        lock.withLock { running = false }
        _ = finished.wait(timeout: .now() + 2)
        socket.close()
    }

    var features: Int { get { lock.withLock { _features } } set { lock.withLock { _features = newValue } } }
    /// False: the device is forgotten, every HELLO gets a REJECT.
    var known: Bool { get { lock.withLock { _known } } set { lock.withLock { _known = newValue } } }
    /// True: nothing is answered, as if the computer went to sleep.
    var silent: Bool { get { lock.withLock { _silent } } set { lock.withLock { _silent = newValue } } }
    var ackLeds: Int? { get { lock.withLock { _ackLeds } } set { lock.withLock { _ackLeds = newValue } } }
    var theme: DesktopTheme? { get { lock.withLock { _theme } } set { lock.withLock { _theme = newValue } } }
    /// This many INPUTs get no ACK.
    var dropAcks: Int { get { lock.withLock { _dropAcks } } set { lock.withLock { _dropAcks = newValue } } }

    var hellos: [Hello] { lock.withLock { _hellos } }
    var inputs: [Input] { lock.withLock { _inputs } }
    var byes: Int { lock.withLock { _byes } }
    var clips: [Clip] { lock.withLock { _clips } }

    private func serve(_ name: String) {
        var buf = [UInt8](repeating: 0, count: 2048)
        while lock.withLock({ running }) {
            waitReadable(socket, nil, timeoutMs: 20)
            while let (n, from) = socket.receive(into: &buf) {
                handle(Array(buf[0..<n]), from, name)
            }
        }
    }

    private func handle(_ data: [UInt8], _ from: Endpoint, _ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !_silent, let p = Packet.parse(data) else { return }
        switch p.type {
        case Wire.hello:
            guard _known, p.deviceId == host.deviceId else {
                socket.send(Wire.header(type: Wire.reject, deviceId: p.deviceId, nonce: [UInt8](repeating: 0, count: 12)) + [Wire.rejectUnknownDevice], to: from)
                return
            }
            guard let plain = p.open(Aead(key: host.key)), let hello = Hello.decode(plain) else { return }
            _hellos.append(hello)
            let serverRandom = SecureRandom().bytes(16)
            sessionId &+= 1
            sendCounter = 0
            lastEseq = 0
            let k = SessionKeys.derive(deviceKey: host.key, clientRandom: hello.clientRandom, serverRandom: serverRandom)
            c2s = Aead(key: k.clientToServer)
            s2c = Aead(key: k.serverToClient)
            let w = Welcome(clientRandom: hello.clientRandom, serverRandom: serverRandom, sessionId: sessionId, name: name, features: _features)
            socket.send(Wire.seal(type: Wire.welcome, deviceId: host.deviceId, nonce: SecureRandom().bytes(12), aead: Aead(key: host.key), plaintext: w.encode()), to: from)
        case Wire.input:
            guard let c2s, let plain = p.open(c2s), let input = Input.decode(plain) else { return }
            _inputs.append(input)
            if let e = input.events.last { lastEseq = e.eseq }
            if _dropAcks > 0 {
                _dropAcks -= 1
                return
            }
            reply(Wire.ack, Ack(clientTimeMs: input.clientTimeMs, lastEseq: lastEseq, leds: _ackLeds, theme: _theme).encode(), to: from)
        case Wire.bye:
            guard let c2s, p.open(c2s) != nil else { return }
            _byes += 1
        case Wire.clip:
            guard let c2s, let plain = p.open(c2s), let clip = Clip.decode(plain, reply: false) else { return }
            _clips.append(clip)
            if clip.offset == clipText.count { clipText += clip.data }
            reply(Wire.clipReply, Clip(op: clip.op, clipId: clip.clipId, offset: clipText.count, total: clip.total).encode(reply: true), to: from)
        default:
            break
        }
    }

    /// With the lock held.
    private func reply(_ type: UInt8, _ body: [UInt8], to: Endpoint) {
        guard let s2c else { return }
        sendCounter += 1
        socket.send(Wire.seal(type: type, deviceId: host.deviceId, nonce: Wire.counterNonce(sessionId: sessionId, counter: sendCounter), aead: s2c, plaintext: body), to: to)
    }
}

/// Everything a link reported, in order.
final class RecordingListener: LinkListener, @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [LinkState] = []
    private var _hostNames: [String] = []
    private var _pings: [Int] = []
    private var _leds: [Int] = []
    private var _themes: [DesktopTheme] = []
    private var _clips: [ClipTransfer.Outcome] = []

    var states: [LinkState] { lock.withLock { _states } }
    var hostNames: [String] { lock.withLock { _hostNames } }
    var pings: [Int] { lock.withLock { _pings } }
    var leds: [Int] { lock.withLock { _leds } }
    var themes: [DesktopTheme] { lock.withLock { _themes } }
    var clips: [ClipTransfer.Outcome] { lock.withLock { _clips } }

    func linkState(_ state: LinkState, hostName: String?) {
        lock.withLock {
            _states.append(state)
            if let hostName { _hostNames.append(hostName) }
        }
    }

    func linkPing(_ ms: Int) { lock.withLock { _pings.append(ms) } }
    func linkLeds(_ leds: Int) { lock.withLock { _leds.append(leds) } }
    func linkTheme(_ theme: DesktopTheme) { lock.withLock { _themes.append(theme) } }
    func linkClip(_ outcome: ClipTransfer.Outcome) { lock.withLock { _clips.append(outcome) } }
}

/// Polls [condition] until it holds or [seconds] pass; true when it held.
func eventually(within seconds: Double = 2, _ condition: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: seconds)
    while Date() < end {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}
