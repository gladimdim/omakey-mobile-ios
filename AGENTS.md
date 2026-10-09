# Omakey iOS contributor instructions

- This is the iPhone port of the Android app in `../omakey-mobile`, which is
  the reference. Port behavior and exact constants from the Kotlin sources
  when the prose is ambiguous. `docs/PLAN.md` is the plan and its
  milestones.
- The wire protocol is `../omakey-omarchy-plugin/docs/PROTOCOL.md`. The
  protocol code must reproduce `docs/test-vectors.json` byte for byte
  (`scripts/sync-vectors.sh` refreshes the copy). Do not change the desktop
  protocol or the Android app to fit iOS.
- No Bluetooth: the app reaches omakeyd over Wi-Fi only (plan §1). The
  protocol's Bluetooth address is parsed, as the protocol has it, and unused.
- Keep `docs/ANDROID_PARITY.md` accurate. When porting an Android change,
  diff from the baseline commit recorded there, update the rows, then move
  the baseline.

## Project

- Open the checked-in `Omakey.xcodeproj`; no generator. Its folders are
  synchronized groups: a file added under `Omakey/`, `OmakeyTests/` or
  `OmakeyUITests/` is built automatically. `Omakey/App/Info.plist` is excluded from the copy
  phase by an exception set; keep it that way.
- `OmakeyKit/` is a local Swift package with no UIKit: `OmakeyProtocol`
  (wire format, crypto, session state machine), `OmakeyCore` (layouts,
  keyboard logic), `OmakeyNet` (the UDP link, reachability, mDNS) and
  `OmakeydStandIn` (a server that types nothing, for tests, the dev server
  and demo mode). Its tests run on the Mac: `swift test --package-path OmakeyKit`.
- Run `scripts/check.sh` before committing: package tests plus an unsigned
  device build. App and UI tests: `scripts/ui-test.sh [-d <simulator>]`
  (it stops a hung test runner after 15 minutes). The UI tests
  host the omakeyd stand-in (`OmakeydStandIn`) in their own process and
  launch the app with `OMAKEY_RESET=<token>` (Debug only), which starts it
  as a fresh install once per token.
- `swift run --package-path OmakeyKit omakey-dev-server` is a computer for
  the simulator to pair with: it prints a pairing link and every key it
  gets, and types nothing.
- Swift 6 language mode. UI code is `@MainActor`. Types shared with the
  network thread take a lock and say so in their doc comment.
- iPhone only (`TARGETED_DEVICE_FAMILY = 1`) until the iPad milestone.

- The demo computer (`DemoComputer`, "Try the demo") is the way to try the
  app without a desktop: keep it working without a network or a pairing.

## Safety

- Pairing keys live only in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable).
  Never log keys, pairing links or typed text.
- Never point tests or debugging sessions at a desktop that types for real.
  Use `omakeyd run --dry-run --port 47899`, which prints the keys.

## Open source

- The repository is public. Nothing personal goes into tracked files,
  commits or logs: no signing team ids, keys, account names, device
  identifiers, or real hostnames and addresses (tests use `omarchy desk`,
  `192.168.1.x`, `10.0.0.x`). Signing lives in the git-ignored
  `Config/Local.xcconfig` (see `Config/Signing.xcconfig`).

## UI tests

- The connect screen's list grows as mDNS answers, which can move a button
  between finding and tapping it: use `tap(_:until:)` from `Support.swift`.
- `hasFocus` is the focus engine's; a text view's keyboard focus shows as
  "Keyboard Focused" in its `debugDescription`. The portrait mode's hidden
  line is in the accessibility tree only for UI test launches.
- The layouts page is a lazy grid: a card off screen doesn't exist until
  scrolled to; use `scroll(to:in:)`.
- Run them on a simulator of their own (`xcrun simctl create "Omakey UI Tests" …`),
  not one someone is using: the tours install, launch, turn and reset the app.
- Performance runs on a connected iPhone: `scripts/perf-test.sh` (see
  `docs/PERFORMANCE.md`). They use only the demo computer and never reset;
  never run the other tours on someone's phone, they reset (unpair) the app.
- The iOS 27.0 simulator doesn't show "Allow Paste?"; `ClipboardTour` expects
  that step to fail there (iOS 26.4 shows it).
- `XCUIElement.twoFingerTap()` puts its fingers at the element's left and
  right edges: tap the touchpad's surface element (`touchpad.surface`), not
  the whole view.
- XCUITest screenshots of the landscape keyboard come out cropped while the
  simulated phone is upright: turn it (`XCUIDevice.shared.orientation`) and
  attach `XCUIScreen.main.screenshot()`.
