import Foundation
import OmakeyNet
import UIKit
import OmakeyProtocol

/// What a link reported, on the main thread.
enum LinkEvent: Sendable {
    case state(LinkState, hostName: String?)
    case ping(Int)
    case leds(Int)
    case theme(DesktopTheme)
    case clip(ClipTransfer.Outcome)
}

/// A link's listener that hands every report to [handler] on the main thread.
final class LinkRelay: LinkListener, @unchecked Sendable {
    private let handler: @MainActor (LinkEvent) -> Void

    init(_ handler: @escaping @MainActor (LinkEvent) -> Void) {
        self.handler = handler
    }

    private func post(_ e: LinkEvent) {
        let h = handler
        DispatchQueue.main.async { MainActor.assumeIsolated { h(e) } }
    }

    func linkState(_ state: LinkState, hostName: String?) { post(.state(state, hostName: hostName)) }
    func linkPing(_ ms: Int) { post(.ping(ms)) }
    func linkLeds(_ leds: Int) { post(.leds(leds)) }
    func linkTheme(_ theme: DesktopTheme) { post(.theme(theme)) }
    func linkClip(_ outcome: ClipTransfer.Outcome) { post(.clip(outcome)) }
}

/// Lets a link finish saying BYE after the app leaves the foreground.
@MainActor
enum Background {
    static func run(_ work: @escaping @Sendable () -> Void) {
        let app = UIApplication.shared
        let box = TaskBox()
        box.id = app.beginBackgroundTask { box.end() }
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async { box.end() }
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var id = UIBackgroundTaskIdentifier.invalid

        func end() {
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    guard id != .invalid else { return }
                    UIApplication.shared.endBackgroundTask(id)
                    id = .invalid
                }
            }
        }
    }
}
