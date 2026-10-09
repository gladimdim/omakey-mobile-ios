import Foundation
import Testing
@testable import OmakeyNet

/// Browses the real network: only with OMAKEY_LIVE=1 and an omakeyd on the
/// LAN. It only listens to mDNS and resolves addresses; nothing is sent to
/// the computer.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OMAKEY_LIVE"] == "1"))
@MainActor
struct LiveDiscoveryTests {
    @Test func findsAnOmakeydAndItsAddress() async throws {
        var found: [Found] = []
        var status: Discovery.Status?
        let d = Discovery { found = $0 }
        d.onStatus = { status = $0 }
        d.start()
        defer { d.stop() }
        for _ in 0..<100 where found.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        print("live discovery:", status.map { "\($0)" } ?? "no status", found)
        let f = try #require(found.first)
        #expect(f.hostId.map { $0.count == 16 } == true)
        #expect(!f.name.isEmpty)
        #expect(f.endpoint.port > 0)
    }
}
