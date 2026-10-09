import Testing
@testable import OmakeyCore
import OmakeyProtocol

struct KeyLayoutsTests {
    let ukFirst = KeyLayouts.preferred("uk-UA")
    let enFirst = KeyLayouts.preferred("en-US")

    @Test func ukrainianLettersGoInUaOnTheirKeys() {
        let p = KeyLayouts.pick("й", current: nil, preferred: enFirst)!
        #expect(p.layout.xkb == "ua")
        #expect(p.stroke == KeyStroke(16, shift: false)) // the Q key
        #expect(KeyLayouts.pick("Ґ", current: "ua", preferred: ukFirst)!.stroke == KeyStroke(43, shift: true))
    }

    @Test func latinGoesInUs() {
        let p = KeyLayouts.pick("q", current: "ua", preferred: ukFirst)!
        #expect(p.layout.xkb == "us")
        #expect(p.stroke == KeyStroke(16, shift: false))
    }

    @Test func punctuationStaysInTheCurrentLayout() {
        // "привіт, світ": the comma is Shift + the dot key on ua, no switch.
        let ua = KeyLayouts.pick(",", current: "ua", preferred: ukFirst)!
        #expect(ua.layout.xkb == "ua" && ua.stroke == KeyStroke(53, shift: true))
        let us = KeyLayouts.pick(",", current: "us", preferred: ukFirst)!
        #expect(us.layout.xkb == "us" && us.stroke == KeyStroke(51, shift: false))
        // Nothing asked yet: the phone keyboard's language decides.
        #expect(KeyLayouts.pick("1", current: nil, preferred: ukFirst)!.layout.xkb == "ua")
        #expect(KeyLayouts.pick("1", current: nil, preferred: enFirst)!.layout.xkb == "us")
        #expect(KeyLayouts.pick(" ", current: "ua", preferred: ukFirst)!.stroke == KeyStroke(UsKeys.keySpace, shift: false))
    }

    @Test func unknownCharactersAreSkipped() {
        #expect(KeyLayouts.pick("€", current: "us", preferred: enFirst) == nil)
        #expect(KeyLayouts.pick("ы", current: "ua", preferred: ukFirst) == nil)
    }

    @Test func decomposedLettersAreTheSameLetter() {
        // й as и + combining breve, as some keyboards hand it over.
        #expect(KeyLayouts.pick("и\u{306}", current: "ua", preferred: ukFirst)!.stroke == KeyStroke(16, shift: false))
    }
}

struct LineDiffTests {
    /// The edit as a readable script: ⌫ ← → for keys, the typed text as is.
    private func script(_ old: String, _ oldCursor: Int, _ new: String, _ newCursor: Int) -> String {
        var out = ""
        LineDiff.edit(old: old, oldCursor: oldCursor, new: new, newCursor: newCursor, key: { code in
            switch code {
            case UsKeys.keyBackspace: out += "⌫"
            case UsKeys.keyLeft: out += "←"
            case UsKeys.keyRight: out += "→"
            default: out += "?"
            }
        }, text: { out += $0 })
        return out
    }

    @Test func typingAppends() { #expect(script("hell", 4, "hello", 5) == "o") }

    @Test func composingWordGrowsOneLetterAtATime() { #expect(script("hel", 3, "hell", 4) == "l") }

    @Test func autocorrectReplacesTheWord() {
        // Space after "teh": the keyboard commits "the " instead. Only the
        // differing part goes: delete "eh", type "he ".
        #expect(script("teh", 3, "the ", 4) == "⌫⌫he ")
        // A suggestion picked with the cursor already past the space.
        #expect(script("teh ", 4, "the ", 4) == "←⌫⌫he→")
    }

    @Test func backspaceAtTheEnd() { #expect(script("hello", 5, "hell", 4) == "⌫") }

    @Test func cursorMovesAreArrows() {
        #expect(script("hello", 5, "hello", 3) == "←←")
        #expect(script("hello", 3, "hello", 4) == "→")
    }

    @Test func editInTheMiddleThenBackToTheEnd() {
        // Cursor after "he", a letter typed there; the cursor follows it.
        #expect(script("hello", 2, "heyllo", 3) == "y")
        #expect(script("heyllo", 3, "heyllo", 6) == "→→→")
    }

    @Test func clearingTheLine() { #expect(script("abc", 3, "", 0) == "⌫⌫⌫") }

    @Test func cyrillicCountsOneUnitPerLetter() {
        #expect(script("привт", 4, "привіт", 5) == "і")
    }
}

/// A scheduler that runs what's due when the test says time has passed.
@MainActor
final class ManualScheduler: Scheduler {
    private var now = 0
    private var tasks: [(at: Int, block: @MainActor () -> Void)] = []

    func after(ms: Int, _ block: @escaping @MainActor () -> Void) {
        tasks.append((now + ms, block))
    }

    func advance(_ ms: Int) {
        let end = now + ms
        while let i = tasks.indices.filter({ tasks[$0].at <= end }).min(by: { tasks[$0].at < tasks[$1].at }) {
            let t = tasks.remove(at: i)
            now = t.at
            t.block()
        }
        now = end
    }
}

@MainActor
final class Gate: LayoutGate {
    var layout: String?
    var acknowledged = true
    var switches: [String] = []

    func current() -> String? { layout }
    func canSwitch() -> Bool { acknowledged }
    func switchTo(_ layout: String) {
        self.layout = layout
        switches.append(layout)
    }
}

@MainActor
struct TypistTests {
    let r = Recorder()
    let gate = Gate()
    let clock = ManualScheduler()

    private func typist(language: String = "en-US", busy: @escaping () -> Bool = { false }) -> Typist {
        Typist(sink: r, gate: gate, scheduler: clock, preferred: { KeyLayouts.preferred(language) }, busy: busy)
    }

    @Test func oneStrokeGoesOutEveryEightMilliseconds() {
        let t = typist()
        t.text("hi")
        #expect(r.log == ["+35", "-35"]) // h at once
        clock.advance(Typist.strokeMs)
        #expect(r.log == ["+35", "-35", "+23", "-23"])
        #expect(gate.switches == ["us"])
    }

    @Test func shiftIsHeldAroundAnUppercaseLetter() {
        let t = typist()
        t.text("A")
        #expect(r.log == ["+42", "+30", "-30", "-42"])
    }

    @Test func aLayoutSwitchWaitsForEverythingToBeAcknowledged() {
        let t = typist()
        gate.layout = "us"
        t.text("aй")
        #expect(r.log == ["+30", "-30"])
        gate.acknowledged = false
        clock.advance(Typist.strokeMs * 3)
        #expect(r.log == ["+30", "-30"]) // й waits: "a" isn't acknowledged
        gate.acknowledged = true
        clock.advance(Typist.strokeMs)
        #expect(r.log == ["+30", "-30", "+16", "-16"])
        #expect(gate.switches == ["ua"])
    }

    @Test func busyHoldsStrokesBack() {
        var busy = true
        let t = typist(busy: { busy })
        t.key(UsKeys.keyEnter)
        clock.advance(50)
        #expect(r.log.isEmpty)
        #expect(t.pending == 1)
        busy = false
        clock.advance(Typist.strokeMs)
        #expect(r.log == ["+28", "-28"])
    }

    @Test func clearDropsWhatHasntGoneOut() {
        let t = typist()
        t.text("abc")
        t.clear()
        clock.advance(100)
        #expect(r.log == ["+30", "-30"])
    }

    @Test func charactersNoLayoutHasAreSkipped() {
        let t = typist()
        t.text("€a")
        #expect(r.log == ["+30", "-30"])
    }
}

struct ThemeTests {
    @Test func prettyNamesLookLikeOmarchys() {
        #expect(Themes.prettyName("tokyo-night") == "Tokyo Night")
        #expect(Themes.prettyName("rose_pine dawn") == "Rose Pine Dawn")
    }

    @Test func fromComputerMixesKeysFromTheDesktopColors() {
        var colors = [UInt32](repeating: 0, count: DesktopTheme.keys.count)
        colors[DesktopTheme.keys.firstIndex(of: "background")!] = 0x000000
        colors[DesktopTheme.keys.firstIndex(of: "foreground")!] = 0xFFFFFF
        colors[DesktopTheme.keys.firstIndex(of: "accent")!] = 0x0000FF
        let t = Themes.fromComputer(DesktopTheme(name: "test-theme", light: false, colors: colors))
        #expect(t.name == "Test Theme")
        #expect(t.bg == 0x000000 && t.fg == 0xFFFFFF && t.accent == 0x0000FF)
        #expect(t.key == 0x1E1E1E) // 12% of the way to the foreground
        #expect(t.keyAccent == 0x000072) // 45% of the way to the accent
        #expect(Themes.fromComputer(nil).bg == Themes.all[0].bg)
    }

    @Test func everyPresetIsInTheSliderRange() {
        for p in PointerPresets.all { #expect((0.3...3).contains(p.sensitivity)) }
        #expect(PointerPresets.default.sensitivity == 1.1)
    }
}
