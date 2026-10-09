import OmakeyCore
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
    private var unit: CGFloat = 1
    private var originX: CGFloat = 0
    private var originY: CGFloat = 0
    /// Units the right side of a split layout is moved right by.
    private var stretch: Float = 0
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
        let w = bounds.width, h = bounds.height
        unit = min(w / CGFloat(l.width), h / CGFloat(l.height))
        let slack = w - unit * CGFloat(l.width)
        // A split layout keeps each side against its screen edge: the spare
        // width goes into the split instead of the margins.
        stretch = l.splitAt != nil && slack > 0 ? Float(slack / unit) : 0
        originX = stretch > 0 ? 0 : (w - unit * CGFloat(l.width)) / 2
        originY = (h - unit * CGFloat(l.height)) / 2
        _ = m.hitTestStretched(0, 0, stretch: stretch) // prime its rectangles
        let gap = unit * 0.05
        let radius = unit * 0.12
        let scale = traitCollection.displayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, k) in l.keys.enumerated() {
            keyLayers[i].setScale(scale)
            let drawn = k.rects.map { $0.stretched(splitAt: l.splitAt, stretch: stretch) }
            let main = rect(drawn[0]).insetBy(dx: gap, dy: gap)
            let shape: CGPath
            if drawn.count > 1 {
                shape = outline(drawn, gap: gap, radius: radius)
            } else {
                shape = CGPath(roundedRect: main, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            keyLayers[i].place(main: main, shape: shape, unit: unit)
        }
        CATransaction.commit()
        refresh()
        updateAccessibility()
    }

    private func rect(_ r: KeyRect) -> CGRect {
        CGRect(x: originX + CGFloat(r.x) * unit, y: originY + CGFloat(r.y) * unit, width: CGFloat(r.w) * unit, height: CGFloat(r.h) * unit)
    }

    /// One outline for a key made of several rectangles: each is inset by the
    /// key gap except on sides where it meets another part, which it overlaps
    /// instead, so the parts read as a single key.
    private func outline(_ parts: [KeyRect], gap: CGFloat, radius: CGFloat) -> CGPath {
        let e: Float = 1e-4
        var path = CGMutablePath() as CGPath
        for (n, p) in parts.enumerated() {
            func meets(_ test: (KeyRect) -> Bool) -> Bool { parts.enumerated().contains { $0.offset != n && test($0.element) } }
            let overlapY = { (o: KeyRect) in o.y < p.y + p.h - e && p.y < o.y + o.h - e }
            let overlapX = { (o: KeyRect) in o.x < p.x + p.w - e && p.x < o.x + o.w - e }
            let l = meets { overlapY($0) && abs($0.x + $0.w - p.x) < e } ? -gap : gap
            let r = meets { overlapY($0) && abs(p.x + p.w - $0.x) < e } ? -gap : gap
            let t = meets { overlapX($0) && abs($0.y + $0.h - p.y) < e } ? -gap : gap
            let b = meets { overlapX($0) && abs(p.y + p.h - $0.y) < e } ? -gap : gap
            let full = rect(p)
            let one = CGRect(x: full.minX + l, y: full.minY + t, width: full.width - l - r, height: full.height - t - b)
            let piece = CGPath(roundedRect: one, cornerWidth: radius, cornerHeight: radius, transform: nil)
            path = path.isEmpty ? piece : path.union(piece)
        }
        return path
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
        let first = slots.isEmpty
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
            if m.down(slot, key) {
                haptics?.key(down: true)
                changed = true
            }
        }
        if changed { refresh() }
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
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // The system took the touches (Control Center, a call): let go of everything.
        releaseAll()
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
    private var shownLabel: String?
    private var shownSub: String?
    private var shownFn: String?

    override init() {
        super.init()
        for t in [label, sub, fn] {
            t.isWrapped = false
            t.truncationMode = .none
        }
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
        let w = main.width, h = main.height
        lockBar.frame = CGRect(x: w / 2 - unit * 0.15, y: h - unit * 0.12, width: unit * 0.3, height: unit * 0.04)
        let subFont = UIFont.mono(unit * 0.2)
        sub.font = subFont
        sub.fontSize = subFont.pointSize
        sub.frame = CGRect(x: unit * 0.1, y: unit * 0.26 - subFont.ascender, width: max(w - unit * 0.2, 1), height: subFont.lineHeight)
        let fnFont = UIFont.mono(unit * 0.16)
        fn.font = fnFont
        fn.fontSize = fnFont.pointSize
        fn.frame = CGRect(x: unit * 0.08, y: h - unit * 0.1 - fnFont.ascender, width: max(w - unit * 0.16, 1), height: fnFont.lineHeight)
        fn.isHidden = w <= unit * 0.6
    }

    func show(fill: UInt32, label text: String, labelColor: UInt32, sub subText: String?, subColor: UInt32,
              fn fnText: String?, fnColor: UInt32, locked: Bool, lockColor: UInt32) {
        shape.fillColor = UIColor(rgb: fill).cgColor
        if text != shownLabel {
            shownLabel = text
            // Fitted to the key: big for one or two characters, smaller for words.
            let size = unit * (text.count <= 2 ? 0.4 : 0.24)
            var font = UIFont.mono(size, bold: true)
            let maxW = bounds.width - unit * 0.12
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            if width > maxW, width > 0 { font = UIFont.mono(size * maxW / width, bold: true) }
            label.font = font
            label.fontSize = font.pointSize
            label.string = text
            label.frame = CGRect(x: 0, y: (bounds.height - font.lineHeight) / 2, width: bounds.width, height: font.lineHeight)
        }
        label.foregroundColor = UIColor(rgb: labelColor).cgColor
        if subText != shownSub {
            shownSub = subText
            sub.string = subText
        }
        sub.foregroundColor = UIColor(rgb: subColor).cgColor
        if fnText != shownFn {
            shownFn = fnText
            fn.string = fnText
        }
        fn.foregroundColor = UIColor(rgb: fnColor).cgColor
        lockBar.isHidden = !locked
        lockBar.backgroundColor = UIColor(rgb: lockColor).cgColor
    }
}
