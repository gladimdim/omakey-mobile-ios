import XCTest

/// The layouts page, layout links, and the theme in Settings.
final class LayoutsTour: XCTestCase {
    private var app: XCUIApplication!

    /// A one-key layout "T" (id "t"), as Android's LayoutLink makes it.
    private let link = "omakey://layout?d=JcwxC8IwEAXg__LmCOqYrUMnVxcRkbM5TWjSgzZaQ-l_9xqXx-P47i14ypgow0IS9Vx2kYq8Mww-PE5BBtiDQXAKtuNAibWetc7BZQ97NPAcXj5XqAsT7HX5f_TKvrB7g1JzrsbXjPTgqKZR04nbVk_t5d5gva0_"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["OMAKEY_RESET"] = UUID().uuidString
        app.launch()
    }

    func testPickImportAndRemoveALayout() throws {
        let layoutButton = app.buttons["omakey.layout"]
        XCTAssertTrue(layoutButton.waitForExistence(timeout: 5))
        XCTAssertEqual(layoutButton.label, "⌨  Omakey Pro")

        // Pick Classic QWERTY from the page of previews.
        tap(layoutButton, until: app.descendants(matching: .any)["layout.omakey-pro"].firstMatch)
        attach("layouts", app)
        let qwerty = app.descendants(matching: .any)["layout.classic-qwerty"].firstMatch
        scroll(to: qwerty, in: app)
        qwerty.tap()
        XCTAssertTrue(eventually { layoutButton.label == "⌨  Classic QWERTY" }, layoutButton.label)

        // A layout link: a preview first, then it's the keyboard's.
        open(link, in: app)
        let importButton = app.buttons["import.confirm"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        attach("import preview", app)
        importButton.tap()
        XCTAssertTrue(eventually { layoutButton.label == "⌨  T" }, layoutButton.label)

        // Imported layouts can be removed; the keyboard falls back to the default.
        let card = app.descendants(matching: .any)["layout.t"].firstMatch
        tap(layoutButton, until: app.descendants(matching: .any)["layout.omakey-pro"].firstMatch)
        let remove = app.buttons["Remove"].firstMatch
        scroll(to: remove, in: app)
        remove.tap()
        app.alerts["Remove T?"].buttons["Remove"].tap()
        XCTAssertTrue(eventually { !card.exists })
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(eventually { layoutButton.label == "⌨  Omakey Pro" }, layoutButton.label)
    }

    func testThemesChangeTheScreens() throws {
        let settings = app.buttons["omakey.settings"]
        let nord = app.buttons["theme.nord"]
        tap(settings, until: nord)
        nord.tap()
        XCTAssertTrue(eventually { nord.label.hasSuffix("selected") }, nord.label)
        attach("settings nord", app)
        app.buttons["theme.tokyo-night"].tap()
        XCTAssertTrue(eventually { app.buttons["theme.tokyo-night"].label.hasSuffix("selected") })
    }
}
