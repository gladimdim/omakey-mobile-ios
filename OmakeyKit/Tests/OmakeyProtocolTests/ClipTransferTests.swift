import Testing
@testable import OmakeyProtocol

struct ClipTransferTests {
    private func sent(_ body: [UInt8]?) -> Clip { Clip.decode(body!, reply: false)! }

    @Test func clipRoundTripsWithStatusOnlyInReplies() {
        let c = Clip(op: Clip.put, clipId: 0x01020304, offset: 1024, flags: Clip.paste, total: 1030, data: Array("hello!".utf8))
        let enc = c.encode(reply: false)
        #expect(enc.count == 14 + 6)
        let d = Clip.decode(enc, reply: false)!
        #expect([d.op, Int(d.clipId), d.offset, d.flags, d.total] == [c.op, Int(c.clipId), c.offset, c.flags, c.total])
        #expect(d.data == c.data)
        let r = Clip(op: Clip.get, clipId: 7, status: Clip.working)
        #expect(r.encode(reply: true).count == 15)
        #expect(Clip.decode(r.encode(reply: true), reply: true)!.status == Clip.working)
        #expect(Clip.decode(Array(r.encode(reply: true).prefix(14)), reply: true) == nil)
    }

    @Test func putSendsPiecesInOrderAndEndsWhenAllAreIn() {
        let text = String(repeating: "ї", count: 1000) // 2000 bytes: two pieces
        let t = ClipTransfer.put(text, paste: true, sensitive: true, id: 5)!
        let first = sent(t.body(nowMs: 0))
        #expect([first.offset, first.total, first.data.count] == [0, 2000, Clip.chunk])
        #expect(first.flags == Clip.paste | Clip.sensitive)
        // Not due until the resend time, then the same piece again.
        #expect(t.body(nowMs: 100) == nil)
        #expect(sent(t.body(nowMs: ClipTransfer.resendMs)).offset == 0)
        // The desktop has the first piece: the second goes at once.
        #expect(t.onReply(Clip(op: Clip.put, clipId: 5, offset: Clip.chunk, total: 2000)) == nil)
        let second = sent(t.body(nowMs: 160))
        #expect([second.offset, second.data.count] == [Clip.chunk, 2000 - Clip.chunk])
        // All in, but the desktop is still setting it: ask again shortly.
        #expect(t.onReply(Clip(op: Clip.put, clipId: 5, status: Clip.working, offset: 2000, total: 2000)) == nil)
        #expect(t.body(nowMs: 170) == nil)
        let poll = sent(t.body(nowMs: 160 + ClipTransfer.pollMs))
        #expect([poll.offset, poll.data.count] == [2000, 0])
        #expect(t.onReply(Clip(op: Clip.put, clipId: 5, offset: 2000, total: 2000)) == .sent)
    }

    @Test func getGathersPiecesAndIgnoresOthersReplies() {
        let text = String(repeating: "selected ✓ ", count: 150)
        let bytes = Array(text.utf8)
        let t = ClipTransfer.get(copy: true, id: 9)
        #expect(sent(t.body(nowMs: 0)).flags == Clip.copy)
        #expect(t.onReply(Clip(op: Clip.get, clipId: 9, status: Clip.working)) == nil)
        // A reply for another transfer changes nothing.
        #expect(t.onReply(Clip(op: Clip.get, clipId: 8, total: 3, data: Array("old".utf8))) == nil)
        var now: Int64 = 100
        var outcome: ClipTransfer.Outcome?
        while outcome == nil {
            let ask = sent(t.body(nowMs: now) ?? t.body(nowMs: now + ClipTransfer.resendMs))
            let end = min(ask.offset + Clip.chunk, bytes.count)
            outcome = t.onReply(Clip(op: Clip.get, clipId: 9, offset: ask.offset, flags: Clip.sensitive, total: bytes.count,
                                     data: Array(bytes[ask.offset..<end])))
            now += 10
        }
        #expect(outcome == .received(text: text, sensitive: true))
    }

    @Test func failuresEndItAndSilenceGivesUp() {
        let t = ClipTransfer.get(copy: false, id: 1)
        _ = t.body(nowMs: 0)
        #expect(t.onReply(Clip(op: Clip.get, clipId: 1, status: Clip.empty)) == .failed(status: Clip.empty))

        let quiet = ClipTransfer.get(copy: false, id: 2)
        _ = quiet.body(nowMs: 1000)
        #expect(!quiet.expired(nowMs: 1000 + ClipTransfer.giveUpMs))
        #expect(quiet.expired(nowMs: 1001 + ClipTransfer.giveUpMs))
    }

    @Test func emptyAndOversizedTextIsNotSent() {
        #expect(ClipTransfer.put("", paste: true, sensitive: false) == nil)
        #expect(ClipTransfer.put(String(repeating: "x", count: Clip.maxText + 1), paste: true, sensitive: false) == nil)
        #expect(ClipTransfer.put(String(repeating: "x", count: Clip.maxText), paste: true, sensitive: false) != nil)
    }
}
