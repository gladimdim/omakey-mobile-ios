import OmakeyCore
import OmakeydStandIn
import OmakeyNet
import OmakeyProtocol
import SwiftUI
import UIKit

/// The keyboard: landscape, full screen, the screen kept on. While it shows
/// it keeps a live connection to the computer (omakeyd over Wi-Fi). The
/// touchpad slides down over the keys; the computer can be switched from
/// here without leaving the keyboard.
///
/// Portrait mode is the same screen upright: the phone's own keyboard at
/// the bottom (mirrored onto the computer through `TextCapture`), the key
/// strip above it (a row you arrange over swiped pages), and the touchpad
/// filling the rest. No layout, no panel.
@MainActor
final class KeyboardViewController: UIViewController {
    private let model: AppModel
    private var host: HostRecord
    private var theme: Theme
    private let portrait: Bool

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
    /// On the demo computer: what it received, as a computer screen would show
    /// it, in a popup that comes up with the first key and goes after a pause.
    private let demoLabel = PaddedLabel()
    private var demoWords: [String] = []
    private var demoEcho = KeyEcho()
    private var demoHide: DispatchWorkItem?
    private var toastTask: Task<Void, Never>?
    private lazy var sink = SinkProxy(self)
    /// Copy and Paste, with the phone's clipboard when omakeyd has the computer's.
    private lazy var clipboard = ClipboardBridge(
        settings: model.settings, link: { [weak self] in self?.link },
        shortcut: { [weak self] modifier, key in self?.shortcut(modifier, key) },
        hostName: { [weak self] in self?.hostName ?? "" },
        toast: { [weak self] in self?.toast($0) }
    )
    private lazy var padSink = PadSinkProxy(self)
    private var observers: [NSObjectProtocol] = []

    // Portrait mode.
    private var typist: Typist?
    private var capture: TextCapture?
    /// Two rows of digits, F-keys, navigation and system keys above the phone's keyboard, each paged on its own.
    private var keyStrip: KeyStripView?
    private let showKeyboardButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let pasteButton = UIButton(type: .system)
    /// The phone's keyboard hidden: a button in its place, so the touchpad keeps its size.
    private let reopen = UIButton(type: .system)
    /// How much of the screen the phone's keyboard covers now; 0 when it's hidden.
    private var keyboardHeight: CGFloat = 0
    private var lastKeyboardHeight: CGFloat = 0

    // The panel.
    private var padOpen = false
    /// Being dragged or animated: layout passes leave it alone.
    private var panelMoving = false
    private var panelY: CGFloat = 0
    private var dragStartY: CGFloat = 0
    /// How much of the panel showed when the drag began.
    private var dragStartShown: CGFloat = 0
    private var animation: CurveAnimation?

    /// Called once the keyboard is gone, for the connect screen.
    var onClose: (() -> Void)?

    init(model: AppModel, host: HostRecord, portrait: Bool) {
        self.model = model
        self.host = host
        self.portrait = portrait
        hostName = host.name
        theme = model.currentTheme()
        keyboard = KeyboardView(theme: theme)
        touchpad = TouchpadView(theme: theme)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        transitioningDelegate = QuickFade.shared
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - The screen

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { portrait ? .portrait : .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { portrait ? .portrait : .landscapeRight }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    /// A swipe from any edge goes to the keyboard first; a second one to the system.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        haptics.enabled = model.settings.haptics
        touchpad.haptics = haptics
        touchpad.sink = padSink
        touchpad.onSensitivityChanged = { [weak self] v in
            guard let self else { return }
            self.model.settings.setPointerSpeed(v, preset: PointerPresets.custom, for: self.host.hostId)
            self.touchpad.presetName = PointerPresets.custom
        }
        touchpad.onPresetsRequested = { [weak self] in self?.pickPreset() }
        applyPadSettings()
        stage.clipsToBounds = true
        view.addSubview(stage)
        if portrait { buildPortrait() } else { buildLandscape() }

        for (b, title, label, action) in [
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
        if model.settings.typedText {
            let t = TypedTickerView(theme: theme)
            ticker = t
            header.addSubview(t)
        }
        view.addSubview(header)

        toastLabel.font = .mono(13)
        toastLabel.numberOfLines = 0
        toastLabel.textAlignment = .center
        toastLabel.layer.cornerRadius = 16
        toastLabel.layer.masksToBounds = true
        toastLabel.alpha = 0
        view.addSubview(toastLabel)
        if DemoComputer.shared.isDemo(host) {
            demoLabel.font = .mono(12, bold: true)
            demoLabel.textAlignment = .center
            demoLabel.lineBreakMode = .byTruncatingHead
            demoLabel.insets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
            demoLabel.layer.cornerRadius = 14
            demoLabel.layer.masksToBounds = true
            demoLabel.layer.borderWidth = 1
            demoLabel.isUserInteractionEnabled = false
            demoLabel.accessibilityIdentifier = "keyboard.demo"
            demoLabel.isHidden = true
            view.addSubview(demoLabel)
            showDemo("The demo computer shows what it gets here", for: 3)
            DemoComputer.shared.onEvent = { [weak self] e in self?.demoReceived(e) }
        }

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
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.viewIfLoaded?.window != nil, self.presentedViewController == nil else { return }
                    self.showPhoneKeyboardSoon()
                }
            },
            nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
                let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let duration = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                MainActor.assumeIsolated { self?.phoneKeyboardMoved(to: end, duration: duration) }
            },
        ]
    }

    private func buildLandscape() {
        keyboard.haptics = haptics
        keyboard.sticky = model.settings.sticky
        keyboard.pull = self
        keyboard.setLayout(model.layouts.selected(), sink: sink)
        touchpad.panelDrag = self
        stage.addSubview(keyboard)
        panel.isHidden = true
        panel.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        // A sheet over the keyboard: a shadow, and rounded bottom corners while it moves.
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.45
        panel.layer.shadowRadius = 20
        panel.layer.shadowOffset = CGSize(width: 0, height: 8)
        // The touchpad joins its panel once the keyboard is up (`addTouchpad`): even
        // hidden, it would be drawn now, a large picture holding up the keyboard's first frame.
        stage.addSubview(panel)

        handle.titleLabel?.font = .mono(12, bold: true)
        handle.layer.cornerRadius = 12
        handle.layer.borderWidth = 1
        handle.accessibilityIdentifier = "keyboard.touchpad"
        handle.accessibilityHint = "Or swipe the top bar down"
        handle.addTarget(self, action: #selector(toggleTouchpad), for: .touchUpInside)
        header.addSubview(handle)
        stickyButton.setTitle("⇧", for: .normal)
        stickyButton.titleLabel?.font = .mono(15, bold: true)
        stickyButton.accessibilityLabel = "Sticky keys"
        stickyButton.addTarget(self, action: #selector(toggleSticky), for: .touchUpInside)
        header.addSubview(stickyButton)
        header.addSubview(grip)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(headerDragged(_:)))
        pan.delegate = self
        header.addGestureRecognizer(pan)
    }

    private func buildPortrait() {
        touchpad.compact = true
        stage.addSubview(touchpad)
        let t = Typist(sink: sink, gate: self, scheduler: MainScheduler(),
                       preferred: { [weak self] in KeyLayouts.preferred(self?.capture?.language) },
                       onChar: { [weak self] c in self?.ticker?.nextChar = c },
                       // Hold back while omakeyd hasn't acknowledged most of what it can keep.
                       busy: { [weak self] in (self?.keys.unacked ?? 0) > Wire.maxEvents - 8 })
        typist = t
        let c = TextCapture(typist: t)
        c.shortcut = { [weak self] in
            guard let self else { return false }
            return self.keys.held().contains { KeyboardViewController.shortcutModifiers.contains(Int($0)) }
        }
        capture = c
        stage.addSubview(c)
        // The upper row as arranged; the pages as last left, digits at first.
        let strip = KeyStripView(theme: theme, typist: t, sink: sink)
        strip.haptics = haptics
        strip.page = model.settings.stripPage
        strip.onPageChanged = { [weak self] in self?.model.settings.stripPage = $0 }
        strip.slotCodes = model.settings.stripSlots
        strip.onSlotsChanged = { [weak self] in self?.model.settings.stripSlots = $0 }
        view.addSubview(strip)
        keyStrip = strip
        for (b, symbol, label, action) in [
            (showKeyboardButton, "keyboard", "Show the keyboard", #selector(showPhoneKeyboard)),
            (copyButton, "doc.on.doc", "Copy on the computer, to the phone too", #selector(copyOnComputer)),
            (pasteButton, "doc.on.clipboard", "Paste on the computer", #selector(pasteOnComputer)),
        ] {
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
            b.accessibilityLabel = label
            b.addTarget(self, action: action, for: .touchUpInside)
            header.addSubview(b)
        }
        copyButton.accessibilityIdentifier = "keyboard.copy"
        pasteButton.accessibilityIdentifier = "keyboard.paste"
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "keyboard", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34))
        config.imagePlacement = .top
        config.imagePadding = 8
        reopen.configuration = config
        reopen.layer.cornerRadius = 16
        reopen.layer.borderWidth = 1.5
        reopen.accessibilityLabel = "Open the keyboard"
        reopen.accessibilityIdentifier = "keyboard.reopen"
        reopen.addTarget(self, action: #selector(showPhoneKeyboard), for: .touchUpInside)
        view.addSubview(reopen)
        lastKeyboardHeight = (view.window?.bounds.height ?? UIScreen.main.bounds.height) * 0.38
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Portrait mode: the phone's keyboard asked for before the screen fades in, so
        // iOS sets it up first and it rises with the screen, not halfway through its fade.
        capture?.show()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Perf.end(.keyboardOpen)
        if !portrait { DispatchQueue.main.async { [weak self] in self?.addTouchpad() } }
        UIApplication.shared.isIdleTimerDisabled = true
        connect()
        showPhoneKeyboardSoon()
    }

    /// Portrait mode: the phone's keyboard comes back whenever the screen does, as
    /// Android shows it on every focus. A moment late, after whatever was closing.
    private func showPhoneKeyboardSoon() {
        guard let capture else { return }
        capture.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak capture] in
            MainActor.assumeIsolated { _ = capture?.isFirstResponder == true || capture?.becomeFirstResponder() == true }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        letGo()
        disconnect()
        UIApplication.shared.isIdleTimerDisabled = Perf.stayAwake
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
        defer { Perf.end(.keyboardBuild) }
        if portrait { layoutPortrait() } else { layoutLandscape() }
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let toast = toastLabel.sizeThatFits(CGSize(width: safe.width * 0.7, height: 200))
        let bottom = portrait ? min(safe.maxY, view.bounds.maxY - keyboardHeight) - 52 * 2 : safe.maxY
        toastLabel.frame = CGRect(x: safe.midX - toast.width / 2, y: bottom - toast.height - 24, width: toast.width, height: toast.height)
        if demoLabel.superview != nil {
            let fit = demoLabel.sizeThatFits(CGSize(width: safe.width * 0.8, height: 60))
            let w = min(fit.width, safe.width * 0.8)
            // Over the touchpad's hint in portrait; in landscape, under the status, clear of the keys.
            let y = portrait ? stage.frame.minY + stage.bounds.height * 0.45 : header.frame.minY + 34
            demoLabel.bounds.size = CGSize(width: w, height: fit.height)
            demoLabel.center = CGPoint(x: safe.midX, y: y + fit.height / 2)
        }
    }

    /// The demo computer got something: show it, newest last.
    private func demoReceived(_ e: OmakeydStandIn.StandInServer.Event) {
        let word: String?
        switch e {
        case .key(let code, let down): word = demoEcho.key(code, down: down)
        case .layout(let xkb): demoEcho.setLayout(xkb); word = nil
        case .releasedAll, .bye: demoEcho.releaseAll(); word = nil
        default: word = DemoComputer.describe(e)
        }
        guard let word else { return }
        if word == "pointer", demoWords.last == "pointer" { return showDemo(nil) }
        demoWords.append(word)
        if demoWords.count > 40 { demoWords.removeFirst(demoWords.count - 40) }
        showDemo("PC received: " + demoWords.joined(separator: " "))
    }

    /// Bring the demo popup up with [text] (nil: as it is), and take it away
    /// once nothing more has come for [seconds]; the next key starts afresh.
    private func showDemo(_ text: String?, for seconds: TimeInterval = 1.5) {
        if let text { demoLabel.text = text }
        view.setNeedsLayout()
        demoHide?.cancel()
        if demoLabel.isHidden || demoLabel.alpha < 1 {
            demoLabel.layer.removeAllAnimations()
            if demoLabel.isHidden {
                demoLabel.isHidden = false
                demoLabel.alpha = 0
                if !UIAccessibility.isReduceMotionEnabled { demoLabel.transform = CGAffineTransform(translationX: 0, y: 6).scaledBy(x: 0.94, y: 0.94) }
            }
            UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.demoLabel.alpha = 1
                self.demoLabel.transform = .identity
            }
        }
        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.demoLabel.alpha = 0
                if !UIAccessibility.isReduceMotionEnabled { self.demoLabel.transform = CGAffineTransform(translationX: 0, y: -4) }
            } completion: { done in
                guard done, self.demoHide?.isCancelled == false else { return }
                self.demoLabel.isHidden = true
                self.demoLabel.transform = .identity
                self.demoWords.removeAll()
            }
        }
        demoHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: hide)
    }

    private func layoutLandscape() {
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
    }

    private func layoutPortrait() {
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let barH: CGFloat = 32
        header.frame = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: barH + (ticker != nil ? 22 : 0))
        let w = header.bounds.width
        let bw: CGFloat = 38
        showKeyboardButton.frame = CGRect(x: 2, y: 0, width: bw, height: barH)
        // Narrow: the status takes the room between the buttons.
        var x = w - 2
        for b in [closeButton, layoutButton, switchButton, pasteButton, copyButton] {
            x -= bw
            b.frame = CGRect(x: x, y: 0, width: bw, height: barH)
        }
        let room = CGRect(x: showKeyboardButton.frame.maxX + 4, y: 4, width: copyButton.frame.minX - showKeyboardButton.frame.maxX - 8, height: 24)
        let fit = min(status.sizeThatFits(room.size).width, room.width)
        status.frame = CGRect(x: room.midX - fit / 2, y: room.minY, width: fit, height: 24)
        ticker?.frame = CGRect(x: 0, y: barH, width: w, height: 22)

        // The phone's keyboard at the bottom, or the button in its place; the key strip just above.
        let keyboardTop: CGFloat
        if keyboardHeight > 0 {
            keyboardTop = view.bounds.maxY - keyboardHeight
            reopen.isHidden = true
        } else {
            keyboardTop = view.bounds.maxY - max(lastKeyboardHeight, view.safeAreaInsets.bottom + 120)
            reopen.isHidden = false
            reopen.frame = CGRect(x: safe.minX + 12, y: keyboardTop + 8, width: safe.width - 24,
                                  height: view.bounds.maxY - keyboardTop - 8 - max(view.safeAreaInsets.bottom, 12))
        }
        let stripH: CGFloat = 96
        keyStrip?.frame = CGRect(x: safe.minX, y: keyboardTop - stripH, width: safe.width, height: stripH)
        let stripTop = keyboardTop - stripH
        stage.frame = CGRect(x: safe.minX, y: header.frame.maxY, width: safe.width, height: max(stripTop - header.frame.maxY, 0))
        touchpad.frame = stage.bounds
        capture?.frame = CGRect(x: 0, y: stage.bounds.maxY - 1, width: 1, height: 1)
    }

    /// The phone's keyboard came up, went down or changed size.
    private func phoneKeyboardMoved(to frame: CGRect?, duration: Double) {
        guard portrait, let frame, let window = view.window else { return }
        let inView = view.convert(frame, from: window.screen.coordinateSpace)
        let h = max(view.bounds.maxY - inView.minY, 0)
        // Only the keyboard is that tall at the bottom.
        keyboardHeight = h > 120 ? h : 0
        if keyboardHeight > 0 { lastKeyboardHeight = keyboardHeight }
        UIView.animate(withDuration: duration) {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    @objc private func showPhoneKeyboard() { capture?.show() }

    @objc private func copyOnComputer() { clipboard.copy() }

    @objc private func pasteOnComputer() { clipboard.paste() }

    private func applyTheme() {
        view.backgroundColor = UIColor(rgb: theme.bg)
        keyboard.theme = theme
        touchpad.theme = theme
        panel.backgroundColor = UIColor(rgb: theme.bg)
        ticker?.theme = theme
        grip.color = UIColor(rgb: theme.fgDim)
        for b in [switchButton, layoutButton, closeButton] { b.setTitleColor(UIColor(rgb: theme.accent), for: .normal) }
        for b in [showKeyboardButton, copyButton, pasteButton] { b.tintColor = UIColor(rgb: theme.accent) }
        keyStrip?.theme = theme
        reopen.backgroundColor = UIColor(rgb: theme.surface)
        reopen.layer.borderColor = UIColor(rgb: theme.accent).cgColor
        reopen.tintColor = UIColor(rgb: theme.accent)
        reopen.configuration?.attributedTitle = AttributedString("Tap to open the keyboard", attributes: AttributeContainer([
            .font: UIFont.mono(14, bold: true), .foregroundColor: UIColor(rgb: theme.fg),
        ]))
        capture?.keyboardAppearance = theme.light ? .light : .dark
        handle.setTitleColor(UIColor(rgb: theme.accent), for: .normal)
        handle.backgroundColor = UIColor(rgb: theme.surface)
        handle.layer.borderColor = UIColor(rgb: theme.accent).cgColor
        toastLabel.backgroundColor = UIColor(rgb: theme.surface)
        demoLabel.backgroundColor = UIColor(rgb: theme.surface).withAlphaComponent(0.92)
        demoLabel.textColor = UIColor(rgb: theme.ok)
        demoLabel.layer.borderColor = UIColor(rgb: theme.ok).cgColor
        toastLabel.textColor = UIColor(rgb: theme.fg)
        overrideUserInterfaceStyle = theme.light ? .light : .dark
        renderSticky()
        renderStatus()
    }

    // MARK: - Keys and the touchpad

    fileprivate func keyDown(_ code: Int) {
        // A layout's Copy and Paste keys are the app's to do, not the computer's.
        switch code {
        case ClipboardKeys.copy: return clipboard.copy()
        case ClipboardKeys.paste: return clipboard.paste()
        default: break
        }
        if keys.press(code) { link?.send() }
        ticker?.keyDown(code)
    }

    fileprivate func keyUp(_ code: Int) {
        if code == ClipboardKeys.copy || code == ClipboardKeys.paste { return }
        if keys.release(code) { link?.send() }
        ticker?.keyUp(code)
        // A key went out: Ctrl or Shift latched on the touchpad, Super or Alt on the key strip, were for it.
        if !UsKeys.modifiers.contains(code) {
            touchpad.modifiersUsed()
            keyStrip?.modifiersUsed()
        }
    }

    fileprivate func padButton(_ code: Int, down: Bool) {
        if down ? keys.press(code) : keys.release(code) { link?.send() }
        // Ctrl and Shift from the touchpad show in the typed text's shortcuts.
        if UsKeys.modifiers.contains(code) {
            if down { ticker?.keyDown(code) } else { ticker?.keyUp(code) }
        }
        // A click let go: Super or Alt latched on the key strip was for it (Super + drag moves a window).
        if !down && (Wire.btnLeft...Wire.btnMiddle).contains(code) { keyStrip?.modifiersUsed() }
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
        typist?.clear()
        keyStrip?.reset()
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
        case .clip(let outcome):
            clipboard.onOutcome(outcome)
        }
    }

    /// What the status pill shows, as last set.
    private var shownStatus = ""

    private func renderStatus() {
        let (color, text): (UInt32, String) = switch linkState {
        case .connected: (theme.ok, hostName + (pingMs >= 0 ? " · \(pingMs) ms" : ""))
        case .connecting: (theme.warn, "Connecting to \(hostName)…")
        case .rejected: (theme.error, "\(hostName) doesn't know this phone. Pair again.")
        }
        // The ping comes every second, mostly the same: a button's configuration is costly to set again.
        let shown = "\(color) \(theme.surface) \(text)"
        guard shown != shownStatus else { return }
        shownStatus = shown
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
        // The other computer's cursor is somewhere else.
        typist?.clear()
        capture?.reset()
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
        if model.layouts.portrait != portrait {
            // Into or out of portrait mode: the other screen, same computer.
            model.reopenKeyboard(host, replacing: self)
        } else if portrait {
            showPhoneKeyboardSoon()
        } else {
            keyboard.setLayout(model.layouts.selected(), sink: sink)
        }
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

    /// Landscape: the touchpad into its panel, drawn while it's still out of sight.
    private func addTouchpad() {
        guard !portrait, touchpad.superview == nil else { return }
        touchpad.frame = panel.bounds
        panel.addSubview(touchpad)
    }

    private func dragBegin(y: CGFloat) {
        let h = stage.bounds.height
        guard h > 0 else { return }
        addTouchpad()
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
        addTouchpad()
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
        animation = CurveAnimation(duration: ms / 1000, curve: CurveAnimation.fling, step: { [weak self] t in
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
    /// Ctrl, Alt and Super, left and right: held, a key makes a shortcut.
    private static let shortcutModifiers: Set<Int> = [29, 97, 56, 100, 125, 126]
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

extension KeyboardViewController: LayoutGate {
    func current() -> String? { keys.layout }
    /// Nothing typed is still unacknowledged, so a new layout can't reach keys typed before it.
    func canSwitch() -> Bool { keys.unacked == 0 }
    func switchTo(_ layout: String) { keys.layout = layout }
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
