import CryptoKit
import OmakeyCore
import OmakeyNet
import OmakeyProtocol
import UIKit
import UniformTypeIdentifiers

/// Copy and Paste between the phone and the computer (PROTOCOL.md, CLIP).
///
/// - **Copy** copies what's selected on the computer and puts it on the
///   phone's clipboard too.
/// - **Paste** pastes on the computer: the phone's clipboard when it has
///   something new since the two last swapped text, else the computer's own,
///   so whichever was copied last is what pastes.
///
/// Without omakeyd's clipboard (an older omakeyd) they are the computer's
/// own copy and paste: Ctrl+Insert and Shift+Insert.
///
/// iOS asks before an app reads the clipboard. The clipboard's change count
/// says "nothing new" without reading it, so Paste only asks when the phone
/// really has something newer to send.
@MainActor
final class ClipboardBridge {
    private let link: () -> Link?
    /// Presses [modifier] + [key] on the computer.
    private let shortcut: (_ modifier: Int, _ key: Int) -> Void
    /// The computer's name, for messages.
    private let hostName: () -> String
    private let toast: (String) -> Void
    private let settings: AppSettings
    private let pasteboard: UIPasteboard

    /// The text a put is sending, until it's in: its hash and the clipboard's change count.
    private var sending: (hash: String, change: Int)?
    /// Said once that the computer's clipboard is out of reach (SteamOS's Game Mode).
    private var saidUnreachable = false

    init(settings: AppSettings, pasteboard: UIPasteboard = .general, link: @escaping () -> Link?,
         shortcut: @escaping (Int, Int) -> Void, hostName: @escaping () -> String, toast: @escaping (String) -> Void) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.link = link
        self.shortcut = shortcut
        self.hostName = hostName
        self.toast = toast
    }

    func copy() {
        if link()?.clip(ClipTransfer.get(copy: true)) != true { shortcut(UsKeys.keyLeftCtrl, UsKeys.keyInsert) }
    }

    func paste() {
        let computerPaste = { [shortcut] in shortcut(UsKeys.keyLeftShift, UsKeys.keyInsert) }
        guard let l = link(), l.features & Wire.featureClipboard != 0 else { return computerPaste() }
        // Nothing new on the phone since the two last swapped: no need to read (and ask).
        let change = pasteboard.changeCount
        if change == settings.lastSwappedChange || !pasteboard.hasStrings { return computerPaste() }
        let sensitive = pasteboard.contains(pasteboardTypes: [Self.concealedType])
        // Reading may ask "Allow Paste?", which holds the reading thread until
        // answered: not the main one, so touches and the link carry on meanwhile.
        let board = pasteboard
        DispatchQueue.global(qos: .userInitiated).async {
            let text = board.string
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.send(text, change: change, sensitive: sensitive, link: l) }
            }
        }
    }

    private func send(_ text: String?, change: Int, sensitive: Bool, link l: Link) {
        let computerPaste = { [shortcut] in shortcut(UsKeys.keyLeftShift, UsKeys.keyInsert) }
        // Declined in the "Allow Paste" prompt, or no text after all.
        guard let text, !text.isEmpty else { return computerPaste() }
        let hash = Self.sha256(text)
        if hash == settings.lastSwapped {
            settings.lastSwappedChange = change
            return computerPaste()
        }
        guard let t = ClipTransfer.put(text, paste: true, sensitive: sensitive) else {
            toast("The phone's clipboard is too large to send (over 64 KB)")
            return computerPaste()
        }
        guard l.clip(t) else { return computerPaste() }
        sending = (hash, change)
    }

    /// A transfer ended.
    func onOutcome(_ outcome: ClipTransfer.Outcome) {
        switch outcome {
        case .sent:
            if let s = sending {
                settings.lastSwapped = s.hash
                settings.lastSwappedChange = s.change
            }
            sending = nil
        case .received(let text, let sensitive):
            if sensitive {
                // As password managers mark it, kept off other devices, and not for long.
                pasteboard.setItems([[UTType.utf8PlainText.identifier: text, Self.concealedType: Data()]],
                                    options: [.localOnly: true, .expirationDate: Date(timeIntervalSinceNow: Self.sensitiveSeconds)])
            } else {
                pasteboard.string = text
            }
            settings.lastSwapped = Self.sha256(text)
            settings.lastSwappedChange = pasteboard.changeCount
            toast("Copied from \(hostName())")
        case .failed(let status):
            let pasting = sending != nil
            sending = nil
            // No clipboard to reach on the computer: a paste is its own
            // Shift+Insert, and a copy was already pressed there.
            if status == Clip.failed {
                if pasting { return shortcut(UsKeys.keyLeftShift, UsKeys.keyInsert) }
                if saidUnreachable { return }
                saidUnreachable = true
                return toast("Copied on \(hostName()), but its clipboard can't reach the phone here")
            }
            let message = switch status {
            case Clip.empty: "Nothing to copy: \(hostName())'s clipboard has no text"
            case Clip.tooLarge: "The copied text is too large for the phone (over 64 KB)"
            case ClipTransfer.gaveUp: "\(hostName()) didn't answer"
            default: "\(hostName()) couldn't use its clipboard"
            }
            toast(message)
        }
    }

    /// The type password managers add to say "don't keep or show this".
    static let concealedType = "org.nspasteboard.ConcealedType"
    /// How long a sensitive text copied from the computer stays on the phone's clipboard.
    static let sensitiveSeconds: TimeInterval = 120

    static func sha256(_ s: String) -> String { Hex.encode(Array(SHA256.hash(data: Data(s.utf8)))) }
}
