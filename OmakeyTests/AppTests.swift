import OmakeyCore
import OmakeyProtocol
import Testing
@testable import Omakey

/// App-level tests; the protocol and keyboard logic are tested in OmakeyKit.
struct AppTests {
    @Test func appLinksThePackage() throws {
        #expect(Wire.platformIOS == 2)
        let keycodes = try Keycodes.parse(BundledSpec.keycodesJSON())
        // The stock layouts reach the app bundle through OmakeyCore's resources.
        let layouts = try BundledSpec.layoutFiles().map { try LayoutParser.parse($0.json, keycodes: keycodes) }
        #expect(layouts.contains { $0.id == "omakey-pro" })
    }
}
