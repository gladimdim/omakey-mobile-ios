/// Where a keyboard's key presses go.
public protocol KeyboardSink: AnyObject {
    func keyDown(_ code: Int)
    func keyUp(_ code: Int)
}

/// Touch → key logic, free of UIKit so it can be unit-tested. Each pointer
/// holds at most one key, from touch-down to lift; fingers never slide onto
/// neighbors. The code a finger pressed is the code its lift releases, even
/// when the Fn layer changed in between.
///
/// With `sticky` on, modifiers and layer keys can be tapped instead of held:
/// a tapped Shift/Ctrl/Alt/Super stays down for the next key, a second tap
/// locks it until a third, and a tapped layer key (Fn) applies to the next
/// key only. Held in a chord, they behave as usual.
///
/// Not thread-safe: use it from the main thread, where touches arrive.
public final class KeyboardModel {
    /// Lock state; it outlives a layout switch. Set from the computer's lock
    /// lights when it reports them, otherwise as this phone has sent it.
    public final class Locks {
        public var capsLock = false
        public init() {}
    }

    public static let maxPointers = 32
    private static let keyLeftShift = 42
    private static let keyRightShift = 54
    private static let keyCapsLock = 58
    private static let latched = 1
    private static let locked = 2
    /// Ctrl, Shift, Alt and Super, left and right.
    public static let modifiers = [29, 42, 56, 125, 97, 54, 100, 126]
    private static let latchCodes = 128

    public static func isModifier(_ code: Int) -> Bool { modifiers.contains(code) }

    public let layout: Layout
    private let sink: KeyboardSink
    private let locks: Locks
    private let keys: [LayoutKey]

    private var pointerKey = [Int](repeating: -1, count: maxPointers)
    private var pointerCode = [Int](repeating: 0, count: maxPointers)
    /// Another key went down while this pointer's key was held: it's a chord, not a tap.
    private var chorded = [Bool](repeating: false, count: maxPointers)
    /// The pointer is tapping a modifier that was already latched or locked.
    private var wasLatched = [Bool](repeating: false, count: maxPointers)
    private var layerStack: [String] = []

    /// How many fingers are on each key, for the pressed highlight.
    public private(set) var pressCount: [Int]

    /// Fingers holding a Shift key right now.
    private var shiftHeld = 0

    /// Latched modifiers by code: `latched` (for the next key) or `locked`.
    private var latch = [Int](repeating: 0, count: latchCodes)

    /// A tapped layer key: the next key uses this layer.
    private var oneShotLayer: String?

    /// For each key, whether it is a letter (its label is the letter its code types).
    private let isLetter: [Bool]
    private let lowerLabel: [String]

    // Rectangles for the last stretch `hitTestStretched` saw.
    private var stretchedFor: Float = .nan
    private var stretchedRects: [[KeyRect]] = []

    public var sticky = false {
        didSet { if !sticky { releaseLatched(all: true) } }
    }

    public init(layout: Layout, sink: KeyboardSink, locks: Locks = Locks()) {
        self.layout = layout
        self.sink = sink
        self.locks = locks
        keys = layout.keys
        pressCount = [Int](repeating: 0, count: layout.keys.count)
        isLetter = layout.keys.map { k in
            guard k.label.count == 1, let c = k.label.unicodeScalars.first, ("A"..."Z").contains(c) else { return false }
            return k.codeName == "KEY_\(k.label)"
        }
        lowerLabel = layout.keys.indices.map { [isLetter] i in
            isLetter[i] ? layout.keys[i].label.lowercased() : layout.keys[i].label
        }
    }

    /// Whether labels show what Shift sends: a Shift key is held or latched.
    public var shifted: Bool {
        shiftHeld > 0 || latch[KeyboardModel.keyLeftShift] != 0 || latch[KeyboardModel.keyRightShift] != 0
    }

    public var capsLock: Bool {
        get { locks.capsLock }
        set { locks.capsLock = newValue }
    }

    /// The layer of the most recently pressed, still-held layer key, else a one-shot layer.
    public var activeLayer: String? { layerStack.last ?? oneShotLayer }

    /// Like `hitTest`, for a split layout drawn with its gap widened by
    /// [stretch] units: the right side is moved right and rectangles crossing
    /// the split are stretched (see `KeyRect.stretched`). The rest of the gap
    /// hits nothing.
    public func hitTestStretched(_ ux: Float, _ uy: Float, stretch: Float) -> Int {
        guard let split = layout.splitAt, stretch > 0 else { return hitTest(ux, uy) }
        if stretch != stretchedFor {
            stretchedRects = keys.map { $0.rects.map { $0.stretched(splitAt: split, stretch: stretch) } }
            stretchedFor = stretch
        }
        for i in keys.indices.reversed() where stretchedRects[i].contains(where: { $0.contains(ux, uy) }) {
            return i
        }
        return -1
    }

    /// Index of the key at layout-unit coordinates, or -1. Keys drawn later win.
    public func hitTest(_ ux: Float, _ uy: Float) -> Int {
        for i in keys.indices.reversed() where keys[i].rects.contains(where: { $0.contains(ux, uy) }) {
            return i
        }
        return -1
    }

    /// The code a key sends on the current layer; 0 when it sends nothing.
    public func codeFor(_ index: Int) -> Int {
        let k = keys[index]
        if k.layer != nil { return 0 }
        guard let layer = activeLayer, let o = k.layers[layer] else { return k.code }
        return o.code
    }

    /// The label a key shows: its layer label while a layer is on, otherwise
    /// what it types. Letters are lowercase unless Shift or Caps Lock (but not
    /// both) is on; with Shift on, symbol keys show their shifted character.
    public func labelFor(_ index: Int) -> String {
        let k = keys[index]
        if let layer = activeLayer, let o = k.layers[layer] { return o.label }
        if isLetter[index] { return shifted != capsLock ? k.label : lowerLabel[index] }
        if shifted, let sub = k.sub { return sub }
        return k.label
    }

    /// The small corner legend: the shifted character, or the plain one while Shift shows the shifted.
    public func subFor(_ index: Int) -> String? {
        let k = keys[index]
        guard let sub = k.sub else { return nil }
        return shifted ? k.label : sub
    }

    /// Whether the key is a latched/locked modifier or the one-shot layer key, for the highlight.
    public func isLatched(_ index: Int) -> Bool {
        let k = keys[index]
        if let layer = k.layer { return layer == oneShotLayer }
        return (0..<KeyboardModel.latchCodes).contains(k.code) && latch[k.code] != 0
    }

    public func isLocked(_ index: Int) -> Bool {
        let c = keys[index].code
        return keys[index].layer == nil && (0..<KeyboardModel.latchCodes).contains(c) && latch[c] == KeyboardModel.locked
    }

    /// Whether [pointerId]'s key, on its own, only typed a character: [typing]
    /// says so of its code, no other finger is down, and no modifier is
    /// latched or layer on. Then one Backspace undoes it, and the touch can
    /// turn into a swipe.
    public func typedOnly(_ pointerId: Int, typing: (Int) -> Bool) -> Bool {
        guard (0..<KeyboardModel.maxPointers).contains(pointerId), pointerKey[pointerId] >= 0 else { return false }
        if !layerStack.isEmpty || oneShotLayer != nil || latch.contains(where: { $0 != 0 }) { return false }
        if pointerKey.indices.contains(where: { $0 != pointerId && pointerKey[$0] >= 0 }) { return false }
        return typing(pointerCode[pointerId])
    }

    /// Lift [pointerId]'s key without it counting as a tap: a swipe took the finger.
    @discardableResult
    public func cancel(_ pointerId: Int) -> Bool {
        guard (0..<KeyboardModel.maxPointers).contains(pointerId) else { return false }
        chorded[pointerId] = true
        return up(pointerId)
    }

    /// Returns true when the view should redraw.
    @discardableResult
    public func down(_ pointerId: Int, _ keyIndex: Int) -> Bool {
        guard (0..<KeyboardModel.maxPointers).contains(pointerId), keyIndex >= 0 else { return false }
        if pointerKey[pointerId] >= 0 { up(pointerId) }
        let k = keys[keyIndex]
        pointerKey[pointerId] = keyIndex
        pressCount[keyIndex] += 1
        chorded[pointerId] = false
        wasLatched[pointerId] = false
        if let layer = k.layer {
            layerStack.append(layer)
            pointerCode[pointerId] = 0
            return true
        }
        let code = codeFor(keyIndex)
        pointerCode[pointerId] = code
        if !KeyboardModel.isModifier(code) {
            // A chord: the modifiers and layer keys held now aren't taps.
            for p in 0..<KeyboardModel.maxPointers where p != pointerId && pointerKey[p] >= 0 { chorded[p] = true }
            // A one-shot layer applies to this one key.
            if layerStack.isEmpty { oneShotLayer = nil }
        }
        if code == KeyboardModel.keyLeftShift || code == KeyboardModel.keyRightShift { shiftHeld += 1 }
        if code == KeyboardModel.keyCapsLock { locks.capsLock.toggle() }
        if sticky && KeyboardModel.isModifier(code) && latch[code] != 0 {
            wasLatched[pointerId] = true // already down on the computer
        } else if code != 0 {
            sink.keyDown(code)
        }
        return true
    }

    @discardableResult
    public func up(_ pointerId: Int) -> Bool {
        guard (0..<KeyboardModel.maxPointers).contains(pointerId) else { return false }
        let keyIndex = pointerKey[pointerId]
        if keyIndex < 0 { return false }
        pointerKey[pointerId] = -1
        pressCount[keyIndex] -= 1
        if let layer = keys[keyIndex].layer {
            if let i = layerStack.lastIndex(of: layer) { layerStack.remove(at: i) }
            if sticky && !chorded[pointerId] { oneShotLayer = oneShotLayer == layer ? nil : layer }
            return true
        }
        let code = pointerCode[pointerId]
        pointerCode[pointerId] = 0
        if code == KeyboardModel.keyLeftShift || code == KeyboardModel.keyRightShift { shiftHeld -= 1 }
        let modifier = KeyboardModel.isModifier(code)
        if sticky && modifier && wasLatched[pointerId] {
            if latch[code] == 0 {
                // Already let go by the key it modified.
            } else if latch[code] == KeyboardModel.latched && !chorded[pointerId] {
                // Tapping a latched modifier locks it.
                latch[code] = KeyboardModel.locked
            } else {
                // Tapping a locked one lets go.
                latch[code] = 0
                sink.keyUp(code)
            }
        } else if sticky && modifier && !chorded[pointerId] {
            latch[code] = KeyboardModel.latched // stays down
        } else {
            if code != 0 { sink.keyUp(code) }
            if code != 0 && !modifier { releaseLatched(all: false) }
        }
        return true
    }

    /// Lift every finger and let go of latched keys (a cancelled touch, the app leaving, a layout switch).
    @discardableResult
    public func cancelAll() -> Bool {
        var changed = false
        for p in 0..<KeyboardModel.maxPointers {
            if pointerKey[p] >= 0 { chorded[p] = true } // a cancel is never a tap
            if up(p) { changed = true }
        }
        if releaseLatched(all: true) { changed = true }
        if oneShotLayer != nil {
            oneShotLayer = nil
            changed = true
        }
        return changed
    }

    /// Release latched modifiers; locked ones too when [all].
    @discardableResult
    private func releaseLatched(all: Bool) -> Bool {
        var any = false
        for c in KeyboardModel.modifiers where latch[c] == KeyboardModel.latched || (all && latch[c] == KeyboardModel.locked) {
            latch[c] = 0
            sink.keyUp(c)
            any = true
        }
        return any
    }
}
