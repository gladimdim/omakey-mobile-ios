/// One clipboard transfer with omakeyd (PROTOCOL.md, CLIP): the phone's
/// text to the desktop (`put`), or the desktop's to the phone (`get`).
/// Socket-free, like `ClientSession`, which owns the one under way: it asks
/// `body` what to send and hands over each reply. Not thread-safe.
public final class ClipTransfer {
    public enum Outcome: Equatable, Sendable {
        /// The desktop has the text, and pasted it when asked to.
        case sent
        /// The desktop's text.
        case received(text: String, sensitive: Bool)
        /// It ended without: a reply's status (`Clip.empty` and friends), or `ClipTransfer.gaveUp`.
        case failed(status: Int)
    }

    /// No reply in this long: send again.
    public static let resendMs: Int64 = 150
    /// The desktop is working on it: ask again after this long.
    public static let pollMs: Int64 = 50
    /// Nothing moved for this long: give up.
    public static let giveUpMs: Int64 = 5000
    /// `Outcome.failed` status when the desktop stopped answering.
    public static let gaveUp = -1

    public let op: Int
    private let flags: Int
    private let text: [UInt8]
    public let id: UInt32

    /// Put: the bytes the desktop has.
    private var sent = 0
    /// Get: the bytes so far.
    private var received: [UInt8] = []

    /// When to send next; 0 is now.
    public private(set) var dueAt: Int64 = 0
    private var lastSent: Int64 = 0
    /// When something last moved; -1 until the first send.
    private var lastProgress: Int64 = -1
    private var progressed = false

    private init(op: Int, flags: Int, text: [UInt8], id: UInt32) {
        self.op = op
        self.flags = flags
        self.text = text
        self.id = id
    }

    /// The phone's [text] to the desktop clipboard, pasted there with
    /// [paste]. Nil when it's empty or over `Clip.maxText` bytes.
    public static func put(_ text: String, paste: Bool, sensitive: Bool, id: UInt32 = .random(in: .min ... .max)) -> ClipTransfer? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= Clip.maxText else { return nil }
        let flags = (paste ? Clip.paste : 0) | (sensitive ? Clip.sensitive : 0)
        return ClipTransfer(op: Clip.put, flags: flags, text: bytes, id: id)
    }

    /// The desktop's clipboard text; with [copy], what's selected there, copied first.
    public static func get(copy: Bool, id: UInt32 = .random(in: .min ... .max)) -> ClipTransfer {
        ClipTransfer(op: Clip.get, flags: copy ? Clip.copy : 0, text: [], id: id)
    }

    /// What to send at [nowMs], or nil when it isn't time.
    public func body(nowMs: Int64) -> [UInt8]? {
        if lastProgress < 0 || progressed { lastProgress = nowMs }
        progressed = false
        if nowMs < dueAt { return nil }
        lastSent = nowMs
        dueAt = nowMs + ClipTransfer.resendMs
        if op == Clip.put {
            let piece = Array(text[sent..<min(sent + Clip.chunk, text.count)])
            return Clip(op: Clip.put, clipId: id, offset: sent, flags: flags, total: text.count, data: piece).encode(reply: false)
        }
        return Clip(op: Clip.get, clipId: id, offset: received.count, flags: flags).encode(reply: false)
    }

    /// Nothing moved for `giveUpMs`.
    public func expired(nowMs: Int64) -> Bool {
        lastProgress >= 0 && !progressed && nowMs - lastProgress > ClipTransfer.giveUpMs
    }

    /// A new session: the desktop forgot the transfer, so start it again.
    public func restart() {
        sent = 0
        received.removeAll()
        dueAt = 0
    }

    /// Digest a reply; the outcome once it's over, else nil.
    public func onReply(_ c: Clip) -> Outcome? {
        guard c.clipId == id, c.op == op else { return nil }
        if c.status != Clip.ok && c.status != Clip.working { return .failed(status: c.status) }
        // A put's reply says what the desktop has, also while it works.
        if op == Clip.put && c.offset > sent {
            sent = min(c.offset, text.count)
            progressed = true
        }
        if c.status == Clip.working {
            // Ask again shortly; a resend would only add to the queue.
            dueAt = lastSent + ClipTransfer.pollMs
            return nil
        }
        if op == Clip.put {
            if sent >= text.count { return .sent }
        } else {
            if c.offset == received.count && !c.data.isEmpty {
                received.append(contentsOf: c.data)
                progressed = true
            }
            if received.count >= c.total {
                return .received(text: String(decoding: received, as: UTF8.self), sensitive: c.flags & Clip.sensitive != 0)
            }
        }
        // The next piece, now.
        dueAt = 0
        return nil
    }
}
