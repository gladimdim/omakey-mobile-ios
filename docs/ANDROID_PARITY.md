# Android parity

What the iPhone app has of the Android app's features.

**Android baseline:** `omakey-mobile` `a1ad3f9` (1.2.1 + Bluetooth icon).
When Android moves on, diff from this commit, update the rows, then move
the baseline.

✅ done · 🚧 partly · ⏳ planned (milestone) · ✖ not possible on iOS

## Protocol (`OmakeyKit/Sources/OmakeyProtocol`)

| Feature | Android | iOS |
|---|---|---|
| Packets: HELLO, WELCOME (features, `bt_address`), INPUT (pointer and layout trailers), ACK (LEDs, theme), BYE, REJECT, CLIP, CLIP_REPLY | `Packets.kt` | ✅ M1 |
| HKDF-SHA256, AES-256-GCM, session keys | `Crypto.kt` | ✅ M1 |
| Client state machine, claim of a WELCOME | `ClientSession.kt` | ✅ M1 |
| Held set (ref-counted, ascending), 32-event queue, fractional motion | `KeyState.kt` | ✅ M1 |
| Pairing link, fingerprint | `Pairing.kt` | ✅ M1 |
| Clipboard transfer | `ClipTransfer.kt` | ✅ M1 |
| Test vectors byte for byte | `TestVectorsTest.kt` | ✅ M1 |
| HID descriptor and reports | `Hid.kt` | ✖ no HID device |

## Pairing and connecting

| Feature | iOS |
|---|---|
| QR code scanner | ✅ M4 (AVFoundation) |
| Paste a pairing link | ✅ M4 (`PasteButton`, no paste prompt) |
| `omakey://pair` and `omakey://layout` links | ✅ M4 (layout preview without the drawing until M9) |
| Pairing confirmation: fingerprint, replace warning, link from another app | ✅ M4 |
| Paired list with Online / Checking / Offline | ✅ M3–M4 (Android's "will try Bluetooth" line ✖) |
| Nearby computers (mDNS) | ✅ M3–M4, plus a Local Network help card |
| Find a computer again after its IP changes | ✅ M3 (`UDPLink.addCandidate`) |
| Remember the address that answered | ✅ M4–M5 |
| Unlink a computer | ✅ M4 (context menu) |
| REJECT → "Pair again" | ✅ M3–M5 |
| UDP link: timing rules, DSCP EF | ✅ M3 |
| Bluetooth fallback to omakeyd | ⏳ M11 over Bluetooth LE (RFCOMM ✖) |
| Bluetooth keyboard mode | ✖ |

## Keyboard

| Feature | iOS |
|---|---|
| Layout drawing (shaped keys, split stretch, legends, styles) | ✅ M5 (a layer per key) |
| Touch-down keys, chords, Fn layers | ✅ M2, M5 |
| Sticky keys | ✅ M2, M5 |
| Caps Lock light | ✅ M5 |
| Status pill, switch computer, switch layout | ✅ M5 |
| Typed text ticker | ✅ M5 |
| Release on focus loss, BYE on leaving | ✅ M5 (resign active, background) |
| Haptics | ✅ M5 (UIImpactFeedbackGenerator) |
| Theme from the computer | 🚧 followed on the keyboard ✅ M5; theme picker ⏳ M9 |

## Touchpad

| Feature | iOS |
|---|---|
| Pull-down panel and its gestures | ✅ M6 (header drag, handle, flick, depth effect) |
| Move, tap, hold, tap-drag, double tap | ✅ M6 |
| Two-finger scroll, two- and three-finger taps | ✅ M6 |
| Side buttons, scroll strips | ✅ M6 |
| Speed strip, presets, per-computer speed | ✅ M6 |
| Swipe down on a key pulls the touchpad | ✅ M6 |

## Portrait mode

| Feature | iOS |
|---|---|
| Phone keyboard mirrored (`LineDiff`, `Typist`) | ✅ M2, M7 (hidden `UITextView`) |
| Per-character layout (`us`, `ua`) | ✅ M2, M7 (`textInputMode.primaryLanguage`) |
| Key strips | ✅ M7 |
| Compact touchpad | ✅ M6–M7 |

| Copy and Paste icons in the portrait top bar | 🚧 icons ✅ M7 (Ctrl+Insert / Shift+Insert); with the phone's clipboard ⏳ M8 |
| Portrait mode as a pseudo-layout | ✅ M7 |

## Clipboard

| Feature | iOS |
|---|---|
| Copy, Paste, sensitive text, fallbacks | ⏳ M8 |
| `KEY_COPY` / `KEY_PASTE` layout keys | 🚧 Ctrl+Insert / Shift+Insert ✅ M5; with the phone's clipboard ⏳ M8 |

## Layouts and settings

| Feature | iOS |
|---|---|
| Built-in layouts and keycodes | ✅ M2 (`scripts/sync-spec.sh`) |
| Layout parser and validation | ✅ M2 |
| Layout links (raw DEFLATE, base64url) | ✅ M2 |
| Layouts page, previews, share, import, remove | ⏳ M9 |
| Settings: layout, theme, computers, haptics, typed text | 🚧 haptics, typed text ✅ M4; the rest ⏳ M9 |
| Phone name (iOS only) | ✅ M4 (Settings) |
