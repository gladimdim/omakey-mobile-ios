import OmakeydStandIn
import XCTest

/// Portrait mode: the phone's own keyboard typing on the omakeyd stand-in,
/// with the key strips and the compact touchpad.
final class PortraitTour: XCTestCase {
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
        // Portrait mode is picked like a layout.
        let row = app.descendants(matching: .any)["layout.portrait"].firstMatch
        tap(app.buttons["omakey.layout"], until: row)
        row.tap()
        XCTAssertTrue(app.buttons["omakey.layout"].waitForExistence(timeout: 5))
        open(server.pairingLink(addresses: ["127.0.0.1"]), in: app)
        let alert = app.alerts["Pair with ui desk?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Pair"].tap()
        let status = app.buttons["keyboard.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { status.label.hasPrefix("ui desk") }, "status: \(status.label)")
    }

    override func tearDown() {
        server.stop()
    }

    func testThePhonesKeyboardTypesOnTheComputer() throws {
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.height, window.width, "portrait: \(window)")
        // The phone's keyboard comes up by itself: the hidden line has the focus.
        let capture = app.textViews["portrait.capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)
        attach("portrait", app)
        // (`hasFocus` is the focus engine's; the keyboard's focus shows in the description.)
        XCTAssertTrue(eventually { capture.debugDescription.contains("Keyboard Focused") }, "the phone's keyboard should be up")

        app.typeText("hi")
        XCTAssertTrue(eventually { seen.keys == ["+35", "-35", "+23", "-23"] }, "\(seen.keys)")
        XCTAssertTrue(seen.all.contains(.layout("us")), "the keys go with the layout that types them")

        // Return is Enter, and the line starts again: Backspace now goes to the computer.
        app.typeText("\n")
        XCTAssertTrue(eventually { seen.keys.suffix(2) == ["+28", "-28"] }, "\(seen.keys)")
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(eventually { seen.keys.suffix(2) == ["+14", "-14"] }, "\(seen.keys)")

        // The upper key strip starts on navigation.
        app.keys["strip.Esc"].firstMatch.tap()
        XCTAssertTrue(eventually { seen.keys.suffix(2) == ["+1", "-1"] }, "\(seen.keys)")
    }
}
