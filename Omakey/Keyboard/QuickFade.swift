import UIKit

/// The keyboard comes up, and goes, as a quick fade: the system's full-screen
/// slide takes half a second, longer while the screen also turns.
@MainActor
final class QuickFade: NSObject, UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning {
    /// The presented view controller holds its transitioning delegate weakly.
    static let shared = QuickFade()

    private var presenting = true

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        self.presenting = true
        return self
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        presenting = false
        return self
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        presenting ? 0.2 : 0.16
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let container = context.containerView
        let duration = transitionDuration(using: context)
        let still = UIAccessibility.isReduceMotionEnabled
        if presenting {
            guard let to = context.view(forKey: .to), let toVC = context.viewController(forKey: .to) else {
                return context.completeTransition(false)
            }
            to.frame = context.finalFrame(for: toVC)
            container.addSubview(to)
            to.alpha = 0
            if !still { to.transform = CGAffineTransform(scaleX: 0.97, y: 0.97) }
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
                to.alpha = 1
                to.transform = .identity
            } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
        } else {
            guard let from = context.view(forKey: .from) else { return context.completeTransition(false) }
            // Full screen: the screen underneath was taken out while the keyboard showed; it comes back under it.
            if let to = context.view(forKey: .to), let toVC = context.viewController(forKey: .to) {
                to.frame = context.finalFrame(for: toVC)
                container.insertSubview(to, belowSubview: from)
            }
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn]) {
                from.alpha = 0
                if !still { from.transform = CGAffineTransform(scaleX: 0.98, y: 0.98) }
            } completion: { _ in
                let done = !context.transitionWasCancelled
                if !done {
                    from.alpha = 1
                    from.transform = .identity
                }
                context.completeTransition(done)
            }
        }
    }
}
