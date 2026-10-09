import Foundation
import Testing
@testable import OmakeyCore

final class Recorder: KeyboardSink {
    var log: [String] = []
    func keyDown(_ code: Int) { log.append("+\(code)") }
    func keyUp(_ code: Int) { log.append("-\(code)") }
}

let keycodes = try! Keycodes.parse(BundledSpec.keycodesJSON())

func bundled(_ id: String) -> String {
    BundledSpec.layoutFiles().first { $0.file == "\(id).json" }!.json
}

struct LayoutAndKeyboardTests {
    let qwertyJSON = bundled("classic-qwerty")
    let qwerty: Layout

    init() throws {
        qwerty = try LayoutParser.parse(qwertyJSON, keycodes: keycodes)
    }

    private func key(_ id: String) -> Int {
        let i = qwerty.keys.firstIndex { $0.id == id }
        precondition(i != nil, "no key \(id)")
        return i!
    }

    @Test func everyBundledLayoutParses() throws {
        let files = BundledSpec.layoutFiles()
        #expect(files.count >= 10)
        for f in files { _ = try LayoutParser.parse(f.json, keycodes: keycodes) }
    }

    @Test func splitQwertyHasTwoSpacesAndACentreThumbCluster() throws {
        let split = try LayoutParser.parse(bundled("omakey-pro"), keycodes: keycodes)
        func k(_ id: String) -> LayoutKey { split.keys.first { $0.id == id }! }
        #expect(split.keys.filter { $0.code == 57 }.count == 2)
        // Modifiers and Enter exist only in the islands.
        let modifiers: Set<Int> = [28, 29, 42, 54, 56, 97, 100, 125, 126]
        #expect(split.name == "Omakey Pro")
        #expect(Set(split.keys.filter { modifiers.contains($0.code) }.map(\.id)) == [
            "center-enter", "center-shift", "center-rshift", "center-ctrl", "center-rctrl", "center-super",
            "center-alt", "center-rsuper", "center-ralt", "rightalt",
        ])
        // Mirrored islands: 2x2 Ctrl and Backspace on both, Shift twins.
        let lc = k("center-ctrl"), rc = k("center-rctrl")
        #expect(lc.w == 2 && rc.w == 2 && lc.h == rc.h && lc.y == rc.y)
        let lb = k("center-backspace"), rb = k("center-backspace-right")
        #expect(lb.code == 14 && rb.code == 14 && lb.y == rb.y && lb.h == rb.h)
        let ls = k("center-shift"), rs = k("center-rshift")
        #expect(ls.y == rs.y && ls.w * ls.h == rs.w * rs.h)
        // Super and Alt mirror each other: outer Super, inner Alt on both islands.
        let lsu = k("center-super"), la = k("center-alt"), ra = k("center-ralt"), rsu = k("center-rsuper")
        #expect(lsu.y == rsu.y && la.y == ra.y)
        #expect(lsu.x < la.x && ra.x < rsu.x)
        #expect(ra.code == 56) // sends Left Alt: Alt even where Right Alt is AltGr
        // Delete sits between the two Backspaces and bridges the split.
        let del = k("center-delete")
        #expect(abs(lb.x + lb.w - del.x) < 1e-4 && abs(del.x + del.w - rb.x) < 1e-4)
        #expect(lb.y == del.y && lb.h == del.h)
        #expect(del.x < split.splitAt! && del.x + del.w > split.splitAt!)
        // The space row is set apart from the letters by 30% of a letter key.
        let z = k("z"), space = k("space-left")
        #expect(abs(space.y - (z.y + z.h) - 0.3) < 1e-4)
        #expect(k("space-right").y == space.y)
        // The one asymmetric key: a regular Backspace in the top right corner.
        let corner = k("corner-backspace")
        #expect(corner.code == 14 && corner.w == 1)
        #expect(abs(split.width - (corner.x + corner.w)) < 1e-4 && corner.y == 0)
        #expect(k("rightalt").y + k("rightalt").h < k("f1").y)
        // Rarely used keys sit in a top row above the F row, which is set apart from the number row.
        let f1 = k("f1")
        for id in ["home", "end", "pageup", "pagedown", "capslock", "esc", "f6", "f7", "sysrq", "insert", "compose",
                   "minus", "leftbrace", "rightbrace", "backslash", "apostrophe"] {
            #expect(k(id).y + k(id).h < f1.y, "\(id)")
        }
        #expect(k("1").y > f1.y + f1.h + 0.1)
        for id in ["home", "end", "pageup", "pagedown"] { #expect(k(id).x + k(id).w <= k("t").x + 1, "\(id)") }
        // Enter is |_|: a bar across the split plus a 2x2 block on each side, joined at the bar.
        let enter = k("center-enter")
        let at = split.splitAt!
        #expect(enter.rects.count == 3)
        #expect(enter.x < at && enter.x + enter.w > at)
        let left = enter.parts[0], right = enter.parts[1]
        #expect(left.x + left.w <= at && right.x >= at)
        for p in enter.parts {
            #expect(p.w == 2 && abs(enter.y - (p.y + p.h)) < 1e-4)
        }
        #expect(left.x == enter.x && abs(right.x + right.w - (enter.x + enter.w)) < 1e-4)
        // Letters touch the outer edges; T is left of the islands, Y right of them.
        for id in ["q", "a", "z"] { #expect(k(id).x == 0) }
        for id in ["p", "semicolon", "slash"] { #expect(abs(split.width - (k(id).x + k(id).w)) < 1e-4) }
        #expect(k("t").x + k("t").w <= lc.x && k("y").x >= rc.x + rc.w)
        for id in ["tab", "grave", "equal"] { #expect(k(id).x >= lc.x && k(id).x < at, "\(id)") }
    }

    @Test func splitLayoutsStretchTheirGapAndHitTestAcrossIt() throws {
        let split = try LayoutParser.parse(bundled("omakey-pro"), keycodes: keycodes)
        let at = split.splitAt!
        #expect(at > 0 && at < split.width)
        // Only Enter's bar, Delete, and Copy and Paste inside the Enter cross the split (they stretch with the gap).
        #expect(Set(split.keys.filter { $0.x < at && $0.x + $0.w > at + 1e-4 }.map(\.id)) == ["center-enter", "center-delete", "copy", "paste"])
        let m = KeyboardModel(layout: split, sink: Recorder())
        func index(_ id: String) -> Int { split.keys.firstIndex { $0.id == id }! }
        let enter = index("center-enter"), shift = index("center-shift"), bksp = index("center-rshift")
        let e = split.keys[enter], sh = split.keys[shift], bk = split.keys[bksp]
        let stretch: Float = 3
        // The right side moved 3 units right; the left side stayed.
        #expect(m.hitTestStretched(bk.x + stretch + 0.5, bk.y + 0.5, stretch: stretch) == bksp)
        #expect(m.hitTestStretched(sh.x + 0.5, sh.y + 0.5, stretch: stretch) == shift)
        // Enter's bar crosses the split, so it stretches: the middle of the widened gap is Enter...
        #expect(m.hitTestStretched(at + stretch / 2, e.y + 0.5, stretch: stretch) == enter)
        // ...and so are both of its 2x2 blocks, the right one moved with the right side.
        #expect(m.hitTestStretched(e.parts[0].x + 0.5, e.parts[0].y + 0.5, stretch: stretch) == enter)
        #expect(m.hitTestStretched(e.parts[1].x + stretch + 0.5, e.parts[1].y + 0.5, stretch: stretch) == enter)
        // Inside the U, Copy over Paste, stretched with the gap like Enter around them.
        let copy = index("copy"), paste = index("paste")
        #expect(m.hitTestStretched(at + stretch / 2, e.parts[0].y + 0.5, stretch: stretch) == copy)
        #expect(m.hitTestStretched(at + stretch / 2, e.y - 0.5, stretch: stretch) == paste)
        #expect(abs(e.parts[0].x + e.parts[0].w - split.keys[copy].x) < 1e-4)
        #expect(abs(e.parts[1].x - (split.keys[paste].x + split.keys[paste].w)) < 1e-4)
        #expect(abs(e.y - (split.keys[paste].y + split.keys[paste].h)) < 1e-4)
        // Above them, between Fn and the arrows, the gap hits nothing; no stretch behaves like hitTest.
        let fn = split.keys.first { $0.id == "fn" }!
        #expect(m.hitTestStretched(at + stretch / 2, fn.y + 0.5, stretch: stretch) == -1)
        #expect(m.hitTestStretched(bk.x + 0.5, bk.y + 0.5, stretch: 0) == bksp)
        // Every bundled split board declares its split.
        for id in ["corne", "ferris-sweep", "lily58", "ergodox", "kinesis-advantage", "alice", "omakey-pro"] {
            #expect(try LayoutParser.parse(bundled(id), keycodes: keycodes).splitAt != nil, "\(id)")
        }
    }

    @Test func labelsFollowShiftAndCapsLock() {
        let m = KeyboardModel(layout: qwerty, sink: Recorder())
        let a = key("a"), one = key("1"), minus = key("minus"), shift = key("leftshift"), caps = key("capslock")
        // Lowercase by default; symbols show their own character with the shifted one in the corner.
        #expect(m.labelFor(a) == "a" && m.labelFor(one) == "1" && m.subFor(one) == "!")
        // Holding Shift shows what will be sent.
        m.down(0, shift)
        #expect(m.labelFor(a) == "A" && m.labelFor(one) == "!" && m.labelFor(minus) == "_")
        #expect(m.subFor(one) == "1")
        #expect(m.labelFor(shift) == "Shift")
        m.up(0)
        #expect(m.labelFor(a) == "a")
        // Caps Lock uppercases letters only; Shift with Caps Lock gives lowercase letters.
        m.down(1, caps); m.up(1)
        #expect(m.capsLock)
        #expect(m.labelFor(a) == "A" && m.labelFor(one) == "1")
        m.down(2, shift)
        #expect(m.labelFor(a) == "a" && m.labelFor(one) == "!")
        m.up(2)
        m.down(3, caps); m.up(3)
        #expect(m.labelFor(a) == "a")
        // The Fn layer's labels win while it is held.
        m.down(4, key("fn"))
        #expect(m.labelFor(key("f1")) == "Mute")
    }

    @Test func capsLockSurvivesALayoutSwitch() {
        let locks = KeyboardModel.Locks()
        let sink = Recorder()
        let m1 = KeyboardModel(layout: qwerty, sink: sink, locks: locks)
        m1.down(0, key("capslock")); m1.up(0)
        let m2 = KeyboardModel(layout: qwerty, sink: sink, locks: locks)
        #expect(m2.labelFor(key("a")) == "A")
    }

    @Test func parsesClassicQwerty() {
        #expect(qwerty.id == "classic-qwerty")
        #expect(qwerty.width == 15 && qwerty.height == 6)
        #expect(qwerty.keys.count == 79)

        let esc = qwerty.keys[key("esc")]
        #expect(esc.code == 1 && esc.style == .mod)
        #expect(qwerty.keys[key("leftmeta")].code == 125)
        #expect(qwerty.keys[key("space")].code == 57)
        #expect(qwerty.keys[key("fn")].layer == "fn")
        #expect(qwerty.keys[key("fn")].code == 0)
        #expect(qwerty.keys[key("f1")].layers["fn"]!.code == 113) // KEY_MUTE
        #expect(qwerty.keys[key("1")].sub == "!")

        // Every row is 15 units wide.
        for y in 0...5 {
            let width = qwerty.keys.filter { $0.y == Float(y) }.reduce(Float(0)) { $0 + $1.w }
            #expect(abs(width - 15) < 1e-4, "row \(y)")
        }
    }

    @Test func fingersHoldIndependentKeys() {
        let r = Recorder()
        let m = KeyboardModel(layout: qwerty, sink: r)
        m.down(0, key("leftmeta"))
        m.down(1, key("space"))
        m.up(1)
        m.up(0)
        #expect(r.log == ["+125", "+57", "-57", "-125"])
    }

    @Test func fnLayerReleasesTheCodeItPressed() {
        let r = Recorder()
        let m = KeyboardModel(layout: qwerty, sink: r)
        m.down(0, key("fn"))
        #expect(m.activeLayer == "fn")
        #expect(m.labelFor(key("up")) == "PgUp")
        m.down(1, key("up")) // Fn + ↑ = PgUp
        m.up(0) // let go of Fn first
        #expect(m.activeLayer == nil)
        m.up(1) // still releases PgUp, not ↑
        m.down(2, key("up")) // plain ↑ now
        m.up(2)
        #expect(r.log == ["+104", "-104", "+103", "-103"])
    }

    @Test func keysWithoutALayerEntryKeepTheirCode() {
        let r = Recorder()
        let m = KeyboardModel(layout: qwerty, sink: r)
        m.down(0, key("fn"))
        m.down(1, key("q"))
        m.cancelAll()
        #expect(r.log == ["+16", "-16"])
        #expect(m.pressCount.allSatisfy { $0 == 0 })
    }

    @Test func hitTestUsesUnitsAndLastKeyWins() {
        let m = KeyboardModel(layout: qwerty, sink: Recorder())
        #expect(m.hitTest(0.5, 0.5) == key("esc"))
        #expect(m.hitTest(7, 5.5) == key("space"))
        #expect(m.hitTest(20, 1) == -1)
    }

    @Test func layoutLinkRoundTrips() throws {
        let link = LayoutLink.encode(qwertyJSON)
        #expect(link.hasPrefix("omakey://layout?d="))
        #expect(link.count < qwertyJSON.count, "link should be compressed")
        #expect(try LayoutLink.decode(link) == qwertyJSON)
        #expect(throws: LayoutError.self) { try LayoutLink.decode("omakey://layout?d=!!!") }
    }

    @Test func layoutLinkFromAndroidDecodes() throws {
        // zlib's raw deflate at level 9 is what Java's Deflater wraps.
        let json = minimal(#"{"id":"k","x":0,"y":0,"w":1,"h":1,"label":"A","code":"KEY_A"}"#)
        let java = "omakey://layout?d=JcwxC8IwEAXg__LmCOqYrUMnVxcRkbM5TWjSgzZaQ-l_9xqXx-P47i14ypgow0IS9Vx2kYq8Mww-PE5BBtiDQXAKtuNAibWetc7BZQ97NPAcXj5XqAsT7HX5f_TKvrB7g1JzrsbXjPTgqKZR04nbVk_t5d5gva0_"
        #expect(try LayoutLink.decode(java) == json)
        // A cut-off link is damaged, not a shorter layout.
        let cut = String(java.dropLast(6))
        #expect(throws: LayoutError.self) { try LayoutLink.decode(cut) }
    }

    @Test func rejectsInvalidLayouts() throws {
        func broken(_ edit: (inout [String: Any]) -> Void) throws -> String {
            var o = try JSONSerialization.jsonObject(with: Data(qwertyJSON.utf8)) as! [String: Any]
            edit(&o)
            return String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
        }
        func editKey(_ i: Int, _ field: String, _ value: Any) -> (inout [String: Any]) -> Void {
            { o in
                var keys = o["keys"] as! [[String: Any]]
                keys[i][field] = value
                o["keys"] = keys
            }
        }
        let cases: [String: String] = [
            "format": try broken { $0["format"] = "other" },
            "version": try broken { $0["version"] = 2 },
            "unknown code": try broken(editKey(0, "code", "KEY_NOPE")),
            "both code and layer": try broken(editKey(0, "layer", "fn")),
            "dup id": try broken(editKey(1, "id", "esc")),
            "tiny key": try broken(editKey(0, "w", 0.1)),
            "long label": try broken(editKey(0, "label", String(repeating: "x", count: 17))),
            "bad style": try broken(editKey(0, "style", "neon")),
            "not json": "{",
        ]
        for (name, json) in cases {
            #expect(throws: LayoutError.self, "accepted: \(name)") { try LayoutParser.parse(json, keycodes: keycodes) }
        }
    }

    @Test func stickyModifiersLatchForOneKeyAndLockOnADoubleTap() {
        let r = Recorder()
        let m = KeyboardModel(layout: qwerty, sink: r)
        m.sticky = true
        let shift = key("leftshift"), a = key("a"), b = key("b")
        // Tap Shift: it stays down for the next key only.
        m.down(0, shift); m.up(0)
        #expect(m.isLatched(shift))
        #expect(m.labelFor(a) == "A")
        m.down(1, a); m.up(1)
        m.down(2, b); m.up(2)
        #expect(r.log == ["+42", "+30", "-30", "-42", "+48", "-48"])
        #expect(!m.isLatched(shift))
        // Tap twice: locked for every key until a third tap.
        r.log.removeAll()
        m.down(0, shift); m.up(0)
        m.down(0, shift); m.up(0)
        #expect(m.isLocked(shift))
        m.down(1, a); m.up(1)
        m.down(1, b); m.up(1)
        m.down(0, shift); m.up(0)
        #expect(r.log == ["+42", "+30", "-30", "+48", "-48", "-42"])
    }

    @Test func heldModifiersStillChordWithStickyOn() {
        let r = Recorder()
        let m = KeyboardModel(layout: qwerty, sink: r)
        m.sticky = true
        m.down(0, key("leftmeta"))
        m.down(1, key("space")); m.up(1)
        m.up(0)
        #expect(r.log == ["+125", "+57", "-57", "-125"])
    }

    @Test func aTappedFnAppliesToTheNextKeyOnly() {
        let r = Recorder()
        let m = KeyboardModel(layout: qwerty, sink: r)
        m.sticky = true
        m.down(0, key("fn")); m.up(0)
        #expect(m.activeLayer == "fn")
        m.down(1, key("up")); m.up(1) // PgUp
        #expect(m.activeLayer == nil)
        m.down(1, key("up")); m.up(1) // plain ↑
        #expect(r.log == ["+104", "-104", "+103", "-103"])
    }

    @Test func cancelLetsGoOfLatchedKeysToo() {
        let r = Recorder()
        let m = KeyboardModel(layout: qwerty, sink: r)
        m.sticky = true
        m.down(0, key("leftctrl")); m.up(0)
        #expect(m.cancelAll())
        #expect(r.log == ["+29", "-29"])
    }

    @Test func aSwipeOnATypingKeyCanBeTakenBack() {
        let r = Recorder()
        let m = KeyboardModel(layout: qwerty, sink: r)
        m.down(0, key("a"))
        #expect(m.typedOnly(0) { UsKeys.printable[$0] != nil })
        m.cancel(0)
        // Nothing latched or held now; a modifier is never "typed only".
        m.down(0, key("leftctrl"))
        #expect(!m.typedOnly(0) { UsKeys.printable[$0] != nil })
        m.up(0)
        #expect(r.log == ["+30", "-30", "+29", "-29"])
    }

    @Test func layerOverridesFollowTheLabelRule() throws {
        let l = try LayoutParser.parse(minimal("""
            {"id":"k","x":0,"y":0,"w":1,"h":1,"label":"↑","code":"KEY_UP",
             "layers":{"fn":{"code":"KEY_PAGEUP"},"nav":{"code":"KEY_HOME","label":"Hm"},"off":{},"note":{"label":"x"}}}
            """), keycodes: keycodes)
        let layers = l.keys[0].layers
        #expect(layers["fn"]!.label == "PgUp") // no label: keycodes.json's
        #expect(layers["nav"]!.label == "Hm")
        #expect(layers["off"]!.label == "") // no code: off and blank
        #expect(layers["off"]!.code == 0)
        #expect(layers["note"]!.label == "x") // off, but labelled
        #expect(layers["note"]!.code == 0)
        #expect(layers["fn"]!.ownLabel == nil) // the printed Fn legend needs its own label
    }

    @Test func theParserTakesTheSchemasTypesWithoutCoercion() throws {
        let ok = #"{"id":"k","x":0,"y":0,"w":1,"h":1,"label":"A","code":"KEY_A"}"#
        _ = try LayoutParser.parse(minimal(ok), keycodes: keycodes)
        let bad = [
            minimal(ok.replacingOccurrences(of: #""x":0"#, with: #""x":"0""#)), // a string as a number
            minimal(ok.replacingOccurrences(of: #""x":0"#, with: #""x":true"#)), // a boolean as a number
            minimal(ok.replacingOccurrences(of: #""label":"A""#, with: #""label":7"#)), // a number as a label
            minimal(ok).replacingOccurrences(of: #""version":1"#, with: #""version":1.9"#),
            minimal(ok).replacingOccurrences(of: #""version":1"#, with: #""version":"1""#),
            minimal(ok.replacingOccurrences(of: "}", with: #","parts":"x"}"#)),
            minimal(ok.replacingOccurrences(of: "}", with: #","parts":[null]}"#)),
            minimal(ok.replacingOccurrences(of: "}", with: #","layers":{"fn":3}}"#)),
        ]
        for json in bad {
            #expect(throws: LayoutError.self, "accepted \(json)") { try LayoutParser.parse(json, keycodes: keycodes) }
        }
    }

    @Test func deeplyNestedJsonIsRefusedBeforeParsing() {
        let deep = minimal(#"{"id":"k","x":0,"y":0,"w":1,"h":1,"label":"A","code":"KEY_A"}"#,
                           #","junk":"# + String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000))
        do {
            _ = try LayoutParser.parse(deep, keycodes: keycodes)
            Issue.record("accepted deep nesting")
        } catch let e as LayoutError {
            #expect(e.message.contains("nested"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        // Brackets inside strings don't count.
        #expect(LayoutParser.nesting(#"{"a":"[[[[{{{{"}"#) == 1)
        #expect(LayoutParser.nesting(#"{"a":"\"[[[["}"#) == 1)
    }
}

func minimal(_ key: String, _ extra: String = "") -> String {
    #"{"format":"omakey-layout","version":1,"id":"t","name":"T","width":2,"height":1"# + extra + #","keys":["# + key + "]}"
}
