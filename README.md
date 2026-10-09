# Omakey for iOS

An iPhone app that turns your phone into a real keyboard and touchpad for an
[Omarchy](https://omarchy.org/) desktop (or a Steam Deck). Every touch
becomes a key press on a kernel-level virtual keyboard made by `omakeyd`,
so Hyprland binds, `SUPER + SPACE`, F-keys, Esc and the lock screen all
work as they do with a hardware keyboard.

**Status: planning.** See [docs/PLAN.md](docs/PLAN.md) for the
implementation plan and its milestones.

It is the iOS counterpart of the Android app:

| Repository | What |
|---|---|
| [omakey-mobile](https://github.com/gladimdim/omakey-mobile) | Android app, the reference implementation |
| [omakey-omarchy-plugin](https://github.com/gladimdim/omakey-omarchy-plugin) | `omakeyd` (the desktop service), the bar widget, and the [wire protocol](https://github.com/gladimdim/omakey-omarchy-plugin/blob/main/docs/PROTOCOL.md) |
| [omakey-layout-studio](https://gladimdim.github.io/omakey-layout-studio/) | Layout editor and layout format |

The iOS app speaks the same protocol (UDP, AES-256-GCM, test vectors
reproduced byte for byte), reads the same layout files and pairs with the
same QR code, so nothing changes on the desktop. Native Swift: SwiftUI
screens, UIKit multi-touch views, CryptoKit, Network.framework, and no
third-party dependencies.

What iOS can't do: be a plain Bluetooth keyboard for any computer, or reach
`omakeyd` over Bluetooth Classic. The iPhone app connects over Wi-Fi; a
Bluetooth Low Energy fallback is planned for later. iPhone first, iPad
later. It will be published on the App Store.

## License

MIT, see [LICENSE](LICENSE).
