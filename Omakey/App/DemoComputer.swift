import Foundation
import OmakeyCore
import OmakeydStandIn
import OmakeyNet
import OmakeyProtocol

/// A computer that lives inside the phone, for trying Omakey without a
/// Linux desktop (and for App Review): the omakeyd stand-in on loopback,
/// speaking the real protocol. It types nothing; the keyboard shows what
/// it received.
@MainActor
final class DemoComputer {
    static let shared = DemoComputer()
    static let name = "Demo computer"

    private var server: StandInServer?
    /// What it received, as it arrives.
    var onEvent: ((StandInServer.Event) -> Void)?

    /// The pairing for it, starting it if needed.
    func start() throws -> HostRecord {
        if let s = server { return s.host }
        let s = try StandInServer(name: DemoComputer.name, bindTo: .loopback())
        s.clipboard = "Hello from the demo computer"
        s.onEvent = { e in
            DispatchQueue.main.async { MainActor.assumeIsolated { DemoComputer.shared.onEvent?(e) } }
        }
        server = s
        return s.host
    }

    func isDemo(_ host: HostRecord) -> Bool { server?.host.hostId == host.hostId }

    /// What it shows for something other than a key (keys are `KeyEcho`'s).
    static func describe(_ e: StandInServer.Event) -> String? {
        switch e {
        case .pointer: return "pointer"
        case .clipboardSet(_, let paste): return paste ? "paste from phone" : "clipboard from phone"
        case .clipboardRead(let copy): return copy ? "copy to phone" : "clipboard to phone"
        case .key, .hello, .layout, .bye, .releasedAll: return nil
        }
    }
}
