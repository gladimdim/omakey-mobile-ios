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
    /// The phone's own layout choice, to put back after a test changed it.
    private var restoreLayout: String?

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMAKEY_PERF"] == "1", "phone performance runs only: scripts/perf-test.sh")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["OMAKEY_STAY_AWAKE"] = "1"
    }

    override func tearDownWithError() throws {
        if let name = restoreLayout {
            restoreLayout = nil
            choose(name)
        }
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

    /// Portrait mode chosen for the test, the phone's own layout choice put back after it.
    private func inPortraitMode() {
        launchToConnect()
        let choice = app.buttons["omakey.layout"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        let original = String(choice.label.drop { $0 == "⌨" || $0 == " " })
        print("layout choice at the start: \(original)")
        guard !original.hasPrefix("Portrait") else { return }
        // Back to the layout it was on in tearDown, whatever happens.
        restoreLayout = original
        let row = app.descendants(matching: .any)["layout.portrait"].firstMatch
        tap(choice, until: row)
        row.tap()
        XCTAssertTrue(eventually { choice.label.contains("Portrait") }, choice.label)
    }

    /// Picks the layout named [name] on the Layouts page, and checks it took.
    private func choose(_ name: String) {
        app.terminate()
        app.launch()
        let choice = app.buttons["omakey.layout"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8))
        let done = app.buttons["Done"]
        tap(choice, until: done)
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        for _ in 0..<14 where !(card.exists && card.isHittable) { app.swipeUp() }
        card.tap()
        XCTAssertTrue(eventually(8) { choice.exists && choice.label.hasSuffix(name) }, "layout choice now: \(choice.label)")
        print("layout choice put back: \(choice.label)")
    }

    /// Not a measurement: picks the layout named in OMAKEY_LAYOUT, to put a phone back as it was.
    func testChooseLayout() throws {
        guard let name = ProcessInfo.processInfo.environment["OMAKEY_LAYOUT"] else {
            throw XCTSkip("TEST_RUNNER_OMAKEY_LAYOUT=<layout name> scripts/perf-test.sh -only-testing:OmakeyUITests/PerformanceTour/testChooseLayout")
        }
        choose(name)
    }

    /// Portrait mode coming up: the touchpad, the key strip and the phone's keyboard.
    func testPortraitOpening() {
        inPortraitMode()
        measure(metrics: [signpost("Keyboard build"), signpost("Keyboard open")], options: options(3)) {
            startMeasuring()
            openDemo()
            stopMeasuring()
            closeKeyboard()
        }
    }

    /// Portrait mode's key pages swiped.
    func testPortraitKeyStrip() {
        inPortraitMode()
        openDemo()
        // Whichever page the strip was left on: a key of it, to swipe from.
        let key = app.keys.matching(NSPredicate(format: "identifier BEGINSWITH 'strip.' AND identifier != 'strip.edit'")).element(boundBy: 2)
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        measure(metrics: [signpost("Strip")], options: options(5, manual: false)) {
            key.swipeLeft(velocity: .fast)
            key.swipeRight(velocity: .fast)
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
