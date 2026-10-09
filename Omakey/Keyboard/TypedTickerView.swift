import OmakeyCore
import UIKit

/// What was typed, running right to left above the keyboard: each key
/// appears at the right edge and drifts off to the left. Printable keys show
/// as the US layout would type them, others as a symbol (⏎ ⌫ ⇥ ← …), and
/// shortcuts as Ctrl+C, Alt+X, Super+Space. Typing faster than it runs speeds
/// it up, so the newest key is always on screen. Purely local: it reads key
/// codes, not what the computer did with them.
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
            setNeedsDisplay()
        }
    }

    private struct Token {
        let text: String
        let color: UInt32
        let x: CGFloat
        let width: CGFloat
    }

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
        contentMode = .redraw
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
        tokens.append(Token(text: text, color: color, x: x, width: w))
        head = x + w + (text.count > 1 || ink != .fg ? TypedTickerView.gap : 0)
        start()
    }

    func keyUp(_ code: Int) {
        held.remove(code)
    }

    /// Clear the tape, e.g. when the keyboard goes to another computer.
    func clear() {
        tokens.removeAll()
        held.removeAll()
        head = scroll
        setNeedsDisplay()
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
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
            lastFrame = 0
        }
        setNeedsDisplay()
    }

    fileprivate func tick(_ l: CADisplayLink) {
        let dt = lastFrame == 0 ? 0 : min(l.timestamp - lastFrame, 0.1)
        lastFrame = l.timestamp
        // A backlog past the right edge runs faster, so typing never outpaces it.
        let backlog = max(head - scroll, 0)
        scroll += (speed + backlog * TypedTickerView.catchUp) * CGFloat(dt)
        let left = scroll - bounds.width
        tokens.removeAll { $0.x + $0.width < left }
        setNeedsDisplay()
        if tokens.isEmpty {
            link?.invalidate()
            link = nil
        }
    }

    override func draw(_ rect: CGRect) {
        let w = bounds.width
        let left = scroll - w
        let y = (bounds.height - font.lineHeight) / 2
        for t in tokens {
            let x = t.x - left
            if x > w { break }
            (t.text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: UIColor(rgb: t.color)])
        }
        // Fade out towards the left edge.
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let fw = min(w * 0.15, 48)
        let bg = UIColor(rgb: theme.bg)
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [bg.cgColor, bg.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: fw, height: bounds.height))
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: fw, y: 0), options: [])
            ctx.restoreGState()
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
