import Foundation
import Testing
@testable import OmakeyNet
import OmakeydStandIn
import OmakeyProtocol

/// UDPLink against the omakeyd stand-in on loopback: the timing rules of PROTOCOL.md.
/// Serialized: each test owns real sockets and threads, and the timing
/// assertions want the machine to themselves.
@Suite(.serialized)
struct UDPLinkTests {
    private func connected(_ server: StandInServer, _ listener: RecordingListener, keys: KeyState = KeyState(),
                           claim: @escaping (UDPLink) -> Bool = { _ in true }) -> UDPLink {
        let link = UDPLink(host: server.host, phoneName: "iPhone", keys: keys, listener: listener, claim: claim)
        link.start()
        return link
    }

    @Test func handshakeThenKeysArrive() throws {
        let server = try StandInServer()
        defer { server.stop() }
        let l = RecordingListener()
        let keys = KeyState()
        let link = connected(server, l, keys: keys)
        defer { link.stop() }

        #expect(eventually { l.states.last == .connected })
        #expect(l.states.first == .connecting)
        #expect(l.hostNames == ["test desk"])
        #expect(server.hellos.first?.platform == Wire.platformIOS)
        #expect(server.hellos.first?.name == "iPhone")
        #expect(link.peer == server.endpoint)
        #expect(link.features == Wire.featurePointer | Wire.featureClipboard)

        #expect(keys.press(30))
        link.send()
        #expect(eventually { server.inputs.contains { $0.held == [30] && $0.events.contains(KeyEvent(eseq: 1, code: 30, value: 1)) } })
        #expect(eventually { !keys.hasUnacked })
        #expect(eventually { !l.pings.isEmpty })
    }

    @Test func aMissingAckIsResentQuickly() throws {
        let server = try StandInServer()
        defer { server.stop() }
        let l = RecordingListener()
        let keys = KeyState()
        let link = connected(server, l, keys: keys)
        defer { link.stop() }
        #expect(eventually { l.states.last == .connected })

        server.dropAcks = 2
        let start = Date()
        keys.press(57)
        link.send()
        // Sent at once, then again within the 20 ms resend bound, until an ACK comes.
        #expect(eventually { !keys.hasUnacked })
        let carrying = server.inputs.filter { $0.events.contains { $0.code == 57 } }
        #expect(carrying.count >= 3)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func aQuietLinkSendsAHeartbeatEvery100ms() throws {
        let server = try StandInServer()
        defer { server.stop() }
        let l = RecordingListener()
        let link = connected(server, l)
        defer { link.stop() }
        #expect(eventually { l.states.last == .connected })
        let before = server.inputs.count
        Thread.sleep(forTimeInterval: 0.45)
        let beats = server.inputs.count - before
        #expect((3...6).contains(beats), "\(beats) heartbeats in 450 ms")
    }

    @Test func aForgottenPhoneIsRejectedButKeepsTrying() throws {
        let server = try StandInServer()
        defer { server.stop() }
        server.known = false
        let l = RecordingListener()
        let link = connected(server, l)
        defer { link.stop() }
        #expect(eventually { l.states.last == .rejected })
        // Paired again on the desktop: the next HELLO (every second now) connects.
        server.known = true
        #expect(eventually(within: 2.5) { l.states.last == .connected })
    }

    @Test func stoppingSaysByeTwice() throws {
        let server = try StandInServer()
        defer { server.stop() }
        let l = RecordingListener()
        let link = connected(server, l)
        #expect(eventually { l.states.last == .connected })
        link.stop()
        #expect(eventually { server.byes == 2 })
    }

    @Test func aComputerThatGoesQuietIsGreetedAgain() throws {
        let server = try StandInServer()
        defer { server.stop() }
        let l = RecordingListener()
        let link = connected(server, l)
        defer { link.stop() }
        #expect(eventually { l.states.last == .connected })
        server.silent = true
        // 1.5 s without an ACK: connecting again, saying HELLO.
        #expect(eventually(within: 2.5) { l.states.last == .connecting })
        server.silent = false
        #expect(eventually { l.states.last == .connected })
        #expect(server.hellos.count >= 2)
    }

    @Test func lockLightsAndTheThemeReachTheListener() throws {
        let server = try StandInServer()
        defer { server.stop() }
        let colors = (0..<UInt32(DesktopTheme.keys.count)).map { $0 * 0x111111 }
        server.theme = DesktopTheme(name: "nord", light: false, colors: colors)
        let l = RecordingListener()
        let keys = KeyState()
        let link = connected(server, l, keys: keys)
        defer { link.stop() }
        #expect(eventually { l.themes.first?.name == "nord" })
        #expect(eventually { l.leds.last == 0 })
        // Caps Lock pressed on the phone: the computer's light comes on.
        keys.press(58)
        keys.release(58)
        link.send()
        #expect(eventually { l.leds.last == Ack.ledCaps })
    }

    @Test func eachKeyIsTypedOnceAndAQuietPhoneLetsGo() throws {
        let server = try StandInServer()
        defer { server.stop() }
        let typed = Typed()
        server.onEvent = { typed.append($0) }
        let l = RecordingListener()
        let keys = KeyState()
        let link = connected(server, l, keys: keys)
        #expect(eventually { l.states.last == .connected })
        server.dropAcks = 3 // resends repeat the events; the server applies them once
        keys.press(125)
        link.send()
        keys.press(57)
        link.send()
        keys.release(57)
        link.send()
        #expect(eventually { !keys.hasUnacked })
        #expect(typed.keys == [.key(code: 125, down: true), .key(code: 57, down: true), .key(code: 57, down: false)])
        // Nothing heard for 500 ms while Super is held: the computer lets go.
        server.silent = true
        #expect(eventually { server.heldKeys.isEmpty })
        #expect(typed.keys.last == .key(code: 125, down: false))
        // Heard again: the held set presses it again.
        server.silent = false
        #expect(eventually { server.heldKeys == [125] })
        link.stop() // BYE lets go at once
        #expect(eventually { server.heldKeys.isEmpty })
    }

    @Test func aWelcomeThatIsntClaimedIsNotTaken() throws {
        let server = try StandInServer()
        defer { server.stop() }
        let l = RecordingListener()
        let link = connected(server, l, claim: { _ in false })
        defer { link.stop() }
        #expect(eventually { server.hellos.count >= 2 })
        #expect(l.states == [.connecting])
    }

    @Test func clipboardNeedsTheFeatureThenSendsAPut() throws {
        let server = try StandInServer()
        defer { server.stop() }
        server.features = Wire.featurePointer
        let l = RecordingListener()
        let link = connected(server, l)
        defer { link.stop() }
        #expect(eventually { l.states.last == .connected })
        #expect(!link.clip(ClipTransfer.put("hi", paste: true, sensitive: false)!))
        link.stop()

        server.features = Wire.featurePointer | Wire.featureClipboard
        let l2 = RecordingListener()
        let link2 = connected(server, l2)
        defer { link2.stop() }
        #expect(eventually { l2.states.last == .connected })
        #expect(link2.clip(ClipTransfer.put("Привіт ✓", paste: true, sensitive: false)!))
        #expect(eventually { l2.clips == [.sent] })
        #expect(server.clips.first?.flags == Clip.paste)
        #expect(server.clipboard == "Привіт ✓")

        // And back: the computer's clipboard to the phone.
        server.clipboard = String(repeating: "selected ✓ ", count: 300) // several pieces
        #expect(link2.clip(ClipTransfer.get(copy: true)))
        #expect(eventually { l2.clips.count == 2 })
        #expect(l2.clips.last == .received(text: server.clipboard, sensitive: false))
    }

    @Test func reachabilityFindsTheComputerAndSaysByeAtOnce() throws {
        let server = try StandInServer()
        defer { server.stop() }
        let probe = Reachability(phoneName: "iPhone") { _ in }
        let flag = Reachability.Flag()
        #expect(probe.probe(server.host, near: nil, flag) == server.endpoint)
        #expect(eventually { server.byes == 2 })

        server.silent = true
        let start = Date()
        #expect(probe.probe(server.host, near: nil, flag) == nil)
        #expect(Date().timeIntervalSince(start) >= 1.1)
    }
}
