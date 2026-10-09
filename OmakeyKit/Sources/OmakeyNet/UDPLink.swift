import Foundation
import OmakeyProtocol
import os

/// omakeyd over UDP: the socket and the timing rules of PROTOCOL.md (a port
/// of Android's `KeyboardLink`). A key change is sent by `send` on the
/// touch thread itself, so it leaves the phone without waiting for another
/// thread to wake up. A dedicated network thread does the rest: handshake,
/// resends, heartbeats and reading ACKs.
///
/// Everything touching `session` (and the fields below it) holds `lock`, so
/// packet counters go out in the order they were assigned. Times are
/// monotonic milliseconds; only the wire's client_time_ms is cut to 32 bits.
public final class UDPLink: Link, @unchecked Sendable {
    /// Resend bounds for unacknowledged events; the actual wait follows the measured ping.
    public static let resendMinMs: Int64 = 5
    public static let resendMs: Int64 = 20
    public static let heartbeatMs: Int64 = 100
    public static let helloFirstMs: Int64 = 50
    public static let helloMs: Int64 = 250
    public static let rejectedHelloMs: Int64 = 1000
    public static let lostMs: Int64 = 1500

    public let keys: KeyState
    private let listener: LinkListener
    /// Asked before a new session is taken; false when another link has the computer.
    private let claim: (UDPLink) -> Bool
    private let log = Logger(subsystem: "com.gladimdim.omakey", category: "link")

    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`.
    private let session: ClientSession
    private var candidates: [Endpoint] = []
    private var running = false
    /// Bumped by every `start`: a thread from an earlier start that outlived `stop` sees it and quits.
    private var generation = 0
    private var socket: UDPSocket?
    private var wakePipe: WakePipe?
    private var done: DispatchSemaphore?
    /// What was sent last, and when.
    private var sentVersion: Int64 = -1
    private var lastSend: Int64 = 0
    /// A new candidate arrived: say HELLO to it now, not at the next retry.
    private var helloNow = false
    private var _features = 0
    private var _btAddress: String?
    private var _peer: Endpoint?

    public init(host: HostRecord, phoneName: String, keys: KeyState, listener: LinkListener,
                claim: @escaping (UDPLink) -> Bool = { _ in true }) {
        self.keys = keys
        self.listener = listener
        self.claim = claim
        session = ClientSession(host: host, phoneName: phoneName, keys: keys)
        for a in host.addresses {
            if let e = Endpoint(host: a, port: host.port), !candidates.contains(e) { candidates.append(e) }
        }
    }

    private func locked<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var features: Int { locked { _features } }
    public var transport: String { "Wi-Fi" }
    /// The computer's Bluetooth address from its WELCOME, if it has one.
    public var btAddress: String? { locked { _btAddress } }
    /// The address that answered.
    public var peer: Endpoint? { locked { _peer } }

    /// Another address for the computer (mDNS found it there): tried first, at once.
    public func addCandidate(_ e: Endpoint) {
        let added = locked { () -> Bool in
            guard !candidates.contains(e) else { return false }
            candidates.insert(e, at: 0)
            helloNow = true
            return true
        }
        if added { wake() }
    }

    public func start() {
        let gen: Int? = locked {
            if running { return nil }
            running = true
            generation += 1
            return generation
        }
        guard let gen else { return }
        let finished = DispatchSemaphore(value: 0)
        locked { done = finished }
        let t = Thread { [self] in
            run(gen)
            finished.signal()
        }
        t.name = "omakey-net"
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Sends BYE and stops. The server then releases every key we held.
    public func stop() {
        let finished = locked { () -> DispatchSemaphore? in
            running = false
            defer { done = nil }
            return done
        }
        wake()
        _ = finished?.wait(timeout: .now() + .milliseconds(500))
    }

    /// A key changed: send the new state right now, from the calling thread.
    /// The UDP send never blocks.
    public func send() {
        locked {
            if let s = socket, session.connected { sendInput(s, MonotonicClock.nowMs()) }
        }
        // The network thread re-arms its resend timer for the new events.
        wake()
    }

    public func clip(_ transfer: ClipTransfer) -> Bool {
        let ok = locked { () -> Bool in
            guard _features & Wire.featureClipboard != 0 else { return false }
            session.clip = transfer
            return true
        }
        if ok { wake() }
        return ok
    }

    /// Wake the network thread. Cheap; safe from any thread.
    public func wake() {
        locked { wakePipe }?.wake()
    }

    /// With `lock` held.
    private func sendInput(_ s: UDPSocket, _ now: Int64) {
        let v = keys.version
        guard let pkt = session.inputPacket(clientTimeMs: UInt32(truncatingIfNeeded: now)) else { return }
        sentVersion = v
        lastSend = now
        if let p = _peer { s.send(pkt, to: p) }
    }

    private func run(_ gen: Int) {
        let s: UDPSocket
        let pipe: WakePipe
        do {
            s = try UDPSocket()
            pipe = try WakePipe()
        } catch {
            log.error("can't open the socket: \(error.localizedDescription, privacy: .public)")
            return
        }
        let alive = { [self] in locked { running && gen == generation } }
        locked {
            socket = s
            wakePipe = pipe
            // A restarted link begins a fresh handshake; the old session got BYE.
            session.restart()
            _peer = nil
            helloNow = true
        }
        defer {
            locked {
                // A newer start() may already own these fields.
                if socket === s { socket = nil }
                if wakePipe === pipe { wakePipe = nil }
            }
            s.close()
            pipe.close()
        }

        var state: LinkState?
        func setState(_ new: LinkState, _ name: String? = nil) {
            if new != state {
                state = new
                listener.linkState(new, hostName: name)
            }
        }
        setState(.connecting)

        var nextHello = MonotonicClock.nowMs()
        var helloInterval = UDPLink.helloFirstMs
        var lastHeard: Int64 = 0
        var lastPingReport: Int64 = 0
        // Smoothed round trip from ACKs. A lost event is resent once an ACK
        // is clearly overdue, instead of after a fixed resendMs.
        var srtt = Float(UDPLink.resendMs)
        var resendMs = UDPLink.resendMs
        var buf = [UInt8](repeating: 0, count: 2048)

        while alive() {
            let now = MonotonicClock.nowMs()
            var timeout: Int64
            if !locked({ session.connected }) {
                let hello: (packet: [UInt8], to: [Endpoint])? = locked {
                    guard helloNow || now >= nextHello else { return nil }
                    helloNow = false
                    return (session.helloPacket(), candidates)
                }
                if let hello {
                    for c in hello.to { s.send(hello.packet, to: c) } // unreachable now: retried
                    // Retry quickly at first, in case the first HELLO was lost:
                    // after 50 ms, then 100, 200, 250, 250…
                    nextHello = now + (state == .rejected ? UDPLink.rejectedHelloMs : helloInterval)
                    helloInterval = min(helloInterval * 2, UDPLink.helloMs)
                }
                timeout = nextHello - now
            } else {
                if now - lastHeard > UDPLink.lostMs {
                    // No ACK for a while: the computer moved, slept or restarted.
                    locked {
                        session.restart()
                        _peer = nil
                    }
                    helloInterval = UDPLink.helloFirstMs
                    nextHello = now
                    setState(.connecting)
                    continue
                }
                var clipDone: ClipTransfer.Outcome?
                timeout = locked {
                    let since = now - lastSend
                    if keys.version != sentVersion || (keys.hasUnacked && since >= resendMs) || since >= UDPLink.heartbeatMs {
                        sendInput(s, now)
                    }
                    clipDone = session.clipExpired(nowMs: now)
                    if let c = session.clipPacket(nowMs: now), let p = _peer { s.send(c, to: p) }
                    let t = MonotonicClock.nowMs()
                    let next = (keys.hasUnacked ? resendMs : UDPLink.heartbeatMs) - (t - lastSend)
                    if let clip = session.clip { return min(next, clip.dueAt - t) }
                    return next
                }
                if let clipDone { listener.linkClip(clipDone) }
            }

            waitReadable(s, pipe, timeoutMs: timeout)

            while let (n, from) = s.receive(into: &buf) {
                let t = MonotonicClock.nowMs()
                let datagram = Array(buf[0..<n])
                let r = locked { () -> ClientSession.Result? in
                    let r = session.receive(datagram, nowMs: UInt32(truncatingIfNeeded: t)) { claim(self) }
                    if case .connected(_, _, let features, let bt) = r {
                        _peer = from
                        _features = features
                        _btAddress = bt
                        sentVersion = -1 // push the held set right away
                    }
                    return r
                }
                switch r {
                case .connected(let hostName, _, _, _)?:
                    lastHeard = t
                    setState(.connected, hostName)
                case .acked(let ping, let leds, let theme)?:
                    lastHeard = t
                    srtt += (Float(max(ping, 0)) - srtt) / 8
                    resendMs = min(max(Int64(srtt * 1.5 + 2), UDPLink.resendMinMs), UDPLink.resendMs)
                    if let leds { listener.linkLeds(leds) }
                    if let theme { listener.linkTheme(theme) }
                    if t - lastPingReport >= 250 {
                        lastPingReport = t
                        listener.linkPing(ping)
                    }
                case .clipDone(let outcome)?:
                    listener.linkClip(outcome)
                case .rejected?:
                    // REJECT isn't authenticated: only believe one from where we
                    // sent HELLO, so a stranger can't slow our retries.
                    if locked({ candidates.contains(from) }) { setState(.rejected) }
                case nil:
                    break
                }
            }
        }
        // Leaving: BYE twice, in case one is lost. The server's 500 ms
        // stuck-key timeout covers the rest.
        locked {
            guard let p = _peer, let bye = session.byePacket() else { return }
            s.send(bye, to: p)
            if let again = session.byePacket() { s.send(again, to: p) }
        }
    }
}
