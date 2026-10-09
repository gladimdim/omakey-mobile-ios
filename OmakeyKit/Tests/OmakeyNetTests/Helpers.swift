import Foundation
import OmakeyNet
import OmakeydStandIn
import OmakeyProtocol

/// Everything a link reported, in order.
final class RecordingListener: LinkListener, @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [LinkState] = []
    private var _hostNames: [String] = []
    private var _pings: [Int] = []
    private var _leds: [Int] = []
    private var _themes: [DesktopTheme] = []
    private var _clips: [ClipTransfer.Outcome] = []

    var states: [LinkState] { lock.withLock { _states } }
    var hostNames: [String] { lock.withLock { _hostNames } }
    var pings: [Int] { lock.withLock { _pings } }
    var leds: [Int] { lock.withLock { _leds } }
    var themes: [DesktopTheme] { lock.withLock { _themes } }
    var clips: [ClipTransfer.Outcome] { lock.withLock { _clips } }

    func linkState(_ state: LinkState, hostName: String?) {
        lock.withLock {
            _states.append(state)
            if let hostName { _hostNames.append(hostName) }
        }
    }

    func linkPing(_ ms: Int) { lock.withLock { _pings.append(ms) } }
    func linkLeds(_ leds: Int) { lock.withLock { _leds.append(leds) } }
    func linkTheme(_ theme: DesktopTheme) { lock.withLock { _themes.append(theme) } }
    func linkClip(_ outcome: ClipTransfer.Outcome) { lock.withLock { _clips.append(outcome) } }
}

/// Polls [condition] until it holds or [seconds] pass; true when it held.
func eventually(within seconds: Double = 2, _ condition: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: seconds)
    while Date() < end {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}

/// Key events from a stand-in, collected across threads.
final class Typed: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StandInServer.Event] = []

    func append(_ e: StandInServer.Event) { lock.withLock { events.append(e) } }

    var keys: [StandInServer.Event] {
        lock.withLock { events.filter { if case .key = $0 { return true } else { return false } } }
    }
}
