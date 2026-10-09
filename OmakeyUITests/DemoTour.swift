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

        app.keys["key.q"].firstMatch.tap()
        let shown = app.staticTexts["keyboard.demo"]
        XCTAssertTrue(eventually { shown.label.contains("Q") }, shown.label)
        attach("demo", app)

        // Nothing was paired: the demo stays out of the computers list.
        app.buttons["keyboard.close"].tap()
        XCTAssertTrue(app.staticTexts["No computers yet."].waitForExistence(timeout: 5))
    }
}
