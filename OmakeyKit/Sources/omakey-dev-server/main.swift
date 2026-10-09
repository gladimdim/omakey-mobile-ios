// A computer for the simulator (or a phone on this Mac's network) to pair
// with: the omakeyd stand-in on a real port, advertised over mDNS, printing
// every key it gets. It types nothing.
//
//   swift run --package-path OmakeyKit omakey-dev-server [--port 47899] [--name "dev mac"] [--reset]
//
// The pairing is kept in ~/Library/Application Support/omakey-dev-server so
// the app stays paired across runs; --reset makes a new one.
import Darwin
import dnssd
import Foundation
import OmakeyCore
import OmakeydStandIn
import OmakeyNet
import OmakeyProtocol

setvbuf(stdout, nil, _IOLBF, 0)
var port: UInt16 = 47899
var name = "dev mac"
var reset = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--port": port = UInt16(args.next() ?? "") ?? port
    case "--name": name = args.next() ?? name
    case "--reset": reset = true
    default:
        print("usage: omakey-dev-server [--port N] [--name NAME] [--reset]")
        exit(2)
    }
}

let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("omakey-dev-server")
let file = dir.appendingPathComponent("identity.json")
var identity = reset ? nil : (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(HostRecord.self, from: $0) }

let server: StandInServer
do {
    server = try StandInServer(name: name, bindTo: .any(port: port), identity: identity)
} catch {
    print("can't listen on UDP \(port): \(error)")
    exit(1)
}
if identity == nil {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? JSONEncoder().encode(server.host).write(to: file, options: .atomic)
    identity = server.host
}

/// This Mac's IPv4 addresses, LAN first, loopback (for the simulator) last.
func addresses() -> [String] {
    var out = [String]()
    var ifs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifs) == 0 else { return ["127.0.0.1"] }
    defer { freeifaddrs(ifs) }
    var p = ifs
    while let i = p?.pointee {
        defer { p = i.ifa_next }
        guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), i.ifa_flags & UInt32(IFF_UP) != 0,
              i.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
        out.append(String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
    return out + ["127.0.0.1"]
}

let link = server.pairingLink(addresses: addresses())
print("""
omakeyd stand-in "\(name)" on UDP \(port): it types nothing, it prints what it gets.

Pairing link (fingerprint \(server.host.fingerprint)):
  \(link)

Simulator:  xcrun simctl openurl booted '\(link)'

""")

// mDNS, as omakeyd advertises itself: _omakey._udp with v, id and n.
var txt = TXTRecordRef()
TXTRecordCreate(&txt, 0, nil)
for (k, v) in [("v", "1"), ("id", server.host.hostId), ("n", name)] {
    let bytes = Array(v.utf8)
    TXTRecordSetValue(&txt, k, UInt8(bytes.count), bytes)
}
var registration: DNSServiceRef?
let err = DNSServiceRegister(&registration, 0, 0, "\(name) omakey", "_omakey._udp", nil, nil, port.bigEndian,
                             TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), nil, nil)
if err == kDNSServiceErr_NoError, let registration {
    DNSServiceSetDispatchQueue(registration, .main)
} else {
    print("(no mDNS: \(err); pair with the link)")
}

/// "KEY_A" for 30: keycodes.json read the other way round.
let codeNames: [Int: String] = {
    guard let root = try? JSONSerialization.jsonObject(with: Data(BundledSpec.keycodesJSON().utf8)) as? [String: Any],
          let keys = root["keys"] as? [[String: Any]] else { return [:] }
    var m = [Int: String]()
    for k in keys {
        if let n = k["name"] as? String, let c = (k["code"] as? NSNumber)?.intValue, m[c] == nil { m[c] = n }
    }
    m[Wire.btnLeft] = "BTN_LEFT"
    m[Wire.btnRight] = "BTN_RIGHT"
    m[Wire.btnMiddle] = "BTN_MIDDLE"
    return m
}()
let start = Date()
func stamp() -> String { String(format: "%8.3f", Date().timeIntervalSince(start)) }
server.onEvent = { e in
    switch e {
    case .hello(let n, let platform): print("\(stamp())  HELLO from \(n) (\(platform == Wire.platformIOS ? "iOS" : "Android"))")
    case .key(let code, let down): print("\(stamp())  \(down ? "▼" : "▲") \(codeNames[code] ?? "code \(code)")")
    case .pointer(let p): print("\(stamp())  pointer dx \(p.dx) dy \(p.dy)\(p.wheel != 0 ? " wheel \(p.wheel)" : "")\(p.hwheel != 0 ? " hwheel \(p.hwheel)" : "")")
    case .layout(let l): print("\(stamp())  layout \(l)")
    case .bye: print("\(stamp())  BYE")
    case .clipboardSet(let text, let paste): print("\(stamp())  clipboard ← phone (\(text.utf8.count) bytes)\(paste ? ", pasted" : "")")
    case .clipboardRead(let copy): print("\(stamp())  clipboard → phone\(copy ? ", copied first" : "")")
    case .releasedAll: print("\(stamp())  (every key let go)")
    }
}
dispatchMain()
