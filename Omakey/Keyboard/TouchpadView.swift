import OmakeyCore
import OmakeyProtocol
import UIKit

/// Where the touchpad's clicks, motion and scroll go.
@MainActor
protocol TouchpadSink: AnyObject {
    func button(_ code: Int, down: Bool)
    /// Pointer motion in mouse counts.
    func motion(dx: Float, dy: Float)
    /// Scroll in 1/120 of a notch: positive [v] scrolls up, positive [h] right.
    func scroll(v: Float, h: Float)
}

/// Swiping up from the speed strip, the grab bar or a side button drags the touchpad away.
@MainActor
protocol TouchpadPanelDrag: AnyObject {
    /// The finger is [dy] points from where it started (negative: up).
    func drag(dy: CGFloat)
    func release(dy: CGFloat, flungUp: Bool)
}

/// A laptop touchpad: a surface that moves the desktop's pointer, framed by
/// buttons (a port of Android's `TouchpadView`, constants and all).
///
/// - One finger moves the pointer. A quick tap clicks; tap and hold
///   right-clicks (a context menu). Tap, then touch again and move: drag
///   with the left button held (tap twice quickly for a double click).
///   Lifting one finger of a two-finger scroll goes back to moving.
/// - Two fingers scroll, both ways, content following the fingers. A
///   two-finger tap right-clicks; a three-finger tap middle-clicks.
/// - Inside them, a narrow scroll strip down each side of the surface: slide
///   a finger up to scroll up, down to scroll down, a tick every notch.
/// - Down each side, mirrored: Left click, Right click, Ctrl + Left and
///   Shift + Left. In portrait mode (`compact`) plain Ctrl and Shift instead,
///   for the phone's own keyboard: hold one, or tap it to keep it down for
///   the next key or click (tap again to let go). They are held while
///   touched, so dragging, Ctrl-click multi-select and Shift-click range
///   select work with the other thumb moving the pointer.
/// - A strip along the top holds the pointer speed: a preset chip and a
///   slider. In portrait mode it is a row inside the top of the surface.
///   Swiping up from the strip, from the grab bar at the very bottom (or
///   tapping it), or from a side button puts the touchpad away. Side buttons
///   press a moment late for that, so a swipe never clicks.
///
/// Distances are points (Android's dp); motion and scroll are counted in
/// pixels, as Android counts them, so a swipe moves the pointer as far.
@MainActor
final class TouchpadView: UIView {
    weak var sink: TouchpadSink?
    weak var panelDrag: TouchpadPanelDrag? {
        didSet { relayout() }
    }

    /// Trackpad-style feedback for clicks, buttons and scrolling; nil for none.
    var haptics: Haptics?

    var theme: Theme {
        didSet { setNeedsDisplay() }
    }

    /// Portrait mode, under the phone's own keyboard: Ctrl and Shift buttons
    /// instead of Ctrl + Left and Shift + Left, slimmer columns, and the
    /// speed in a row along the top of the surface.
    var compact = false {
        didSet {
            leftColumn = sideColumn()
            rightColumn = sideColumn()
            relayout()
        }
    }

    /// False while the computer's omakeyd is too old for the touchpad.
    var supported = true {
        didSet { setNeedsDisplay() }
    }

    /// Pointer speed multiplier, set by the slider or a preset.
    var sensitivity: Float = 1 {
        didSet {
            sensitivity = min(max(sensitivity, TouchpadView.minSens), TouchpadView.maxSens)
            setNeedsDisplay(strip.insetBy(dx: -2, dy: -2))
        }
    }

    /// The preset the sensitivity came from, or "Custom". Shown in the chip.
    var presetName = "" {
        didSet { setNeedsDisplay(strip.insetBy(dx: -2, dy: -2)) }
    }

    /// The slider moved; the screen saves it and marks the preset Custom.
    var onSensitivityChanged: ((Float) -> Void)?
    /// The preset chip was tapped.
    var onPresetsRequested: (() -> Void)?

    private let slop: CGFloat = 6
    private let swipeSlop: CGFloat = 14
    private let motionScale: Float = 1.1
    /// 1/120-notch units per pixel: a notch every 50 px.
    private let scrollScale: Float = 2.4

    private enum Icon { case left, right, key }

    /// A button: the codes it holds (pressed in order, released in reverse).
    private final class Button {
        let codes: [Int]
        let label: String
        let icon: Icon
        /// A badge on the mouse icon, or the symbol of a key button.
        let modifier: String?
        var rect = CGRect.zero
        var held = 0
        var latched = false
        var downAt: TimeInterval = 0
        /// Something was typed or clicked while it was held: lifting it lets go.
        var used = false
        /// Touched while latched: lifting it lets go.
        var unlatchOnUp = false

        init(_ codes: [Int], _ label: String, _ icon: Icon, _ modifier: String?) {
            self.codes = codes
            self.label = label
            self.icon = icon
            self.modifier = modifier
        }

        /// A key button (Ctrl, Shift) can stay down after a tap, for the next key or click.
        var sticky: Bool { icon == .key }
    }

    private func sideColumn() -> [Button] {
        compact ? [
            Button([Wire.btnLeft], "Left", .left, nil),
            Button([Wire.btnRight], "Right", .right, nil),
            Button([UsKeys.keyLeftCtrl], "Ctrl", .key, "⌃"),
            Button([UsKeys.keyLeftShift], "Shift", .key, "⇧"),
        ] : [
            Button([Wire.btnLeft], "Left", .left, nil),
            Button([Wire.btnRight], "Right", .right, nil),
            Button([UsKeys.keyLeftCtrl, Wire.btnLeft], "Ctrl + Left", .left, "Ctrl"),
            Button([UsKeys.keyLeftShift, Wire.btnLeft], "Shift + Left", .left, "⇧"),
        ]
    }

    // The same four down both sides, mirrored.
    private lazy var leftColumn = sideColumn()
    private lazy var rightColumn = sideColumn()
    private var buttons: [Button] { leftColumn + rightColumn }

    // Geometry.
    /// Where the pointer moves; in compact mode the speed row is above it, on the same `surface`.
    private var pad = CGRect.zero
    private var surface = CGRect.zero
    /// The scroll strips, left and right, and their slightly wider touch areas.
    private var scrollers = [CGRect.zero, .zero]
    private var scrollTouch = [CGRect.zero, .zero]
    /// Fingers on each scroll strip, for drawing it pressed.
    private var scrollHeld = [0, 0]
    /// Scroll sent since the last notch tick, in 1/120 notch.
    private var scrollPending: Float = 0
    /// Slides the grip lines with the scroll.
    private var scrollTravel: CGFloat = 0
    private var strip = CGRect.zero
    private var slider = CGRect.zero
    private var sliderTouch = CGRect.zero
    private var chip = CGRect.zero
    /// The grab bar along the very bottom, when the touchpad can be put away.
    private var grab = CGRect.zero
    /// Compact mode on a narrow surface: the chip shows just the number.
    private var shortChip = false

    // Fingers: what each is doing, and where it was last.
    private enum Role: Equatable {
        case pad, swipe, strip, grab, slider, chip
        case scroll(Int)
        case button(Int)
    }

    private var roles: [ObjectIdentifier: Role] = [:]
    private var last: [ObjectIdentifier: CGPoint] = [:]
    private var padFingers = 0
    /// Where a swipe began, in window coordinates (the view itself moves with the panel).
    private var swipeStart: [ObjectIdentifier: CGPoint] = [:]
    private var tracker = VelocityTracker()
    /// Side buttons waiting to press, by finger: a swipe up meanwhile puts the touchpad away instead.
    private var deferred: [ObjectIdentifier: DispatchWorkItem] = [:]

    // The current pad gesture.
    private var gestureStart: TimeInterval = 0
    private var startTouch: ObjectIdentifier?
    private var startPoint = CGPoint.zero
    private var maxFingers = 0
    /// Finger travel, for telling taps from moves.
    private var travelled: CGFloat = 0
    /// Finger travel since the last glide tick, in points.
    private var glided: CGFloat = 0
    private var moving = false
    private var longPressed = false

    // Tap-and-drag: a tap's click waits briefly, in case a second touch turns it into a drag.
    private var pendingClick = false
    private var tapDragging = false
    private var dragMoved = false
    private var flushClick: DispatchWorkItem?
    private var longPress: DispatchWorkItem?

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isOpaque = false
        contentMode = .redraw
        accessibilityIdentifier = "touchpad"
    }

    // MARK: - Accessibility

    /// The surface, for VoiceOver users to move the pointer by touch.
    private lazy var surfaceElement: UIAccessibilityElement = {
        let e = UIAccessibilityElement(accessibilityContainer: self)
        e.accessibilityLabel = "Touchpad"
        e.accessibilityHint = "Move one finger to move the pointer. Tap to click."
        e.accessibilityTraits = .allowsDirectInteraction
        e.accessibilityIdentifier = "touchpad.surface"
        return e
    }()

    private func updateAccessibility() {
        surfaceElement.accessibilityFrameInContainerSpace = pad
        var elements: [Any] = [surfaceElement]
        for (i, b) in buttons.enumerated() {
            let e = UIAccessibilityElement(accessibilityContainer: self)
            e.accessibilityLabel = b.label + (i < leftColumn.count ? ", left side" : ", right side")
            e.accessibilityTraits = .button
            e.accessibilityIdentifier = "touchpad.\(i < leftColumn.count ? "left" : "right").\(b.label)"
            e.accessibilityFrameInContainerSpace = b.rect
            elements.append(e)
        }
        let speed = UIAccessibilityElement(accessibilityContainer: self)
        speed.accessibilityLabel = "Pointer speed: \(chipLabel().replacingOccurrences(of: " ▾", with: ""))"
        speed.accessibilityTraits = .button
        speed.accessibilityIdentifier = "touchpad.speed"
        speed.accessibilityFrameInContainerSpace = chip
        elements.append(speed)
        accessibilityElements = elements
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }

    private func relayout() {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let gap: CGFloat = 6
        let stripH: CGFloat = 46
        let grabH: CGFloat = panelDrag != nil ? TouchpadView.grabHeight : 0
        let columnW = compact ? max(60, w * 0.16) : max(80, w * 0.095)
        grab = CGRect(x: 0, y: h - grabH, width: w, height: grabH)

        // Side columns, mirrored, full height.
        let columnBottom = h - grabH - gap
        for (column, left) in [(leftColumn, gap), (rightColumn, w - gap - columnW)] {
            let cellH = (columnBottom - gap - gap * CGFloat(column.count - 1)) / CGFloat(column.count)
            for (i, b) in column.enumerated() {
                b.rect = CGRect(x: left, y: gap + CGFloat(i) * (cellH + gap), width: columnW, height: cellH)
            }
        }
        // Scroll strips a quarter of a button column wide, then the surface between them.
        let scrollW = columnW * 0.25
        let scrollTop = compact ? gap : gap * 2 + stripH
        scrollers[0] = CGRect(x: gap * 2 + columnW, y: scrollTop, width: scrollW, height: columnBottom - scrollTop)
        scrollers[1] = CGRect(x: w - gap * 2 - columnW - scrollW, y: scrollTop, width: scrollW, height: columnBottom - scrollTop)
        for i in 0..<2 { scrollTouch[i] = scrollers[i].insetBy(dx: -gap, dy: 0) }
        surface = CGRect(x: scrollers[0].maxX + gap, y: scrollTop, width: scrollers[1].minX - gap - scrollers[0].maxX - gap,
                         height: columnBottom - scrollTop)
        pad = surface
        let chipFont = UIFont.mono(12, bold: true)
        if compact {
            // The speed row along the top of the surface: the chip at the start, the slider filling the rest.
            strip = CGRect(x: surface.minX, y: surface.minY, width: surface.width, height: TouchpadView.speedRowHeight)
            pad = CGRect(x: surface.minX, y: strip.maxY, width: surface.width, height: surface.maxY - strip.maxY)
            let chipH: CGFloat = 26, sliderH: CGFloat = 18
            // Room for the widest speed, so the chip keeps its size as it changes.
            shortChip = width(of: "Speed 0.00× ▾", chipFont) + 24 > strip.width * 0.5
            let chipW = width(of: shortChip ? "0.00× ▾" : "Speed 0.00× ▾", chipFont) + 24
            chip = CGRect(x: strip.minX + 8, y: strip.midY - chipH / 2, width: chipW, height: chipH)
            slider = CGRect(x: chip.maxX + 14, y: strip.midY - sliderH / 2, width: max(strip.maxX - 14 - chip.maxX - 14, 40), height: sliderH)
            sliderTouch = CGRect(x: slider.minX - 10, y: strip.minY, width: strip.maxX - slider.minX + 10, height: strip.height)
        } else {
            strip = CGRect(x: scrollers[0].minX, y: gap, width: scrollers[1].maxX - scrollers[0].minX, height: stripH)
            let chipH: CGFloat = 28, sliderH: CGFloat = 22
            // Speed in the strip: the preset chip, then the slider, centered together.
            let chipW = min(strip.width * 0.32, 230)
            let labels: CGFloat = 44 // room for "slow" and "fast"
            // The slider takes what's left when the strip is narrow.
            let sliderW = max(min(strip.width * 0.42, 320, strip.width - chipW - 16 - labels * 2 - 8), 40)
            let total = chipW + 16 + labels + sliderW + labels
            var x = strip.midX - total / 2
            chip = CGRect(x: x, y: strip.midY - chipH / 2, width: chipW, height: chipH)
            x += chipW + 16 + labels
            slider = CGRect(x: x, y: strip.midY - sliderH / 2, width: sliderW, height: sliderH)
            sliderTouch = CGRect(x: slider.minX - 8, y: strip.minY, width: slider.width + 16, height: strip.height)
        }
        updateAccessibility()
        setNeedsDisplay()
    }

    private func width(of s: String, _ font: UIFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - State from outside

    /// A key went to the computer, or a click: latched Ctrl and Shift let go
    /// (they were for that one), held ones let go when lifted instead of latching.
    func modifiersUsed() {
        for b in buttons where b.sticky {
            if b.latched && !b.unlatchOnUp {
                b.latched = false
                release(b)
            } else if b.held > 0 {
                b.used = true
            }
        }
    }

    /// Let go of every button, e.g. when the touchpad is put away.
    func releaseAll() {
        longPress?.cancel()
        // A gesture that was swiping the panel snaps back instead of freezing half way.
        if roles.values.contains(.swipe) { panelDrag?.release(dy: 0, flungUp: false) }
        flushClick?.cancel()
        if pendingClick {
            pendingClick = false
            click(Wire.btnLeft, felt: true)
        }
        if tapDragging {
            tapDragging = false
            sink?.button(Wire.btnLeft, down: false)
        }
        for b in buttons {
            b.latched = false
            b.unlatchOnUp = false
            if b.held > 0 {
                b.held = 1
                release(b, felt: false)
            }
        }
        deferred.values.forEach { $0.cancel() }
        deferred.removeAll()
        roles.removeAll()
        last.removeAll()
        swipeStart.removeAll()
        padFingers = 0
        scrollHeld = [0, 0]
        setNeedsDisplay()
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { fingerDown(t, event) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        fingersMoved(touches, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { fingerUp(t, event) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseAll()
    }

    private func fingerDown(_ t: UITouch, _ event: UIEvent?) {
        let id = ObjectIdentifier(t)
        let p = t.location(in: self)
        last[id] = p
        if sliderTouch.contains(p) {
            roles[id] = .slider
            slide(p.x)
            return
        }
        if chip.contains(p) {
            roles[id] = .chip
            return
        }
        if let sc = scrollTouch.firstIndex(where: { $0.contains(p) }) {
            roles[id] = .scroll(sc)
            haptics?.touch()
            scrollHeld[sc] += 1
            setNeedsDisplay(scrollers[sc].insetBy(dx: -2, dy: -2))
            return
        }
        // A touch in the gap between two side buttons counts as the nearer one.
        let all = buttons
        if let b = all.firstIndex(where: { $0.rect.contains(p) })
            ?? all.firstIndex(where: { p.x >= $0.rect.minX && p.x <= $0.rect.maxX && p.y >= $0.rect.minY - 3 && p.y <= $0.rect.maxY + 3 }) {
            roles[id] = .button(b)
            let btn = all[b]
            if btn.sticky {
                if btn.latched {
                    // Already down: this touch lets it go when lifted.
                    btn.unlatchOnUp = true
                    setNeedsDisplay(btn.rect)
                    return
                }
                btn.downAt = t.timestamp
                btn.used = false
            }
            if !btn.sticky && panelDrag != nil {
                // Pressed a moment later: a swipe up from here puts the touchpad away without clicking.
                swipeStart[id] = t.location(in: window)
                tracker.clear()
                tracker.add(t, event, in: self)
                let later = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.deferred[id] = nil
                    if self.roles[id] == .button(b) { self.press(btn) }
                }
                deferred[id] = later
                DispatchQueue.main.asyncAfter(deadline: .now() + TouchpadView.buttonDelay, execute: later)
                return
            }
            press(btn)
            return
        }
        if grab.contains(p) || strip.contains(p) {
            roles[id] = grab.contains(p) ? .grab : .strip
            swipeStart[id] = t.location(in: window)
            tracker.clear()
            tracker.add(t, event, in: self)
            return
        }
        guard pad.contains(p) else { return }
        roles[id] = .pad
        padFingers += 1
        if padFingers == 1 {
            if pendingClick {
                // A touch right after a tap: hold the button and drag.
                flushClick?.cancel()
                pendingClick = false
                tapDragging = true
                dragMoved = false
                sink?.button(Wire.btnLeft, down: true)
                haptics?.down()
            } else {
                haptics?.touch()
            }
            gestureStart = t.timestamp
            startTouch = id
            startPoint = p
            maxFingers = 1
            travelled = 0
            glided = 0
            moving = false
            longPressed = false
            let lp = DispatchWorkItem { [weak self] in self?.longPressFired() }
            longPress = lp
            DispatchQueue.main.asyncAfter(deadline: .now() + TouchpadView.longPressTime, execute: lp)
        } else {
            longPress?.cancel()
            maxFingers = max(maxFingers, padFingers)
        }
    }

    private func longPressFired() {
        if padFingers == 1 && maxFingers == 1 && !moving && !tapDragging {
            longPressed = true
            click(Wire.btnRight, felt: true)
            haptics?.force()
        }
    }

    private func fingersMoved(_ touches: Set<UITouch>, _ event: UIEvent?) {
        let scale = traitCollection.displayScale
        var sumDx: CGFloat = 0, sumDy: CGFloat = 0
        var n = 0
        // Every finger on the pad counts, moved or not, as on Android.
        for t in event?.allTouches ?? touches {
            let id = ObjectIdentifier(t)
            guard let role = roles[id] else { continue }
            let p = t.location(in: self)
            switch role {
            case .slider:
                slide(p.x)
            case .button where deferred[id] != nil:
                // Swiping up from a side button not pressed yet puts the touchpad away.
                tracker.add(t, event, in: self)
                if let s = swipeStart[id], t.location(in: window).y - s.y < -swipeSlop {
                    deferred[id]?.cancel()
                    deferred[id] = nil
                    roles[id] = .swipe
                }
            case .strip, .grab:
                // So does swiping up from the strip or the grab bar.
                tracker.add(t, event, in: self)
                if let s = swipeStart[id], t.location(in: window).y - s.y < -swipeSlop { roles[id] = .swipe }
            case .swipe:
                tracker.add(t, event, in: self)
                if let s = swipeStart[id] { panelDrag?.drag(dy: t.location(in: window).y - s.y) }
            case .scroll(let i):
                if let l = last[id] { stripScroll(p.y - l.y, i) }
                last[id] = p
            case .pad:
                if let l = last[id] {
                    sumDx += p.x - l.x
                    sumDy += p.y - l.y
                }
                last[id] = p
                n += 1
            default:
                break
            }
        }
        guard n > 0 else { return }
        // The pointer moving: a side button held for a drag goes down now, not a moment later.
        flushDeferred()
        let dx = sumDx / CGFloat(n), dy = sumDy / CGFloat(n)
        travelled += abs(dx) + abs(dy)
        guard let s = sink else { return }
        if padFingers == 1 {
            if !moving, let start = startTouch,
               let t = (event?.allTouches ?? touches).first(where: { ObjectIdentifier($0) == start }),
               hypot(t.location(in: self).x - startPoint.x, t.location(in: self).y - startPoint.y) > slop {
                moving = true
                dragMoved = true
                longPress?.cancel()
            }
            if moving {
                s.motion(dx: Float(dx * scale) * motionScale * sensitivity, dy: Float(dy * scale) * motionScale * sensitivity)
                glide(dx, dy)
            }
        } else if padFingers >= 2 {
            // Content follows the fingers: fingers up scrolls down.
            s.scroll(v: Float(dy * scale) * scrollScale, h: Float(-dx * scale) * scrollScale)
            glide(dx, dy)
        }
    }

    /// The faintest tick every few points the fingers glide, whatever the
    /// pointer speed: a texture under the finger, quicker as it moves faster.
    private func glide(_ dx: CGFloat, _ dy: CGFloat) {
        glided += hypot(dx, dy)
        guard glided >= TouchpadView.glideStep else { return }
        glided = glided.truncatingRemainder(dividingBy: TouchpadView.glideStep)
        haptics?.glide()
    }

    private func fingerUp(_ t: UITouch, _ event: UIEvent?) {
        let id = ObjectIdentifier(t)
        guard let role = roles.removeValue(forKey: id) else { return }
        defer {
            last[id] = nil
            swipeStart[id] = nil
        }
        switch role {
        case .slider:
            return
        case .chip:
            if chip.contains(t.location(in: self)) { onPresetsRequested?() }
            return
        case .grab:
            // A tap on the grab bar: back to the keyboard.
            panelDrag?.release(dy: 0, flungUp: true)
            return
        case .strip:
            return
        case .swipe:
            tracker.add(t, event, in: self)
            let dy = t.location(in: window).y - (swipeStart[id]?.y ?? 0)
            // The finger's speed as it let go, not the whole swipe's average.
            panelDrag?.release(dy: dy, flungUp: tracker.velocity.y < -TouchpadView.flingPointsPerSecond)
            return
        case .scroll(let i):
            scrollHeld[i] = max(scrollHeld[i] - 1, 0)
            setNeedsDisplay(scrollers[i].insetBy(dx: -2, dy: -2))
            return
        case .button(let b):
            let btn = buttons[b]
            if let d = deferred.removeValue(forKey: id) {
                // Lifted before it pressed: a click.
                d.cancel()
                press(btn)
                release(btn)
            } else if !btn.sticky {
                release(btn)
            } else if btn.unlatchOnUp {
                btn.unlatchOnUp = false
                btn.latched = false
                release(btn)
            } else if (t.timestamp - btn.downAt) * 1000 < TouchpadView.tapMs && !btn.used {
                // A quick tap with nothing typed meanwhile: stays down for the next key.
                btn.latched = true
                setNeedsDisplay(btn.rect)
            } else {
                release(btn)
            }
            return
        case .pad:
            break
        }
        padFingers -= 1
        if padFingers == 1 {
            // Back to one finger: it moves the pointer, from where it is now.
            if let left = roles.first(where: { $0.value == .pad })?.key {
                startTouch = left
                startPoint = last[left] ?? startPoint
                moving = false
            }
        }
        if padFingers > 0 { return }
        longPress?.cancel()
        let duration = (t.timestamp - gestureStart) * 1000
        let still = travelled < slop * CGFloat(maxFingers)
        #if DEBUG
        // For the UI tests' failure messages: what the last gesture looked like.
        surfaceElement.accessibilityValue = "fingers \(maxFingers), \(Int(duration)) ms, travelled \(Int(travelled))"
        #endif
        if tapDragging {
            tapDragging = false
            sink?.button(Wire.btnLeft, down: false)
            modifiersUsed()
            // Touched again without moving: that was a double tap, a double click.
            if !dragMoved && maxFingers == 1 && duration < TouchpadView.tapMs { click(Wire.btnLeft) } else { haptics?.up() }
            return
        }
        if maxFingers == 1 && !moving && !longPressed && duration < TouchpadView.tapMs {
            // Felt now, as the finger lifts; the click itself waits for a possible drag.
            haptics?.tap()
            pendingClick = true
            let f = DispatchWorkItem { [weak self] in
                guard let self, self.pendingClick else { return }
                self.pendingClick = false
                self.click(Wire.btnLeft, felt: true)
            }
            flushClick = f
            DispatchQueue.main.asyncAfter(deadline: .now() + TouchpadView.dragWindow, execute: f)
        } else if maxFingers == 2 && still && duration < TouchpadView.multiTapMs {
            click(Wire.btnRight)
        } else if maxFingers == 3 && still && duration < TouchpadView.multiTapMs {
            click(Wire.btnMiddle)
        }
    }

    /// A scroll strip finger moved [dy] points: up scrolls up, a tick each notch.
    private func stripScroll(_ dy: CGFloat, _ i: Int) {
        guard dy != 0 else { return }
        let v = Float(-dy * traitCollection.displayScale) * scrollScale
        sink?.scroll(v: v, h: 0)
        scrollTravel += dy
        scrollPending += v
        if abs(scrollPending) >= TouchpadView.notch {
            scrollPending = scrollPending.truncatingRemainder(dividingBy: TouchpadView.notch)
            haptics?.notch()
        }
        setNeedsDisplay(scrollers[i].insetBy(dx: -2, dy: -2))
    }

    private func press(_ b: Button) {
        b.held += 1
        if b.held == 1 {
            // Modifier first, then the mouse button: Ctrl is down before the click lands.
            for c in b.codes { sink?.button(c, down: true) }
            haptics?.down()
        }
        setNeedsDisplay(b.rect)
    }

    /// Press every side button still waiting, now.
    private func flushDeferred() {
        let waiting = deferred
        deferred.removeAll()
        for item in waiting.values {
            item.cancel()
            item.perform()
        }
    }

    /// [felt]: play the release click; not when everything is let go at once.
    private func release(_ b: Button, felt: Bool = true) {
        if b.held > 0 {
            b.held -= 1
            if b.held == 0 {
                for c in b.codes.reversed() { sink?.button(c, down: false) }
                if felt { haptics?.up() }
                // A mouse button let go: that was the click a latched Ctrl or Shift was for.
                if felt && !b.sticky { modifiersUsed() }
            }
        }
        setNeedsDisplay(b.rect)
    }

    /// Press and release [code]; [felt]: its haptic has already played.
    private func click(_ code: Int, felt: Bool = false) {
        guard let s = sink else { return }
        s.button(code, down: true)
        s.button(code, down: false)
        if !felt { haptics?.tap() }
        modifiersUsed()
    }

    /// Slider position (0 left … 1 right) to sensitivity, on a log scale.
    private func sens(at t: Float) -> Float { TouchpadView.minSens * pow(TouchpadView.maxSens / TouchpadView.minSens, t) }

    private func position(of s: Float) -> Float { log(s / TouchpadView.minSens) / log(TouchpadView.maxSens / TouchpadView.minSens) }

    private func slide(_ x: CGFloat) {
        let t = Float(min(max((x - slider.minX) / slider.width, 0), 1))
        // Snap to 0.05, which is plenty and keeps the label steady.
        let v = min(max((sens(at: t) * 20).rounded() / 20, TouchpadView.minSens), TouchpadView.maxSens)
        if v != sensitivity {
            sensitivity = v
            onSensitivityChanged?(v)
        }
    }

    // MARK: - Drawing

    private func color(_ c: UInt32) -> UIColor { UIColor(rgb: c) }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let radius: CGFloat = 14
        color(theme.surface).setFill()
        UIBezierPath(roundedRect: surface, cornerRadius: radius).fill()
        // A faint dot grid, so the surface reads as a touchpad.
        color(theme.key).setFill()
        let step: CGFloat = 22, dot: CGFloat = 1.4
        var y = pad.minY + step
        while y < pad.maxY - step / 2 {
            if y + dot >= rect.minY && y - dot <= rect.maxY {
                var x = pad.minX + step
                while x < pad.maxX - step / 2 {
                    ctx.fillEllipse(in: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2))
                    x += step
                }
            }
            y += step
        }

        let hintY = pad.minY + pad.height * 0.36
        if supported {
            let font = UIFont.mono(13)
            let hint = "move · tap to click · hold for menu · two fingers scroll"
            // Too wide for the surface: one hint per line.
            let lines = width(of: hint, font) > pad.width - 24 ? hint.components(separatedBy: " · ") : [hint]
            var ly = hintY - CGFloat(lines.count - 1) * 9
            for line in lines {
                drawText(line, centerX: pad.midX, baseline: ly, font: font, color: theme.fgDim)
                ly += 18
            }
            if panelDrag != nil {
                drawText("swipe up on the side buttons or the bottom edge to hide", centerX: pad.midX, baseline: ly + 2,
                         font: .mono(11), color: theme.fgDim)
            }
        } else {
            drawText("Update Omakey on your computer to use the touchpad:", centerX: pad.midX, baseline: hintY, font: .mono(13), color: theme.warn)
            drawText("bar icon → Update the service", centerX: pad.midX, baseline: hintY + 22, font: .mono(13), color: theme.warn)
        }

        drawSpeed(ctx)
        if panelDrag != nil { drawGrab() }
        for i in 0..<2 { drawScroller(ctx, scrollers[i], held: scrollHeld[i] > 0) }
        for b in buttons { drawButton(b, radius: radius) }
    }

    private func drawText(_ s: String, centerX: CGFloat, baseline: CGFloat, font: UIFont, color c: UInt32) {
        let w = width(of: s, font)
        (s as NSString).draw(at: CGPoint(x: centerX - w / 2, y: baseline - font.ascender), withAttributes: [.font: font, .foregroundColor: color(c)])
    }

    private func drawText(_ s: String, left: CGFloat, baseline: CGFloat, font: UIFont, color c: UInt32) {
        (s as NSString).draw(at: CGPoint(x: left, y: baseline - font.ascender), withAttributes: [.font: font, .foregroundColor: color(c)])
    }

    /// A scroll strip: arrows at the ends, grip lines between them that follow the finger.
    private func drawScroller(_ ctx: CGContext, _ r: CGRect, held: Bool) {
        color(held ? theme.keyAccent : theme.keyMod).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: r.width / 2).fill()
        let stroke = color(held ? theme.fgOnAccent : theme.fgDim)
        stroke.setStroke()
        let half = min(r.width * 0.3, 6)
        let cx = r.midX, inset: CGFloat = 10
        let arrows = UIBezierPath()
        let upTip = r.minY + inset
        arrows.move(to: CGPoint(x: cx - half, y: upTip + half))
        arrows.addLine(to: CGPoint(x: cx, y: upTip))
        arrows.addLine(to: CGPoint(x: cx + half, y: upTip + half))
        let downTip = r.maxY - inset
        arrows.move(to: CGPoint(x: cx - half, y: downTip - half))
        arrows.addLine(to: CGPoint(x: cx, y: downTip))
        arrows.addLine(to: CGPoint(x: cx + half, y: downTip - half))
        arrows.lineWidth = 1.6
        arrows.lineCapStyle = .round
        arrows.stroke()
        // Grip lines in the middle third, sliding with the scroll.
        let top = r.minY + r.height / 3, bottom = r.maxY - r.height / 3
        let step: CGFloat = 9
        let shift = (scrollTravel.truncatingRemainder(dividingBy: step) + step).truncatingRemainder(dividingBy: step)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: r.minX, y: top, width: r.width, height: bottom - top))
        let lines = UIBezierPath()
        var y = top - step + shift
        while y < bottom + step {
            lines.move(to: CGPoint(x: cx - half * 0.8, y: y))
            lines.addLine(to: CGPoint(x: cx + half * 0.8, y: y))
            y += step
        }
        lines.lineWidth = 1.6
        lines.stroke()
        ctx.restoreGState()
    }

    private func drawSpeed(_ ctx: CGContext) {
        if compact {
            // A hairline between the pointer surface and the speed row on it.
            color(theme.key).setFill()
            ctx.fill(CGRect(x: strip.minX + 12, y: strip.maxY - 1, width: strip.width - 24, height: 1))
        } else {
            color(theme.surface).setFill()
            UIBezierPath(roundedRect: strip, cornerRadius: strip.height / 2).fill()
        }
        let r = slider, h = r.height
        let t = CGFloat(position(of: sensitivity))
        color(theme.keyMod).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: h / 2).fill()
        let knobX = r.minX + t * r.width
        color(theme.keyAccent).setFill()
        UIBezierPath(roundedRect: CGRect(x: r.minX, y: r.minY, width: max(knobX, r.minX + h) - r.minX, height: h), cornerRadius: h / 2).fill()
        color(theme.accent).setFill()
        let kx = min(max(knobX, r.minX + h / 2), r.maxX - h / 2)
        ctx.fillEllipse(in: CGRect(x: kx - h * 0.42, y: r.midY - h * 0.42, width: h * 0.84, height: h * 0.84))
        if !compact {
            let f = UIFont.mono(10)
            drawText("slow", left: r.minX - 8 - width(of: "slow", f), baseline: r.midY + 4, font: f, color: theme.fgDim)
            drawText("fast", left: r.maxX + 8, baseline: r.midY + 4, font: f, color: theme.fgDim)
        }
        color(theme.keyMod).setFill()
        UIBezierPath(roundedRect: chip, cornerRadius: chip.height / 2).fill()
        let f = UIFont.mono(12, bold: true)
        drawText(chipLabel(), centerX: chip.midX, baseline: chip.midY + (f.ascender + f.descender) / 2, font: f, color: theme.accent)
    }

    /// The grab bar: a hairline across the whole width, a handle in the middle
    /// with arrows pointing the way the touchpad goes.
    private func drawGrab() {
        let cy = grab.midY + 2
        color(theme.key).setFill()
        UIRectFill(CGRect(x: grab.minX, y: grab.minY + 1, width: grab.width, height: 1))
        let hw: CGFloat = 26
        color(theme.fgDim).setFill()
        UIBezierPath(roundedRect: CGRect(x: grab.midX - hw, y: cy - 2, width: hw * 2, height: 4), cornerRadius: 2).fill()
        color(theme.fgDim).setStroke()
        let a: CGFloat = 4
        let p = UIBezierPath()
        for x in [grab.midX - hw - 16, grab.midX + hw + 16] {
            p.move(to: CGPoint(x: x - a, y: cy + a / 2))
            p.addLine(to: CGPoint(x: x, y: cy - a / 2))
            p.addLine(to: CGPoint(x: x + a, y: cy + a / 2))
        }
        p.lineWidth = 1.6
        p.lineCapStyle = .round
        p.stroke()
    }

    /// The preset and speed; just the speed when narrow.
    private func chipLabel() -> String {
        var value = String(format: "%.2f", sensitivity)
        while value.hasSuffix("0") { value.removeLast() }
        if value.hasSuffix(".") { value.removeLast() }
        if !compact { return "\(presetName.isEmpty ? "Pointer speed" : presetName) · \(value)× ▾" }
        return shortChip ? "\(value)× ▾" : "Speed \(value)× ▾"
    }

    private func drawButton(_ b: Button, radius: CGFloat) {
        if b.sticky { return drawKeyButton(b, radius: radius) }
        let r = b.rect
        let held = b.held > 0
        let mouse = (Wire.btnLeft...Wire.btnMiddle).contains(b.codes.last ?? 0)
        color(held ? theme.accent : mouse ? theme.key : theme.keyMod).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: radius).fill()
        let fg = held ? theme.bg : mouse ? theme.fg : theme.fgDim
        // Mouse icon with the button it presses filled in, a modifier badge, and the name underneath.
        let size = min(r.height * 0.42, r.width * 0.5)
        let cy = r.midY - r.height * 0.1
        drawMouse(cx: r.midX, cy: cy, size: size, which: b.icon, outline: fg, fill: held ? theme.bg : theme.accent)
        if let m = b.modifier {
            let f = UIFont.mono(11)
            let w = width(of: m, f) + 10
            let bx = r.midX + size * 0.55, by = cy - size * 0.55
            color(held ? theme.bg : theme.surface).setFill()
            UIBezierPath(roundedRect: CGRect(x: bx - w / 2, y: by - 9, width: w, height: 18), cornerRadius: 9).fill()
            drawText(m, centerX: bx, baseline: by + (f.ascender + f.descender) / 2, font: f, color: held ? theme.accent : theme.layer)
        }
        drawText(b.label, centerX: r.midX, baseline: r.maxY - 8, font: .mono(11), color: fg)
    }

    /// Ctrl or Shift: its symbol large, the name under it; latched ones stay tinted.
    private func drawKeyButton(_ b: Button, radius: CGFloat) {
        let r = b.rect
        let touched = b.held > 0 && !b.latched || b.unlatchOnUp
        color(touched ? theme.accent : b.latched ? theme.keyAccent : theme.keyMod).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: radius).fill()
        let fg = touched ? theme.bg : b.latched ? theme.fgOnAccent : theme.fg
        let big = UIFont.mono(min(r.height * 0.32, r.width * 0.42))
        drawText(b.modifier ?? "", centerX: r.midX, baseline: r.midY + (big.ascender + big.descender) / 2 - r.height * 0.08, font: big, color: fg)
        drawText(b.latched && !touched ? "\(b.label) ●" : b.label, centerX: r.midX, baseline: r.maxY - 8, font: .mono(11), color: fg)
    }

    /// A mouse outline, [size] tall, with the [which] button filled.
    private func drawMouse(cx: CGFloat, cy: CGFloat, size: CGFloat, which: Icon, outline: UInt32, fill: UInt32) {
        let w = size * 0.66
        let body = CGRect(x: cx - w / 2, y: cy - size / 2, width: w, height: size)
        let corner = w / 2
        let split = body.minY + size * 0.42
        let half = which == .left ? CGRect(x: body.minX, y: body.minY, width: cx - body.minX, height: split - body.minY)
            : CGRect(x: cx, y: body.minY, width: body.maxX - cx, height: split - body.minY)
        let shape = UIBezierPath(roundedRect: body, cornerRadius: corner)
        if let ctx = UIGraphicsGetCurrentContext() {
            ctx.saveGState()
            ctx.clip(to: half)
            color(fill).setFill()
            shape.fill()
            ctx.restoreGState()
        }
        color(outline).setStroke()
        shape.lineWidth = 1.6
        shape.stroke()
        let lines = UIBezierPath()
        lines.move(to: CGPoint(x: body.minX, y: split))
        lines.addLine(to: CGPoint(x: body.maxX, y: split))
        lines.move(to: CGPoint(x: cx, y: body.minY))
        lines.addLine(to: CGPoint(x: cx, y: split))
        lines.lineWidth = 1.6
        lines.stroke()
    }

    // MARK: - Constants (from Android)

    /// How long a side button waits before pressing, so a swipe up from it never clicks.
    static let buttonDelay: TimeInterval = 0.12
    static let grabHeight: CGFloat = 22
    /// Compact mode: the speed row's height at the top of the surface.
    static let speedRowHeight: CGFloat = 40
    static let tapMs: TimeInterval = 220
    static let multiTapMs: TimeInterval = 300
    static let longPressTime: TimeInterval = 0.45
    /// How long a tap waits for a second touch that would make it a drag.
    static let dragWindow: TimeInterval = 0.15
    static let flingPointsPerSecond: CGFloat = 500
    static let minSens: Float = 0.3
    static let maxSens: Float = 3
    static let notch: Float = 120
    /// Points of finger travel between glide ticks: about a wheel notch's worth of two-finger scroll.
    static let glideStep: CGFloat = 16
}
