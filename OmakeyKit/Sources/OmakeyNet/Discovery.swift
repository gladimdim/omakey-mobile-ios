import Foundation
import Network
import OmakeyProtocol

/// A computer advertising `_omakey._udp`.
public struct Found: Equatable, Sendable {
    public let serviceName: String
    /// The TXT record's `id`, lowercased; nil from something that isn't omakeyd.
    public let hostId: String?
    public let name: String
    public let endpoint: Endpoint
}

/// Browses mDNS for omakeyd and resolves each service to an IPv4 address
/// (a UDP `NWConnection` resolves without sending anything). Results and
/// status go to the callbacks on the main thread.
@MainActor
public final class Discovery {
    public enum Status: Equatable, Sendable {
        case browsing
        /// Local Network access is off for the app: nothing on the LAN can be reached.
        case denied
        case failed
    }

    private let onChange: @MainActor ([Found]) -> Void
    public var onStatus: (@MainActor (Status) -> Void)?
    private var browser: NWBrowser?
    private var found: [String: Found] = [:]
    private var resolving: [String: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.gladimdim.omakey.discovery")

    public init(onChange: @escaping @MainActor ([Found]) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.serviceType, domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onState(state) } }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onResults(results) } }
        }
        browser = b
        b.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        for c in resolving.values { c.cancel() }
        resolving.removeAll()
    }

    private func onState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            onStatus?(.browsing)
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                onStatus?(.denied)
            } else if case .failed = state {
                onStatus?(.failed)
            }
        default:
            break
        }
    }

    private func onResults(_ results: Set<NWBrowser.Result>) {
        var names = Set<String>()
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            names.insert(name)
            if found[name] != nil || resolving[name] != nil { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = r.metadata { txt = record.dictionary }
            resolve(name, r.endpoint, hostId: txt["id"]?.lowercased(), shown: txt["n"] ?? name)
        }
        // Gone from the network.
        let gone = found.keys.filter { !names.contains($0) }
        for n in gone { found[n] = nil }
        for n in resolving.keys where !names.contains(n) {
            resolving[n]?.cancel()
            resolving[n] = nil
        }
        if !gone.isEmpty { onChange(Array(found.values)) }
    }

    private func resolve(_ name: String, _ endpoint: NWEndpoint, hostId: String?, shown: String) {
        let params = NWParameters.udp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        resolving[name] = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let c else { return }
            switch state {
            case .ready:
                let remote = c.currentPath?.remoteEndpoint
                c.cancel()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.resolved(name, remote, hostId: hostId, shown: shown) }
                }
            case .failed, .waiting:
                c.cancel()
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.resolved(name, nil, hostId: hostId, shown: shown) } }
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func resolved(_ name: String, _ remote: NWEndpoint?, hostId: String?, shown: String) {
        guard resolving.removeValue(forKey: name) != nil else { return } // stopped, or gone meanwhile
        guard case .hostPort(.ipv4(let addr), let port)? = remote,
              let e = Endpoint(host: addr.rawValue.map(String.init).joined(separator: "."), port: Int(port.rawValue))
        else { return }
        found[name] = Found(serviceName: name, hostId: hostId, name: shown, endpoint: e)
        onChange(Array(found.values))
    }
}
