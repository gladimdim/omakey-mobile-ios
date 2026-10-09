import UIKit

/// Touch feedback modelled on a MacBook's Force Touch trackpad: a crisp
/// click as a button goes down and a softer one as it comes back up, a
/// deeper double click for a long press (a force click), and faint ticks
/// while scrolling. Keys get the same down and up pair, a little lighter.
@MainActor
final class Haptics {
    /// Off in Settings: nothing plays.
    var enabled = true

    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let tick = UISelectionFeedbackGenerator()

    init() {
        prepare()
    }

    /// A touchpad button went down / came back up.
    func down() { play { rigid.impactOccurred(intensity: 0.85) } }
    func up() { play { soft.impactOccurred(intensity: 0.4) } }

    /// A tap that clicks: the down and up of a click in one.
    func tap() {
        play { rigid.impactOccurred(intensity: 0.85) }
        later(45) { $0.soft.impactOccurred(intensity: 0.4) }
    }

    /// A long press: the deeper second click of a force click.
    func force() {
        play { heavy.impactOccurred(intensity: 1) }
        later(70) { $0.heavy.impactOccurred(intensity: 0.9) }
    }

    /// A scroll strip passed a wheel notch.
    func notch() { play { tick.selectionChanged() } }

    func key(down: Bool) {
        play { down ? rigid.impactOccurred(intensity: 0.6) : soft.impactOccurred(intensity: 0.3) }
    }

    private func play(_ body: () -> Void) {
        guard enabled else { return }
        body()
        // Keep the Taptic Engine awake for the next one: a cold start adds latency.
        prepare()
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
        tick.prepare()
    }
}
