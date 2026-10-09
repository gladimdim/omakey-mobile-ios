import os
import UIKit

/// Signposts around what has to feel instant: start-up, a keyboard coming
/// up, a key going out, and the touches that move things on screen. For
/// Instruments and the phone performance runs (`PerformanceTour`,
/// `scripts/perf-test.sh`); they cost next to nothing while nothing records.
@MainActor
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.gladimdim.omakey", category: "perf")

    /// Launched with OMAKEY_STAY_AWAKE=1 (the phone performance runs): the phone doesn't sleep.
    static let stayAwake = ProcessInfo.processInfo.environment["OMAKEY_STAY_AWAKE"] == "1"

    enum Span: Hashable {
        /// App init: the stores read, the model built.
        case start
        /// A keyboard asked for, until it's built and laid out.
        case keyboardBuild
        /// A keyboard asked for, until it's up (its presentation done): an animation interval.
        case keyboardOpen
        /// Settings or Layouts asked for, until the page is built.
        case sheet
        /// Settings or Layouts asked for, and the next 0.6 s, its slide up (an animation interval).
        case sheetSlide
        /// Fingers on the keyboard (an animation interval: frames and hitches).
        case typing
        /// Fingers on the touchpad (an animation interval).
        case touchpad
    }

    private static var running: [Span: OSSignpostIntervalState] = [:]

    static func begin(_ span: Span) {
        guard running[span] == nil else { return }
        running[span] = switch span {
        case .start: signposter.beginInterval("Start")
        case .keyboardBuild: signposter.beginInterval("Keyboard build")
        case .keyboardOpen: signposter.beginAnimationInterval("Keyboard open")
        case .sheet: signposter.beginInterval("Sheet")
        case .sheetSlide: signposter.beginAnimationInterval("Sheet slide")
        case .typing: signposter.beginAnimationInterval("Typing")
        case .touchpad: signposter.beginAnimationInterval("Touchpad")
        }
    }

    static func end(_ span: Span) {
        guard let state = running.removeValue(forKey: span) else { return }
        switch span {
        case .start: signposter.endInterval("Start", state)
        case .keyboardBuild: signposter.endInterval("Keyboard build", state)
        case .keyboardOpen: signposter.endInterval("Keyboard open", state)
        case .sheet: signposter.endInterval("Sheet", state)
        case .sheetSlide: signposter.endInterval("Sheet slide", state)
        case .typing: signposter.endInterval("Typing", state)
        case .touchpad: signposter.endInterval("Touchpad", state)
        }
    }
}
