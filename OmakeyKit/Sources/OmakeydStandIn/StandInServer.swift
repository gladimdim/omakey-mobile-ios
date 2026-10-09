import Foundation
import OmakeyNet
import OmakeyProtocol

/// A stand-in for omakeyd: the server side of PROTOCOL.md, written from the
/// spec, that types nothing. It drives the network tests, `omakey-dev-server`
/// (a computer for the simulator to pair with) and the app's demo mode.
///
/// Like the real server it applies each event once (newest `eseq` wins),
/// reconciles the held set, lets go of a quiet session's keys after 500 ms,
/// reports Caps Lock in the ACK's LED byte, sends the theme in a session's
/// first ACKs, and keeps a clipboard. Knobs make it misbehave the ways a
/// network does.
public final class StandInServer: @unchecked Sendable {
    /// What the "computer" saw, for logs and the demo screen.
    public enum Event: Sendable, Equatable {
        case hello(name: String, platform: UInt8)
        case key(code: Int, down: Bool)
        case pointer(Pointer)
        case layout(String)
        case bye
        /// The phone's text arrived; [paste]: it was pasted too.
        case clipboardSet(text: String, paste: Bool)
        /// The phone asked for the clipboard; [copy]: what's selected was copied first.
        case clipboardRead(copy: Bool)
        /// Every held key let go: the phone went quiet or left.
        case releasedAll
    }

    public static let stuckKeyMs: Int64 = 500
    static let keyCapsLock = 58

    public let host: HostRecord
    public var endpoint: Endpoint { socket.localEndpoint }

    private let socket: UDPSocket
    private let lock = NSLock()
    private var running = true
    private let finished = DispatchSemaphore(value: 0)

    // Knobs (under the lock).
    private var _features = Wire.featurePointer | Wire.featureClipboard
    private var _known = true
    private var _silent = false
    private var _reportsLeds = true
    private var _theme: DesktopTheme?
    private var _dropAcks = 0
    private var _clipboard = ""
    private var _onEvent: (@Sendable (Event) -> Void)?

    // What arrived (under the lock).
    private var _hellos: [Hello] = []
    private var _inputs: [Input] = []
    private var _byes = 0
    private var _clips: [Clip] = []

    // The session (one phone at a time).
    private var c2s: Aead?
    private var s2c: Aead?
    private var sessionId: UInt32 = 0
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0
    private var lastEseq: UInt16 = 0
    private var held = Set<Int>()
    private var lastHeard: Int64 = 0
    private var themeAcks = 0
    private var capsLock = false
    private var clipId: UInt32?
    private var clipIn: [UInt8] = []
    /// The put under way is in and set.
    private var clipSet = false

    /// [host]: the identity to answer as (its addresses and port are ignored);
    /// nil makes a fresh one.
    public init(name: String = "test desk", bindTo: Endpoint = .loopback(), identity: HostRecord? = nil) throws {
        socket = try UDPSocket(bindTo: bindTo)
        let id = identity ?? HostRecord(hostId: Hex.encode(SecureRandom().bytes(8)), name: name, addresses: [], port: 0,
                                        deviceId: SecureRandom().bytes(8), key: SecureRandom().bytes(32))
        host = HostRecord(hostId: id.hostId, name: name, addresses: ["127.0.0.1"], port: Int(socket.localEndpoint.port),
                          deviceId: id.deviceId, key: id.key)
        let t = Thread { [self] in
            serve(name)
            finished.signal()
        }
        t.name = "omakeyd-stand-in"
        t.start()
    }

    public func stop() {
        lock.withLock { running = false }
        _ = finished.wait(timeout: .now() + 2)
        socket.close()
    }

    /// `omakey://pair?…` for this server at [addresses] (the phone tries them in order).
    public func pairingLink(addresses: [String]) -> String {
        let name = host.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "computer"
        return "omakey://pair?v=1&h=\(host.hostId)&n=\(name)&a=\(addresses.joined(separator: ","))"
            + "&p=\(host.port)&d=\(host.deviceIdHex)&k=\(Base64URL.encode(host.key))"
    }

    private func guarded<T>(_ get: () -> T) -> T { lock.withLock(get) }

    public var features: Int { get { guarded { _features } } set { lock.withLock { _features = newValue } } }
    /// False: the phone is forgotten, every HELLO gets a REJECT.
    public var known: Bool { get { guarded { _known } } set { lock.withLock { _known = newValue } } }
    /// True: nothing is answered, as if the computer went to sleep.
    public var silent: Bool { get { guarded { _silent } } set { lock.withLock { _silent = newValue } } }
    /// False: ACKs carry no LED byte (and so no theme), as from servers before 0.4.
    public var reportsLeds: Bool { get { guarded { _reportsLeds } } set { lock.withLock { _reportsLeds = newValue } } }
    public var theme: DesktopTheme? { get { guarded { _theme } } set { lock.withLock { _theme = newValue; themeAcks = 0 } } }
    /// This many INPUTs get no ACK.
    public var dropAcks: Int { get { guarded { _dropAcks } } set { lock.withLock { _dropAcks = newValue } } }
    /// The "computer's" clipboard.
    public var clipboard: String { get { guarded { _clipboard } } set { lock.withLock { _clipboard = newValue } } }
    /// Called on the server's thread, never with its lock held.
    public var onEvent: (@Sendable (Event) -> Void)? { get { guarded { _onEvent } } set { lock.withLock { _onEvent = newValue } } }

    public var hellos: [Hello] { guarded { _hellos } }
    public var inputs: [Input] { guarded { _inputs } }
    public var byes: Int { guarded { _byes } }
    public var clips: [Clip] { guarded { _clips } }
    /// Keys down on the "computer" right now.
    public var heldKeys: Set<Int> { guarded { held } }

    private func serve(_ name: String) {
        var buf = [UInt8](repeating: 0, count: 2048)
        while guarded({ running }) {
            waitReadable(socket, nil, timeoutMs: 20)
            while let (n, from) = socket.receive(into: &buf) {
                let events = guarded { handle(Array(buf[0..<n]), from, name) }
                emit(events)
            }
            // The stuck-key rule: a quiet session's keys are let go.
            emit(guarded { () -> [Event] in
                guard !held.isEmpty, MonotonicClock.nowMs() - lastHeard > StandInServer.stuckKeyMs else { return [] }
                return releaseAll()
            })
        }
    }

    private func emit(_ events: [Event]) {
        guard !events.isEmpty, let f = onEvent else { return }
        for e in events { f(e) }
    }

    /// With the lock held: one datagram; the events it caused.
    private func handle(_ data: [UInt8], _ from: Endpoint, _ name: String) -> [Event] {
        guard !_silent, let p = Packet.parse(data) else { return [] }
        switch p.type {
        case Wire.hello:
            guard _known, p.deviceId == host.deviceId else {
                let reject = Wire.header(type: Wire.reject, deviceId: p.deviceId, nonce: [UInt8](repeating: 0, count: 12)) + [Wire.rejectUnknownDevice]
                socket.send(reject, to: from)
                return []
            }
            guard let plain = p.open(Aead(key: host.key)), let hello = Hello.decode(plain) else { return [] }
            _hellos.append(hello)
            var events = releaseAll()
            let serverRandom = SecureRandom().bytes(16)
            sessionId &+= 1
            sendCounter = 0
            recvCounter = 0
            lastEseq = 0
            themeAcks = 0
            let k = SessionKeys.derive(deviceKey: host.key, clientRandom: hello.clientRandom, serverRandom: serverRandom)
            c2s = Aead(key: k.clientToServer)
            s2c = Aead(key: k.serverToClient)
            let w = Welcome(clientRandom: hello.clientRandom, serverRandom: serverRandom, sessionId: sessionId, name: name, features: _features)
            socket.send(Wire.seal(type: Wire.welcome, deviceId: host.deviceId, nonce: SecureRandom().bytes(12),
                                  aead: Aead(key: host.key), plaintext: w.encode()), to: from)
            events.insert(.hello(name: hello.name, platform: hello.platform), at: 0)
            return events
        case Wire.input:
            guard let c2s, p.sessionId == sessionId, p.counter > recvCounter,
                  let plain = p.open(c2s), let input = Input.decode(plain)
            else { return [] }
            recvCounter = p.counter
            lastHeard = MonotonicClock.nowMs()
            _inputs.append(input)
            let events = apply(input)
            if _dropAcks > 0 {
                _dropAcks -= 1
                return events
            }
            var theme: DesktopTheme?
            if let t = _theme, themeAcks < 4 {
                theme = t
                themeAcks += 1
            }
            let leds = _reportsLeds ? (capsLock ? Ack.ledCaps : 0) : nil
            reply(Wire.ack, Ack(clientTimeMs: input.clientTimeMs, lastEseq: lastEseq, leds: leds, theme: leds != nil ? theme : nil).encode(), to: from)
            return events
        case Wire.bye:
            guard let c2s, p.sessionId == sessionId, p.open(c2s) != nil else { return [] }
            _byes += 1
            return releaseAll() + [.bye]
        case Wire.clip:
            guard _features & Wire.featureClipboard != 0, let c2s, p.sessionId == sessionId, p.counter > recvCounter,
                  let plain = p.open(c2s), let clip = Clip.decode(plain, reply: false)
            else { return [] }
            recvCounter = p.counter
            _clips.append(clip)
            return answerClip(clip, from)
        default:
            return []
        }
    }

    /// With the lock held: the events newer than the last applied, then the held set.
    private func apply(_ input: Input) -> [Event] {
        var events = [Event]()
        if let layout = input.layout { events.append(.layout(layout)) }
        for e in input.events where Wire.eseqNewer(e.eseq, lastEseq) {
            lastEseq = e.eseq
            let code = Int(e.code)
            if e.value == 1, held.insert(code).inserted {
                if code == StandInServer.keyCapsLock { capsLock.toggle() }
                events.append(.key(code: code, down: true))
            } else if e.value == 0, held.remove(code) != nil {
                events.append(.key(code: code, down: false))
            }
        }
        // Reconcile: what the phone says it holds is what's down.
        let wanted = Set(input.held.map(Int.init))
        for code in held.subtracting(wanted).sorted() {
            held.remove(code)
            events.append(.key(code: code, down: false))
        }
        for code in wanted.subtracting(held).sorted() {
            held.insert(code)
            events.append(.key(code: code, down: true))
        }
        if let p = input.pointer { events.append(.pointer(p)) }
        return events
    }

    /// With the lock held.
    private func releaseAll() -> [Event] {
        guard !held.isEmpty else { return [] }
        let events = held.sorted().map { Event.key(code: $0, down: false) }
        held.removeAll()
        return events + [.releasedAll]
    }

    /// With the lock held.
    private func answerClip(_ clip: Clip, _ from: Endpoint) -> [Event] {
        var events = [Event]()
        let fresh = clip.clipId != clipId
        if fresh {
            clipId = clip.clipId
            clipIn.removeAll()
            clipSet = false
        }
        if clip.op == Clip.put {
            // Only a piece that starts where the bytes so far end.
            if clip.offset == clipIn.count { clipIn += clip.data }
            if clipIn.count >= clip.total && !clipSet {
                clipSet = true
                _clipboard = String(decoding: clipIn, as: UTF8.self)
                events.append(.clipboardSet(text: _clipboard, paste: clip.flags & Clip.paste != 0))
            }
            reply(Wire.clipReply, Clip(op: Clip.put, clipId: clip.clipId, offset: clipIn.count, total: clip.total).encode(reply: true), to: from)
        } else {
            if fresh { events.append(.clipboardRead(copy: clip.flags & Clip.copy != 0)) }
            let text = Array(_clipboard.utf8)
            if text.isEmpty {
                reply(Wire.clipReply, Clip(op: Clip.get, clipId: clip.clipId, status: Clip.empty).encode(reply: true), to: from)
            } else {
                let start = min(clip.offset, text.count)
                let piece = Array(text[start..<min(start + Clip.chunk, text.count)])
                reply(Wire.clipReply, Clip(op: Clip.get, clipId: clip.clipId, offset: start, total: text.count, data: piece).encode(reply: true), to: from)
            }
        }
        return events
    }

    /// With the lock held.
    private func reply(_ type: UInt8, _ body: [UInt8], to: Endpoint) {
        guard let s2c else { return }
        sendCounter += 1
        socket.send(Wire.seal(type: type, deviceId: host.deviceId, nonce: Wire.counterNonce(sessionId: sessionId, counter: sendCounter),
                              aead: s2c, plaintext: body), to: to)
    }
}
