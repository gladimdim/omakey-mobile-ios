import Foundation
import OmakeydStandIn
import XCTest

/// Key events the stand-in saw, collected across threads.
final class SeenKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StandInServer.Event] = []

    func append(_ e: StandInServer.Event) { lock.withLock { events.append(e) } }

    /// "+16", "-16": presses and releases in order.
    var keys: [String] {
        lock.withLock {
            events.compactMap { if case .key(let code, let down) = $0 { return (down ? "+" : "-") + "\(code)" } else { return nil } }
        }
    }

    var all: [StandInServer.Event] { lock.withLock { events } }
}

extension XCTestCase {
    /// As a link from another app arrives: iOS asks "Open in Omakey?" first.
    func open(_ link: String, in app: XCUIApplication) {
        app.open(URL(string: link)!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    func attach(_ name: String, _ app: XCUIApplication) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Polls [condition] until it holds or [seconds] pass.
    func eventually(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return condition()
    }
}
