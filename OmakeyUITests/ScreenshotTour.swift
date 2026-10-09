import OmakeydStandIn
import XCTest

/// Not a test: the README's screenshots, on a simulator, with the stand-in
/// "omarchy desk" as the computer and no computers from the real network.
/// Run with `scripts/screenshots.sh`.
final class ScreenshotTour: XCTestCase {
    private var server: StandInServer!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMAKEY_SCREENSHOTS"] == "1", "scripts/screenshots.sh only")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        server = try StandInServer(name: "omarchy desk")
        app = XCUIApplication()
        app.launchEnvironment["OMAKEY_RESET"] = UUID().uuidString
        app.launchEnvironment["OMAKEY_SCREENSHOTS"] = "1"
        app.launch()
    }

    override func tearDown() {
        server?.stop()
        XCUIDevice.shared.orientation = .portrait
    }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 1.2)
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testTakeTheScreenshots() throws {
        // Pair: the keyboard comes up.
        open(server.pairingLink(addresses: ["127.0.0.1"]), in: app)
        let alert = app.alerts["Pair with omarchy desk?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Pair"].tap()
        let status = app.buttons["keyboard.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { status.label.hasPrefix("omarchy desk") }, status.label)

        // The landscape keyboard, something typed.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        for k in ["o", "m", "a", "k", "e", "y"] { app.keys["key.\(k)"].firstMatch.tap() }
        shot("2-keyboard")

        // The touchpad, pulled over it.
        app.buttons["keyboard.touchpad"].tap()
        XCTAssertTrue(app.otherElements["touchpad.surface"].waitForExistence(timeout: 5))
        shot("3-touchpad")

        // The connect screen with the computer online.
        app.buttons["keyboard.close"].tap()
        XCUIDevice.shared.orientation = .portrait
        let card = app.buttons["omakey.host.\(server.host.hostId)"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually(8) { card.label.contains("Online") }, card.label)
        shot("1-connect")

        // Layouts, then portrait mode picked there.
        let row = app.descendants(matching: .any)["layout.portrait"].firstMatch
        tap(app.buttons["omakey.layout"], until: row)
        shot("5-layouts")
        row.tap()

        // Portrait mode, with a few keys put in the upper row.
        tap(card, until: app.buttons["keyboard.status"])
        let edit = app.descendants(matching: .any)["strip.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        // To the navigation page first (digits → F-keys → navigation), with long swipes across the strip.
        func swipeStrip(at key: XCUIElement) {
            let y = key.frame.midY, w = app.frame.width
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: w * 0.85, dy: y))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: w * 0.15, dy: y)), withVelocity: .fast, thenHoldForDuration: 0)
        }
        swipeStrip(at: app.descendants(matching: .any)["strip.1"].firstMatch)
        let f5 = app.descendants(matching: .any)["strip.F5"].firstMatch
        XCTAssertTrue(f5.waitForExistence(timeout: 3))
        swipeStrip(at: f5)
        XCTAssertTrue(app.descendants(matching: .any)["strip.Esc"].firstMatch.waitForExistence(timeout: 3))
        edit.tap()
        for k in ["Esc", "Tab", "Home", "End", "←", "→"] { app.descendants(matching: .any)["strip.\(k)"].firstMatch.tap() }
        edit.tap()
        shot("4-portrait")

        // Settings and the themes.
        app.buttons["keyboard.close"].tap()
        let settings = app.buttons["omakey.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        shot("6-settings")
    }
}
