import OmakeyProtocol
import Testing
@testable import Omakey

/// App-level tests; the protocol and keyboard logic are tested in OmakeyKit.
struct AppTests {
    @Test func appLinksTheProtocol() {
        #expect(Wire.platformIOS == 2)
    }
}
