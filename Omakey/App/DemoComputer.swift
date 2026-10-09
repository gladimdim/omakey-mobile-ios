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

    /// "Super", "A", "←": how a key reads.
    static func describe(_ e: StandInServer.Event) -> String? {
        switch e {
        case .key(let code, let down):
            guard down else { return nil }
            return KeyNames.shared.label(code)
        case .pointer: return "pointer"
        case .clipboardSet(_, let paste): return paste ? "paste from phone" : "clipboard from phone"
        case .clipboardRead(let copy): return copy ? "copy to phone" : "clipboard to phone"
        case .hello, .layout, .bye, .releasedAll: return nil
        }
    }
}

/// Key labels by code, from keycodes.json: what a key says on a keyboard.
@MainActor
final class KeyNames {
    static let shared = KeyNames()
    private var labels: [Int: String] = [:]

    private init() {
        guard let root = try? JSONSerialization.jsonObject(with: Data(BundledSpec.keycodesJSON().utf8)) as? [String: Any],
              let keys = root["keys"] as? [[String: Any]] else { return }
        for k in keys {
            guard let code = (k["code"] as? NSNumber)?.intValue, labels[code] == nil else { continue }
            let name = k["name"] as? String ?? "code \(code)"
            labels[code] = (k["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name.replacingOccurrences(of: "KEY_", with: "")
        }
        labels[Wire.btnLeft] = "left click"
        labels[Wire.btnRight] = "right click"
        labels[Wire.btnMiddle] = "middle click"
    }

    func label(_ code: Int) -> String { labels[code] ?? "code \(code)" }
}
