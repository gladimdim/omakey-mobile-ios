# App Store submission

Omakey for iOS is published on the App Store from its first public
release. Internal TestFlight builds are for testing on our own devices.

Talk to App Store Connect with the `asc` CLI. Credentials stay outside this
repository (see `AGENTS.md`). Preview every write first, and ask before
creating the app record, submitting for review or changing prices.

## Checklist for 1.0.0

- [ ] App record: bundle id `com.gladimdim.omakey`, name "Omakey", primary
      language English (U.S.), SKU `omakey-ios`. Created in App Store
      Connect, with the user's OK.
- [ ] Availability: iPhone only. Opt out of "iPhone and iPad Apps on Apple
      Silicon Macs" (no multi-touch there).
- [ ] Price: free. Category: Utilities (secondary: Productivity).
- [ ] Age rating: 4+ (no objectionable content, no unrestricted web access).
- [ ] Metadata: `store/metadata` (`asc metadata validate --dir ./store/metadata`,
      then `asc metadata plan` / `apply`).
- [ ] Privacy policy URL: `docs/PRIVACY.md` on GitHub.
- [ ] App Privacy: **Data Not Collected**. The privacy manifest
      (`Omakey/App/PrivacyInfo.xcprivacy`) declares no tracking and no
      collected data.
- [ ] Export compliance: the app encrypts its own traffic with AES-256-GCM
      through Apple's CryptoKit. Answer Apple's encryption questions before
      the first upload, then set `ITSAppUsesNonExemptEncryption` in
      `Info.plist` so later uploads don't ask again. **A decision for the
      owner.**
- [ ] Screenshots: 6.9″ iPhone (1320 × 2868, or 2868 × 1320 landscape):
      the connect screen, the landscape keyboard, the touchpad, portrait
      mode, the layouts page. From the UI tours (`scripts/ui-test.sh`
      attaches them) or a device.
- [ ] App Review notes and a video: below.
- [ ] Version 1.0.0, build 1, archived with `asc xcode archive` or Xcode,
      uploaded, and submitted for review.

## App Review notes

> Omakey is a keyboard and touchpad for a Linux computer running the free,
> open-source Omakey desktop service (Omarchy, or a Steam Deck with
> SteamOS): https://gladimdim.github.io/omakey-omarchy-plugin/
>
> You don't need one to review it. On the first screen, scroll down and tap
> **Try the demo**. A demo computer inside the app (the same encrypted
> protocol, over the phone's own loopback) receives everything you type and
> shows what it got at the top of the keyboard.
>
> - The keyboard opens in landscape. **⌄ touchpad** (top left) pulls the
>   touchpad over the keys: move a finger, tap to click, two fingers to
>   scroll.
> - **⌨** (top right) switches layouts; **Portrait: your keyboard +
>   touchpad** types with the iPhone keyboard, upright.
> - Copy and Paste (keys inside the big Enter, or icons in portrait mode)
>   exchange text with the demo computer's clipboard.
>
> With a real computer, pairing is a QR code the computer shows; the video
> shows it on an Omarchy desktop. The app asks for Local Network access to
> reach the computer, and for the camera only to scan that code.
