/// The keys that turn one line into another, with the cursor where it was and where it ends.
public enum LineDiff {
    /// Replaces the changed middle of [old] (what's equal at both ends is
    /// kept): moves to its end, deletes back over it, types the new middle,
    /// then moves to [newCursor]. [key] gets arrows and Backspace, [text] the
    /// characters. Cursors count UTF-16 units, as `UITextView` selections do.
    public static func edit(old: String, oldCursor: Int, new: String, newCursor: Int, key: (Int) -> Void, text: (String) -> Void) {
        let o = Array(old.utf16)
        let n = Array(new.utf16)
        var p = 0
        while p < o.count && p < n.count && o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p && s < n.count - p && o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        let oldEnd = o.count - s
        let newEnd = n.count - s
        var at = oldCursor
        func move(to: Int) {
            for _ in stride(from: at, to: to, by: -1) { key(UsKeys.keyLeft) }
            for _ in stride(from: at, to: to, by: 1) { key(UsKeys.keyRight) }
            at = to
        }
        if oldEnd > p || newEnd > p {
            move(to: oldEnd)
            for _ in p..<oldEnd { key(UsKeys.keyBackspace) }
            if newEnd > p { text(String(decoding: n[p..<newEnd], as: UTF16.self)) }
            at = newEnd
        }
        move(to: newCursor)
    }
}

/// Which layout the computer reads Omakey's keys with, and changing it.
@MainActor
public protocol LayoutGate: AnyObject {
    /// The layout asked for now; nil when none has been.
    func current() -> String?
    /// Nothing typed is still unacknowledged, so a new layout can't reach keys typed before it.
    func canSwitch() -> Bool
    func switchTo(_ layout: String)
}

/// Runs a block on the main thread a few milliseconds later; tests drive it by hand.
@MainActor
public protocol Scheduler: AnyObject {
    func after(ms: Int, _ block: @escaping @MainActor () -> Void)
}

/// Key strokes for the computer, paced: the phone's keyboard can hand over a
/// whole word at once (a suggestion, an autocorrection), and omakeyd keeps
/// only so many unacknowledged events. One stroke goes out every
/// `strokeMs` while [busy] says there's room. A character goes with the
/// layout that types it (`KeyLayouts`); a change of layout waits until
/// everything before it is acknowledged.
@MainActor
public final class Typist {
    public static let strokeMs = 8

    private struct Stroke {
        let codes: [Int]
        let layout: String?
        let char: Character?
    }

    private let sink: KeyboardSink
    private weak var gate: LayoutGate?
    private let scheduler: Scheduler
    /// The phone keyboard's layouts, its own language first.
    private let preferred: () -> [KeyLayout]
    /// The character a stroke types, just before it goes (for the typed text strip).
    private let onChar: (Character?) -> Void
    private let busy: () -> Bool

    private var queue: [Stroke] = []
    private var pumping = false
    /// The layout of the last stroke queued, for picking the next one.
    private var queuedLayout: String?

    public init(sink: KeyboardSink, gate: LayoutGate, scheduler: Scheduler, preferred: @escaping () -> [KeyLayout],
                onChar: @escaping (Character?) -> Void = { _ in }, busy: @escaping () -> Bool) {
        self.sink = sink
        self.gate = gate
        self.scheduler = scheduler
        self.preferred = preferred
        self.onChar = onChar
        self.busy = busy
    }

    /// Strokes waiting to go out.
    public var pending: Int { queue.count }

    /// Tap [code] in any layout, with Shift held around it when [shift].
    public func key(_ code: Int, shift: Bool = false) {
        add(code, shift: shift, layout: nil, char: nil)
    }

    /// Type [s]; characters no known layout has are skipped.
    public func text(_ s: String) {
        let prefs = preferred()
        for c in s {
            let current = queue.isEmpty ? gate?.current() : queuedLayout ?? gate?.current()
            guard let (layout, stroke) = KeyLayouts.pick(c, current: current, preferred: prefs) else { continue }
            add(stroke.code, shift: stroke.shift, layout: layout.xkb, char: c)
        }
    }

    /// Drop what hasn't gone out yet, e.g. when the screen goes away.
    public func clear() {
        queue.removeAll()
        queuedLayout = nil
    }

    private func add(_ code: Int, shift: Bool, layout: String?, char: Character?) {
        queue.append(Stroke(codes: shift ? [UsKeys.keyLeftShift, code] : [code], layout: layout, char: char))
        if let layout { queuedLayout = layout }
        pump()
    }

    private func pump() {
        if pumping { return }
        guard let stroke = queue.first else { return }
        let switching = stroke.layout != nil && stroke.layout != gate?.current()
        if !busy() && (!switching || gate?.canSwitch() == true) {
            if switching, let layout = stroke.layout { gate?.switchTo(layout) }
            queue.removeFirst()
            onChar(stroke.char)
            for c in stroke.codes { sink.keyDown(c) }
            for c in stroke.codes.reversed() { sink.keyUp(c) }
        }
        pumping = true
        scheduler.after(ms: Typist.strokeMs) { [weak self] in
            guard let self else { return }
            self.pumping = false
            self.pump()
        }
    }
}
