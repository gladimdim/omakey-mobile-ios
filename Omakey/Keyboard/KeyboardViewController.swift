import OmakeyCore
import OmakeyNet
import OmakeyProtocol
import SwiftUI
import UIKit

/// The keyboard: landscape, full screen, the screen kept on. While it shows
/// it keeps a live connection to the computer (omakeyd over Wi-Fi). The
/// touchpad slides down over the keys; the computer can be switched from
/// here without leaving the keyboard.
@MainActor
final class KeyboardViewController: UIViewController {
    private let model: AppModel
    private var host: HostRecord
    private var theme: Theme

    private let keys = KeyState()
    private var link: UDPLink?
    /// Bumped for every link, so reports from a replaced one are ignored.
    private var linkGeneration = 0
    private var discovery: Discovery?
    private var nearby: [Found] = []
    private var linkState = LinkState.connecting
    private var hostName: String
    private var pingMs = -1

    private let keyboard: KeyboardView
    private let touchpad: TouchpadView
    private let haptics = Haptics()
    private var ticker: TypedTickerView?

    /// The top bar, the grip and the typed text: a vertical drag anywhere on it pulls the touchpad.
    private let header = UIView()
    private let handle = UIButton(type: .system)
    private let status = UIButton(type: .system)
    private let stickyButton = UIButton(type: .system)
    private let switchButton = UIButton(type: .system)
    private let layoutButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let grip = PullGripView()
    /// The keyboard, with the touchpad's panel above it.
    private let stage = UIView()
    private let panel = UIView()

    private let toastLabel = PaddedLabel()
    private var toastTask: Task<Void, Never>?
    private lazy var sink = SinkProxy(self)
    private lazy var padSink = PadSinkProxy(self)
    private var observers: [NSObjectProtocol] = []

    // The panel.
    private var padOpen = false
    /// Being dragged or animated: layout passes leave it alone.
    private var panelMoving = false
    private var panelY: CGFloat = 0
    private var dragStartY: CGFloat = 0
    /// How much of the panel showed when the drag began.
    private var dragStartShown: CGFloat = 0
    private var animation: PanelAnimation?

    /// Called once the keyboard is gone, for the connect screen.
    var onClose: (() -> Void)?

    init(model: AppModel, host: HostRecord) {
        self.model = model
        self.host = host
        hostName = host.name
        theme = model.currentTheme()
        keyboard = KeyboardView(theme: theme)
        touchpad = TouchpadView(theme: theme)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - The screen

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    /// A swipe from any edge goes to the keyboard first; a second one to the system.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        haptics.enabled = model.settings.haptics
        keyboard.haptics = haptics
        keyboard.sticky = model.settings.sticky
        keyboard.pull = self
        keyboard.setLayout(model.layouts.selected(), sink: sink)
        touchpad.haptics = haptics
        touchpad.sink = padSink
        touchpad.panelDrag = self
        touchpad.onSensitivityChanged = { [weak self] v in
            guard let self else { return }
            self.model.settings.setPointerSpeed(v, preset: PointerPresets.custom, for: self.host.hostId)
            self.touchpad.presetName = PointerPresets.custom
        }
        touchpad.onPresetsRequested = { [weak self] in self?.pickPreset() }
        applyPadSettings()

        stage.clipsToBounds = true
        stage.addSubview(keyboard)
        panel.isHidden = true
        panel.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        // A sheet over the keyboard: a shadow, and rounded bottom corners while it moves.
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.45
        panel.layer.shadowRadius = 20
        panel.layer.shadowOffset = CGSize(width: 0, height: 8)
        panel.addSubview(touchpad)
        stage.addSubview(panel)
        view.addSubview(stage)

        handle.titleLabel?.font = .mono(12, bold: true)
        handle.layer.cornerRadius = 12
        handle.layer.borderWidth = 1
        handle.accessibilityIdentifier = "keyboard.touchpad"
        handle.accessibilityHint = "Or swipe the top bar down"
        handle.addTarget(self, action: #selector(toggleTouchpad), for: .touchUpInside)
        header.addSubview(handle)
        for (b, title, label, action) in [
            (stickyButton, "⇧", "Sticky keys", #selector(toggleSticky)),
            (switchButton, "⇄", "Switch computer", #selector(pickHost)),
            (layoutButton, "⌨", "Switch layout", #selector(pickLayout)),
            (closeButton, "✕", "Close", #selector(close)),
        ] {
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .mono(15, bold: true)
            b.accessibilityLabel = label
            b.addTarget(self, action: action, for: .touchUpInside)
            header.addSubview(b)
        }
        closeButton.accessibilityIdentifier = "keyboard.close"
        status.addTarget(self, action: #selector(pickHost), for: .touchUpInside)
        status.accessibilityIdentifier = "keyboard.status"
        header.addSubview(status)
        header.addSubview(grip)
        if model.settings.typedText {
            let t = TypedTickerView(theme: theme)
            ticker = t
            header.addSubview(t)
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(headerDragged(_:)))
        pan.delegate = self
        header.addGestureRecognizer(pan)
        view.addSubview(header)

        toastLabel.font = .mono(13)
        toastLabel.numberOfLines = 0
        toastLabel.textAlignment = .center
        toastLabel.layer.cornerRadius = 16
        toastLabel.layer.masksToBounds = true
        toastLabel.alpha = 0
        view.addSubview(toastLabel)

        applyTheme()
        renderHandle()

        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.letGo() }
            },
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.disconnect() }
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.connect() }
            },
        ]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        connect()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        letGo()
        disconnect()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        animation?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        onClose?()
        onClose = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let barH: CGFloat = 32
        let headerH = barH + 10 + (ticker != nil ? 22 : 0)
        header.frame = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: headerH)
        let w = header.bounds.width
        handle.frame = CGRect(x: 8, y: 4, width: 136, height: 26)
        // The buttons on the right of the top bar.
        var x = w - 4
        for b in [closeButton, layoutButton, switchButton, stickyButton] {
            x -= 44
            b.frame = CGRect(x: x, y: 0, width: 44, height: barH)
        }
        // The connection status, centered: as wide as the room between the handle and the buttons.
        let side = max(handle.frame.maxX, w - stickyButton.frame.minX) + 8
        let maxW = max(w - side * 2, 80)
        let fit = status.sizeThatFits(CGSize(width: maxW, height: 24))
        let sw = min(fit.width, maxW)
        status.frame = CGRect(x: w / 2 - sw / 2, y: 4, width: sw, height: 24)
        grip.frame = CGRect(x: 0, y: barH, width: w, height: 10)
        ticker?.frame = CGRect(x: 0, y: barH + 10, width: w, height: 22)

        let oldHeight = stage.bounds.height
        stage.frame = CGRect(x: safe.minX, y: header.frame.maxY, width: safe.width, height: safe.maxY - header.frame.maxY)
        keyboard.bounds = CGRect(origin: .zero, size: stage.bounds.size)
        keyboard.center = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
        panel.bounds = CGRect(origin: .zero, size: stage.bounds.size)
        panel.center = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
        touchpad.frame = panel.bounds
        // Keep a closed panel parked just above the stage when its size
        // changes, but not while it is being dragged or animated.
        if !panelMoving && (!padOpen || oldHeight != stage.bounds.height) { setPanelY(padOpen ? 0 : -stage.bounds.height) }

        let toast = toastLabel.sizeThatFits(CGSize(width: safe.width * 0.7, height: 200))
        toastLabel.frame = CGRect(x: safe.midX - toast.width / 2, y: safe.maxY - toast.height - 24, width: toast.width, height: toast.height)
    }

    private func applyTheme() {
        view.backgroundColor = UIColor(rgb: theme.bg)
        keyboard.theme = theme
        touchpad.theme = theme
        panel.backgroundColor = UIColor(rgb: theme.bg)
        ticker?.theme = theme
        grip.color = UIColor(rgb: theme.fgDim)
        for b in [switchButton, layoutButton, closeButton] { b.setTitleColor(UIColor(rgb: theme.accent), for: .normal) }
        handle.setTitleColor(UIColor(rgb: theme.accent), for: .normal)
        handle.backgroundColor = UIColor(rgb: theme.surface)
        handle.layer.borderColor = UIColor(rgb: theme.accent).cgColor
        toastLabel.backgroundColor = UIColor(rgb: theme.surface)
        toastLabel.textColor = UIColor(rgb: theme.fg)
        overrideUserInterfaceStyle = theme.light ? .light : .dark
        renderSticky()
        renderStatus()
    }

    // MARK: - Keys and the touchpad

    fileprivate func keyDown(_ code: Int) {
        // A layout's Copy and Paste keys are the app's to do, not the computer's.
        switch code {
        case ClipboardKeys.copy: return shortcut(UsKeys.keyLeftCtrl, UsKeys.keyInsert)
        case ClipboardKeys.paste: return shortcut(UsKeys.keyLeftShift, UsKeys.keyInsert)
        default: break
        }
        if keys.press(code) { link?.send() }
        ticker?.keyDown(code)
    }

    fileprivate func keyUp(_ code: Int) {
        if code == ClipboardKeys.copy || code == ClipboardKeys.paste { return }
        if keys.release(code) { link?.send() }
        ticker?.keyUp(code)
        // A key went out: Ctrl or Shift latched on the touchpad were for it.
        if !UsKeys.modifiers.contains(code) { touchpad.modifiersUsed() }
    }

    fileprivate func padButton(_ code: Int, down: Bool) {
        if down ? keys.press(code) : keys.release(code) { link?.send() }
        // Ctrl and Shift from the touchpad show in the typed text's shortcuts.
        if UsKeys.modifiers.contains(code) {
            if down { ticker?.keyDown(code) } else { ticker?.keyUp(code) }
        }
    }

    fileprivate func padMotion(dx: Float, dy: Float) {
        keys.addMotion(dx: dx, dy: dy)
        link?.send()
    }

    fileprivate func padScroll(v: Float, h: Float) {
        keys.addScroll(v: v, h: h)
        link?.send()
    }

    /// Presses [modifier] + [key] on the computer, a step at a time.
    private func shortcut(_ modifier: Int, _ key: Int) {
        let steps: [@MainActor (KeyState) -> Bool] = [{ $0.press(modifier) }, { $0.press(key) }, { $0.release(key) }, { $0.release(modifier) }]
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(i * KeyboardViewController.shortcutStepMs)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, step(self.keys) else { return }
                    self.link?.send()
                }
            }
        }
    }

    /// Never leave a key held on the computer while we're not looking.
    private func letGo() {
        keyboard.releaseAll()
        touchpad.releaseAll()
        keys.releaseAll()
        link?.send()
    }

    /// Each computer keeps its own touchpad speed: their monitors differ.
    private func applyPadSettings() {
        let speed = model.settings.pointerSpeed(for: host.hostId)
        touchpad.sensitivity = speed.sensitivity
        touchpad.presetName = speed.preset
    }

    private func pickPreset() {
        let page = UIHostingController(rootView: PresetPicker(
            title: "Pointer speed for \(hostName)", current: touchpad.presetName, palette: Palette(theme: theme)
        ) { [weak self] preset in
            guard let self else { return }
            self.model.settings.setPointerSpeed(preset.sensitivity, preset: preset.name, for: self.host.hostId)
            self.applyPadSettings()
        })
        page.sheetPresentationController?.detents = [.large()]
        present(page, animated: true)
    }

    // MARK: - The connection

    private func connect() {
        guard link == nil, UIApplication.shared.applicationState != .background else { return }
        linkGeneration += 1
        let gen = linkGeneration
        let relay = LinkRelay { [weak self] e in
            guard let self, self.linkGeneration == gen else { return }
            self.onLink(e)
        }
        let l = UDPLink(host: host, phoneName: model.settings.phoneName, keys: keys, listener: relay)
        link = l
        l.start()
        // The computer may have a new address; mDNS finds it by host id.
        if discovery == nil {
            let d = Discovery { [weak self] found in
                self?.nearby = found
                self?.routeCandidates()
            }
            discovery = d
            d.start()
        }
        routeCandidates()
    }

    /// Lets go of the computer: BYE, so it releases whatever was held.
    private func disconnect() {
        discovery?.stop()
        discovery = nil
        guard let l = link else { return }
        link = nil
        linkGeneration += 1
        linkState = .connecting
        pingMs = -1
        Background.run { l.stop() }
    }

    private func routeCandidates() {
        guard let l = link else { return }
        for f in nearby where f.hostId == host.hostId { l.addCandidate(f.endpoint) }
    }

    private func onLink(_ e: LinkEvent) {
        switch e {
        case .state(let s, let name):
            linkState = s
            if let name { hostName = name }
            if s == .connected, let l = link {
                if let peer = l.peer { model.hosts.rememberAddress(host.hostId, peer.host) }
                touchpad.supported = l.features & Wire.featurePointer != 0
            }
            if s != .connected { pingMs = -1 }
            renderStatus()
        case .ping(let ms):
            pingMs = ms
            renderStatus()
        case .leds(let leds):
            keyboard.setCapsLock(leds & Ack.ledCaps != 0)
            ticker?.capsLock = leds & Ack.ledCaps != 0
        case .theme(let t):
            let s = model.settings
            guard s.desktopTheme != t || s.desktopThemeFrom != hostName else { return }
            s.desktopTheme = t
            s.desktopThemeFrom = hostName
            // Following the computer: take its new colors now.
            if s.themeId == Themes.fromComputerId {
                theme = Themes.fromComputer(t)
                applyTheme()
            }
        case .clip:
            break // M8
        }
    }

    private func renderStatus() {
        let (color, text): (UInt32, String) = switch linkState {
        case .connected: (theme.ok, hostName + (pingMs >= 0 ? " · \(pingMs) ms" : ""))
        case .connecting: (theme.warn, "Connecting to \(hostName)…")
        case .rejected: (theme.error, "\(hostName) doesn't know this phone. Pair again.")
        }
        var c = UIButton.Configuration.plain()
        c.attributedTitle = AttributedString("●  " + text, attributes: AttributeContainer([
            .font: UIFont.mono(12, bold: true), .foregroundColor: UIColor(rgb: color),
        ]))
        c.titleLineBreakMode = .byTruncatingTail
        c.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        c.background.backgroundColor = UIColor(rgb: theme.surface)
        c.background.cornerRadius = 12
        status.configuration = c
        status.accessibilityLabel = text
        view.setNeedsLayout()
    }

    // MARK: - The top bar

    @objc private func toggleSticky() {
        keyboard.releaseAll()
        keyboard.sticky.toggle()
        model.settings.sticky = keyboard.sticky
        renderSticky()
        toast(keyboard.sticky ? "Sticky keys on: tap a modifier for the next key, twice to lock it" : "Sticky keys off")
    }

    private func renderSticky() {
        stickyButton.setTitleColor(UIColor(rgb: keyboard.sticky ? theme.accent : theme.fgDim), for: .normal)
        stickyButton.accessibilityValue = keyboard.sticky ? "on" : "off"
    }

    private func renderHandle() {
        handle.setTitle(padOpen ? "⌃  keyboard" : "⌄  touchpad", for: .normal)
        handle.accessibilityLabel = padOpen ? "Keyboard" : "Touchpad"
    }

    @objc private func toggleTouchpad() { setPad(!padOpen) }

    @objc private func pickHost() {
        let all = model.hosts.all()
        let nearbyIds = Set(nearby.compactMap(\.hostId))
        let sheet = UIAlertController(title: "Type on", message: nil, preferredStyle: .actionSheet)
        for h in all {
            let current = h.hostId == host.hostId
            let detail = if current && linkState == .connected { pingMs >= 0 ? "connected · \(pingMs) ms" : "connected" }
                else if current { "connecting…" }
                else if nearbyIds.contains(h.hostId) { "nearby" }
                else { "not seen on this network" }
            sheet.addAction(UIAlertAction(title: (current ? "● " : "") + "\(h.name)  ·  \(detail)", style: .default) { [weak self] _ in
                self?.switchTo(h)
            })
        }
        sheet.addAction(UIAlertAction(title: "Pair another…", style: .default) { [weak self] _ in self?.close() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = status
        present(sheet, animated: true)
    }

    /// Move the keyboard to another computer.
    private func switchTo(_ next: HostRecord) {
        guard next.hostId != host.hostId else { return }
        // Let go of everything first: the old computer gets BYE and releases
        // whatever was held; nothing carries over to the new one.
        letGo()
        disconnect()
        host = next
        hostName = next.name
        // Another computer, its own Caps Lock: assume off until it says.
        keyboard.setCapsLock(false)
        ticker?.capsLock = false
        ticker?.clear()
        // Most recently used first on the connect screen.
        model.hosts.put(next)
        applyPadSettings()
        renderStatus()
        connect()
    }

    @objc private func pickLayout() {
        letGo()
        let page = UIHostingController(rootView: LayoutsView(model: model).onDisappear { [weak self] in
            self?.layoutPicked()
        })
        present(page, animated: true)
    }

    private func layoutPicked() {
        keyboard.setLayout(model.layouts.selected(), sink: sink)
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: - The touchpad's panel

    @objc private func headerDragged(_ g: UIPanGestureRecognizer) {
        let y = g.location(in: view).y
        switch g.state {
        case .began: dragBegin(y: y - g.translation(in: view).y)
        case .changed: dragMove(y: y)
        case .ended: dragEnd(velocityY: g.velocity(in: view).y)
        case .cancelled, .failed: dragEnd(velocityY: 0)
        default: break
        }
    }

    private func dragBegin(y: CGFloat) {
        let h = stage.bounds.height
        guard h > 0 else { return }
        animation?.stop()
        panelMoving = true
        panel.isHidden = false
        dragStartY = y
        dragStartShown = panelY + h
    }

    private func dragMove(y: CGFloat) {
        let h = stage.bounds.height
        setPanelY(min(max(dragStartShown + y - dragStartY, 0), h) - h)
    }

    /// Let go: a flick decides, else whichever is nearer; the flick's speed carries on.
    private func dragEnd(velocityY: CGFloat) {
        let h = stage.bounds.height
        let shown = panelY + h
        let flick = KeyboardViewController.flickPointsPerSecond
        let open = velocityY > flick ? true : velocityY < -flick ? false : shown > h / 2
        setPad(open, velocity: velocityY)
    }

    /// Moves the panel and gives the depth: as it covers the keyboard, the
    /// keyboard sinks back (smaller, dimmer) and the panel widens to full
    /// and loses its rounded corners, as a sheet landing over it.
    private func setPanelY(_ y: CGFloat) {
        panelY = y
        let h = stage.bounds.height
        guard h > 0 else { return }
        let p = min(max((y + h) / h, 0), 1)
        let s = 1 - 0.07 * p
        // Scaled about a point 60% of the way down, as on Android.
        keyboard.transform = CGAffineTransform(translationX: 0, y: 0.1 * h * (1 - s)).scaledBy(x: s, y: s)
        keyboard.alpha = 1 - 0.6 * p
        panel.transform = CGAffineTransform(translationX: 0, y: y).scaledBy(x: 0.94 + 0.06 * p, y: 1)
        panel.layer.cornerRadius = 28 * (1 - p)
    }

    /// Fly the panel over the keyboard ([open]) or away above it. [velocity]:
    /// the finger's speed when let go, points per second, so the motion carries on from it.
    private func setPad(_ open: Bool, velocity: CGFloat = 0) {
        let h = stage.bounds.height
        if open && !padOpen { keyboard.releaseAll() }
        if !open && padOpen { touchpad.releaseAll() }
        padOpen = open
        renderHandle()
        panel.isHidden = false
        panelMoving = true
        animation?.stop()
        let from = panelY, to = open ? 0 : -h
        let distance = abs(to - from)
        let ms = abs(velocity) > 1 ? min(max(distance / abs(velocity) * 1000 * 2.2, 160), 360) : 220 + 140 * distance / max(h, 1)
        animation = PanelAnimation(duration: ms / 1000, step: { [weak self] t in
            self?.setPanelY(from + (to - from) * t)
        }, done: { [weak self] in
            guard let self else { return }
            self.panelMoving = false
            if !self.padOpen { self.panel.isHidden = true }
            UIAccessibility.post(notification: .screenChanged, argument: self.padOpen ? self.touchpad : self.keyboard)
        })
    }

    // MARK: - Toasts

    private func toast(_ text: String) {
        toastLabel.text = text
        view.setNeedsLayout()
        view.layoutIfNeeded()
        UIView.animate(withDuration: 0.2) { self.toastLabel.alpha = 1 }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            UIView.animate(withDuration: 0.3) { self?.toastLabel.alpha = 0 }
        }
    }

    /// Between the presses and releases of a Copy or Paste shortcut.
    private static let shortcutStepMs = 25
    /// A swipe of the top bar faster than this throws the touchpad that way.
    private static let flickPointsPerSecond: CGFloat = 400
}

extension KeyboardViewController: UIGestureRecognizerDelegate {
    /// Only a vertical drag of the header moves the panel; taps still reach its buttons.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: view)
        return abs(v.y) > abs(v.x)
    }
}

extension KeyboardViewController: KeyboardPull {
    func begin(y: CGFloat) { dragBegin(y: y) }
    func move(y: CGFloat) { dragMove(y: y) }
    func end(velocityY: CGFloat) { dragEnd(velocityY: velocityY) }
}

extension KeyboardViewController: TouchpadPanelDrag {
    func drag(dy: CGFloat) {
        panelMoving = true
        animation?.stop()
        setPanelY(min(max(dy, -stage.bounds.height), 0))
    }

    func release(dy: CGFloat, flungUp: Bool) {
        setPad(!(flungUp || -dy > stage.bounds.height * 0.25))
    }
}

/// Frames of the panel's flight: fast at first, easing to rest (Android's
/// PathInterpolator(0.05, 0.7, 0.1, 1)), at the display's highest rate.
@MainActor
private final class PanelAnimation {
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private let duration: CFTimeInterval
    private let step: (CGFloat) -> Void
    private let done: () -> Void

    init(duration: CFTimeInterval, step: @escaping (CGFloat) -> Void, done: @escaping () -> Void) {
        self.duration = max(duration, 0.01)
        self.step = step
        self.done = done
        let l = CADisplayLink(target: Frame(self), selector: #selector(Frame.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ l: CADisplayLink) {
        if start == 0 { start = l.timestamp }
        let t = min((l.targetTimestamp - start) / duration, 1)
        step(CGFloat(Self.ease(t)))
        if t >= 1 {
            stop()
            done()
        }
    }

    /// The cubic Bézier (0.05, 0.7), (0.1, 1) at time [x], solved for its y.
    static func ease(_ x: Double) -> Double {
        let (x1, y1, x2, y2) = (0.05, 0.7, 0.1, 1.0)
        func bez(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * a * t * (1 - t) * (1 - t) + 3 * b * t * t * (1 - t) + t * t * t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if bez(mid, x1, x2) < x { lo = mid } else { hi = mid }
        }
        return bez((lo + hi) / 2, y1, y2)
    }

    private final class Frame: NSObject {
        weak var owner: PanelAnimation?

        init(_ owner: PanelAnimation) {
            self.owner = owner
        }

        @MainActor @objc func tick(_ l: CADisplayLink) {
            guard let owner else {
                l.invalidate()
                return
            }
            owner.tick(l)
        }
    }
}

/// The keyboard model's sink, without the model keeping the screen alive.
@MainActor
private final class SinkProxy: KeyboardSink {
    weak var target: KeyboardViewController?

    init(_ target: KeyboardViewController) {
        self.target = target
    }

    nonisolated func keyDown(_ code: Int) { MainActor.assumeIsolated { target?.keyDown(code) } }
    nonisolated func keyUp(_ code: Int) { MainActor.assumeIsolated { target?.keyUp(code) } }
}

/// The touchpad's sink, likewise.
@MainActor
private final class PadSinkProxy: TouchpadSink {
    weak var target: KeyboardViewController?

    init(_ target: KeyboardViewController) {
        self.target = target
    }

    func button(_ code: Int, down: Bool) { target?.padButton(code, down: down) }
    func motion(dx: Float, dy: Float) { target?.padMotion(dx: dx, dy: dy) }
    func scroll(v: Float, h: Float) { target?.padScroll(v: v, h: h) }
}

/// Layout keys that are Copy and Paste: the app does these itself.
enum ClipboardKeys {
    static let copy = 133
    static let paste = 135
}

/// Under the top bar: a handle with arrows pointing down, to show the bar pulls the touchpad down.
final class PullGripView: UIView {
    var color = UIColor.gray {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let cx = bounds.midX, cy = bounds.midY, hw: CGFloat = 18
        color.setFill()
        UIBezierPath(roundedRect: CGRect(x: cx - hw, y: cy - 1.5, width: hw * 2, height: 3), cornerRadius: 1.5).fill()
        color.setStroke()
        let a: CGFloat = 3.5
        for x in [cx - hw - 12, cx + hw + 12] {
            let p = UIBezierPath()
            p.move(to: CGPoint(x: x - a, y: cy - a / 2))
            p.addLine(to: CGPoint(x: x, y: cy + a / 2))
            p.addLine(to: CGPoint(x: x + a, y: cy - a / 2))
            p.lineWidth = 1.6
            p.lineCapStyle = .round
            p.stroke()
        }
    }
}

/// A label with room around its text.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}
