import UIKit

/// A finger's speed from its last moves, points per second: what a flick
/// was doing as it let go, not the whole gesture's average.
struct VelocityTracker {
    private var samples: [(t: TimeInterval, p: CGPoint)] = []
    /// Only moves this recent count.
    private static let window: TimeInterval = 0.1

    mutating func clear() { samples.removeAll(keepingCapacity: true) }

    mutating func add(_ p: CGPoint, at t: TimeInterval) {
        samples.append((t, p))
        samples.removeAll { t - $0.t > VelocityTracker.window }
    }

    /// Every coalesced sample of [touch], in [view]'s window coordinates.
    @MainActor
    mutating func add(_ touch: UITouch, _ event: UIEvent?, in view: UIView) {
        for c in event?.coalescedTouches(for: touch) ?? [touch] { add(c.location(in: view.window), at: c.timestamp) }
    }

    var velocity: CGPoint {
        guard let a = samples.first, let b = samples.last, b.t > a.t else { return .zero }
        let dt = CGFloat(b.t - a.t)
        return CGPoint(x: (b.p.x - a.p.x) / dt, y: (b.p.y - a.p.y) / dt)
    }
}
