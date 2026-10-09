import OmakeydStandIn
import XCTest

/// Only the landscape keyboard is landscape: the connect screen and portrait
/// mode follow the phone, and closing a keyboard lets go of the lock.
/// The phone stays upright throughout, so nothing here turns it back.
final class OrientationTour: XCTestCase {
    private var server: StandInServer!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        server = try StandInServer(name: "ui desk")
        app = XCUIApplication()
        app.launchEnvironment["OMAKEY_RESET"] = UUID().uuidString
        app.launch()
    }

    override func tearDown() {
        server.stop()
    }

    private var upright: Bool {
        let w = app.windows.firstMatch.frame
        return w.height > w.width
    }

    private func expectUpright(_ when: String) {
        let ok = eventually(3) { upright }
        if !ok { attach(when, app) }
        XCTAssertTrue(ok, "\(when): \(app.windows.firstMatch.frame)")
    }

    func testOnlyTheLandscapeKeyboardIsLandscape() throws {
        expectUpright("launch")
        open(server.pairingLink(addresses: ["127.0.0.1"]), in: app)
        let alert = app.alerts["Pair with ui desk?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Pair"].tap()
        XCTAssertTrue(app.buttons["keyboard.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(eventually(3) { !self.upright }, "the keyboard is landscape")
        app.buttons["keyboard.close"].tap()
        expectUpright("after closing the landscape keyboard")

        // The connect screen turns with the phone.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(eventually(3) { !self.upright }, "the connect screen follows the phone")
        XCUIDevice.shared.orientation = .portrait
        expectUpright("turned back")

        // Into portrait mode from the keyboard, and out of it again.
        app.buttons["omakey.host.\(server.host.hostId)"].tap()
        XCTAssertTrue(app.buttons["Switch layout"].waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)["layout.portrait"].firstMatch
        tap(app.buttons["Switch layout"], until: row)
        row.tap()
        XCTAssertTrue(app.textViews["portrait.capture"].waitForExistence(timeout: 5))
        expectUpright("portrait mode")
        app.buttons["keyboard.close"].tap()
        expectUpright("after closing portrait mode")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(eventually(3) { !self.upright }, "the connect screen still follows the phone")
        XCUIDevice.shared.orientation = .portrait
    }
}
