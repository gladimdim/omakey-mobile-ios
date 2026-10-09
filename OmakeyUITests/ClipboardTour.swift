import OmakeydStandIn
import XCTest

/// Copy and Paste between the phone and the omakeyd stand-in's clipboard.
final class ClipboardTour: XCTestCase {
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

    func testCopyBringsTheComputersTextAndPasteSendsOnlyWhatsNew() throws {
        // Copy: what's selected on the computer, onto the phone.
        server.clipboard = "from the desk ✓"
        app.keys["key.copy"].firstMatch.tap()
        XCTAssertTrue(eventually { seen.all.contains(.clipboardRead(copy: true)) })
        XCTAssertTrue(app.staticTexts["Copied from ui desk"].waitForExistence(timeout: 3))

        // Paste with nothing newer on the phone: the computer's own paste, without reading the phone's.
        app.keys["key.paste"].firstMatch.tap()
        XCTAssertTrue(eventually { seen.keys.suffix(4) == ["+42", "+110", "-110", "-42"] }, "\(seen.keys)")

        // The phone copies something: Paste brings it along.
        UIPasteboard.general.string = "from the phone"
        app.keys["key.paste"].firstMatch.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            // The iOS 27.0 simulator fails to show "Allow Paste?" for any app's read (its log:
            // "Error returned while setting TCC value"), so the read comes back empty. It works on
            // iOS 26.4. Check on an iOS 27 phone; this goes green by itself once the prompt shows.
            XCTExpectFailure("iOS 27 simulator: no paste prompt", options: .nonStrict())
        }
        XCTAssertTrue(eventually { seen.all.contains(.clipboardSet(text: "from the phone", paste: true)) }, "\(seen.all)")
    }
}
