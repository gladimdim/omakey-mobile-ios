import XCTest

/// Not a test: frames of the keyboard opening and closing with animations
/// slowed down, to look at. Run alone, on a simulator.
final class TransitionFilm: XCTestCase {
    func testFilmTheKeyboardOpeningAndClosing() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMAKEY_FILM"] == "1")
        let app = XCUIApplication()
        app.launchEnvironment["OMAKEY_RESET"] = UUID().uuidString
        app.launchEnvironment["OMAKEY_SLOW_ANIMATIONS"] = "10"
        app.launch()
        let demo = app.buttons["omakey.demo"]
        scroll(to: demo, in: app)
        demo.tap()
        for i in 0..<10 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = String(format: "open %02d", i)
            shot.lifetime = .keepAlways
            add(shot)
            Thread.sleep(forTimeInterval: 0.35)
        }
        app.buttons["keyboard.close"].tap()
        for i in 0..<8 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = String(format: "close %02d", i)
            shot.lifetime = .keepAlways
            add(shot)
            Thread.sleep(forTimeInterval: 0.35)
        }
    }
}
