import OmakeyCore
import UIKit

/// The keys the phone's own keyboard lacks, above it in portrait mode, in
/// two rows.
///
/// The lower row is pages swiped sideways: digits, F1–F12, navigation, and
/// system keys (Super and Alt, Print Screen, media). The pages follow the
/// finger and settle with an animation drawn every frame.
///
/// The upper row stays put and holds the keys you put there. Its pencil
/// button starts editing, and the keys tremble like icons on the Home
/// Screen: drag a key up from the pages into a slot (or tap it for the first
/// empty one), drag one along the row to move it (a key in the way swaps
/// places with it), and tap one, or drag it down off the row, to clear its
/// slot. Empty slots show as dashed outlines. The tick button is done.
///
/// A key types when lifted, so a swipe that starts on one types nothing;
/// held still, it goes down on the computer and repeats there until lifted.
///
/// Super, Ctrl, Alt and Shift are for shortcuts with the phone's keyboard:
/// hold one and type (on the phone's keyboard, or another key here with a
/// second finger), or tap it to keep it down for the next key or click, and
/// tap again to let go. Several can be down at once: Ctrl + Alt + T.
@MainActor
final class KeyStripView: UIView {
    var haptics: Haptics?
    var theme: Theme {
        didSet {
            backgroundColor = UIColor(rgb: theme.bg)
            setNeedsDisplay()
        }
    }

    /// The page settled on, to come back to it next time.
    var onPageChanged: ((Int) -> Void)?

    /// The upper row was rearranged: its key codes, 0 for an empty slot, to keep.
    var onSlotsChanged: (([Int]) -> Void)?

    private final class Key: Equatable {
        let label: String
        let code: Int
        let sticky: Bool
        /// Kept down after a tap, until the next key or another tap.
        var latched = false
        /// Down on the computer because a finger holds it.
        var down = false
        /// A key or click happened while held: lifting lets go instead of latching.
        var used = false
        var downAt: TimeInterval = 0
        /// Touched while latched: lifting lets go.
        var unlatchOnUp = false

        init(_ label: String, _ code: Int, sticky: Bool = false) {
            self.label = label
            self.code = code
            self.sticky = sticky
        }

        static func == (a: Key, b: Key) -> Bool { a === b }
    }

    private let pages: [[Key]] = [
        Array("1234567890").enumerated().map { Key(String($0.element), 2 + $0.offset) },
        (1...12).map { Key("F\($0)", $0 <= 10 ? 58 + $0 : 76 + $0) },
        [Key("Esc", 1), Key("Tab", 15), Key("Home", 102), Key("End", 107), Key("PgUp", 104), Key("PgDn", 109),
         Key("Del", 111), Key("←", 105), Key("↑", 103), Key("↓", 108), Key("→", 106)],
        [Key("Super", UsKeys.keyLeftMeta, sticky: true), Key("Ctrl", UsKeys.keyLeftCtrl, sticky: true),
         Key("Alt", UsKeys.keyLeftAlt, sticky: true), Key("Shift", UsKeys.keyLeftShift, sticky: true),
         Key("PrtSc", 99), Key("Menu", 127), Key("Mute", 113), Key("Vol−", 114), Key("Vol+", 115), Key("⏯", 164)],
    ]

    /// Every key once. The upper row holds the same keys as the pages, so a latched one shows latched in both.
    private var catalog: [Key] { Array(pages.joined()) }

    /// The upper row; nil is an empty slot.
    private var slots = [Key?](repeating: nil, count: KeyStripView.slotCount)

    /// The upper row as key codes, 0 for an empty slot; setting it fills the row.
    var slotCodes: [Int] {
        get { slots.map { $0?.code ?? 0 } }
        set {
            let all = catalog
            for i in slots.indices {
                let k = i < newValue.count ? all.first { $0.code == newValue[i] } : nil
                // Never the same key twice, whatever was kept.
                slots[i] = k.flatMap { k in slots[..<i].contains(k) ? nil : k }
            }
            setNeedsDisplay()
            updateAccessibility()
        }
    }

    /// Arranging the upper row: keys tremble, move instead of typing.
    private var editing = false

    private let typist: Typist
    private weak var sink: KeyboardSink?

    /// How far the pages are scrolled; page n rests at n × width.
    private var offset: CGFloat = 0
    private var current = 0

    /// The page showing; setting it jumps there.
    var page: Int {
        get { current }
        set {
            current = min(max(newValue, 0), pages.count - 1)
            offset = CGFloat(current) * bounds.width
            setNeedsDisplay()
        }
    }

    // The first finger.
    private var primary: ObjectIdentifier?
    private var downX: CGFloat = 0
    private var downY: CGFloat = 0
    private var startOffset: CGFloat = 0
    private var swiping = false
    private var pressed: Key?
    /// The upper row's slot under the finger, or -1 on the pages.
    private var pressedSlot = -1
    /// The finger went down on the pencil (or tick) button.
    private var pressedEdit = false
    private var holding: Key?
    private var tracker = VelocityTracker()
    private var settle: CurveAnimation?
    private var hold: DispatchWorkItem?
    private var modifierDown: DispatchWorkItem?
    /// While editing, a key on the pages held still is picked up too, not only one dragged upwards.
    private var pickUp: DispatchWorkItem?
    /// Keys under fingers other than the first: tapped when lifted.
    private var others: [ObjectIdentifier: Key] = [:]

    // A key picked up while editing, following the finger.
    private var dragged: Key?
    /// Where it came from: an upper row slot, or -1 for the pages.
    private var dragFrom = -1
    /// The slot it would land in, or -1 for none (off the row).
    private var dragTo = -1
    private var dragAt = CGPoint.zero
    /// Redraws every frame while editing, for the trembling.
    private var frames: CADisplayLink?

    init(theme: Theme, typist: Typist, sink: KeyboardSink) {
        self.theme = theme
        self.typist = typist
        self.sink = sink
        super.init(frame: .zero)
        backgroundColor = UIColor(rgb: theme.bg)
        isMultipleTouchEnabled = true
        contentMode = .redraw
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        offset = CGFloat(current) * bounds.width
        updateAccessibility()
    }

    /// A key went to the computer, or a click: latched modifiers were for it; held ones now let go when lifted.
    func modifiersUsed() {
        for k in catalog {
            if k.latched && !k.unlatchOnUp {
                k.latched = false
                sink?.keyUp(k.code)
                setNeedsDisplay()
            } else if k.down {
                k.used = true
            }
        }
    }

    /// Forget everything held, e.g. when the screen goes away (the computer is told separately).
    func reset() {
        hold?.cancel()
        modifierDown?.cancel()
        pickUp?.cancel()
        for k in catalog {
            k.latched = false
            k.down = false
            k.unlatchOnUp = false
        }
        pressed = nil
        holding = nil
        primary = nil
        pressedEdit = false
        dragged = nil
        others.removeAll()
        if editing {
            editing = false
            tremble(false)
            updateAccessibility()
        }
        setNeedsDisplay()
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if primary == nil {
                settle?.stop()
                primary = ObjectIdentifier(t)
                downX = p.x
                downY = p.y
                startOffset = offset
                swiping = false
                tracker.clear()
                tracker.add(t, event, in: self)
                let top = p.y < topRowBottom
                pressedEdit = top && p.x >= slotsRight
                pressedSlot = top && !pressedEdit ? slotAt(p.x) : -1
                if pressedEdit {
                    haptics?.key(down: true)
                    continue
                }
                let k = key(at: p)
                pressed = k
                if let k {
                    haptics?.key(down: true)
                    if editing {
                        if !top { schedule(&pickUp, KeyStripView.pickUpTime) { [weak self] in self?.pickedUp() } }
                    } else if k.latched {
                        k.unlatchOnUp = true
                    } else if k.sticky {
                        k.downAt = t.timestamp
                        schedule(&modifierDown, KeyStripView.modifierDelay) { [weak self] in self?.modifierHeld() }
                    } else {
                        schedule(&hold, KeyStripView.holdTime) { [weak self] in self?.keyHeld() }
                    }
                }
            } else if !editing, !pressedEdit, let k = key(at: p) {
                // Another finger: a key while the first holds a modifier (Ctrl + →). Not while editing.
                others[ObjectIdentifier(t)] = k
                haptics?.key(down: true)
            }
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first(where: { ObjectIdentifier($0) == primary }) else { return }
        tracker.add(t, event, in: self)
        if pressedEdit { return }
        let p = t.location(in: self)
        if dragged != nil { return moveDrag(to: p) }
        let x = p.x
        let dx = x - downX, dy = p.y - downY
        if pressedSlot >= 0 {
            // The upper row doesn't swipe; while editing, a key slid along it moves.
            if editing, let k = pressed, hypot(dx, dy) > KeyStripView.slop {
                startDrag(k, from: pressedSlot)
                moveDrag(to: p)
            }
            return
        }
        if editing, !swiping, let k = pressed, abs(dy) > KeyStripView.slop, abs(dy) > abs(dx) {
            // Editing: up (or down) picks a key off the page, sideways still swipes.
            startDrag(k, from: -1)
            moveDrag(to: p)
            return
        }
        if !swiping && holding == nil && pressed?.down != true && abs(dx) > KeyStripView.slop {
            swiping = true
            hold?.cancel()
            modifierDown?.cancel()
            pickUp?.cancel()
            pressed?.unlatchOnUp = false
            pressed = nil
            // Pick up from here, so the page doesn't jump by the slop.
            downX = x
            startOffset = offset
        }
        if swiping {
            offset = rubber(startOffset - (x - downX))
            setNeedsDisplay()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            if id == primary {
                tracker.add(t, event, in: self)
                // The first finger lifted: done with it, as if it were the last.
                liftPrimary(at: t.timestamp, t.location(in: self))
                primary = nil
            } else if let k = others.removeValue(forKey: id) {
                tap(k)
            }
        }
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        hold?.cancel()
        modifierDown?.cancel()
        pickUp?.cancel()
        if let h = holding { sink?.keyUp(h.code) }
        if let k = pressed, k.down { letGo(k) }
        holding = nil
        pressed = nil
        primary = nil
        pressedEdit = false
        dragged = nil
        others.removeAll()
        if swiping { snap(0) }
        setNeedsDisplay()
    }

    private func schedule(_ slot: inout DispatchWorkItem?, _ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        slot?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        slot = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Held still: down on the computer, which repeats it until lifted.
    private func keyHeld() {
        guard let k = pressed else { return }
        holding = k
        sink?.keyDown(k.code)
    }

    /// While editing, a key held still on the pages comes off them.
    private func pickedUp() {
        guard let k = pressed, editing, !swiping else { return }
        startDrag(k, from: -1)
    }

    /// A modifier held still goes down on the computer: not at once, so a swipe's start never presses it.
    private func modifierHeld() {
        guard let k = pressed, k.sticky, !k.latched, !swiping else { return }
        k.down = true
        k.used = false
        sink?.keyDown(k.code)
        setNeedsDisplay()
    }

    private func liftPrimary(at time: TimeInterval, _ p: CGPoint) {
        hold?.cancel()
        modifierDown?.cancel()
        pickUp?.cancel()
        if pressedEdit {
            pressedEdit = false
            haptics?.key(down: false)
            // Lifted off the button: changed their mind.
            if p.y < topRowBottom && p.x >= slotsRight - KeyStripView.slop { setEditing(!editing) }
            return
        }
        if dragged != nil { return drop() }
        let held = holding
        let k = pressed
        holding = nil
        pressed = nil
        if swiping {
            snap(tracker.velocity.x)
        } else if let held {
            sink?.keyUp(held.code)
            haptics?.key(down: false)
        } else if let k, editing {
            haptics?.key(down: false)
            // A tap while editing: a key on the row leaves it, one on the pages takes the first empty slot.
            let before = slotCodes
            if pressedSlot >= 0 {
                StripSlots.drop(&slots, k, from: pressedSlot, to: -1)
            } else if !slots.contains(k), let free = slots.firstIndex(where: { $0 == nil }) {
                slots[free] = k
            }
            slotsChanged(since: before)
        } else if let k {
            if k.sticky { liftModifier(k, at: time) } else { tap(k) }
        }
    }

    private func setEditing(_ on: Bool) {
        editing = on
        haptics?.notch()
        tremble(on)
        setNeedsDisplay()
        updateAccessibility()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    private func slotsChanged(since before: [Int]) {
        if slotCodes != before { onSlotsChanged?(slotCodes) }
        setNeedsDisplay()
        updateAccessibility()
    }

    /// A modifier lifted: let go, or stay down for the next key after a quick tap.
    private func liftModifier(_ k: Key, at time: TimeInterval) {
        haptics?.key(down: false)
        if k.unlatchOnUp {
            k.unlatchOnUp = false
            k.latched = false
            sink?.keyUp(k.code)
        } else if k.down && k.used {
            // Held, and something was typed with it: done.
            letGo(k)
        } else if time - k.downAt < KeyStripView.tapTime {
            // A quick tap (or held but nothing typed yet, briefly): keep it down for the next key.
            if !k.down { sink?.keyDown(k.code) }
            k.down = false
            k.latched = true
        } else if k.down {
            letGo(k)
        }
    }

    private func letGo(_ k: Key) {
        k.down = false
        sink?.keyUp(k.code)
    }

    private func tap(_ k: Key) {
        haptics?.key(down: false)
        guard k.sticky else { return typist.key(k.code) }
        // A modifier under a second finger: toggled.
        k.latched.toggle()
        if k.latched { sink?.keyDown(k.code) } else { sink?.keyUp(k.code) }
    }

    private func startDrag(_ k: Key, from: Int) {
        pickUp?.cancel()
        pressed = nil
        dragged = k
        dragFrom = from
        dragTo = from
        dragAt = CGPoint(x: downX, y: downY)
        haptics?.force()
        setNeedsDisplay()
    }

    private func moveDrag(to p: CGPoint) {
        dragAt = p
        let to = dropSlot()
        if to != dragTo {
            dragTo = to
            haptics?.notch()
        }
        setNeedsDisplay()
    }

    private func drop() {
        guard let k = dragged else { return }
        dragged = nil
        let before = slotCodes
        StripSlots.drop(&slots, k, from: dragFrom, to: dropSlot())
        haptics?.key(down: false)
        slotsChanged(since: before)
    }

    /// Where the dragged key would land: a slot while it's over the upper row (or above it), else -1.
    private func dropSlot() -> Int { dragAt.y - KeyStripView.liftBy < topRowBottom ? slotAt(dragAt.x) : -1 }

    /// For VoiceOver: a key on the upper row moved to another slot.
    private func move(from: Int, to: Int) -> Bool {
        guard let k = slots[from], slots.indices.contains(to) else { return false }
        let before = slotCodes
        StripSlots.drop(&slots, k, from: from, to: to)
        slotsChanged(since: before)
        return true
    }

    /// Redraw every frame while editing, for the trembling (not with Reduce Motion, which keeps the keys still).
    private func tremble(_ on: Bool) {
        frames?.invalidate()
        frames = nil
        guard on, !UIAccessibility.isReduceMotionEnabled else { return }
        let l = CADisplayLink(target: Redraw(self), selector: #selector(Redraw.tick(_:)))
        l.add(to: .main, forMode: .common)
        frames = l
    }

    private final class Redraw: NSObject {
        weak var view: UIView?

        init(_ view: UIView) {
            self.view = view
        }

        @MainActor @objc func tick(_ l: CADisplayLink) {
            guard let view else { return l.invalidate() }
            view.setNeedsDisplay()
        }
    }

    /// Past the first or last page the pages move a third as far: they resist.
    private func rubber(_ o: CGFloat) -> CGFloat {
        let maxOffset = CGFloat(pages.count - 1) * bounds.width
        if o < 0 { return o / 3 }
        if o > maxOffset { return maxOffset + (o - maxOffset) / 3 }
        return o
    }

    /// Settle on a page: the next one after a flick, else the nearest.
    private func snap(_ vx: CGFloat) {
        let w = bounds.width
        guard w > 0 else { return }
        let nearest = Int((offset / w).rounded())
        let start = Int((startOffset / w).rounded())
        let target = min(max(vx < -KeyStripView.flick ? start + 1 : vx > KeyStripView.flick ? start - 1 : nearest, 0), pages.count - 1)
        let from = offset, to = CGFloat(target) * w
        let distance = abs(to - from) / w
        settle?.stop()
        settle = CurveAnimation(duration: min(180 + 160 * Double(distance), 340) / 1000, curve: CurveAnimation.settle) { [weak self] t in
            self?.offset = from + (to - from) * t
            self?.setNeedsDisplay()
        }
        if target != current {
            current = target
            onPageChanged?(target)
            haptics?.notch()
            updateAccessibility()
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    // MARK: - Drawing

    private static let dotsHeight: CGFloat = 10
    private static let pad: CGFloat = 6
    private static let gap: CGFloat = 4
    private static let radius: CGFloat = 7
    /// The pencil button's width, right of the slots.
    private static let editWidth: CGFloat = 34
    /// The upper row's share of the height; the pages' row also holds the dots.
    private static let topShare: CGFloat = 0.46
    /// A dragged key is drawn this far above the finger, so the finger doesn't hide it.
    private static let liftBy: CGFloat = 18

    /// The upper row is the view's top [topRowBottom] points; the pages and their dots fill the rest.
    private var topRowBottom: CGFloat { bounds.height * KeyStripView.topShare }
    /// The upper row's slots end here; the pencil (or tick) button is to the right.
    private var slotsRight: CGFloat { bounds.width - KeyStripView.pad - KeyStripView.editWidth }
    private var slotWidth: CGFloat { (slotsRight - KeyStripView.pad) / CGFloat(KeyStripView.slotCount) }

    /// The upper row's slot at x, the nearest one past either end.
    private func slotAt(_ x: CGFloat) -> Int {
        min(max(Int(floor((x - KeyStripView.pad) / slotWidth)), 0), KeyStripView.slotCount - 1)
    }

    private func slotRect(_ i: Int) -> CGRect {
        let left = KeyStripView.pad + CGFloat(i) * slotWidth
        let top = KeyStripView.pad * 0.5
        return CGRect(x: left + KeyStripView.gap / 2, y: top, width: slotWidth - KeyStripView.gap,
                      height: topRowBottom - KeyStripView.pad * 0.5 - top)
    }

    /// The key at a point: in the upper row's slot, or on the page under it.
    private func key(at p: CGPoint) -> Key? {
        guard bounds.width > 0 else { return nil }
        if p.y < topRowBottom { return p.x < slotsRight ? slots[slotAt(p.x)] : nil }
        guard p.y <= bounds.height - KeyStripView.dotsHeight else { return nil }
        let w = bounds.width
        let contentX = p.x + offset
        let pi = Int(floor(contentX / w))
        guard pages.indices.contains(pi) else { return nil }
        let keys = pages[pi]
        let local = contentX - CGFloat(pi) * w - KeyStripView.pad
        let i = Int(floor(local / ((w - KeyStripView.pad * 2) / CGFloat(keys.count))))
        return keys.indices.contains(i) ? keys[i] : nil
    }

    override func draw(_ rect: CGRect) {
        let w = bounds.width
        guard w > 0, let ctx = UIGraphicsGetCurrentContext() else { return }
        let now = CACurrentMediaTime()
        var n = 0

        // The upper row: while a key is dragged, as it would be if dropped here.
        var shown = slots
        if let k0 = dragged { StripSlots.drop(&shown, k0, from: dragFrom, to: dragTo) }
        for (i, k) in shown.enumerated() {
            let r = slotRect(i)
            if let k, k !== dragged {
                trembling(ctx, r, n, now) {
                    drawKey(k, in: r)
                    if editing { removeBadge(r) }
                }
                n += 1
            } else {
                // Empty, or where the dragged key would land: a dashed outline.
                let landing = k != nil
                let outline = UIBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: KeyStripView.radius)
                outline.lineWidth = 1.5
                outline.setLineDash([4, 3], count: 2, phase: 0)
                UIColor(rgb: landing ? theme.accent : theme.fgDim, alpha: landing ? 1 : 0.45).setStroke()
                outline.stroke()
            }
        }
        if dragged == nil && shown.allSatisfy({ $0 == nil }) {
            // A first look: say how to fill it.
            hint(editing ? KeyStripView.dragHint : KeyStripView.pencilHint, cy: topRowBottom / 2)
        }
        drawEditButton()

        // The pages.
        let keyTop = topRowBottom + KeyStripView.pad * 0.5
        let keyBottom = bounds.height - KeyStripView.dotsHeight
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: topRowBottom, width: w, height: bounds.height - topRowBottom))
        for (pi, keys) in pages.enumerated() {
            let pageLeft = CGFloat(pi) * w - offset
            if pageLeft > w || pageLeft + w < 0 {
                n += keys.count
                continue
            }
            let keyW = (w - KeyStripView.pad * 2) / CGFloat(keys.count)
            for (i, k) in keys.enumerated() {
                let left = pageLeft + KeyStripView.pad + CGFloat(i) * keyW
                let r = CGRect(x: left + KeyStripView.gap / 2, y: keyTop, width: keyW - KeyStripView.gap, height: keyBottom - keyTop)
                trembling(ctx, r, n, now) { drawKey(k, in: r) }
                n += 1
            }
        }
        ctx.restoreGState()
        // Page dots; the current one a pill that slides with the pages.
        let count = pages.count
        let step: CGFloat = 12
        let cy = bounds.height - KeyStripView.dotsHeight / 2
        let startX = w / 2 - step * CGFloat(count - 1) / 2
        UIColor(rgb: theme.fgDim).setFill()
        for i in 0..<count {
            UIBezierPath(ovalIn: CGRect(x: startX + CGFloat(i) * step - 2, y: cy - 2, width: 4, height: 4)).fill()
        }
        let at = min(max(offset / w, 0), CGFloat(count - 1))
        let x = startX + at * step
        UIColor(rgb: theme.accent).setFill()
        UIBezierPath(roundedRect: CGRect(x: x - 5, y: cy - 2, width: 10, height: 4), cornerRadius: 2).fill()

        // The dragged key, raised above the finger and a little larger; faded where dropping clears it.
        if let k0 = dragged {
            let slot = slotRect(0)
            let kw = slot.width * 1.15, kh = slot.height * 1.15
            let cx = min(max(dragAt.x, kw / 2), w - kw / 2)
            let cy = min(max(dragAt.y - KeyStripView.liftBy, kh / 2), bounds.height - kh / 2)
            let r = CGRect(x: cx - kw / 2, y: cy - kh / 2, width: kw, height: kh)
            UIColor(rgb: theme.accent, alpha: dragTo < 0 ? 0.55 : 1).setFill()
            UIBezierPath(roundedRect: r, cornerRadius: KeyStripView.radius).fill()
            drawLabel(k0.label, in: r, color: theme.bg)
        }
    }

    /// Draw with the key in [r] rocking while editing, each a little out of step with its neighbours.
    private func trembling(_ ctx: CGContext, _ r: CGRect, _ i: Int, _ now: CFTimeInterval, _ draw: () -> Void) {
        guard editing, frames != nil else { return draw() }
        let phase = now.truncatingRemainder(dividingBy: KeyStripView.trembleTime) / KeyStripView.trembleTime * 2 * .pi + Double(i) * 1.7
        ctx.saveGState()
        ctx.translateBy(x: r.midX, y: r.midY)
        ctx.rotate(by: CGFloat(sin(phase) * KeyStripView.trembleDegrees * .pi / 180))
        ctx.translateBy(x: -r.midX, y: -r.midY)
        draw()
        ctx.restoreGState()
    }

    private func drawKey(_ k: Key, in r: CGRect) {
        let down = k === pressed || k === holding || k.down || others.values.contains { $0 === k }
        UIColor(rgb: down ? theme.accent : k.latched ? theme.keyAccent : k.sticky ? theme.keyMod : theme.key).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: KeyStripView.radius).fill()
        drawLabel(k.label, in: r, color: down ? theme.bg : k.latched ? theme.fgOnAccent : theme.fg)
    }

    /// A key's label, centred in [r] and as large as fits: "PgDn" on a narrow key, "5" big.
    private func drawLabel(_ label: String, in r: CGRect, color: UInt32) {
        var font = UIFont.mono(14, bold: true)
        let tw = (label as NSString).size(withAttributes: [.font: font]).width
        if tw > r.width - 6 { font = UIFont.mono(14 * (r.width - 6) / tw, bold: true) }
        let size = (label as NSString).size(withAttributes: [.font: font])
        (label as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2),
                                 withAttributes: [.font: font, .foregroundColor: UIColor(rgb: color)])
    }

    /// The small × in the corner of a key in [r] while editing: tapping takes it off the row.
    private func removeBadge(_ r: CGRect) {
        let c = CGPoint(x: r.minX + 3, y: r.minY + 3)
        UIColor(rgb: theme.fgDim).setFill()
        UIBezierPath(arcCenter: c, radius: 6, startAngle: 0, endAngle: 2 * .pi, clockwise: true).fill()
        let x = UIBezierPath()
        x.move(to: CGPoint(x: c.x - 2.2, y: c.y - 2.2))
        x.addLine(to: CGPoint(x: c.x + 2.2, y: c.y + 2.2))
        x.move(to: CGPoint(x: c.x - 2.2, y: c.y + 2.2))
        x.addLine(to: CGPoint(x: c.x + 2.2, y: c.y - 2.2))
        x.lineWidth = 1.5
        x.lineCapStyle = .round
        UIColor(rgb: theme.bg).setStroke()
        x.stroke()
    }

    /// Right of the slots: a pencil to start arranging, a tick on an accent circle to finish.
    private func drawEditButton() {
        let c = CGPoint(x: (slotsRight + bounds.width - KeyStripView.pad) / 2, y: topRowBottom / 2)
        let circle = UIBezierPath(arcCenter: c, radius: 13, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        if editing {
            UIColor(rgb: pressedEdit ? theme.keyAccent : theme.accent).setFill()
            circle.fill()
        } else if pressedEdit {
            UIColor(rgb: theme.key).setFill()
            circle.fill()
        }
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: editing ? .bold : .semibold)
        guard let icon = UIImage(systemName: editing ? "checkmark" : "pencil", withConfiguration: config)?
            .withTintColor(UIColor(rgb: editing ? theme.bg : theme.fgDim), renderingMode: .alwaysOriginal) else { return }
        icon.draw(at: CGPoint(x: c.x - icon.size.width / 2, y: c.y - icon.size.height / 2))
    }

    /// A line of help over the upper row's slots, on the background so the outlines don't cross it.
    private func hint(_ text: String, cy: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.mono(11), .foregroundColor: UIColor(rgb: theme.fgDim)]
        let size = (text as NSString).size(withAttributes: attrs)
        let cx = (KeyStripView.pad + slotsRight) / 2
        let pill = CGRect(x: cx - size.width / 2 - 8, y: cy - 9, width: size.width + 16, height: 18)
        UIColor(rgb: theme.bg).setFill()
        UIBezierPath(roundedRect: pill, cornerRadius: 9).fill()
        (text as NSString).draw(at: CGPoint(x: cx - size.width / 2, y: cy - size.height / 2), withAttributes: attrs)
    }

    // MARK: - Accessibility

    /// The upper row, its pencil and the showing page's keys, so VoiceOver can
    /// type and arrange them and UI tests can find them.
    private func updateAccessibility() {
        guard bounds.width > 0 else { return }
        var elements: [Any] = []
        for (i, k) in slots.enumerated() where k != nil || editing {
            let e = UIAccessibilityElement(accessibilityContainer: self)
            e.accessibilityIdentifier = "slot.\(i)"
            e.accessibilityFrameInContainerSpace = CGRect(x: KeyStripView.pad + CGFloat(i) * slotWidth, y: 0, width: slotWidth, height: topRowBottom)
            if let k {
                e.accessibilityLabel = k.label
                e.accessibilityTraits = editing ? .button : .keyboardKey
                if editing {
                    e.accessibilityHint = "Takes it off the row."
                    e.accessibilityCustomActions = [("Move left", i - 1), ("Move right", i + 1)]
                        .filter { slots.indices.contains($0.1) }
                        .map { name, to in UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.move(from: i, to: to) ?? false } }
                }
            } else {
                e.accessibilityLabel = "Empty slot"
            }
            elements.append(e)
        }
        if !editing && slots.allSatisfy({ $0 == nil }) {
            let e = UIAccessibilityElement(accessibilityContainer: self)
            e.accessibilityLabel = KeyStripView.pencilHint
            e.accessibilityTraits = .staticText
            e.accessibilityFrameInContainerSpace = CGRect(x: 0, y: 0, width: slotsRight, height: topRowBottom)
            elements.append(e)
        }
        let edit = UIAccessibilityElement(accessibilityContainer: self)
        edit.accessibilityIdentifier = "strip.edit"
        edit.accessibilityLabel = editing ? "Done arranging" : "Choose keys for the upper row"
        edit.accessibilityTraits = .button
        edit.accessibilityFrameInContainerSpace = CGRect(x: slotsRight, y: 0, width: bounds.width - slotsRight, height: topRowBottom)
        elements.append(edit)

        let keys = pages[current]
        let keyW = (bounds.width - KeyStripView.pad * 2) / CGFloat(keys.count)
        elements += keys.enumerated().map { i, k in
            let e = UIAccessibilityElement(accessibilityContainer: self)
            e.accessibilityLabel = k.label
            e.accessibilityIdentifier = "strip.\(k.label)"
            e.accessibilityTraits = editing ? .button : .keyboardKey
            if editing { e.accessibilityHint = "Adds it to the upper row." }
            e.accessibilityFrameInContainerSpace = CGRect(x: KeyStripView.pad + CGFloat(i) * keyW, y: topRowBottom, width: keyW,
                                                          height: bounds.height - KeyStripView.dotsHeight - topRowBottom)
            return e
        }
        accessibilityElements = elements + [pageElement]
    }

    /// Swipe up or down with VoiceOver to change page.
    private lazy var pageElement: UIAccessibilityElement = {
        let e = PageElement(accessibilityContainer: self)
        e.strip = self
        e.accessibilityTraits = .adjustable
        e.accessibilityLabel = "Key strip page"
        return e
    }()

    fileprivate func adjustPage(by delta: Int) {
        let target = min(max(current + delta, 0), pages.count - 1)
        guard target != current else { return }
        page = target
        onPageChanged?(target)
        updateAccessibility()
    }

    private final class PageElement: UIAccessibilityElement {
        weak var strip: KeyStripView?
        override func accessibilityIncrement() { strip?.adjustPage(by: 1) }
        override func accessibilityDecrement() { strip?.adjustPage(by: -1) }
        override var accessibilityValue: String? {
            get { strip.map { "\($0.current + 1) of \($0.pages.count)" } }
            set {}
        }
        override var accessibilityFrameInContainerSpace: CGRect {
            get { strip.map { CGRect(x: 0, y: $0.bounds.height - KeyStripView.dotsHeight, width: $0.bounds.width, height: KeyStripView.dotsHeight) } ?? .zero }
            set {}
        }
    }

    private static let pencilHint = "Tap the pencil to choose keys for this row"
    private static let dragHint = "Drag keys up here"
    private static let slotCount = 10
    private static let slop: CGFloat = 8
    private static let holdTime: TimeInterval = 0.35
    private static let pickUpTime: TimeInterval = 0.3
    private static let trembleTime: CFTimeInterval = 0.26
    private static let trembleDegrees = 2.2
    private static let modifierDelay: TimeInterval = 0.1
    private static let tapTime: TimeInterval = 0.3
    private static let flick: CGFloat = 350
}
