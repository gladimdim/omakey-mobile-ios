import Darwin
import Foundation

/// An IPv4 address and port, as omakeyd's pairing link lists them.
public struct Endpoint: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    /// Nil unless [host] is a dotted IPv4 address and [port] fits.
    public init?(host: String, port: Int) {
        var a = in_addr()
        guard (1...65535).contains(port), inet_pton(AF_INET, host, &a) == 1 else { return nil }
        self.host = host
        self.port = UInt16(port)
    }

    /// Loopback, on [port]; 0 lets the system pick one when binding.
    static func loopback(port: UInt16 = 0) -> Endpoint { Endpoint(unchecked: "127.0.0.1", port: port) }

    private init(unchecked host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    init(_ sa: sockaddr_in) {
        var a = sa.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        host = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        port = UInt16(bigEndian: sa.sin_port)
    }

    var sockaddr: sockaddr_in {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &sa.sin_addr)
        return sa
    }

    public var description: String { "\(host):\(port)" }
}

/// Milliseconds on a clock that never jumps; only differences mean anything.
public enum MonotonicClock {
    public static func nowMs() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000) }
}

/// A non-blocking IPv4 UDP socket. Sends never block; a receive with
/// nothing waiting returns nil.
final class UDPSocket {
    let fd: Int32

    /// [bindTo] nil: any address, a port the system picks.
    init(bindTo: Endpoint? = nil) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        // DSCP EF, and the voice service class: Wi-Fi WMM puts it in the
        // voice queue, the lowest-latency one.
        var tos: Int32 = 0xB8
        setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
        var service: Int32 = NET_SERVICE_TYPE_VO
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, socklen_t(MemoryLayout<Int32>.size))
        var sa = bindTo?.sockaddr ?? {
            var any = sockaddr_in()
            any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            any.sin_family = sa_family_t(AF_INET)
            return any
        }()
        let ok = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else {
            let e = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: e) ?? .EIO)
        }
    }

    /// The local address, for tests that bind to loopback.
    var localEndpoint: Endpoint {
        var sa = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Endpoint(sa)
    }

    /// False when it didn't go (no route, a Wi-Fi blip); the caller retries later.
    @discardableResult
    func send(_ data: [UInt8], to e: Endpoint) -> Bool {
        var sa = e.sockaddr
        let n = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return n == data.count
    }

    /// One datagram and its sender; nil when nothing is waiting.
    func receive(into buf: inout [UInt8]) -> (count: Int, from: Endpoint)? {
        var sa = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buf.withUnsafeMutableBytes { b in
            withUnsafeMutablePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &len) }
            }
        }
        // A datagram longer than the buffer comes truncated; the protocol drops it.
        guard n >= 0 else { return nil }
        return (n, Endpoint(sa))
    }

    func close() { Darwin.close(fd) }
}

/// Wakes a thread sleeping in `poll`: one end is polled, the other written to.
final class WakePipe {
    let readFD: Int32
    let writeFD: Int32

    init() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        readFD = fds[0]
        writeFD = fds[1]
        for fd in fds { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
    }

    /// Cheap and safe from any thread; a full pipe already means "wake up".
    func wake() {
        var b: UInt8 = 1
        _ = write(writeFD, &b, 1)
    }

    func drain() {
        var buf = [UInt8](repeating: 0, count: 64)
        while read(readFD, &buf, buf.count) > 0 {}
    }

    func close() {
        Darwin.close(readFD)
        Darwin.close(writeFD)
    }
}

/// Sleeps until [socket] is readable, [wake] is written to, or [timeoutMs] passes.
func waitReadable(_ socket: UDPSocket, _ wake: WakePipe?, timeoutMs: Int64) {
    var fds = [pollfd(fd: socket.fd, events: Int16(POLLIN), revents: 0)]
    if let wake { fds.append(pollfd(fd: wake.readFD, events: Int16(POLLIN), revents: 0)) }
    _ = poll(&fds, nfds_t(fds.count), Int32(min(max(timeoutMs, 1), 1000)))
    wake?.drain()
}
