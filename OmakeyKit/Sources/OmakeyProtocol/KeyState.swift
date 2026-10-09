import os

/// What the phone holds right now, and the press/release events the server
/// hasn't acknowledged yet. The touch thread calls `press`/`release`; the
/// network thread calls `buildInput`/`ack`. Every method takes the lock.
///
/// Two keys in a layout may share a code, so held codes are reference
/// counted: the server sees one press when the first finger lands and one
/// release when the last lifts.
public final class KeyState: @unchecked Sendable {
    public static let maxCode = 0x2FF
    public static let maxHeld = 64

    private let lock = OSAllocatedUnfairLock()

    // Everything below is guarded by `lock`.
    private var counts = [Int](repeating: 0, count: KeyState.maxCode + 1)
    /// Held codes in ascending order, as PROTOCOL.md sends them.
    private var heldOrder: [UInt16] = []
    private var pending: [KeyEvent] = []
    private var nextEseq: UInt16 = 1
    // Touchpad motion and scroll waiting for the next INPUT. Fractions are
    // kept, so slow finger movement still adds up to whole counts.
    private var moveX: Float = 0
    private var moveY: Float = 0
    private var wheel: Float = 0
    private var hwheel: Float = 0
    private var _version: Int64 = 0
    private var _layout: String?

    public init() {
        heldOrder.reserveCapacity(KeyState.maxHeld)
        pending.reserveCapacity(Wire.maxEvents + 1)
    }

    private func locked<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Key events sent but not yet acknowledged; past `Wire.maxEvents` the oldest are dropped.
    public var unacked: Int { locked { pending.count } }

    /// Bumped on every change, so the sender knows to transmit now.
    public var version: Int64 { locked { _version } }

    public var hasUnacked: Bool { locked { !pending.isEmpty } }

    public var isHolding: Bool { locked { !heldOrder.isEmpty } }

    /// The xkb layout the computer reads these keys with (INPUT `layout`); nil leaves it alone.
    public var layout: String? {
        get { locked { _layout } }
        set { locked { _layout = newValue } }
    }

    @discardableResult
    public func press(_ code: Int) -> Bool {
        locked { pressLocked(code) }
    }

    @discardableResult
    public func release(_ code: Int) -> Bool {
        locked { releaseLocked(code) }
    }

    /// Lets go of everything, sending a release for each held key.
    public func releaseAll() {
        locked {
            while let code = heldOrder.last {
                counts[Int(code)] = 1
                releaseLocked(Int(code))
            }
            for i in counts.indices { counts[i] = 0 }
        }
    }

    /// A new session starts: sequence numbers restart, old events are moot.
    public func resetSession() {
        locked {
            pending.removeAll(keepingCapacity: true)
            nextEseq = 1
            _version += 1
        }
    }

    public func ack(_ lastEseq: UInt16) {
        locked {
            var drop = 0
            while drop < pending.count, !Wire.eseqNewer(pending[drop].eseq, lastEseq) { drop += 1 }
            pending.removeFirst(drop)
        }
    }

    public func held() -> [UInt16] { locked { heldOrder } }

    /// Touchpad motion in mouse counts; sent with the next INPUT, once.
    public func addMotion(dx: Float, dy: Float) {
        locked {
            moveX += dx
            moveY += dy
            _version += 1
        }
    }

    /// Scroll in 1/120 of a notch: positive [v] scrolls up, positive [h] right.
    public func addScroll(v: Float, h: Float) {
        locked {
            wheel += v
            hwheel += h
            _version += 1
        }
    }

    public func buildInput(clientTimeMs: UInt32) -> Input {
        locked {
            Input(clientTimeMs: clientTimeMs, held: heldOrder, events: pending, pointer: takePointerLocked(), layout: _layout)
        }
    }

    /// Motion and scroll gathered since the last call, in whole counts; nil when none.
    public func takePointer() -> Pointer? { locked { takePointerLocked() } }

    // MARK: - With the lock held

    @discardableResult
    private func pressLocked(_ code: Int) -> Bool {
        guard (1...KeyState.maxCode).contains(code) else { return false }
        counts[code] += 1
        if counts[code] > 1 { return false }
        if heldOrder.count < KeyState.maxHeld {
            let c = UInt16(code)
            heldOrder.insert(c, at: heldOrder.firstIndex { $0 > c } ?? heldOrder.endIndex)
        }
        addEvent(code, 1)
        return true
    }

    @discardableResult
    private func releaseLocked(_ code: Int) -> Bool {
        guard (1...KeyState.maxCode).contains(code), counts[code] > 0 else { return false }
        counts[code] -= 1
        if counts[code] > 0 { return false }
        heldOrder.removeAll { $0 == UInt16(code) }
        addEvent(code, 0)
        return true
    }

    private func takePointerLocked() -> Pointer? {
        func take(_ v: Float) -> Int16 {
            guard v.isFinite else { return 0 }
            return Int16(max(min(v, Float(Int16.max)), Float(Int16.min)).rounded(.towardZero))
        }
        let p = Pointer(dx: take(moveX), dy: take(moveY), wheel: take(wheel), hwheel: take(hwheel))
        if p == .zero { return nil }
        moveX -= Float(p.dx)
        moveY -= Float(p.dy)
        wheel -= Float(p.wheel)
        hwheel -= Float(p.hwheel)
        return p
    }

    private func addEvent(_ code: Int, _ value: UInt8) {
        pending.append(KeyEvent(eseq: nextEseq, code: UInt16(code), value: value))
        nextEseq &+= 1
        // Over the cap, drop the oldest; the held set still repairs the state.
        if pending.count > Wire.maxEvents { pending.removeFirst(pending.count - Wire.maxEvents) }
        _version += 1
    }
}
