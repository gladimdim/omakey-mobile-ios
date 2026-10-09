import XCTest

/// The demo computer inside the phone, as App Review will use it: no
/// desktop, no pairing, and it shows what it gets.
final class DemoTour: XCTestCase {
    func testTheDemoComputerShowsWhatItGets() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OMAKEY_RESET"] = UUID().uuidString
        app.launch()
        let demo = app.buttons["omakey.demo"]
        scroll(to: demo, in: app)
        demo.tap()

        let status = app.buttons["keyboard.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { status.label.hasPrefix("Demo computer") }, status.label)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        // It comes up with what was typed, as typed: q, then Shift (latched) + q.
        let shown = app.staticTexts["keyboard.demo"]
        XCTAssertTrue(eventually(6) { !shown.exists }, "the greeting goes by itself")
        app.keys["key.q"].firstMatch.tap()
        XCTAssertTrue(eventually { shown.exists && shown.label == "PC received: q" }, shown.label)
        app.buttons["Sticky keys"].tap()
        app.keys["key.center-shift"].firstMatch.tap()
        app.keys["key.q"].firstMatch.tap()
        XCTAssertTrue(eventually { shown.label == "PC received: q Q" }, shown.label)
        attach("demo", app)
        // And goes after a pause; the next key starts afresh.
        XCTAssertTrue(eventually(4) { !shown.exists }, "still up: \(shown.label)")
        app.keys["key.q"].firstMatch.tap()
        XCTAssertTrue(eventually { shown.exists && shown.label == "PC received: q" }, shown.label)

        // Nothing was paired: the demo stays out of the computers list.
        app.buttons["keyboard.close"].tap()
        XCTAssertTrue(app.staticTexts["No computers yet."].waitForExistence(timeout: 5))
    }
}
