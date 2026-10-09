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

        // The key pages start on digits.
        app.keys["strip.1"].firstMatch.tap()
        XCTAssertTrue(eventually { seen.keys.suffix(2) == ["+2", "-2"] }, "\(seen.keys)")
    }

    func testTheUpperRowIsYours() throws {
        func slot(_ i: Int) -> XCUIElement { app.descendants(matching: .any)["slot.\(i)"].firstMatch }
        func page(_ label: String) -> XCUIElement { app.descendants(matching: .any)["strip.\(label)"].firstMatch }
        func drag(_ from: XCUIElement, to: XCUICoordinate, hold: TimeInterval) {
            from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: hold, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        func middle(_ e: XCUIElement) -> XCUICoordinate { e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) }

        // Empty at first, saying how to fill it.
        let edit = app.descendants(matching: .any)["strip.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tap the pencil to choose keys for this row"].exists)
        XCTAssertFalse(slot(0).exists)
        edit.tap()
        XCTAssertTrue(eventually { edit.label == "Done arranging" }, edit.label)
        attach("arranging", app)

        // A tap on the pages takes the first empty slot; a drag up, the slot it's dropped on.
        page("1").tap()
        XCTAssertTrue(eventually { slot(0).label == "1" }, slot(0).label)
        drag(page("2"), to: middle(slot(3)), hold: 0.6)
        XCTAssertTrue(eventually { slot(3).label == "2" }, slot(3).label)
        // Along the row: the key there swaps places.
        drag(slot(0), to: middle(slot(3)), hold: 0.2)
        XCTAssertTrue(eventually { slot(0).label == "2" && slot(3).label == "1" }, "\(slot(0).label) \(slot(3).label)")
        // Down off the row, or a tap on it: the slot empties.
        drag(slot(0), to: page("5").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), hold: 0.2)
        XCTAssertTrue(eventually { slot(0).label == "Empty slot" }, slot(0).label)
        page("3").tap()
        XCTAssertTrue(eventually { slot(0).label == "3" }, slot(0).label)
        slot(0).tap()
        XCTAssertTrue(eventually { slot(0).label == "Empty slot" }, slot(0).label)
        // Nothing typed while arranging.
        XCTAssertFalse(seen.keys.contains("+2") || seen.keys.contains("+3") || seen.keys.contains("+4"), "\(seen.keys)")

        // Done: the row's keys type, and empty slots aren't there.
        edit.tap()
        XCTAssertTrue(eventually { edit.label == "Choose keys for the upper row" }, edit.label)
        XCTAssertFalse(slot(0).exists)
        attach("arranged", app)
        slot(3).tap()
        XCTAssertTrue(eventually { seen.keys.suffix(2) == ["+2", "-2"] }, "\(seen.keys)")

        // Kept for next time.
        app.buttons["keyboard.close"].tap()
        let card = app.buttons["omakey.host.\(server.host.hostId)"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(eventually { slot(3).exists && slot(3).label == "1" }, "after reopening: \(slot(3).exists)")
    }
}
