import OmakeyCore
import os
import UIKit

/// Draws a layout and turns raw multi-touch into key presses. Keys fire on
/// touch-down (`touchesBegan`), not on lift, and every finger is its own
/// key, so chords like SUPER + SHIFT + 4 work. Each key is a layer, so a
/// press redraws only what changed.
@MainActor
final class KeyboardView: UIView {
    var theme: Theme {
        didSet {
            backgroundColor = UIColor(rgb: theme.bg)
            refresh()
        }
    }

    /// Felt on every key press and release; nil for none.
    var haptics: Haptics?

    /// False for a preview: touches do nothing.
    var interactive = true {
        didSet { isUserInteractionEnabled = interactive }
    }

    /// Tap modifiers and Fn instead of holding them (see `KeyboardModel.sticky`).
    var sticky = false {
        didSet {
            model?.sticky = sticky
            refresh()
        }
    }

    /// Pulling the touchpad down over the keyboard, from a quick swipe down that started on a key.
    var pull: KeyboardPull?

    private(set) var model: KeyboardModel?
    /// Caps Lock as sent from here or reported by the computer; kept when the layout changes.
    private let locks = KeyboardModel.Locks()
    private var keyLayers: [KeyLayer] = []
    private var geometry: KeyGeometry?
    private var unit: CGFloat { geometry?.unit ?? 1 }
    private var originX: CGFloat { geometry?.originX ?? 0 }
    private var originY: CGFloat { geometry?.originY ?? 0 }
    /// Units the right side of a split layout is moved right by.
    private var stretch: Float { geometry?.stretch ?? 0 }
    private var laidOut = CGSize.zero

    /// Each finger's pointer slot in the model.
    private var slots: [ObjectIdentifier: Int] = [:]
    private var freeSlots = Array((0..<KeyboardModel.maxPointers).reversed())
    /// Where keys go; kept for the Backspace that takes back a swipe's first key.
    private var sink: KeyboardSink?

    // The first finger, while it may still turn into a swipe down.
    private var swipeTouch: ObjectIdentifier?
    private var swipeStart = CGPoint.zero
    private var swipeAt: TimeInterval = 0
    private var pulling = false
    private var tracker = VelocityTracker()

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = UIColor(rgb: theme.bg)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        // VoiceOver users type by touch, as everyone else.
        accessibilityTraits = .allowsDirectInteraction
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: KeyboardView, _) in
            view.laidOut = .zero
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setLayout(_ layout: Layout, sink: KeyboardSink) {
        self.sink = sink
        releaseAll()
        let m = KeyboardModel(layout: layout, sink: sink, locks: locks)
        m.sticky = sticky
        model = m
        keyLayers.forEach { $0.removeFromSuperlayer() }
        keyLayers = layout.keys.map { _ in
            let l = KeyLayer()
            layer.addSublayer(l)
            return l
        }
        laidOut = .zero
        setNeedsLayout()
    }

    /// The computer's Caps Lock light, when it reports it.
    func setCapsLock(_ on: Bool) {
        guard locks.capsLock != on else { return }
        locks.capsLock = on
        refresh()
    }

    var capsLock: Bool { locks.capsLock }

    /// Lift every finger, e.g. when the app leaves the screen.
    func releaseAll() {
        if model?.cancelAll() == true { refresh() }
        slots.removeAll()
        freeSlots = Array((0..<KeyboardModel.maxPointers).reversed())
        if pulling {
            pulling = false
            pull?.end(velocityY: 0)
        }
        swipeTouch = nil
    }

    // MARK: - Geometry

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOut { computeGeometry() }
    }

    private func computeGeometry() {
        guard let m = model, bounds.width > 0, bounds.height > 0 else { return }
        laidOut = bounds.size
        let l = m.layout
        let g = KeyGeometry(layout: l, size: bounds.size)
        geometry = g
        _ = m.hitTestStretched(0, 0, stretch: g.stretch) // prime its rectangles
        let scale = traitCollection.displayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, k) in l.keys.enumerated() {
            keyLayers[i].setScale(scale)
            let placed = g.place(k)
            keyLayers[i].place(main: placed.main, shape: placed.shape, unit: g.unit)
        }
        CATransaction.commit()
        refresh()
        updateAccessibility()
    }

    // MARK: - Drawing

    /// Colors and labels for the model's state: Shift, Caps Lock, the active layer, pressed keys.
    private func refresh() {
        guard let m = model, laidOut != .zero else { return }
        let keys = m.layout.keys
        let layer = m.activeLayer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in keys.indices {
            let k = keys[i]
            let pressed = m.pressCount[i] > 0 || m.isLatched(i)
            let fill: UInt32 =
                if pressed { theme.accent }
                else if k.layer != nil && k.layer == layer { theme.accent }
                else if k.code == 58 && m.capsLock { theme.keyAccent }
                else {
                    switch k.style {
                    case .accent: theme.keyAccent
                    case .mod: theme.keyMod
                    case .fkey: theme.keyFkey
                    default: theme.key
                    }
                }
            let override = layer.flatMap { k.layers[$0] }
            let labelColor: UInt32 =
                if pressed { theme.bg }
                else if override != nil { theme.layer }
                else if layer != nil && k.layer == nil { theme.fgDim }
                else if k.style == .accent { theme.fgOnAccent }
                else { theme.fg }
            let label = m.labelFor(i)
            let sub = layer == nil ? m.subFor(i) : nil
            let fn = layer == nil ? k.layers["fn"]?.ownLabel : nil
            keyLayers[i].show(fill: fill, label: label, labelColor: labelColor, sub: sub,
                              subColor: pressed ? theme.bg : theme.fgDim, fn: fn, fnColor: pressed ? theme.bg : theme.layer,
                              locked: m.isLocked(i), lockColor: theme.bg)
        }
        CATransaction.commit()
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard interactive, let m = model else { return }
        let span = Perf.signposter.beginInterval("Key")
        defer { Perf.signposter.endInterval("Key", span) }
        let first = slots.isEmpty
        if first { Perf.begin(.typing) }
        var changed = false
        for t in touches {
            guard let slot = freeSlots.popLast() else { continue }
            let id = ObjectIdentifier(t)
            slots[id] = slot
            let p = t.location(in: self)
            if pull != nil && first && touches.count == 1 {
                swipeTouch = id
                swipeStart = t.location(in: window)
                swipeAt = t.timestamp
                tracker.clear()
                tracker.add(swipeStart, at: t.timestamp)
            } else {
                swipeTouch = nil // a second finger: typing, not a swipe
            }
            if pulling { continue }
            let key = m.hitTestStretched(Float((p.x - originX) / unit), Float((p.y - originY) / unit), stretch: stretch)
            let model = Perf.signposter.beginInterval("Key model")
            let down = m.down(slot, key)
            Perf.signposter.endInterval("Key model", model)
            if down {
                let feel = Perf.signposter.beginInterval("Key haptic")
                haptics?.key(down: true)
                Perf.signposter.endInterval("Key haptic", feel)
                changed = true
            }
        }
        let draw = Perf.signposter.beginInterval("Key draw")
        if changed { refresh() }
        Perf.signposter.endInterval("Key draw", draw)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let m = model else { return }
        if pulling {
            if let t = touches.first(where: { ObjectIdentifier($0) == swipeTouch }) {
                tracker.add(t, event, in: self)
                pull?.move(y: t.location(in: window).y)
            }
            return
        }
        guard let id = swipeTouch, let t = touches.first(where: { ObjectIdentifier($0) == id }), let slot = slots[id] else { return }
        tracker.add(t, event, in: self)
        let p = t.location(in: window)
        let dy = p.y - swipeStart.y
        if t.timestamp - swipeAt >= KeyboardView.swipeSeconds {
            swipeTouch = nil
        } else if dy > unit * KeyboardView.swipeUnits && dy > 2 * abs(p.x - swipeStart.x)
                    && m.typedOnly(slot, typing: { UsKeys.printable[$0] != nil }) {
            // A swipe down, not a key: take the character back and pull the touchpad.
            m.cancel(slot)
            sink?.keyDown(UsKeys.keyBackspace)
            sink?.keyUp(UsKeys.keyBackspace)
            pulling = true
            refresh()
            pull?.begin(y: swipeStart.y)
            pull?.move(y: p.y)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let m = model else { return }
        var changed = false
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let slot = slots.removeValue(forKey: id) else { continue }
            freeSlots.append(slot)
            if pulling {
                if id == swipeTouch {
                    pulling = false
                    swipeTouch = nil
                    tracker.add(t, event, in: self)
                    pull?.end(velocityY: tracker.velocity.y)
                }
                continue
            }
            if id == swipeTouch { swipeTouch = nil }
            if m.up(slot) {
                haptics?.key(down: false)
                changed = true
            }
        }
        if changed { refresh() }
        if slots.isEmpty { Perf.end(.typing) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // The system took the touches (Control Center, a call): let go of everything.
        releaseAll()
        Perf.end(.typing)
    }

    /// A swipe down must cover this many key units within `swipeSeconds`: quicker than a key repeats.
    static let swipeUnits: CGFloat = 0.55
    static let swipeSeconds: TimeInterval = 0.25

    // MARK: - Accessibility

    private func updateAccessibility() {
        guard let m = model else { return }
        accessibilityElements = m.layout.keys.indices.map { i in
            let e = UIAccessibilityElement(accessibilityContainer: self)
            e.accessibilityLabel = m.layout.keys[i].label
            e.accessibilityIdentifier = "key.\(m.layout.keys[i].id)"
            e.accessibilityTraits = .keyboardKey
            e.accessibilityFrameInContainerSpace = keyLayers[i].frame
            return e
        }
    }
}

/// Pulling the touchpad down over the keyboard; y in window coordinates.
@MainActor
protocol KeyboardPull: AnyObject {
    func begin(y: CGFloat)
    func move(y: CGFloat)
    func end(velocityY: CGFloat)
}

/// One key: its shape, its label, the shifted legend in the corner, the
/// printed Fn legend, and the bar under a locked modifier.
private final class KeyLayer: CALayer {
    private let shape = CAShapeLayer()
    private let label = CATextLayer()
    private let sub = CATextLayer()
    private let fn = CATextLayer()
    private let lockBar = CALayer()
    private var unit: CGFloat = 1
    /// The key is wide enough for an Fn legend.
    private var fnFits = false
    private var shownLabel: String?
    private var shownSub: String?
    private var shownFn: String?
    /// The colors as last set: a layer property set again, even to the same
    /// value, makes Core Animation draw its text or shape again.
    private var shownFill: UInt32?
    private var shownLabelColor: UInt32?
    private var shownSubColor: UInt32?
    private var shownFnColor: UInt32?
    private var shownLocked: Bool?
    private var shownLockColor: UInt32?

    override init() {
        super.init()
        for t in [label, sub, fn] {
            t.isWrapped = false
            t.truncationMode = .none
            // Text is drawn off the main thread, so a keyboard coming up (hundreds of legends) doesn't hold up its frame.
            t.drawsAsynchronously = true
        }
        // Most keys have no corner or Fn legend: those layers stay hidden, nothing to draw or keep.
        sub.isHidden = true
        fn.isHidden = true
        label.alignmentMode = .center
        sub.alignmentMode = .left
        fn.alignmentMode = .right
        addSublayer(shape)
        addSublayer(label)
        addSublayer(sub)
        addSublayer(fn)
        addSublayer(lockBar)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setScale(_ s: CGFloat) {
        for l in [self, shape, label, sub, fn, lockBar] as [CALayer] { l.contentsScale = s }
    }

    /// [main]: the label's rectangle; [shape]: the whole key, in the same (view) coordinates.
    func place(main: CGRect, shape path: CGPath, unit: CGFloat) {
        self.unit = unit
        frame = main
        var t = CGAffineTransform(translationX: -main.minX, y: -main.minY)
        shape.path = path.copy(using: &t)
        setScale(contentsScale)
        shownLabel = nil
        shownSub = nil
        shownFn = nil
        shownFill = nil
        shownLabelColor = nil
        shownSubColor = nil
        shownFnColor = nil
        shownLocked = nil
        shownLockColor = nil
        let w = main.width, h = main.height
        lockBar.frame = CGRect(x: w / 2 - unit * 0.15, y: h - unit * 0.12, width: unit * 0.3, height: unit * 0.04)
        let subFont = KeyGeometry.subFont(unit: unit)
        sub.font = subFont
        sub.fontSize = subFont.pointSize
        sub.frame = KeyGeometry.subFrame(subFont, unit: unit, width: w)
        let fnFont = KeyGeometry.fnFont(unit: unit)
        fn.font = fnFont
        fn.fontSize = fnFont.pointSize
        fn.frame = KeyGeometry.fnFrame(fnFont, unit: unit, width: w, height: h)
        fnFits = KeyGeometry.showsFn(unit: unit, width: w)
    }

    func show(fill: UInt32, label text: String, labelColor: UInt32, sub subText: String?, subColor: UInt32,
              fn fnText: String?, fnColor: UInt32, locked: Bool, lockColor: UInt32) {
        if fill != shownFill {
            shownFill = fill
            shape.fillColor = KeyLayer.color(fill)
        }
        if text != shownLabel {
            shownLabel = text
            let font = KeyGeometry.labelFont(text, unit: unit, width: bounds.width)
            label.font = font
            label.fontSize = font.pointSize
            label.string = text
            label.frame = KeyGeometry.labelFrame(font, width: bounds.width, height: bounds.height)
        }
        if labelColor != shownLabelColor {
            shownLabelColor = labelColor
            label.foregroundColor = KeyLayer.color(labelColor)
        }
        if subText != shownSub {
            shownSub = subText
            sub.string = subText
            sub.isHidden = subText == nil
        }
        if subColor != shownSubColor {
            shownSubColor = subColor
            sub.foregroundColor = KeyLayer.color(subColor)
        }
        if fnText != shownFn {
            shownFn = fnText
            fn.string = fnText
            fn.isHidden = fnText == nil || !fnFits
        }
        if fnColor != shownFnColor {
            shownFnColor = fnColor
            fn.foregroundColor = KeyLayer.color(fnColor)
        }
        if locked != shownLocked {
            shownLocked = locked
            lockBar.isHidden = !locked
        }
        if lockColor != shownLockColor {
            shownLockColor = lockColor
            lockBar.backgroundColor = KeyLayer.color(lockColor)
        }
    }

    /// The theme's few colors, made once (under a lock: layers aren't the main actor's).
    private static let colors = OSAllocatedUnfairLock(initialState: [UInt32: CGColor]())

    private static func color(_ rgb: UInt32) -> CGColor {
        colors.withLock { cache in
            if let c = cache[rgb] { return c }
            let c = UIColor(rgb: rgb).cgColor
            cache[rgb] = c
            return c
        }
    }
}
