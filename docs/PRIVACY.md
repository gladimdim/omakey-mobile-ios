# Omakey privacy policy

*Effective October 9, 2026.*

Omakey turns your iPhone into a keyboard and touchpad for your own
computer. It collects no data about you and has no servers, accounts,
advertising or analytics. Nothing leaves your phone except the key presses,
pointer movements and clipboard text you send to your own computer.

## What stays on your phone

- **Pairings.** Each computer you pair gives the phone a 256-bit key. It is
  kept in the iOS Keychain, only on this device: it is not synced to iCloud
  and not restored onto another phone. Deleting the app removes it.
- **Settings and layouts.** Your theme, keyboard options, pointer speeds and
  imported layouts are stored in the app's own storage.
- **The clipboard.** When you tap Copy or Paste, text moves between your
  phone's clipboard and your computer's. Omakey keeps only a fingerprint
  (a SHA-256 hash) of the last text the two swapped, so it can tell whether
  there is something new, never the text itself. Text your computer marks as
  a password stays off your other devices and expires from the phone's
  clipboard after two minutes.

## What goes to your computer

Key presses, pointer movements, scrolling, clipboard text when you ask for
it, and the phone name you set, sent over your local network to the
computer you paired, encrypted and authenticated with that computer's key.
Nothing is sent anywhere else.

## Permissions

- **Local Network**: to find your computer and send it your typing.
- **Camera**: to scan the pairing QR code your computer shows. No images are
  stored or sent.

## Contact

Questions: open an issue at
<https://github.com/gladimdim/omakey-mobile-ios/issues>.
