import Foundation
import OmakeyProtocol

/// Which paired computers answer right now, for the connect screen. Every
/// `periodMs` each one gets a HELLO at its known addresses (and where mDNS
/// last saw it), and a BYE as soon as its WELCOME comes back. A session that
/// never sends INPUT can't push out one that is typing, and omakeyd doesn't
/// list it as connected (PROTOCOL.md, "Safety rules on the server").
/// Results go to [onChange] on the main queue, only when they change: host
/// id → the address that answered, or nil when none did.
public final class Reachability: @unchecked Sendable {
    public static let periodMs = 4000
    static let timeoutMs: Int64 = 1200
    static let retryMs: Int64 = 300

    private let phoneName: String
    private let onChange: @MainActor ([String: Endpoint?]) -> Void
    private let condition = NSCondition()
    // Guarded by `condition`.
    private var hosts: [HostRecord] = []
    private var seen: [String: Endpoint] = [:]
    /// The flag of the running check thread; a stopped thread sees its own flag cleared and quits.
    private var alive: Flag?

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var isSet: Bool { lock.withLock { value } }
        func clear() { lock.withLock { value = false } }
    }

    public init(phoneName: String, onChange: @escaping @MainActor ([String: Endpoint?]) -> Void) {
        self.phoneName = phoneName
        self.onChange = onChange
    }

    /// The computers to check, and where mDNS found any of them (host id → address). Checks a new one right away.
    public func update(paired: [HostRecord], nearby: [String: Endpoint]) {
        condition.lock()
        let fresh = paired.contains { p in !hosts.contains { $0.hostId == p.hostId } }
        hosts = paired
        seen = nearby
        if fresh { condition.broadcast() }
        condition.unlock()
    }

    public func start() {
        condition.lock()
        defer { condition.unlock() }
        if alive != nil { return }
        let flag = Flag()
        alive = flag
        let t = Thread { [self] in run(flag) }
        t.name = "omakey-reach"
        t.qualityOfService = .utility
        t.start()
    }

    public func stop() {
        condition.lock()
        alive?.clear()
        alive = nil
        condition.broadcast()
        condition.unlock()
    }

    private func run(_ flag: Flag) {
        var last: [String: Endpoint?]?
        while flag.isSet {
            condition.lock()
            let (list, nearby) = (hosts, seen)
            condition.unlock()
            var now = [String: Endpoint?]()
            for h in list where flag.isSet { now[h.hostId] = probe(h, near: nearby[h.hostId], flag) }
            if !flag.isSet { break }
            if now != last {
                last = now
                let result = now
                let deliver = onChange
                DispatchQueue.main.async {
                    if flag.isSet { MainActor.assumeIsolated { deliver(result) } }
                }
            }
            condition.lock()
            if flag.isSet { condition.wait(until: Date(timeIntervalSinceNow: Double(Reachability.periodMs) / 1000)) }
            condition.unlock()
        }
    }

    /// The address that answered, or nil.
    func probe(_ host: HostRecord, near: Endpoint?, _ flag: Flag) -> Endpoint? {
        var targets = [Endpoint]()
        for e in [near] + host.addresses.map({ Endpoint(host: $0, port: host.port) }) {
            if let e, !targets.contains(e) { targets.append(e) }
        }
        guard !targets.isEmpty, let s = try? UDPSocket() else { return nil }
        defer { s.close() }
        let session = ClientSession(host: host, phoneName: phoneName, keys: KeyState())
        var buf = [UInt8](repeating: 0, count: 2048)
        let deadline = MonotonicClock.nowMs() + Reachability.timeoutMs
        var nextHello: Int64 = 0
        while flag.isSet {
            let t = MonotonicClock.nowMs()
            if t >= deadline { return nil }
            if t >= nextHello {
                let hello = session.helloPacket()
                for a in targets { s.send(hello, to: a) } // that network may be gone
                nextHello = t + Reachability.retryMs
            }
            waitReadable(s, nil, timeoutMs: min(nextHello, deadline) - t)
            while let (n, from) = s.receive(into: &buf) {
                if case .connected = session.receive(Array(buf[0..<n]), nowMs: UInt32(truncatingIfNeeded: t)) {
                    // Twice, in case one is lost; omakeyd drops it after 30 s anyway.
                    for _ in 0..<2 { if let bye = session.byePacket() { s.send(bye, to: from) } }
                    return from
                }
            }
        }
        return nil
    }
}
