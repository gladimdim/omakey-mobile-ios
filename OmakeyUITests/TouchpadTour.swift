import OmakeydStandIn
import XCTest

/// The touchpad over the keyboard, clicking and moving on the omakeyd stand-in.
final class TouchpadTour: XCTestCase {
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
        XCUIDevice.shared.orientation = .landscapeLeft
        let status = app.buttons["keyboard.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { status.label.hasPrefix("ui desk") }, "status: \(status.label)")
    }

    override func tearDown() {
        server.stop()
        XCUIDevice.shared.orientation = .portrait
    }

    private var pointerMoves: Int {
        seen.all.filter { if case .pointer = $0 { return true } else { return false } }.count
    }

    func testTapDragAndTheOtherClicks() throws {
        app.buttons["keyboard.touchpad"].tap()
        let pad = app.otherElements["touchpad.surface"]
        XCTAssertTrue(pad.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(eventually(2) { pad.isHittable })
        Thread.sleep(forTimeInterval: 0.5) // the panel lands
        attach("touchpad", app)

        // A tap clicks, once the 150 ms drag window has passed.
        let middle = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        middle.tap()
        XCTAssertTrue(eventually { seen.keys.suffix(2) == ["+272", "-272"] }, "\(seen.keys)")

        // One finger moves the pointer.
        middle.press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.4)))
        XCTAssertTrue(eventually { pointerMoves > 0 })

        // Two fingers tapping: a right click. Holding one: a right click too.
        pad.twoFingerTap()
        XCTAssertTrue(eventually { seen.keys.suffix(2) == ["+273", "-273"] }, "\(seen.keys) after \(pad.value ?? "nothing")")
        let before = seen.keys.count
        middle.press(forDuration: 0.8)
        XCTAssertTrue(eventually { seen.keys.count == before + 2 && seen.keys.suffix(2) == ["+273", "-273"] }, "\(seen.keys)")

        // The handle puts it away again, and the keys are back.
        app.buttons["keyboard.touchpad"].tap()
        XCTAssertTrue(eventually(2) { !pad.isHittable })
        app.keys["key.q"].firstMatch.tap()
        XCTAssertTrue(eventually { seen.keys.suffix(2) == ["+16", "-16"] }, "\(seen.keys)")
    }
}
