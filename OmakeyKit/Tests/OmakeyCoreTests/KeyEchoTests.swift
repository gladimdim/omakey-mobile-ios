import Testing
@testable import OmakeyCore

struct KeyEchoTests {
    /// Each key pressed and let go, in order; what showed.
    private func echo(_ e: inout KeyEcho, _ keys: [(Int, Bool)]) -> [String] {
        keys.compactMap { e.key($0.0, down: $0.1) }
    }

    private func tap(_ code: Int) -> [(Int, Bool)] { [(code, true), (code, false)] }

    @Test func lettersAsTypedNotAsOnTheKeycap() {
        var e = KeyEcho()
        // k, Shift+k, k with Caps Lock on, then off again.
        let shown = echo(&e, tap(37) + [(42, true)] + tap(37) + [(42, false)] + tap(58) + tap(37) + tap(58) + tap(37))
        #expect(shown == ["k", "K", "Caps", "K", "Caps", "k"])
    }

    @Test func capsLockLeavesDigitsAndShiftUndoesIt() {
        var e = KeyEcho()
        let shown = echo(&e, tap(58) + tap(2) + [(42, true)] + tap(2) + tap(37) + [(42, false)])
        #expect(shown == ["Caps", "1", "!", "k"])
    }

    @Test func spaceAndKeysThatTypeNoCharacter() {
        var e = KeyEcho()
        #expect(echo(&e, tap(57) + tap(28) + tap(14) + tap(103)) == ["␣", "Enter", "Backspace", "↑"])
    }

    @Test func shortcutsByTheirKeys() {
        var e = KeyEcho()
        #expect(echo(&e, [(29, true)] + tap(46) + [(29, false)]) == ["Ctrl+C"])
        #expect(echo(&e, [(125, true), (42, true)] + tap(16) + [(42, false), (125, false)]) == ["Super+Shift+Q"])
        #expect(echo(&e, [(125, true)] + tap(57) + [(125, false)]) == ["Super+Space"])
        #expect(echo(&e, [(29, true)] + tap(272) + [(29, false)]) == ["Ctrl+left click"])
    }

    @Test func aModifierOnItsOwnShowsWhenLetGo() {
        var e = KeyEcho()
        #expect(echo(&e, tap(125)) == ["Super"])
        // Shift alone too, but not when it shifted something.
        #expect(echo(&e, tap(42)) == ["Shift"])
        #expect(echo(&e, [(42, true)] + tap(30) + [(42, false)]) == ["A"])
    }

    @Test func inTheLayoutThePhoneAskedFor() {
        var e = KeyEcho()
        e.setLayout("ua")
        #expect(echo(&e, tap(37) + [(42, true)] + tap(37) + [(42, false)]) == ["л", "Л"])
        e.setLayout("us")
        #expect(echo(&e, tap(37)) == ["k"])
    }

    @Test func releasingEverythingForgetsHeldModifiers() {
        var e = KeyEcho()
        _ = e.key(29, down: true)
        e.releaseAll()
        #expect(echo(&e, tap(46)) == ["c"])
    }
}
