import OmakeyCore
import OmakeyNet
import OmakeyProtocol
import SwiftUI
import UIKit

/// The keyboard: landscape, full screen, the screen kept on. While it shows
/// it keeps a live connection to the computer (omakeyd over Wi-Fi). The
/// computer can be switched from here without leaving the keyboard.
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
    private let haptics = Haptics()
    private var ticker: TypedTickerView?
    private let status = UIButton(type: .system)
    private let stickyButton = UIButton(type: .system)
    private let switchButton = UIButton(type: .system)
    private let layoutButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let grip = PullGripView()
    private let toastLabel = PaddedLabel()
    private var toastTask: Task<Void, Never>?
    private lazy var sink = SinkProxy(self)
    private var observers: [NSObjectProtocol] = []

    /// Called once the keyboard is gone, for the connect screen.
    var onClose: (() -> Void)?

    init(model: AppModel, host: HostRecord) {
        self.model = model
        self.host = host
        hostName = host.name
        theme = model.currentTheme()
        keyboard = KeyboardView(theme: theme)
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
        keyboard.haptics = haptics
        haptics.enabled = model.settings.haptics
        keyboard.sticky = model.settings.sticky
        keyboard.setLayout(model.layouts.selected(), sink: sink)
        view.addSubview(keyboard)

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
            view.addSubview(b)
        }
        closeButton.accessibilityIdentifier = "keyboard.close"
        status.addTarget(self, action: #selector(pickHost), for: .touchUpInside)
        status.accessibilityIdentifier = "keyboard.status"
        view.addSubview(status)
        view.addSubview(grip)
        if model.settings.typedText {
            let t = TypedTickerView(theme: theme)
            ticker = t
            view.addSubview(t)
        }
        toastLabel.font = .mono(13)
        toastLabel.numberOfLines = 0
        toastLabel.textAlignment = .center
        toastLabel.layer.cornerRadius = 16
        toastLabel.layer.masksToBounds = true
        toastLabel.alpha = 0
        view.addSubview(toastLabel)

        applyTheme()
        renderSticky()
        renderStatus()

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
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        onClose?()
        onClose = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let barH: CGFloat = 32
        // The buttons on the right of the top bar.
        var x = safe.maxX - 4
        for b in [closeButton, layoutButton, switchButton, stickyButton] {
            let w: CGFloat = 44
            x -= w
            b.frame = CGRect(x: x, y: safe.minY, width: w, height: barH)
        }
        // The connection status, centered: as wide as the room between the edges and the buttons.
        let side = max(safe.maxX - stickyButton.frame.minX, 16) + 8
        let maxW = max(safe.width - side * 2, 80)
        let fit = status.sizeThatFits(CGSize(width: maxW, height: 24))
        let w = min(fit.width, maxW)
        status.frame = CGRect(x: safe.midX - w / 2, y: safe.minY + 4, width: w, height: 24)
        var y = safe.minY + barH
        grip.frame = CGRect(x: safe.minX, y: y, width: safe.width, height: 10)
        y += 10
        if let ticker {
            ticker.frame = CGRect(x: safe.minX, y: y, width: safe.width, height: 22)
            y += 22
        }
        keyboard.frame = CGRect(x: safe.minX, y: y, width: safe.width, height: safe.maxY - y)
        let toast = toastLabel.sizeThatFits(CGSize(width: safe.width * 0.7, height: 200))
        toastLabel.frame = CGRect(x: safe.midX - toast.width / 2, y: safe.maxY - toast.height - 24, width: toast.width, height: toast.height)
    }

    private func applyTheme() {
        view.backgroundColor = UIColor(rgb: theme.bg)
        keyboard.theme = theme
        ticker?.theme = theme
        grip.color = UIColor(rgb: theme.fgDim)
        for b in [switchButton, layoutButton, closeButton] { b.setTitleColor(UIColor(rgb: theme.accent), for: .normal) }
        toastLabel.backgroundColor = UIColor(rgb: theme.surface)
        toastLabel.textColor = UIColor(rgb: theme.fg)
        overrideUserInterfaceStyle = theme.light ? .light : .dark
        renderSticky()
        renderStatus()
    }

    // MARK: - Keys

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
        keys.releaseAll()
        link?.send()
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
            if s == .connected, let peer = link?.peer {
                model.hosts.rememberAddress(host.hostId, peer.host)
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
