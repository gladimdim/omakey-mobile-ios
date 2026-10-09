# Omakey for iOS: implementation plan

*Written 2026-10-09.* References:

| What | Where | Baseline |
|------|-------|----------|
| Android app (the reference) | `../omakey-mobile` | `a1ad3f9` (1.2.1 + Bluetooth icon) |
| Desktop daemon `omakeyd`, bar widget | `../omakey-omarchy-plugin` | `cdcc9b4` |
| Wire protocol | `omakey-omarchy-plugin/docs/PROTOCOL.md` | version 1 |
| Test vectors | `omakey-omarchy-plugin/docs/test-vectors.json` | identical to Android's copy |
| Layout format | `omakey-layout-studio/spec/LAYOUT.md` | `format: omakey-layout`, version 1 |

The iOS app is a native port of the Android app. The phone becomes a
keyboard and touchpad for a computer running `omakeyd`. It speaks the same
protocol, reads the same layout files and pairs with the same QR code, so
the desktop needs no changes.

**Decided (2026-10-09):**

| Question | Decision |
|---|---|
| Team and signing | the one developer team used by `super-desktop-ios` (`29UL2Y36R9`), automatic signing |
| Bundle id | `com.gladimdim.omakey` (the Android id, and the `com.gladimdim.*` pattern of the other apps) |
| Release path | the App Store from the first public release. TestFlight only for builds on our own devices |
| License | MIT, as `omakey-omarchy-plugin` |
| iPad | later (M12). iPhone only until then |
| Bluetooth Low Energy | planned for later (M11, §12) |

---

## 1. Scope

**In (parity with Android 1.2.1):** QR and link pairing with fingerprint
check, mDNS discovery and reachability, the landscape keyboard with all 10
built-in layouts and imported ones, sticky keys, Fn layers, Caps Lock
light, the pull-down touchpad, portrait mode (the phone's own keyboard
under the touchpad), the shared clipboard, desktop themes, haptics, the
typed-text ticker, layout sharing and import, and settings.

**Out, because iOS can't do it:**

- **Bluetooth keyboard mode** (the phone as a standard HID keyboard for any
  computer). iOS has no HID Device profile for apps. Classic Bluetooth is
  closed to apps, and CoreBluetooth won't let an app advertise the HID
  service (0x1812). The Bluetooth keyboard section of the connect screen
  isn't there on iOS.
- **Bluetooth fallback to omakeyd** (RFCOMM). iOS has no public RFCOMM
  API: ExternalAccessory only works with MFi accessories. iOS is Wi-Fi only
  until M11, which adds a Bluetooth Low Energy fallback (§12). The `b`
  address in a pairing link and the `bt_address` in WELCOME are still
  parsed and stored.

---

## 2. Feature inventory: Android → iOS

M = milestone (§5).

### Pairing and connecting

| Feature | Android | iOS | M |
|---|---|---|---|
| Pair by QR code | zxing-android-embedded | AVFoundation `AVCaptureMetadataOutput` scanner | 4 |
| Pair by pasted link | clipboard button | SwiftUI `PasteButton` (no paste prompt) | 4 |
| `omakey://pair`, `omakey://layout` links | intent filters | `CFBundleURLTypes` + `onOpenURL` | 4 |
| Confirm before saving: name, addresses, fingerprint `ABCD-1234`, loud warning when it replaces a pairing with another key, note when the link came from another app | AlertDialog | sheet | 4 |
| Paired list: Online / Checking… / Offline, by HELLO+BYE probes every 4 s | `Reachability` | same, own UDP socket | 3–4 |
| Nearby unpaired computers (mDNS `_omakey._udp`, TXT `id`, `n`) | `NsdManager` | `NWBrowser` + TXT record | 3–4 |
| Find a computer again by host id after its IP changes | mDNS candidates fed to the link | same | 3 |
| Remember the address that answered, first of at most 6 | `HostStore.rememberAddress` | same | 3 |
| Unlink a computer | long press | context menu and swipe action | 4 |
| REJECT shows "doesn't know this phone. Pair again." and never deletes the pairing | | same | 3 |
| Bluetooth fallback over RFCOMM | `RfcommLink`, `FallbackLink` | not possible (§1) | — |
| Bluetooth keyboard mode | `BluetoothHidLink`, `Hid.kt` | not possible (§1) | — |

### Keyboard (landscape)

| Feature | Android | iOS | M |
|---|---|---|---|
| Layout drawing: shaped keys (union of parts), split layouts stretched to the screen edges, fitted labels, shifted sub-legend, printed Fn legend, key styles | `KeyboardView` on a Canvas | `KeyboardView`, one `CALayer` per key, so a press redraws one key | 5 |
| Keys fire on touch-down; one key per finger; chords; Fn layers; the code a finger pressed is the code its lift releases | `KeyboardModel` | port of `KeyboardModel`, unchanged | 2, 5 |
| Sticky keys (⇧ in the top bar): tap a modifier for the next key, twice to lock; Fn one-shot | | same | 5 |
| Caps Lock follows the computer's LED (ACK `leds`) | | same | 5 |
| Status pill: `● Connecting to X…`, `● X · 12 ms`, `● X doesn't know this phone. Pair again.`; tap to switch computer | | same strings and colors | 5 |
| Switch computer without leaving (⇄), "Pair another…" | dialog | `UIMenu` / sheet | 5 |
| Switch layout (⌨) | landscape layouts page | sheet with the layouts list | 5, 9 |
| Typed text ticker, running right to left; shortcuts shown as `Ctrl+C` | `TypedTicker` | `CADisplayLink`-driven view | 5 |
| Let go of every key when the screen loses focus; BYE (twice) on leaving; the daemon's 500 ms timeout covers the rest | `onPause`, `onStop` | `willResignActive` (Control Center, calls), `didEnterBackground` inside `beginBackgroundTask` | 5 |
| Low-latency Wi-Fi | `WIFI_MODE_FULL_LOW_LATENCY` lock | no API: 100 ms heartbeat keeps the radio awake, DSCP EF + `NET_SERVICE_TYPE_VO` | 3 |
| Fullscreen, screen kept on, draw under the cutout | window flags | `isIdleTimerDisabled`, status bar hidden, home indicator auto-hidden, `preferredScreenEdgesDeferringSystemGestures = .all` | 5 |
| Haptics: key down/up, button down/up, tap click, force click, scroll notch | Vibrator primitives | `UIImpactFeedbackGenerator` (rigid/soft with intensity) and Core Haptics transients for the double clicks | 5 |
| Follow the computer's Omarchy theme (ACK `theme`) | `Palette.fromComputer` | same color math | 5, 9 |

### Touchpad

All constants are ported from `TouchpadView.kt`: `TAP_MS` 220, `MULTI_TAP_MS` 300,
`LONG_PRESS_MS` 450, `DRAG_WINDOW_MS` 150, `BUTTON_DELAY_MS` 120, slop 6 dp,
swipe slop 14 dp, motion ×1.1, scroll 2.4 units/px, notch 120, speed 0.3–3×
on a log scale snapped to 0.05.

| Feature | iOS notes | M |
|---|---|---|
| Pull-down panel over the keyboard: drag the top bar, tap the handle, flick; the keyboard sinks back as the sheet lands | `UIViewPropertyAnimator` with a spring that starts at the finger's velocity; 120 Hz via `CADisableMinimumFrameDurationOnPhone` | 6 |
| Swipe down on a typing key pulls the touchpad and takes the character back with Backspace | same rule (0.55 key units within 250 ms) | 6 |
| One finger moves; tap clicks (waits 150 ms for a drag); hold right-clicks; tap then touch and move drags; double tap double-clicks | `UITouch` identity → pointer slots; `coalescedTouches(for:)` for every digitizer sample | 6 |
| Two fingers scroll (content follows); two-finger tap right-clicks, three-finger tap middle-clicks | same | 6 |
| Side buttons, mirrored: Left, Right, Ctrl+Left, Shift+Left, pressed 120 ms late so a swipe up never clicks | same | 6 |
| Scroll strips down each side, with a tick every notch | same | 6 |
| Speed strip at the top: log slider and preset chip (Laptop … Triple 1080p), kept per computer | `UserDefaults` keys `sens:<id>`, `preset:<id>` | 6 |
| Grab bar along the bottom: swipe up or tap to put it away, kept above the home indicator | `safeAreaInsets.bottom` | 6 |
| "Update Omakey on your computer" when WELCOME lacks the pointer feature | same | 6 |

### Portrait mode

| Feature | Android | iOS | M |
|---|---|---|---|
| The phone's own keyboard types into the computer, autocorrect included: each change of a one-line buffer goes out as arrows, Backspaces and characters | `ImeCapture` + `LineDiff` | hidden `UITextView` subclass: `textViewDidChange` and selection changes run `LineDiff`; `deleteBackward()` on an empty line sends Backspace; `"\n"` sends Enter and starts the line again | 7 |
| Strokes paced every 8 ms, held back while 24+ events are unacknowledged | `Typist` | same, `DispatchSourceTimer` on main | 2, 7 |
| Each character goes with an xkb layout that has it (`us`, `ua`); switching waits until everything before is acknowledged | `KeyLayouts.pick`, IME subtype | same, language from `textInputMode.primaryLanguage` | 2, 7 |
| Two key strips above the keyboard, each swiped through its own pages: digits, F1–F12, navigation, system (Super/Ctrl/Alt/Shift sticky, PrtSc, media) | `KeyStrip` | `KeyStripView`, pinned to `keyboardLayoutGuide` | 7 |
| Compact touchpad: plain Ctrl and Shift buttons that latch | `compact` | same | 7 |
| "Tap to open the keyboard" in the keyboard's place when it's hidden | | same, sized to the last keyboard height | 7 |
| Copy and Paste icons in the top bar | `ClipIcon` | SF Symbols or drawn outlines | 8 |

### Clipboard (omakeyd 1.2.0+, WELCOME feature bit 1)

| Feature | iOS notes | M |
|---|---|---|
| **Copy**: CLIP get with the copy flag, then put the text on the phone's clipboard | `UIPasteboard.general`; sensitive text set with `.localOnly` and a short `.expirationDate`, so it stays off Universal Clipboard | 8 |
| **Paste**: send the phone's clipboard when it is newer than what the two last swapped (SHA-256 kept, never the text), else Shift+Insert | `changeCount` tells "unchanged" without reading, so no paste prompt; reading prompts only when there is something new | 8 |
| Without the feature, or when the clipboard is out of reach: Ctrl+Insert / Shift+Insert, 25 ms between steps | same | 8 |
| `KEY_COPY` (133) and `KEY_PASTE` (135) layout keys | same | 8 |
| Messages: empty, too large (64 KB), didn't answer, unreachable | toast-style banner | 8 |

### Layouts and settings

| Feature | iOS notes | M |
|---|---|---|
| 10 built-in layouts, Omakey Pro first and recommended | bundle resources, synced from the studio | 2, 9 |
| Layouts page: live previews, IN USE / IMPORTED / MODE badges, ★ Recommended | SwiftUI list; previews are non-interactive `KeyboardView`s | 9 |
| Share a layout as an `omakey://layout?d=…` link, or as JSON when large | `ShareLink` | 9 |
| Import from a file, a link, pasted JSON, or a file opened from Files; preview first, warn when it replaces an imported layout with the same id | `fileImporter`, `onOpenURL`, `CFBundleDocumentTypes` for `public.json` | 9 |
| Import from another app's share sheet | Share extension | later |
| Portrait mode as a pseudo-layout (`portrait`) | same | 7, 9 |
| Settings: default layout, theme (9 + From computer), computers with Unlink, haptics, show typed text, version | SwiftUI `Form` | 9 |
| **Phone name** (iOS only) | `UIDevice.name` is just "iPhone" without a restricted entitlement, so the name the desktop shows is a setting, default "iPhone" | 9 |

---

## 3. Where iOS differs, and what we do about it

| Android | iOS | What we do |
|---|---|---|
| `requestUnbufferedDispatch` for touchpad moves | touches arrive once per display frame | read `coalescedTouches(for:)` for every sample; ask for 120 Hz on ProMotion phones |
| Wi-Fi lock against power save | no API | the 100 ms heartbeat already keeps the radio awake; measure ping on a device against Android on the same Wi-Fi |
| Local network needs no permission | **Local Network privacy prompt** on the first LAN packet | `NSLocalNetworkUsageDescription`, `NSBonjourServices = [_omakey._udp]`. When the browser reports a policy denial, show a screen that explains it and links to Settings |
| `Settings.Global.DEVICE_NAME` | `UIDevice.name` is generic | Phone name setting |
| Reading the clipboard is silent (a notice on 12+) | paste permission prompt (iOS 16+) | `PasteButton` for Paste link; `changeCount` before reading for Paste |
| Keystore key wraps pairing keys; backups off | Keychain | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable, so keys never leave the phone. Keychain items survive deleting the app, so a fresh install (no `UserDefaults` marker) wipes them, as uninstalling does on Android |
| Per-activity orientation in the manifest | per view controller | the keyboard is a `UIViewController` with `supportedInterfaceOrientations = .landscape` (portrait mode: `.portrait`), plus an AppDelegate orientation lock and `requestGeometryUpdate` |
| Raw multi-touch, any number of pointers | iPhone reports at most 5 touches | chords of up to 5 fingers; `KeyboardModel` keeps 32 slots |
| `Deflater(BEST_COMPRESSION, nowrap)` | `Compression` `COMPRESSION_ZLIB` is raw DEFLATE | same format, so links interoperate; iOS links may be a little longer |
| `org.json` with typed reads | `JSONSerialization` | keep the parser's no-coercion rules: `NSNumber` that is a `CFBoolean` is not a number, `7` is not a label. Run the nesting-depth check before parsing |
| `URLDecoder` (`+` is a space) | `URLComponents` (`+` stays `+`) | decode the query by hand to match. omakeyd writes `%20`, but a hand-made link may not |

---

## 4. Architecture

### Repository layout

```
omakey-mobile-ios/
  Omakey.xcodeproj           checked in; no project generator; synchronized folders,
                             so files under Omakey/ and OmakeyTests/ need no project edit
  Omakey/                    the app target
    App/                     OmakeyApp, AppDelegate (orientation lock), Info.plist, PrivacyInfo.xcprivacy
    Store/                   HostStore (Keychain), LayoutStore, AppSettings, TouchpadSettings
    Keyboard/                KeyboardViewController, KeyboardView, TouchpadView, PanelController,
                             KeyStripView, TypedTickerView, TextCapture, StatusPill, Haptics, ClipboardBridge
    Screens/                 ConnectView, PairingSheet, QRScanner, LayoutsView, LayoutPreview,
                             SettingsView, HostPicker, PresetPicker, LocalNetworkHelp
    Theme/                   Palette (UIKit + SwiftUI colors)
    Resources/               keycodes.json, layouts/*.json, Assets.xcassets (icon from the Android artwork)
  OmakeyKit/                 local Swift package, linked by the app, tested with `swift test` on macOS
    Package.swift
    Sources/OmakeyProtocol/  Wire, Packets, Crypto, ClientSession, KeyState, Pairing, ClipTransfer, Hex
    Sources/OmakeyCore/      Keycodes, Layout, LayoutParser, LayoutLink, KeyboardModel, UsKeys,
                             KeyLayouts, LineDiff, Typist, PointerPresets, Themes, Spec/ (layouts)
    Sources/OmakeyNet/       Link, UDPLink, Reachability, Discovery (no UIKit, so tested on the Mac)
    Tests/OmakeyProtocolTests/  TestVectorsTests, ProtocolTests, ClipTransferTests, Fixtures/test-vectors.json
    Tests/OmakeyCoreTests/      LayoutAndKeyboardTests, TypingTests (KeyLayouts, LineDiff, Typist, themes)
    Tests/OmakeyNetTests/       UDPLink and Reachability against a fake omakeyd on loopback;
                                live Discovery with OMAKEY_LIVE=1
  OmakeyTests/               app-level tests on a simulator
  scripts/
    sync-spec.sh             layouts + keycodes from ../omakey-layout-studio/spec (mirror, not merge)
    sync-vectors.sh          test-vectors.json from ../omakey-omarchy-plugin/docs
    check.sh                 swift test + unsigned generic iOS build
  docs/                      PLAN.md (this file), ANDROID_PARITY.md, VALIDATION.md
  store/                     App Store metadata, privacy answers, review notes (M10)
  AGENTS.md                  contributor and agent rules
  LICENSE                    MIT
```

### Kotlin → Swift map

| Android | iOS |
|---|---|
| `protocol/Packets.kt` | `OmakeyProtocol/Packets.swift`: `Wire`, `Packet`, `Hello`, `Welcome`, `Input`, `Ack`, `DesktopTheme`, `Clip`. Big-endian reader/writer over `[UInt8]` |
| `protocol/Crypto.kt` | `Crypto.swift`: `HKDF<SHA256>.extract` / `.expand`, `AES.GCM.seal(_:using:nonce:authenticating:)`; open returns `nil` on a bad tag |
| `protocol/ClientSession.kt` | `ClientSession.swift`, with a `platform` parameter (iOS sends `2`; the vector test passes `1`) and an injectable random source |
| `protocol/KeyState.kt` | `KeyState.swift`: ref-counted held set, ascending; event queue capped at 32; fractional motion; guarded by `OSAllocatedUnfairLock` |
| `protocol/Pairing.kt` | `Pairing.swift`: `HostRecord`, `PairingURI`, fingerprint from `SHA256` |
| `protocol/ClipTransfer.kt` | `ClipTransfer.swift` |
| `protocol/Hid.kt` | not ported (no HID device on iOS) |
| `layout/Layout.kt`, `LayoutLink.kt` | `OmakeyCore/Layout*.swift`, `LayoutLink.swift` |
| `keyboard/KeyboardModel.kt`, `UsKeys.kt`, `KeyLayouts.kt` | same names in `OmakeyCore` |
| `ui/PhoneKeyboard.kt` | `LineDiff.swift`, `Typist.swift` (core, scheduler injected for tests); the input capture is `Keyboard/TextCapture.swift` |
| `ui/PointerPresets.kt`, `ui/Palette.kt` | `PointerPresets.swift`; theme mixing in `ThemeMath.swift`, colors in `Theme/Palette.swift` |
| `net/Link.kt` | `OmakeyNet/Link.swift` protocol (states: connecting, connected, rejected) |
| `net/KeyboardLink.kt` | `OmakeyNet/UDPLink.swift` |
| `net/FallbackLink.kt`, `RfcommLink.kt`, `BluetoothHidLink.kt` | not ported; `Link` leaves room for a second transport |
| `net/Discovery.kt`, `Reachability.kt` | `OmakeyNet/Discovery.swift` (`NWBrowser`), `OmakeyNet/Reachability.swift` |
| `store/Stores.kt` | `HostStore` (Keychain), `LayoutStore` (Application Support/layouts), `AppSettings` (`UserDefaults`) |
| `ui/MainActivity.kt` | `ConnectView` (SwiftUI) |
| `ui/KeyboardActivity.kt` (+ portrait subclass) | `KeyboardViewController` (UIKit), one class with a portrait flag |
| `keyboard/KeyboardView.kt`, `TouchpadView.kt`, `ui/KeyStrip.kt`, `ui/TypedTicker.kt` | `UIView` subclasses of the same names |
| `ui/ClipboardBridge.kt`, `keyboard/Haptics.kt` | same names |
| `ui/SettingsActivity.kt`, `LayoutsActivity.kt`, `LayoutPreview.kt`, `PortraitPreview.kt`, `Unlink.kt` | SwiftUI screens and sheets |

### Threads

- **Main thread**: touches, `KeyboardModel`, `Typist`, UI. A key change
  updates `KeyState` and calls `link.send()`, which sends the INPUT right
  there with a non-blocking `sendto`, just as Android sends from the touch
  thread.
- **Network thread** (one per link, QoS `.userInteractive`): a `poll()` loop
  over the UDP socket and a wake pipe (the `Selector.wakeup()` equivalent).
  It handles the handshake, resends, the heartbeat, ACKs, CLIP and the
  LOST → re-HELLO rule. The rules match `KeyboardLink.kt`: resend after
  1.5 × smoothed ping + 2 ms (5–20 ms), heartbeat every 100 ms, HELLO
  after 50, 100, 200, then every 250 ms (1 s after a REJECT), lost after
  1.5 s of silence, and BYE twice on stop.
- Everything that touches a `ClientSession` holds its lock, so packet
  counters leave in the order they were assigned. `KeyState` has its own
  lock. Both are `final class … : @unchecked Sendable`, and the lock is
  documented on the type.
- Link callbacks hop to the main queue, and are dropped there when the
  link has been replaced (the `link !== l` check in `KeyboardActivity`).
- Swift 6 language mode. UI types are `@MainActor`.

### Decisions

1. **A BSD UDP socket, not `NWConnection`, for the keyboard link.** One
   unconnected socket says HELLO to every candidate address and takes the
   peer from whichever answers, which is how `KeyboardLink` works. An INPUT
   goes out synchronously from the touch handler with no queue hop. The
   socket gets `IP_TOS 0xB8` (DSCP EF) and `SO_NET_SERVICE_TYPE =
   NET_SERVICE_TYPE_VO`, so Wi-Fi WMM queues it as voice. `NWConnection` is
   one connection per endpoint with asynchronous sends. The Android README
   suggested it for iOS; this supersedes that. An `NWPathMonitor` triggers
   an immediate re-HELLO when the Wi-Fi network changes; otherwise the
   1.5 s lost timer handles it.
2. **`NWBrowser` for Bonjour**, with `.bonjourWithTXTRecord` for `id` and
   `n`. An IPv4 address for the socket comes from a UDP `NWConnection` to
   the service, which resolves it without sending anything. A browser in the policy-denied state is how we
   learn that Local Network access was refused.
3. **CryptoKit only.** No third-party code anywhere: no dependencies, as on
   Android, where the only one is zxing.
4. **UIKit for touch, SwiftUI for screens.** The keyboard, touchpad, key
   strips and ticker are `UIView`s with `touchesBegan/Moved/Ended/Cancelled`
   and `isMultipleTouchEnabled`. The keyboard screen is a `UIViewController`
   presented full screen from the root. Orientation lock, status bar, home
   indicator and edge-gesture deferral are view-controller properties that
   SwiftUI doesn't reach. The connect, layouts and settings screens are
   SwiftUI.
5. **AVFoundation QR scanner.** It works on every supported iPhone and
   needs no model download. VisionKit's `DataScannerViewController` needs
   an A12 or newer and adds nothing for a QR code.
6. **iOS 17 minimum, iPhone only, Xcode 27, no dependencies.** This
   matches `super-desktop-ios`. `TARGETED_DEVICE_FAMILY = 1` until iPad
   support (M12).
7. **Same layouts and keycodes as Android**, synced from
   `omakey-layout-studio/spec` by `scripts/sync-spec.sh`, the same script
   with an iOS destination.
8. **Platform byte 2.** `omakeyd` parses it and needs no change.

---

## 5. Milestones

Each milestone ends with a commit that builds and passes its tests.
`scripts/check.sh` runs `swift test --package-path OmakeyKit` plus an
unsigned generic iOS build.

### M0: Plan and repository (done)
Plan, README, `.gitignore`, MIT `LICENSE`, the public GitHub repository
`gladimdim/omakey-mobile-ios`.

### M1: Project skeleton and `OmakeyProtocol` (done, except reserving the name)
- `Omakey.xcodeproj` (app + unit test targets), `OmakeyKit` package linked
  as a local package, `AGENTS.md`, `docs/ANDROID_PARITY.md` (one row per
  feature in §2, with Android baseline `a1ad3f9`), `scripts/check.sh`,
  `scripts/sync-vectors.sh`.
- Signing: team `29UL2Y36R9`, automatic, bundle id `com.gladimdim.omakey`,
  test target `com.gladimdim.omakey.tests`, version 1.0.0 (1).
- Reserve the name: register the bundle id and create the App Store Connect
  app record with `asc`. This is an account change, so ask first.
- Port `Packets`, `Crypto`, `ClientSession`, `KeyState`, `Pairing`,
  `ClipTransfer`, `Hex`.
- Port the tests: `TestVectorsTest` (4), `ProtocolTest` (22),
  `ClipTransferTest` (5).
- **Done when:** every vector in `test-vectors.json` reproduces byte for
  byte (HELLO, WELCOME, INPUT 1, 2 and 4 with the pointer trailer, ACK, BYE,
  CLIP put and CLIP_REPLY); the fingerprint of the vector key is `630D-CD29`;
  an iOS HELLO decodes with platform 2.

### M2: `OmakeyCore` (done)
- `Keycodes`, `Layout`, `LayoutParser` (all LAYOUT.md checks: id and layer
  regexes, sizes, 256 keys, 16-character labels, 8 parts, 256 KB, depth
  32), `LayoutLink`, `KeyboardModel`, `UsKeys`, `KeyLayouts` (`us`, `ua`),
  `LineDiff`, `Typist`, `PointerPresets`, `ThemeMath`.
- Bundle `keycodes.json` and `layouts/*.json`. Every built-in layout must
  parse.
- Port the tests: `LayoutAndKeyboardTest` (19), `KeyLayoutsTest` (4),
  `LineDiffTest` (7), and add `Typist` tests with a manual clock.
- **Done when:** the ported tests pass; a layout link made on Android
  decodes on iOS and the other way round.

### M3: Networking (done)
- `UDPLink` with the timing rules above. `Discovery` routes mDNS candidates
  for the target's host id into the link. `Reachability` probes every paired
  computer every 4 s (HELLO, then BYE as soon as WELCOME comes back,
  1.2 s timeout, 300 ms retry). Local Network status.
- Networking lives in the package's `OmakeyNet` target, not the app, so
  its tests run on the Mac. `OmakeyNetTests`: a fake omakeyd on `127.0.0.1`
  built from the package's WELCOME and ACK encoders. Cover the handshake, the claim of the first
  WELCOME, resend until ACK, the heartbeat, a REJECT taken only from a
  HELLO address, lost → re-HELLO, BYE twice on stop, and theme and LED
  delivery.
- **Done when:** the fake-server tests pass, and on a device a throwaway
  debug screen connects to a real `omakeyd run --dry-run`, which prints the
  keys.

### M4: Connect screen, pairing, stores, links (done)
- `HostStore` (Keychain, wipe on fresh install), `AppSettings`,
  `LayoutStore`.
- `ConnectView`: header with ⚙, **Select computer to use** (status lines
  as on Android), **Nearby**, **Pair a computer** (Scan QR code, Paste
  link), **Layout** button.
- QR scanner, pairing sheet with fingerprint and replace warning, and
  `omakey://` links from outside (with the "came from another app" note).
- Local Network help screen.
- **Done when:** pairing with a real desktop works from both QR and link,
  survives a relaunch, and an unlinked computer disappears. Checked so far
  by `OmakeyUITests` against the omakeyd stand-in (link pairing, the
  fingerprint, the replace warning, online, unlink); the QR scanner needs
  a device and a real desktop.

### M5: Landscape keyboard
- `KeyboardViewController`: top bar (⌄ touchpad handle, status pill,
  ⇧ sticky, ⇄ computer, ⌨ layout, ✕), the pull grip, typed ticker,
  `KeyboardView`.
- Lifecycle: release on resign-active, stop with BYE on background,
  reconnect on foreground. Idle timer, hidden bars, deferred edge gestures.
- Haptics, Caps Lock light, theme from the computer (recolor in place
  instead of Android's `recreate()`).
- Host picker that switches computers in place: release everything, BYE
  the old one, reset Caps Lock and the ticker.
- **Done when:** on a device, `SUPER + SPACE`, `CTRL + SHIFT + T`, Fn
  layers on Omakey Pro and sticky keys all work on Omarchy, nothing sticks
  after a Control Center pull or an app switch, and ping is within a couple
  of ms of Android on the same Wi-Fi.

### M6: Touchpad
- `TouchpadView` port with every gesture and constant above, plus
  `PanelController` for the sheet: drag from the top bar, from a key swipe,
  from the grab bar or a side button, with the flick decision and the depth
  effect on the keyboard.
- Speed strip, preset picker, per-computer speed.
- **Done when:** every touchpad bullet in the Android README works against
  omakeyd 0.3+, and the "update" hint shows against an older one.

### M7: Portrait mode
- `TextCapture` (hidden `UITextView`): traits keep the system keyboard
  useful but harmless for a computer. Autocorrect stays on (it's the point),
  while smart quotes, smart dashes and inline predictions are off, because
  the computer layouts can't type `’` or `—`.
- `Typist` with the layout gate (`keys.layout`, `unacked == 0`) and the busy
  rule (`unacked > 24`).
- Two `KeyStripView`s pinned to `keyboardLayoutGuide`, pages remembered
  (`stripPage`, `stripPage2`). Compact touchpad above. Reopen placeholder.
- Portrait as a pseudo-layout: picking it switches screens for the same
  computer.
- **Done when:** typing, autocorrection, cursor moves with the space bar,
  deleting past the line, Enter, a Ukrainian keyboard switching to `ua` and
  shortcuts with the strip's Ctrl all arrive correctly.

### M8: Clipboard
- `ClipboardBridge` port, top bar icons in portrait, and the `KEY_COPY` /
  `KEY_PASTE` keys.
- **Done when:** copy desktop → phone, phone → paste on desktop, the
  "nothing new" path (Shift+Insert without reading the phone's clipboard),
  a password marked sensitive, 64 KB limits, and the Steam Deck Game Mode
  "failed" path all behave as on Android 1.2.0.

### M9: Layouts and settings
- `LayoutsView` with previews and badges, share (link, or JSON file when
  the link is too long), import (file, link, text) with preview and replace
  warning, remove.
- `SettingsView`: default layout, theme swatches including From computer,
  computers with Unlink, haptics, typed text, phone name, version.
- **Done when:** a layout made in the studio imports by link and by file,
  shares back, and every built-in previews correctly.

### M10: Polish and release
- App icon from `artwork/omakey.svg`, launch screen, VoiceOver labels on the
  bars and connect screen, Dynamic Type on SwiftUI screens.
- **Demo mode for App Review.** Reviewers have no omakeyd. A "Demo computer"
  entry talks to an in-process stand-in for omakeyd on loopback, built from
  the package's encoders, and shows what it receives. Add review notes and a
  video of a real Omarchy desktop.
- `PrivacyInfo.xcprivacy` (UserDefaults reason `CA92.1`), App Privacy
  "Data Not Collected", export compliance answers, `store/` metadata
  (`store/README.md` is the submission checklist), screenshots. The `asc`
  CLI talks to App Store Connect. Credentials stay outside the repository,
  as in `super-desktop-ios`.
- Release 1.0.0 straight to the App Store, free, iPhone only. Opt out of
  availability on Apple silicon Macs: there's no multi-touch there. Internal
  TestFlight builds only for testing on our own devices, with no external
  beta. Submitting for review needs your OK.
- `docs/VALIDATION.md`: what ran on which device and simulator.

### M11 (later): Bluetooth Low Energy fallback
Off Wi-Fi, the iPhone reaches omakeyd over Bluetooth LE. This needs a
daemon release first. Design in §12.

### M12 (later): iPad
A large keyboard surface (up to 11 touches) without haptics: universal
layout work, all four orientations or full-screen only, and the keyboard
sized for a 13″ screen.

### Later, unscheduled
- **Share extension** for importing layouts from other apps' share sheets.

---

## 6. Testing and verification

- **Unit (`swift test`, macOS, no simulator):** 61 ported Android tests
  (`ProtocolTest` 22, `ClipTransferTest` 5, `TestVectorsTest` 4,
  `LayoutAndKeyboardTest` 19, `KeyLayoutsTest` 4, `LineDiffTest` 7), plus
  `Typist` tests and an iOS-platform HELLO test. Not ported: `HidTest` (9)
  and `FallbackLinkTest` (6), which cover features iOS doesn't have.
- **Link tests:** `UDPLink` against the in-process fake omakeyd (M3).
- **Against a real desktop:** `omakeyd run --dry-run --port 47899` prints
  keys instead of typing, and the bar widget shows the phone, its address,
  packet loss and held keys. Never point tests at a desktop session that
  types for real.
- **Simulator limits:** no camera (pair with a link), Option-drag gives only
  two touches, no haptics. Local network works through the Mac. Record them
  in `docs/VALIDATION.md`.
- **Device checks:** latency against Android on the same Wi-Fi, touches at
  the screen edges, chords of 5, and the Local Network prompt on a clean
  install.

---

## 7. Desktop side

Nothing is required for M1–M10. omakeyd accepts platform `2` in HELLO and
lists the phone by the name it sends. M11 needs a daemon release (§12).
Follow-ups in sibling repositories, each only with approval:

- `omakey-mobile/README.md`: its `ios/` row ("Planned (M3)") should point to
  this repository.
- Plugin README and website: an App Store link next to the APK once
  published.

---

## 8. Release checklist (M10)

- Bundle id `com.gladimdim.omakey`, team `29UL2Y36R9`, automatic signing.
- App Store Connect record (made in M1), category Utilities, price free,
  age rating, privacy policy URL (a page in this repository).
- `Info.plist`: `NSLocalNetworkUsageDescription`, `NSBonjourServices`,
  `NSCameraUsageDescription`, `CFBundleURLTypes` (`omakey`),
  `CFBundleDocumentTypes` (`public.json`, opened as a copy),
  `UISupportedInterfaceOrientations` (portrait + both landscapes),
  `CADisableMinimumFrameDurationOnPhone`, `ITSAppUsesNonExemptEncryption`.
- Export compliance: the app encrypts its own traffic with AES-256-GCM
  through CryptoKit. Answer Apple's questions before the first upload.
- App Review: demo mode, review notes, a video.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| iOS's system-gesture gate can delay `touchesBegan` for touches that start at a screen edge, even with deferral | measure on a device; keep the bottom inset free like the Android grab bar; if needed, inset the keyboard slightly from the edges |
| No control over Wi-Fi power save | heartbeat, DSCP/WMM voice; compare ping and jitter with Android |
| The user refuses Local Network access, so nothing works | a clear help screen that links to Settings, shown as soon as the browser reports the denial |
| Third-party keyboards (Gboard, SwiftKey for iOS) change text in unusual ways in portrait mode | `LineDiff` sends any text change as edits; test with each |
| The paste prompt annoys people | `changeCount` avoids reading when nothing changed; `PasteButton` where we can |
| App Review can't test without omakeyd | demo mode |
| Keychain items outliving a reinstall bring back stale pairings | wipe on first launch of a fresh install |

---

## 10. Open questions

The questions from the first draft are decided (top of this file). Still
open, for M11: see the end of §12.

---

## 11. Keeping up with Android

`docs/ANDROID_PARITY.md` (M1) has one row per feature in §2 with its iOS
status, and records the Android commit it was checked against (`a1ad3f9`).
When the Android app changes: diff from that baseline, port or mark each
change, then move the baseline. The protocol vectors are re-synced with
`scripts/sync-vectors.sh` and must keep passing byte for byte.

---

## 12. M11 (later): Bluetooth Low Energy fallback

**Goal:** as on Android, typing keeps working when Wi-Fi can't reach the
computer. iOS apps can't use RFCOMM, so this uses GATT over Bluetooth LE,
the one Bluetooth path open to them. Only the carrier changes: the packets,
keys, nonces and counters are the same as over UDP, as with RFCOMM.

### Protocol: a new "Bluetooth LE" section in PROTOCOL.md

- **Service** `4f4b6579-6d61-4b79-9001-6f6d616b6579` (the RFCOMM UUID with
  `9000` → `9001`), with two characteristics:
  - `…-9002-…`, **to the desktop**: Write Without Response (and Write).
  - `…-9003-…`, **to the phone**: Notify.
- **Framing.** Each direction is a byte stream made of the characteristic
  values in order. It carries the RFCOMM framing: a 2-byte big-endian
  length, then the datagram, where a length of 0 or over 1200 closes the
  connection. A datagram longer than one value (ATT MTU − 3; iOS usually
  gets 182–244 bytes) spans several values. An INPUT fits in one; a CLIP
  piece of about 1.1 KB takes a few.
- **Finding the computer.** The advertisement carries the service UUID,
  with the 8-byte host id as its service data. iOS hides Bluetooth
  addresses from apps (CoreBluetooth gives per-app identifiers), so the `b`
  address can't be used to connect, but the host id identifies the
  computer. mDNS already broadcasts the host id on the LAN. Over BLE,
  anyone nearby can see it too. It's no key material, but it is a stable
  identifier.
- **WELCOME `features` bit 2** (value 4): the server offers Bluetooth LE.
  The phone asks for Bluetooth permission only once a computer says it has
  it, as Android asks for RFCOMM only when there's a `bt_address`.
- **The rest is as for RFCOMM.** Bluetooth pairing and link encryption are
  neither needed nor relied on (the characteristics need none). The link
  layer is reliable and ordered, so there are no resends. The 100 ms
  heartbeat stays. At most 8 connections, closed after 30 s of silence,
  keys released when a connection drops, and held keys stay down across a
  transport switch.
- **Latency.** An iOS central gets a 15 ms connection interval at best
  (30 ms is typical), so a key costs 15–30 ms more than over Wi-Fi. That's
  fine for a fallback, and UDP stays preferred.

### Daemon (`omakeyd`, Rust and zbus, next to `bluetooth.rs`)

- `ble.rs`: register a GATT application (`org.bluez.GattManager1`: an
  ObjectManager with the service and its two characteristics) and an LE
  advertisement (`org.bluez.LEAdvertisingManager1`). Register again when
  `bluetoothd` restarts, as the RFCOMM profile does.
- `AcquireWrite` and `AcquireNotify` hand over a socket per connection.
  Read and write them like the RFCOMM streams, reusing the framing and the
  `Peer::Bluetooth` handling. Report the transport as `bluetooth-le` in
  `state.json` and the bar widget.
- Advertise only while the adapter is powered and supports LE. `BtStatus`
  reports LE separately.
- Tests next to the RFCOMM ones: a datagram split across many values,
  several datagrams in one value, and a length of 0 or over 1200 closing
  the connection.
- The Steam Deck has BlueZ too, so the same code runs there.

### iOS

- `BLELink` (CoreBluetooth central): scan for the service, match the host
  id in the service data, connect, subscribe to notifications, then follow
  `RfcommLink`'s rules. A writer sends the newest state whenever
  `canSendWriteWithoutResponse` allows, so a burst of touchpad moves becomes
  one packet. No resends; heartbeat and ping as usual.
- Port `FallbackLink` and its 6 tests. UDP runs all along. BLE starts after
  1.2 s without a WELCOME, or when the session in use goes quiet. The first
  transport to be welcomed owns the session. A WELCOME over UDP moves the
  phone back to Wi-Fi and BLE stops.
- `NSBluetoothAlwaysUsageDescription`, asked for once per computer when it
  first reports the feature. The status pill and the lists show the
  Bluetooth sign, as on Android.
- Foreground only. The keyboard only types while it's on screen anyway.

### Android

Nothing is required: Android keeps RFCOMM. The protocol section is written
so Android could use BLE as well later, for example on phones where RFCOMM
misbehaves.

### Order and open points

1. Daemon first: a plugin release with BLE, then iOS 1.x with `BLELink`.
   Phones and desktops without it carry on over Wi-Fi and RFCOMM.
2. Advertise the fixed host id (simplest, as above), or something that
   rotates? A rotating id only helps if it can't be derived from the host
   id, which mDNS already publishes. Start with the fixed id.
3. Advertise all the time, or only while a paired phone has been seen
   recently? Desktops don't mind; on a Steam Deck running on battery it may
   matter. Measure before deciding.
