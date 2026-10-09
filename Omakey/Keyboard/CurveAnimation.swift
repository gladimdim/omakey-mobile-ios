import UIKit

/// A value from 0 to 1 over [duration], eased by a cubic Bézier as
/// Android's PathInterpolator does, a step every display frame at up to
/// 120 Hz. Stopping it leaves the value where it was.
@MainActor
final class CurveAnimation {
    typealias Curve = (x1: Double, y1: Double, x2: Double, y2: Double)
    /// Fast at first, easing to rest: a sheet thrown and landing.
    static let fling: Curve = (0.05, 0.7, 0.1, 1)
    /// Starts at the finger's speed and eases in, like a sheet let go.
    static let settle: Curve = (0.2, 0, 0, 1)

    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private let duration: CFTimeInterval
    private let curve: Curve
    private let step: (CGFloat) -> Void
    private let done: () -> Void

    init(duration: CFTimeInterval, curve: Curve, step: @escaping (CGFloat) -> Void, done: @escaping () -> Void = {}) {
        self.duration = max(duration, 0.01)
        self.curve = curve
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
        step(CGFloat(Self.ease(t, curve)))
        if t >= 1 {
            stop()
            done()
        }
    }

    /// The curve at time [x], solved for its y.
    static func ease(_ x: Double, _ c: Curve) -> Double {
        func bez(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * a * t * (1 - t) * (1 - t) + 3 * b * t * t * (1 - t) + t * t * t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if bez(mid, c.x1, c.x2) < x { lo = mid } else { hi = mid }
        }
        return bez((lo + hi) / 2, c.y1, c.y2)
    }

    private final class Frame: NSObject {
        weak var owner: CurveAnimation?

        init(_ owner: CurveAnimation) {
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
