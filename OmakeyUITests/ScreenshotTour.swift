import OmakeydStandIn
import XCTest

/// Not a test: the README's screenshots, on a simulator, with the stand-in
/// "omarchy desk" as the computer and no computers from the real network.
/// Run with `scripts/screenshots.sh`; names ending in `.landscape` are of a
/// sideways screen, which the script turns upright.
final class ScreenshotTour: XCTestCase {
    private var server: StandInServer!
    private var app: XCUIApplication!

    /// The other built-in layouts, for the gallery (Omakey Pro is the first picture).
    private let gallery = ["classic-qwerty", "corne", "ergodox", "alice", "lily58", "kinesis-advantage", "ferris-sweep",
                           "classic-colemak"]
    private let themes = ["catppuccin-latte", "gruvbox", "rose-pine", "everforest"]

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

    private func shot(_ name: String, settle: TimeInterval = 1.2) {
        Thread.sleep(forTimeInterval: settle)
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private var status: XCUIElement { app.buttons["keyboard.status"] }
    private var hostCard: XCUIElement { app.buttons["omakey.host.\(server.host.hostId)"] }

    private func openKeyboard() {
        tap(hostCard, until: status)
        XCTAssertTrue(eventually { status.label.hasPrefix("omarchy desk") }, status.label)
    }

    private func closeKeyboard() {
        app.buttons["keyboard.close"].tap()
        XCTAssertTrue(hostCard.waitForExistence(timeout: 5))
    }

    /// Picks a layout on the Layouts page, from the connect screen or the keyboard's ⌨.
    private func pick(_ id: String, from button: XCUIElement) {
        let done = app.buttons["Done"]
        tap(button, until: done)
        let card = app.descendants(matching: .any)["layout.\(id)"].firstMatch
        scroll(to: card, in: app)
        card.tap()
        XCTAssertTrue(eventually { !done.exists }, "the Layouts page should close")
    }

    func testTakeTheScreenshots() throws {
        // Pair: the keyboard comes up, on Omakey Pro.
        open(server.pairingLink(addresses: ["127.0.0.1"]), in: app)
        let alert = app.alerts["Pair with omarchy desk?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Pair"].tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { status.label.hasPrefix("omarchy desk") }, status.label)

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        for k in ["o", "m", "a", "k", "e", "y"] { app.keys["key.\(k)"].firstMatch.tap() }
        shot("omakey-pro.landscape")

        app.buttons["keyboard.touchpad"].tap()
        XCTAssertTrue(app.otherElements["touchpad.surface"].waitForExistence(timeout: 5))
        shot("touchpad.landscape")
        app.buttons["keyboard.touchpad"].tap()
        Thread.sleep(forTimeInterval: 0.6)

        // Every other built-in layout, picked on the Layouts page (upright: its cards are tall).
        closeKeyboard()
        for id in gallery {
            XCUIDevice.shared.orientation = .portrait
            pick(id, from: app.buttons["omakey.layout"])
            XCUIDevice.shared.orientation = .landscapeLeft
            openKeyboard()
            shot("layout-\(id).landscape")
            closeKeyboard()
        }
        XCUIDevice.shared.orientation = .portrait
        pick("omakey-pro", from: app.buttons["omakey.layout"])

        // Omakey Pro in other themes, picked in Settings.
        for theme in themes {
            XCUIDevice.shared.orientation = .portrait
            let done = app.buttons["Done"]
            tap(app.buttons["omakey.settings"], until: done)
            let tile = app.buttons["theme.\(theme)"]
            scroll(to: tile, in: app)
            tile.tap()
            done.tap()
            XCTAssertTrue(hostCard.waitForExistence(timeout: 5))
            XCUIDevice.shared.orientation = .landscapeLeft
            openKeyboard()
            shot("theme-\(theme).landscape")
            closeKeyboard()
        }
        XCUIDevice.shared.orientation = .portrait
        let done = app.buttons["Done"]
        tap(app.buttons["omakey.settings"], until: done)
        let tokyo = app.buttons["theme.tokyo-night"]
        scroll(to: tokyo, in: app)
        tokyo.tap()
        done.tap()

        // The connect screen with the computer online, and the Layouts page.
        XCTAssertTrue(hostCard.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually(8) { hostCard.label.contains("Online") }, hostCard.label)
        shot("connect")
        let row = app.descendants(matching: .any)["layout.portrait"].firstMatch
        tap(app.buttons["omakey.layout"], until: row)
        shot("layouts")
        row.tap()

        // Portrait mode: arranging the upper key row, then typing with the iPhone's keyboard.
        openKeyboard()
        let edit = app.descendants(matching: .any)["strip.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        // To the navigation page (digits → F-keys → navigation), with long swipes across the strip.
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
        shot("portrait-arrange", settle: 0.8)
        edit.tap()
        app.typeText("Hello, Omarchy")
        shot("portrait", settle: 0.8)

        // Settings.
        closeKeyboard()
        tap(app.buttons["omakey.settings"], until: app.buttons["Done"])
        shot("settings")
    }
}
