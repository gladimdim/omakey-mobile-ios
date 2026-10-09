import XCTest

/// How fast it is on a real phone: start-up, the keyboard and the pages
/// coming up, scrolling, typing and the touchpad. Run on a connected iPhone
/// with `scripts/perf-test.sh` (Release build); skipped otherwise.
///
/// Safe on someone's own phone: only the demo computer inside the app,
/// never a reset, so pairings and settings stay as they are, and nothing
/// is picked or changed. The app keeps the phone awake meanwhile.
final class PerformanceTour: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMAKEY_PERF"] == "1", "phone performance runs only: scripts/perf-test.sh")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["OMAKEY_STAY_AWAKE"] = "1"
    }

    private func signpost(_ name: String) -> XCTOSSignpostMetric {
        XCTOSSignpostMetric(subsystem: "com.gladimdim.omakey", category: "perf", name: name)
    }

    private func options(_ iterations: Int, manual: Bool = true) -> XCTMeasureOptions {
        let o = XCTMeasureOptions()
        o.iterationCount = iterations
        if manual { o.invocationOptions = [.manuallyStart, .manuallyStop] }
        return o
    }

    private var demo: XCUIElement { app.buttons["omakey.demo"] }

    private func launchToConnect() {
        app.launch()
        scroll(to: demo, in: app)
    }

    private func openDemo() {
        let status = app.buttons["keyboard.status"]
        // The list above can still grow as the phone's own computers answer: tap until it opens.
        tap(demo, until: status)
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertTrue(eventually(8) { status.label.hasPrefix("Demo computer") }, status.label)
    }

    private func closeKeyboard() {
        app.buttons["keyboard.close"].tap()
        XCTAssertTrue(demo.waitForExistence(timeout: 8))
    }

    func testStartUp() {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true), signpost("Start")], options: options(5, manual: false)) {
            app.launch()
        }
    }

    func testOpeningTheKeyboard() {
        launchToConnect()
        measure(metrics: [signpost("Keyboard build"), signpost("Keyboard open")], options: options(5)) {
            startMeasuring()
            openDemo()
            stopMeasuring()
            closeKeyboard()
        }
    }

    func testOpeningSettings() {
        launchToConnect()
        let settings = app.buttons["omakey.settings"]
        measure(metrics: [signpost("Sheet"), signpost("Sheet slide")], options: options(5)) {
            startMeasuring()
            settings.tap()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
            stopMeasuring()
            app.buttons["Done"].tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
        }
    }

    func testOpeningAndScrollingLayouts() {
        launchToConnect()
        let layouts = app.buttons["omakey.layout"]
        measure(metrics: [signpost("Sheet"), signpost("Sheet slide"), XCTOSSignpostMetric.scrollDraggingMetric, XCTOSSignpostMetric.scrollDecelerationMetric],
                options: options(5)) {
            startMeasuring()
            layouts.tap()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            for _ in 0..<3 { app.swipeUp(velocity: .fast) }
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
            stopMeasuring()
            done.tap()
            XCTAssertTrue(layouts.waitForExistence(timeout: 5))
        }
    }

    func testTyping() throws {
        launchToConnect()
        openDemo()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let keys = ["q", "w", "e", "r", "t", "a", "s", "d", "f", "g"].map { app.keys["key.\($0)"].firstMatch }
        guard keys[0].waitForExistence(timeout: 3) else {
            throw XCTSkip("the phone's own layout choice is portrait mode: no keyboard keys to tap")
        }
        var i = 0
        measure(metrics: [signpost("Key"), signpost("Key model"), signpost("Key haptic"), signpost("Key draw"), signpost("Typing")],
                options: options(10, manual: false)) {
            keys[i % keys.count].tap()
            keys[(i + 3) % keys.count].tap()
            i += 1
        }
    }

    func testTouchpad() throws {
        launchToConnect()
        openDemo()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let surface = app.otherElements["touchpad.surface"]
        if !surface.exists {
            let pull = app.buttons["keyboard.touchpad"]
            guard pull.waitForExistence(timeout: 3) else { throw XCTSkip("no touchpad button") }
            pull.tap()
        }
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        let from = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let to = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4))
        measure(metrics: [signpost("Touchpad")],
                options: options(5, manual: false)) {
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0)
            to.press(forDuration: 0.05, thenDragTo: from, withVelocity: .default, thenHoldForDuration: 0)
        }
    }
}
