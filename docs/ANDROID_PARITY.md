# Android parity

What the iPhone app has of the Android app's features.

**Android baseline:** `omakey-mobile` `fd9ebc2` (1.4.0).
When Android moves on, diff from this commit, update the rows, then move
the baseline.

✅ done · 🚧 partly · ⏳ planned (milestone) · ✖ not in the iOS app

## Protocol (`OmakeyKit/Sources/OmakeyProtocol`)

| Feature | Android | iOS |
|---|---|---|
| Packets: HELLO, WELCOME (features, `bt_address`), INPUT (pointer and layout trailers), ACK (LEDs, theme), BYE, REJECT, CLIP, CLIP_REPLY | `Packets.kt` | ✅ M1 |
| HKDF-SHA256, AES-256-GCM, session keys | `Crypto.kt` | ✅ M1 |
| Client state machine, claim of a WELCOME | `ClientSession.kt` | ✅ M1 |
| Held set (ref-counted, ascending), 32-event queue, fractional motion | `KeyState.kt` | ✅ M1 |
| Pairing link, fingerprint | `Pairing.kt` | ✅ M1 |
| WELCOME `wake_mac` (1.4.0): feature bit 2 (`FEATURE_WAKE`), six MAC bytes after a Bluetooth slot that is then always there; an all-zero `bt_address` reads as none | `Packets.kt`, `ClientSession.kt` | ⏳ |
| Pairing link `w=<mac hex>` (1.4.0), kept as `wakeMac` "e8:8d:…" | `Pairing.kt` | ⏳ |
| Wake-on-LAN magic packet (six `0xFF`, the MAC 16 times, 102 bytes), subnet broadcast address | `WakeOnLan.kt` | ⏳ |
| Clipboard transfer | `ClipTransfer.kt` | ✅ M1 |
| Test vectors byte for byte | `TestVectorsTest.kt` | ✅ M1 |
| HID descriptor and reports | `Hid.kt` | ✖ no HID device |

## Pairing and connecting

| Feature | iOS |
|---|---|
| QR code scanner | ✅ M4 (AVFoundation) |
| Paste a pairing link | ✅ M4 (`PasteButton`, no paste prompt) |
| `omakey://pair` and `omakey://layout` links | ✅ M4, M9 |
| Pairing confirmation: fingerprint, replace warning, link from another app | ✅ M4 |
| Paired list with Online / Checking / Offline | ✅ M3–M4 (no "will try Bluetooth" line: no Bluetooth) |
| Nearby computers (mDNS) | ✅ M3–M4, plus a Local Network help card |
| Find a computer again after its IP changes | ✅ M3 (`UDPLink.addCandidate`) |
| Remember the address that answered | ✅ M4–M5 |
| Unlink a computer | ✅ M4 (context menu) |
| REJECT → "Pair again" | ✅ M3–M5 |
| UDP link: timing rules, DSCP EF | ✅ M3 |
| Wake on LAN (1.4.0): keep the last `wakeMac` a Wi-Fi WELCOME gave, forget it after one without the bit | `Stores.kt` `rememberWakeMac`, `KeyboardActivity.kt` | ⏳ |
| Wake on LAN: no answer 2 s after opening the keyboard → magic packet to UDP port 9 at `255.255.255.255` and the Wi-Fi subnet's broadcast address, on the Wi-Fi interface (not a VPN over it), again every 5 s, at most 6; status "Waking <computer>…" | `Waker.kt`, `KeyboardActivity.kt` | ⏳ (sending broadcasts needs Apple's `com.apple.developer.networking.multicast` entitlement; bind to Wi-Fi with `NWParameters.requiredInterfaceType = .wifi`) |
| Paired list: "○ Asleep or off · opening it wakes it" for a computer with a `wakeMac` that doesn't answer | `MainActivity.kt` | ⏳ |
| Log of each connect: time taken and the address that answered | `KeyboardLink.kt` | ⏳ (no keys or addresses of real machines in logs) |
| Bluetooth fallback to omakeyd | ✖ no Bluetooth in the iOS app (dropped 2026-10-09) |
| Bluetooth keyboard mode | ✖ no Bluetooth in the iOS app (and iOS can't be a HID keyboard) |

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
| Theme from the computer | ✅ M5, M9 |

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
| Upper key row you arrange (1.3.0): ten slots, pencil, trembling keys, drag up, move, swap, clear | ✅ (VoiceOver: tap to add or remove, Move left / Move right actions) |
| Compact touchpad | ✅ M6–M7 |

| Copy and Paste icons in the portrait top bar | ✅ M7–M8 |
| Portrait mode as a pseudo-layout | ✅ M7 |

## Clipboard

| Feature | iOS |
|---|---|
| Copy, Paste, sensitive text, fallbacks | ✅ M8 (`changeCount` saves the paste prompt; sensitive text local-only for 2 minutes) |
| `KEY_COPY` / `KEY_PASTE` layout keys | ✅ M5, M8 |

## Layouts and settings

| Feature | iOS |
|---|---|
| Built-in layouts and keycodes | ✅ M2 (`scripts/sync-spec.sh`) |
| Layout parser and validation | ✅ M2 |
| Layout links (raw DEFLATE, base64url) | ✅ M2 |
| Layouts page, previews, share, import, remove | ✅ M9 (import from Files and links; another app's share sheet ⏳ later) |
| Settings: layout, theme, computers, haptics, typed text | ✅ M9 |
| Settings: Wake on LAN switch, on by default (1.4.0); computers that can be woken say "Wake on LAN" | ⏳ |
| Phone name (iOS only) | ✅ M4 (Settings) |

## iOS only

| Feature | iOS |
|---|---|
| Demo computer inside the app ("Try the demo"), for App Review and trying it without a desktop | ✅ M10 |
| Demo popup: what the demo computer received, as typed ("k", "K", "Ctrl+C"), up while typing, gone after 1.5 s | ✅ |
| Touchpad haptics beyond Android's clicks and notches: a soft touch when a finger lands, faint ticks as it glides | ✅ |
| Phone name setting (iOS doesn't give apps the device's name) | ✅ M4, M9 |
| Local Network help card when access is off | ✅ M4 |
| Dynamic Type on the connect, layouts and settings screens | ✅ M10 |
