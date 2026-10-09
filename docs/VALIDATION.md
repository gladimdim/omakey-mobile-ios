# Validation

What has been checked, where, and what still needs a device or a real
desktop. Newest first.

## 2026-10-09: the upper key row you arrange (Android 1.3.0)

- `StripSlotsTests` (Android's `StripSlotsTest`, ported) pass on the Mac.
- `PortraitTour.testTheUpperRowIsYours` on the iOS 27.0 simulator: the
  empty row says how to fill it; with the pencil, a tap on the pages takes
  the first empty slot, a key held and dragged up lands on the slot it's
  dropped on, one dragged along the row swaps places, one dragged down off
  the row or tapped leaves it; nothing types while arranging; after the
  tick the row's keys type, and the row is still there after the keyboard
  is closed and opened again.
- All fifteen app and UI tests pass, on the simulator kept for them.
- Not yet tried: the trembling and drag feel on a phone, and VoiceOver's
  Move left / Move right actions.

## 2026-10-09: orientation, and Paste on iOS 27

- **Orientation.** Closing a keyboard forced the screen upright instead of
  following the phone, and a turn requested while the screen already faced
  that way could land after the phone's own next turn, leaving the screen
  stuck until the phone turned again. Now a closed keyboard hands back to
  the way the phone is held, a turn is only asked for when needed, and
  switching between the landscape keyboard and portrait mode turns first.
  `OrientationTour` keeps the phone upright throughout (the other tours
  turn it, which hid this).
- **Paste.** Reading the phone's clipboard moved back to the main thread,
  loaded asynchronously (`NSItemProvider`), so iOS can show "Allow Paste?".
  On a fresh iOS 26.4 simulator the prompt shows and the phone's text
  reaches the computer. On the iOS 27.0 simulator iOS never shows the
  prompt, for any read, and the read comes back empty, so Paste falls back
  to the computer's own Shift+Insert; `ClipboardTour` marks that step as an
  expected failure there. **To check on an iOS 27 phone.**
- UI tests run on a simulator of their own ("Omakey UI Tests", iOS 27.0),
  apart from the ones used by hand.

## 2026-10-09: portrait mode from the keyboard

Reported: portrait mode showed no controls. Reproduced by picking portrait
mode from the landscape keyboard's ⌨: the portrait keyboard was presented
while the phone was still turning upright and landed sideways, half off
screen, never connecting. Fixed by turning first and presenting after.
`PortraitRoutesTour` covers the three ways in (from the keyboard, from a
paired computer, with the phone held sideways), each until connected with
the phone's keyboard up.

## 2026-10-09: M1–M10 in the simulator (Xcode 27.0, iOS 27 simulator, iPhone 17 Pro)

**On the Mac (`swift test --package-path OmakeyKit`), 89 tests and one opt-in live test:**

- Protocol: every vector in the daemon's `test-vectors.json` byte for byte
  (HELLO, WELCOME, INPUT ×3 with the pointer trailer, ACK, BYE, CLIP put
  and its reply), fingerprint `630D-CD29`, and Android's ProtocolTest and
  ClipTransferTest.
- Keyboard logic: Android's LayoutAndKeyboardTest, KeyLayoutsTest and
  LineDiffTest; Typist pacing and layout switching; theme math; every
  bundled layout parses; an Android (zlib) layout link decodes.
- Networking against the omakeyd stand-in on loopback: handshake, resend
  until ACK, 100 ms heartbeat, REJECT and recovery, lost → HELLO again, BYE
  twice, LEDs and theme, a WELCOME not claimed, clipboard put and get,
  events applied once despite resends, the 500 ms stuck-key release,
  reachability probes.
- `OMAKEY_LIVE=1`: Discovery found a real omakeyd (a Steam Deck) on the LAN
  with its host id and address.

**In the simulator (`scripts/ui-test.sh`), one app test and ten tours (thirteen
with the portrait routes added since), all passing, against the stand-in
hosted by the test runner:**

- Pairing by link: fingerprint, "came from another app", online, unlink;
  the loud warning for a pairing with another key.
- Landscape keyboard: a key, sticky Super + Space, Caps Lock from the
  computer's LED, landscape, BYE on closing.
- Touchpad: tap, drag, two-finger tap, long press, putting it away.
- Portrait mode: typing through the iPhone keyboard with the `us` layout,
  Return, Backspace on an empty line, a key strip key.
- Clipboard: Copy to the phone, Paste with nothing new (Shift+Insert, no
  read), Paste of the phone's new text through the "Allow Paste" prompt.
- Layouts: picking, importing by link through the preview, removing; themes.
- Demo: the demo computer receives a key and shows it, and stays out of the
  computers list.

## Still to check on a device with a real desktop

- Latency and jitter against Android on the same Wi-Fi (the Wi-Fi radio's
  power save can't be controlled on iOS).
- Chords of several fingers (the simulator gives two), touches at the
  screen edges (the system-gesture gate), and the 5-touch limit.
- The QR scanner with a real code; the Local Network prompt on a clean
  install, and the help card after declining it.
- Portrait mode with autocorrection, the space-bar cursor, Gboard or
  SwiftKey, and a Ukrainian keyboard switching to `ua`.
- Touchpad feel: speed per preset, scrolling, side buttons with the thumb,
  haptics.
- Leaving and coming back: Control Center, a call, the app switcher, the
  screen locking; nothing stuck on the computer.
- Pairing over a real omakeyd (Omarchy and the Steam Deck), and the bar
  widget listing the phone by its name as an iOS device.
