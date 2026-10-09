import OmakeydStandIn
import XCTest

/// The landscape keyboard typing on the omakeyd stand-in.
final class KeyboardTour: XCTestCase {
    private var server: StandInServer!
    private var app: XCUIApplication!
    private let seen = SeenKeys()

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try StandInServer(name: "ui desk")
        let seen = seen
        server.onEvent = { seen.append($0) }
        app = XCUIApplication()
        app.launchEnvironment["OMAKEY_RESET"] = UUID().uuidString
        app.launch()
        open(server.pairingLink(addresses: ["127.0.0.1"]), in: app)
        let alert = app.alerts["Pair with ui desk?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Pair"].tap()
        // The keyboard is landscape either way; turned, the screenshots show all of it.
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        server.stop()
        XCUIDevice.shared.orientation = .portrait
    }

    func testKeysReachTheComputerAndLeavingSaysBye() throws {
        let status = app.buttons["keyboard.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { status.label.hasPrefix("ui desk") }, "status: \(status.label)")
        XCTAssertEqual(server.hellos.last?.platform, 2) // iOS
        // Landscape, whichever way the phone is held.
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "the keyboard should be landscape: \(window)")
        attach("keyboard", app)

        app.keys["key.q"].firstMatch.tap()
        XCTAssertTrue(eventually { seen.keys == ["+16", "-16"] }, "\(seen.keys)")

        // Sticky keys: tap Super, then Space, as Super + Space.
        app.buttons["Sticky keys"].tap()
        app.keys["key.center-super"].firstMatch.tap()
        app.keys["key.space-left"].firstMatch.tap()
        XCTAssertTrue(eventually { seen.keys.suffix(4) == ["+125", "+57", "-57", "-125"] }, "\(seen.keys)")

        app.buttons["keyboard.close"].tap()
        XCTAssertTrue(eventually { server.byes >= 1 })
        XCTAssertTrue(server.heldKeys.isEmpty)
        XCTAssertTrue(app.buttons["omakey.layout"].waitForExistence(timeout: 5))
    }

    func testCapsLockFollowsTheComputersLight() throws {
        let status = app.buttons["keyboard.status"]
        XCTAssertTrue(eventually { status.label.hasPrefix("ui desk") })
        app.keys["key.capslock"].firstMatch.tap()
        XCTAssertTrue(eventually { seen.keys.contains("+58") })
        // The computer's light comes back in the ACK; the keys show capitals.
        XCTAssertTrue(app.keys["key.a"].firstMatch.waitForExistence(timeout: 2))
        attach("caps lock", app)
    }
}
