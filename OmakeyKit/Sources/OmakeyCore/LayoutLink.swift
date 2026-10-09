import Compression
import Foundation
import OmakeyProtocol

/// `omakey://layout?d=<raw DEFLATE, base64url, no padding>` (LAYOUT.md, "Sharing").
/// Apple's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951), the same format
/// Android's `Deflater(…, nowrap = true)` writes.
public enum LayoutLink {
    public static let prefix = "omakey://layout?"

    public static func isLayoutLink(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
    }

    public static func decode(_ link: String) throws -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix),
              let d = trimmed.dropFirst(prefix.count).split(separator: "&").first(where: { $0.hasPrefix("d=") })?.dropFirst(2)
        else { throw LayoutError("Layout link has no data") }
        guard let bytes = Base64URL.decode(String(d)) else { throw LayoutError("Layout link is damaged") }
        let out = try inflate(bytes, limit: LayoutParser.maxBytes)
        return String(decoding: out, as: UTF8.self)
    }

    public static func encode(_ json: String) -> String {
        let compressed = (try? (Data(json.utf8) as NSData).compressed(using: .zlib)) as Data? ?? Data()
        return prefix + "d=" + Base64URL.encode(Array(compressed))
    }

    /// Raw DEFLATE, refusing more than [limit] bytes of output (a small link must not become a huge string).
    static func inflate(_ input: [UInt8], limit: Int) throws -> [UInt8] {
        let damaged = LayoutError("Layout link is damaged")
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw damaged }
        defer { compression_stream_destroy(streamPtr) }

        let chunk = 8192
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var out = [UInt8]()
        return try input.withUnsafeBufferPointer { src -> [UInt8] in
            streamPtr.pointee.src_ptr = src.baseAddress ?? UnsafePointer(dst)
            streamPtr.pointee.src_size = src.count
            while true {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = chunk
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - streamPtr.pointee.dst_size
                out.append(contentsOf: UnsafeBufferPointer(start: dst, count: produced))
                if out.count > limit { throw LayoutError("Layout is larger than 256 KB") }
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK:
                    // Out of input without the end of the stream: cut short.
                    if produced == 0 && streamPtr.pointee.src_size == 0 { throw damaged }
                default: throw damaged
                }
            }
        }
    }
}
