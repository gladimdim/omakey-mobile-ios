import OmakeydStandIn
import XCTest

/// The connect screen against an omakeyd stand-in hosted by the test runner
/// itself (the simulator shares the Mac's loopback). Nothing types anywhere.
final class PairingTour: XCTestCase {
    private var server: StandInServer!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try StandInServer(name: "ui desk")
        app = XCUIApplication()
        app.launchEnvironment["OMAKEY_RESET"] = UUID().uuidString
        app.launch()
    }

    override func tearDown() {
        server.stop()
    }

    func testPairingByLinkShowsTheFingerprintAndTheComputerComesOnline() throws {
        XCTAssertTrue(app.staticTexts["No computers yet."].waitForExistence(timeout: 5))
        openLink(server.pairingLink(addresses: ["127.0.0.1"]))

        let alert = app.alerts["Pair with ui desk?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let message = alert.staticTexts.element(matching: NSPredicate(format: "label CONTAINS 'Fingerprint'"))
        XCTAssertTrue(message.label.contains(server.host.fingerprint), message.label)
        XCTAssertTrue(message.label.contains("came from another app"), message.label)
        alert.buttons["Pair"].tap()

        let card = app.buttons["omakey.host.\(server.host.hostId)"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let online = card.staticTexts.element(matching: NSPredicate(format: "label BEGINSWITH '● Online'"))
        XCTAssertTrue(online.waitForExistence(timeout: 8), "the reachability probe should find the stand-in")
        attach("paired")

        // Unlinking takes it off the list.
        card.press(forDuration: 1)
        app.buttons["Unlink"].firstMatch.tap()
        app.alerts["Unlink ui desk?"].buttons["Unlink"].tap()
        XCTAssertTrue(app.staticTexts["No computers yet."].waitForExistence(timeout: 5))
    }

    func testAPairingWithAnotherKeyWarnsLoudly() throws {
        openLink(server.pairingLink(addresses: ["127.0.0.1"]))
        let first = app.alerts["Pair with ui desk?"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.buttons["Pair"].tap()
        XCTAssertTrue(app.buttons["omakey.host.\(server.host.hostId)"].waitForExistence(timeout: 5))

        // The same computer id, a different key: as a link from someone else would be.
        let impostor = try StandInServer(name: "ui desk", identity: .init(
            hostId: server.host.hostId, name: "ui desk", addresses: [], port: 0, deviceId: server.host.deviceId,
            key: [UInt8](repeating: 7, count: 32)))
        defer { impostor.stop() }
        openLink(impostor.pairingLink(addresses: ["127.0.0.1"]))
        let alert = app.alerts["Replace pairing?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let message = alert.staticTexts.element(matching: NSPredicate(format: "label CONTAINS 'replaces your existing pairing'"))
        XCTAssertTrue(message.exists)
        attach("replace warning")
        alert.buttons["Cancel"].tap()
    }

    /// As a link from another app arrives: iOS asks "Open in Omakey?" first.
    private func openLink(_ link: String) {
        app.open(URL(string: link)!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    private func attach(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
