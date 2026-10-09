import OmakeydStandIn
import XCTest

/// Portrait mode reached the other ways: from the keyboard's layout button,
/// and from a computer already paired.
final class PortraitRoutesTour: XCTestCase {
    private var server: StandInServer!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try StandInServer(name: "ui desk")
        app = XCUIApplication()
        app.launchEnvironment["OMAKEY_RESET"] = UUID().uuidString
        app.launch()
        open(server.pairingLink(addresses: ["127.0.0.1"]), in: app)
        let alert = app.alerts["Pair with ui desk?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Pair"].tap()
        XCTAssertTrue(app.buttons["keyboard.status"].waitForExistence(timeout: 5))
    }

    override func tearDown() {
        server.stop()
        XCUIDevice.shared.orientation = .portrait
    }

    private func checkPortraitControls(_ name: String) {
        let touchpad = app.otherElements["touchpad.surface"]
        let esc = app.keys["strip.Esc"]
        let status = app.buttons["keyboard.status"]
        let capture = app.textViews["portrait.capture"]
        let ok = eventually(8) {
            touchpad.exists && esc.exists && status.isHittable && status.label.hasPrefix("ui desk")
                && capture.debugDescription.contains("Keyboard Focused")
        }
        attach(name, app)
        XCTAssertTrue(ok, "\(name): touchpad \(touchpad.exists), strip \(esc.exists), status '\(status.label)'\n\(app.debugDescription)")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.height, window.width, "\(name): portrait \(window)")
    }

    func testFromTheKeyboardsLayoutButton() throws {
        // The landscape keyboard is up; pick portrait mode from its ⌨.
        app.buttons["Switch layout"].tap()
        let row = app.descendants(matching: .any)["layout.portrait"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        checkPortraitControls("from the keyboard")
    }

    func testFromAPairedComputer() throws {
        app.buttons["keyboard.close"].tap()
        let row = app.descendants(matching: .any)["layout.portrait"].firstMatch
        tap(app.buttons["omakey.layout"], until: row)
        row.tap()
        let card = app.buttons["omakey.host.\(server.host.hostId)"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        checkPortraitControls("from the list")
    }

    func testHeldSideways() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["keyboard.close"].tap()
        let row = app.descendants(matching: .any)["layout.portrait"].firstMatch
        tap(app.buttons["omakey.layout"], until: row)
        row.tap()
        app.buttons["omakey.host.\(server.host.hostId)"].tap()
        checkPortraitControls("held sideways")
    }
}
