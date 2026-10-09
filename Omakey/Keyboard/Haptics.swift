import UIKit

/// Touch feedback modelled on a MacBook's Force Touch trackpad: a crisp
/// click as a button goes down and a softer one as it comes back up, a
/// deeper double click for a long press (a force click), and faint ticks
/// while scrolling. Keys get the same down and up pair, a little lighter.
///
/// Beyond Android: the touchpad's surface answers a finger landing with
/// a soft touch, and a finger gliding (moving the pointer or scrolling)
/// with the faintest ticks, so it feels live under the finger.
@MainActor
final class Haptics {
    /// Off in Settings: nothing plays.
    var enabled = true

    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let tick = UISelectionFeedbackGenerator()
    /// When the last glide tick played, to keep a fast swipe from becoming a rumble.
    private var lastGlide: CFTimeInterval = 0

    init() {
        // Woken a moment later, not while the keyboard is being built: each prepare is a call into the system.
        DispatchQueue.main.async { [weak self] in self?.prepare() }
    }

    /// A touchpad button went down / came back up.
    func down() { impact(rigid, 0.85) }
    func up() { impact(soft, 0.4) }

    /// A tap that clicks: the down and up of a click in one.
    func tap() {
        impact(rigid, 0.85)
        later(45) { $0.impact($0.soft, 0.4) }
    }

    /// A long press: the deeper second click of a force click.
    func force() {
        impact(heavy, 1)
        later(70) { $0.impact($0.heavy, 0.9) }
    }

    /// A scroll strip passed a wheel notch.
    func notch() {
        guard enabled else { return }
        tick.selectionChanged()
        tick.prepare()
    }

    /// A finger landed on the touchpad: barely there.
    func touch() { impact(soft, 0.45) }

    /// A finger glided a step on the touchpad, moving the pointer or scrolling: fainter still.
    func glide() {
        let now = CACurrentMediaTime()
        guard now - lastGlide >= Haptics.glideGap else { return }
        lastGlide = now
        impact(light, 0.3)
    }

    func key(down: Bool) {
        if down { impact(rigid, 0.6) } else { impact(soft, 0.3) }
    }

    private func impact(_ g: UIImpactFeedbackGenerator, _ intensity: CGFloat) {
        guard enabled else { return }
        g.impactOccurred(intensity: intensity)
        // Keep the Taptic Engine awake for the next one, a cold start adds latency;
        // just this generator, as each prepare is a call into the system.
        g.prepare()
    }

    private func later(_ ms: Int, _ body: @escaping @MainActor (Haptics) -> Void) {
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                body(self)
            }
        }
    }

    private func prepare() {
        rigid.prepare()
        soft.prepare()
        heavy.prepare()
        light.prepare()
        tick.prepare()
    }

    /// At most about 30 glide ticks a second.
    private static let glideGap: CFTimeInterval = 0.033
}
