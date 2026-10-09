import OmakeyCore
import UIKit

/// What was typed, running right to left above the keyboard: each key
/// appears at the right edge and drifts off to the left. Printable keys show
/// as the US layout would type them, others as a symbol (⏎ ⌫ ⇥ ← …), and
/// shortcuts as Ctrl+C, Alt+X, Super+Space. Typing faster than it runs speeds
/// it up, so the newest key is always on screen. Purely local: it reads key
/// codes, not what the computer did with them.
///
/// Each token is a text layer drawn once, on a tape that slides: a frame
/// moves the tape, nothing is drawn again, so it runs at 120 Hz for little.
@MainActor
final class TypedTickerView: UIView {
    /// Base speed in points per second.
    var speed: CGFloat = 70

    /// The computer's Caps Lock, as it reports it.
    var capsLock = false

    /// What the next printable key really types, when the phone knows better
    /// than the US layout (a Ukrainian letter from the phone's keyboard).
    var nextChar: Character?

    var theme: Theme {
        didSet {
            backgroundColor = UIColor(rgb: theme.bg)
            paintFade()
        }
    }

    private struct Token {
        let layer: CATextLayer
        let x: CGFloat
        let width: CGFloat
    }

    /// The tokens, at their tape positions; slid left as the tape runs.
    private let tape = CALayer()
    /// Fades the tape out towards the left edge.
    private let fade = CAGradientLayer()

    private enum Ink { case fg, layer, accent }

    private var tokens: [Token] = []
    /// Tape position of the view's right edge; the tape only ever moves forwards.
    private var scroll: CGFloat = 0
    /// Where the next token goes.
    private var head: CGFloat = 0
    private var lastFrame: CFTimeInterval = 0
    private var held = Set<Int>()
    private var link: CADisplayLink?
    private let font = UIFont.mono(13, bold: true)

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = UIColor(rgb: theme.bg)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = true
        layer.addSublayer(tape)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(fade)
        paintFade()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = CGRect(x: 0, y: 0, width: min(bounds.width * 0.15, 48), height: bounds.height)
        let y = (bounds.height - font.lineHeight) / 2
        for t in tokens { t.layer.frame.origin.y = y }
        slide()
        CATransaction.commit()
    }

    private func paintFade() {
        let bg = UIColor(rgb: theme.bg)
        fade.colors = [bg.cgColor, bg.withAlphaComponent(0).cgColor]
    }

    /// The tape where `scroll` says: a token at tape position x shows at x - (scroll - width).
    private func slide() {
        tape.transform = CATransform3DMakeTranslation(bounds.width - scroll, 0, 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func keyDown(_ code: Int) {
        if TypedTickerView.modifiers.contains(code) {
            held.insert(code)
            return
        }
        if code == 58 { capsLock.toggle() }
        guard let (text, ink) = describe(code) else { return }
        let color: UInt32 = switch ink {
        case .fg: theme.fg
        case .layer: theme.layer
        case .accent: theme.accent
        }
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        // Caught up with the text: start again at the right edge.
        let x = max(head, scroll)
        let l = CATextLayer()
        l.string = text
        l.font = font
        l.fontSize = font.pointSize
        l.foregroundColor = UIColor(rgb: color).cgColor
        l.contentsScale = traitCollection.displayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.frame = CGRect(x: x, y: (bounds.height - font.lineHeight) / 2, width: ceil(w) + 2, height: ceil(font.lineHeight))
        tape.addSublayer(l)
        CATransaction.commit()
        tokens.append(Token(layer: l, x: x, width: w))
        head = x + w + (text.count > 1 || ink != .fg ? TypedTickerView.gap : 0)
        start()
    }

    func keyUp(_ code: Int) {
        held.remove(code)
    }

    /// Clear the tape, e.g. when the keyboard goes to another computer.
    func clear() {
        for t in tokens { t.layer.removeFromSuperlayer() }
        tokens.removeAll()
        held.removeAll()
        head = scroll
    }

    private func describe(_ code: Int) -> (String, Ink)? {
        let ctrl = held.contains(29) || held.contains(97)
        let alt = held.contains(56) || held.contains(100)
        let meta = held.contains(125) || held.contains(126)
        let shift = held.contains(42) || held.contains(54)
        let printable = UsKeys.printable[code]
        // Meant for this key only, whatever it turns out to be.
        let really = nextChar
        nextChar = nil
        if ctrl || alt || meta {
            guard let name = (code != UsKeys.keySpace ? printable.map { String($0.0).uppercased() } : nil) ?? TypedTickerView.symbols[code]
            else { return nil }
            let mods = (meta ? "Super+" : "") + (ctrl ? "Ctrl+" : "") + (alt ? "Alt+" : "") + (shift ? "Shift+" : "")
            return (mods + name, .layer)
        }
        if let really, really != "\n", really != "\t" { return (String(really), .fg) }
        if let (plain, shifted) = printable {
            let upper = plain.isLetter && plain.isASCII ? shift != capsLock : shift
            return (String(upper ? shifted : plain), .fg)
        }
        return TypedTickerView.symbols[code].map { ($0, .accent) }
    }

    // MARK: - Animation

    private func start() {
        if link == nil {
            let l = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
            lastFrame = 0
        }
    }

    fileprivate func tick(_ l: CADisplayLink) {
        let dt = lastFrame == 0 ? 0 : min(l.timestamp - lastFrame, 0.1)
        lastFrame = l.timestamp
        // A backlog past the right edge runs faster, so typing never outpaces it.
        let backlog = max(head - scroll, 0)
        scroll += (speed + backlog * TypedTickerView.catchUp) * CGFloat(dt)
        let left = scroll - bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tokens.removeAll { t in
            guard t.x + t.width < left else { return false }
            t.layer.removeFromSuperlayer()
            return true
        }
        slide()
        CATransaction.commit()
        if tokens.isEmpty {
            link?.invalidate()
            link = nil
        }
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    private static let gap: CGFloat = 4
    /// Extra speed per point of backlog, per second.
    private static let catchUp: CGFloat = 3
    private static let modifiers: Set<Int> = [29, 97, 42, 54, 56, 100, 125, 126]
    private static let symbols: [Int: String] = {
        var m: [Int: String] = [1: "⎋", 14: "⌫", 15: "⇥", 28: "⏎", 57: "Space", 103: "↑", 108: "↓", 105: "←", 106: "→",
                                102: "Home", 107: "End", 104: "PgUp", 109: "PgDn", 110: "Ins", 111: "Del", 87: "F11", 88: "F12"]
        for i in 0..<10 { m[59 + i] = "F\(i + 1)" }
        return m
    }()
}

/// The display link's target, holding the view weakly so the link doesn't keep it alive.
private final class Ticker: NSObject {
    weak var view: TypedTickerView?

    init(_ view: TypedTickerView) {
        self.view = view
    }

    @MainActor @objc func tick(_ l: CADisplayLink) {
        guard let view else {
            l.invalidate()
            return
        }
        view.tick(l)
    }
}
