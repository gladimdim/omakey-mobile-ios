# Omakey iOS contributor instructions

- This is the iPhone port of the Android app in `../omakey-mobile`, which is
  the reference. Port behavior and exact constants from the Kotlin sources
  when the prose is ambiguous. `docs/PLAN.md` is the plan and its
  milestones.
- The wire protocol is `../omakey-omarchy-plugin/docs/PROTOCOL.md`. The
  protocol code must reproduce `docs/test-vectors.json` byte for byte
  (`scripts/sync-vectors.sh` refreshes the copy). Do not change the desktop
  protocol or the Android app to fit iOS; the planned exception is the
  Bluetooth LE transport (plan §12), which goes through the plugin repo
  first.
- Keep `docs/ANDROID_PARITY.md` accurate. When porting an Android change,
  diff from the baseline commit recorded there, update the rows, then move
  the baseline.

## Project

- Open the checked-in `Omakey.xcodeproj`; no generator. Its folders are
  synchronized groups: a file added under `Omakey/` or `OmakeyTests/` is
  built automatically. `Omakey/App/Info.plist` is excluded from the copy
  phase by an exception set; keep it that way.
- `OmakeyKit/` is a local Swift package with no UIKit: `OmakeyProtocol`
  (wire format, crypto, session state machine) and, from M2, `OmakeyCore`
  (layouts, keyboard logic). Its tests run on the Mac:
  `swift test --package-path OmakeyKit`.
- Run `scripts/check.sh` before committing: package tests plus an unsigned
  device build. App and UI tests: `xcodebuild -project Omakey.xcodeproj
  -scheme Omakey -destination 'id=<iPhone simulator>' test`. The UI tests
  host the omakeyd stand-in (`OmakeydStandIn`) in their own process and
  launch the app with `OMAKEY_RESET=<token>` (Debug only), which starts it
  as a fresh install once per token.
- `swift run --package-path OmakeyKit omakey-dev-server` is a computer for
  the simulator to pair with: it prints a pairing link and every key it
  gets, and types nothing.
- Swift 6 language mode. UI code is `@MainActor`. Types shared with the
  network thread take a lock and say so in their doc comment.
- iPhone only (`TARGETED_DEVICE_FAMILY = 1`) until the iPad milestone.

## Safety

- Pairing keys live only in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable).
  Never log keys, pairing links or typed text.
- Never point tests or debugging sessions at a desktop that types for real.
  Use `omakeyd run --dry-run --port 47899`, which prints the keys.

## App Store Connect

- Store material goes in `store/` (from M10). Talk to App Store Connect with
  the `asc` CLI. Credentials stay outside this public repository, as in
  `super-desktop-ios`: never write key IDs, issuer IDs, key paths or key
  material into tracked files, commits or logs.
- Preview every write with `--dry-run`, and ask before creating the app
  record, submitting for review or changing prices.
