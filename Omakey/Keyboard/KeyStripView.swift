import OmakeyCore
import UIKit

/// The keys the phone's own keyboard lacks, above it in portrait mode, as
/// pages swiped sideways: digits, F1–F12, navigation, and system keys
/// (Super and Alt, Print Screen, media). The pages follow the finger and
/// settle with an animation drawn every frame.
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

    private final class Key {
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
    private var startOffset: CGFloat = 0
    private var swiping = false
    private var pressed: Key?
    private var holding: Key?
    private var tracker = VelocityTracker()
    private var settle: CurveAnimation?
    private var hold: DispatchWorkItem?
    private var modifierDown: DispatchWorkItem?
    /// Keys under fingers other than the first: tapped when lifted.
    private var others: [ObjectIdentifier: Key] = [:]

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
        for k in pages.joined() {
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
        for k in pages.joined() {
            k.latched = false
            k.down = false
            k.unlatchOnUp = false
        }
        pressed = nil
        holding = nil
        primary = nil
        others.removeAll()
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
                startOffset = offset
                swiping = false
                tracker.clear()
                tracker.add(t, event, in: self)
                let k = key(at: p)
                pressed = k
                if let k {
                    haptics?.key(down: true)
                    if k.latched {
                        k.unlatchOnUp = true
                    } else if k.sticky {
                        k.downAt = t.timestamp
                        schedule(&modifierDown, KeyStripView.modifierDelay) { [weak self] in self?.modifierHeld() }
                    } else {
                        schedule(&hold, KeyStripView.holdTime) { [weak self] in self?.keyHeld() }
                    }
                }
            } else if let k = key(at: p) {
                // Another finger: a key while the first holds a modifier (Ctrl + →).
                others[ObjectIdentifier(t)] = k
                haptics?.key(down: true)
            }
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first(where: { ObjectIdentifier($0) == primary }) else { return }
        tracker.add(t, event, in: self)
        let x = t.location(in: self).x
        let dx = x - downX
        if !swiping && holding == nil && pressed?.down != true && abs(dx) > KeyStripView.slop {
            swiping = true
            hold?.cancel()
            modifierDown?.cancel()
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
                liftPrimary(at: t.timestamp)
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
        if let h = holding { sink?.keyUp(h.code) }
        if let k = pressed, k.down { letGo(k) }
        holding = nil
        pressed = nil
        primary = nil
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

    /// A modifier held still goes down on the computer: not at once, so a swipe's start never presses it.
    private func modifierHeld() {
        guard let k = pressed, k.sticky, !k.latched, !swiping else { return }
        k.down = true
        k.used = false
        sink?.keyDown(k.code)
        setNeedsDisplay()
    }

    private func liftPrimary(at time: TimeInterval) {
        hold?.cancel()
        modifierDown?.cancel()
        let held = holding
        let k = pressed
        holding = nil
        pressed = nil
        if swiping {
            snap(tracker.velocity.x)
        } else if let held {
            sink?.keyUp(held.code)
            haptics?.key(down: false)
        } else if let k {
            if k.sticky { liftModifier(k, at: time) } else { tap(k) }
        }
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

    /// The key at a point, on the page under it.
    private func key(at p: CGPoint) -> Key? {
        guard p.y <= bounds.height - KeyStripView.dotsHeight, bounds.width > 0 else { return nil }
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
        guard w > 0 else { return }
        let keyTop = KeyStripView.pad * 0.5
        let keyBottom = bounds.height - KeyStripView.dotsHeight
        for (pi, keys) in pages.enumerated() {
            let pageLeft = CGFloat(pi) * w - offset
            if pageLeft > w || pageLeft + w < 0 { continue }
            let keyW = (w - KeyStripView.pad * 2) / CGFloat(keys.count)
            for (i, k) in keys.enumerated() {
                let left = pageLeft + KeyStripView.pad + CGFloat(i) * keyW
                let r = CGRect(x: left + KeyStripView.gap / 2, y: keyTop, width: keyW - KeyStripView.gap, height: keyBottom - keyTop)
                let down = k === pressed || k === holding || k.down || others.values.contains { $0 === k }
                UIColor(rgb: down ? theme.accent : k.latched ? theme.keyAccent : k.sticky ? theme.keyMod : theme.key).setFill()
                UIBezierPath(roundedRect: r, cornerRadius: 7).fill()
                // As large as fits: "PgDn" on a narrow key, "5" big.
                var font = UIFont.mono(14, bold: true)
                let tw = (k.label as NSString).size(withAttributes: [.font: font]).width
                if tw > r.width - 6 { font = UIFont.mono(14 * (r.width - 6) / tw, bold: true) }
                let color = UIColor(rgb: down ? theme.bg : k.latched ? theme.fgOnAccent : theme.fg)
                let size = (k.label as NSString).size(withAttributes: [.font: font])
                (k.label as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2),
                                           withAttributes: [.font: font, .foregroundColor: color])
            }
        }
        // Page dots; the current one a pill that slides with the pages.
        let n = pages.count
        let step: CGFloat = 12
        let cy = bounds.height - KeyStripView.dotsHeight / 2
        let startX = w / 2 - step * CGFloat(n - 1) / 2
        UIColor(rgb: theme.fgDim).setFill()
        for i in 0..<n {
            UIBezierPath(ovalIn: CGRect(x: startX + CGFloat(i) * step - 2, y: cy - 2, width: 4, height: 4)).fill()
        }
        let at = min(max(offset / w, 0), CGFloat(n - 1))
        let x = startX + at * step
        UIColor(rgb: theme.accent).setFill()
        UIBezierPath(roundedRect: CGRect(x: x - 5, y: cy - 2, width: 10, height: 4), cornerRadius: 2).fill()
    }

    // MARK: - Accessibility

    /// The showing page's keys, so VoiceOver can type them and UI tests can find them.
    private func updateAccessibility() {
        guard bounds.width > 0 else { return }
        let keys = pages[current]
        let keyW = (bounds.width - KeyStripView.pad * 2) / CGFloat(keys.count)
        accessibilityElements = keys.enumerated().map { i, k in
            let e = UIAccessibilityElement(accessibilityContainer: self)
            e.accessibilityLabel = k.label
            e.accessibilityIdentifier = "strip.\(k.label)"
            e.accessibilityTraits = .keyboardKey
            e.accessibilityFrameInContainerSpace = CGRect(x: KeyStripView.pad + CGFloat(i) * keyW, y: 0, width: keyW,
                                                          height: bounds.height - KeyStripView.dotsHeight)
            return e
        } + [pageElement]
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

    private static let slop: CGFloat = 8
    private static let holdTime: TimeInterval = 0.35
    private static let modifierDelay: TimeInterval = 0.1
    private static let tapTime: TimeInterval = 0.3
    private static let flick: CGFloat = 350
}
