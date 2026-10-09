import OmakeyCore
import UIKit

/// An invisible editor for the phone's own keyboard (Apple's, Gboard,
/// SwiftKey, any). Whatever the keyboard does to its text is mirrored on the
/// computer: the change between the text before and after (a typed letter,
/// an autocorrection, a delete, the cursor moved with the space bar) goes out
/// as arrows, backspaces and characters. After Return the text starts empty
/// again, so it stays one short line.
@MainActor
final class TextCapture: UITextView, UITextViewDelegate {
    private let typist: Typist
    /// Ctrl, Alt or Super is down on the computer: what's typed now is a shortcut, not text.
    var shortcut: () -> Bool = { false }

    /// The text and cursor as the computer has them; cursors count UTF-16 units.
    private var sent = ""
    private var sentCursor = 0

    init(typist: Typist) {
        self.typist = typist
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), textContainer: nil)
        delegate = self
        // Autocorrect stays on: it's the point. What the computer's layouts
        // can't type (curly quotes, dashes) is off, and nothing is learned
        // from a password typed here.
        autocorrectionType = .default
        spellCheckingType = .default
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        autocapitalizationType = .sentences
        keyboardType = .default
        returnKeyType = .default
        textContentType = nil
        // Present for the keyboard, invisible to the eye and to VoiceOver.
        alpha = 0.02
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        accessibilityIdentifier = "portrait.capture"
        #if DEBUG
        // UI tests type into it, so it has to be in their accessibility tree.
        if ProcessInfo.processInfo.environment["OMAKEY_RESET"] != nil {
            isAccessibilityElement = true
            accessibilityElementsHidden = false
        }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The phone keyboard's language: "uk-UA" puts Ukrainian before English.
    var language: String? { textInputMode?.primaryLanguage }

    /// Bring the phone's keyboard up.
    func show() {
        becomeFirstResponder()
    }

    /// Forget the line: a new computer, or the keyboard is back after a pause.
    func reset() {
        sent = ""
        sentCursor = 0
        unmarkText()
        text = ""
    }

    private var cursor: Int { selectedRange.location + selectedRange.length }

    /// Send the change from what the computer has to what's here.
    private func sync() {
        let now = text ?? ""
        let c = cursor
        guard now != sent || c != sentCursor else { return }
        LineDiff.edit(old: sent, oldCursor: sentCursor, new: now, newCursor: c, key: { typist.key($0) }, text: { typist.text($0) })
        sent = now
        sentCursor = c
        // A shortcut (Ctrl from the touchpad + C) typed nothing on the computer: start the line again.
        // A new line, or a long one: start empty too (outside the keyboard's call).
        if shortcut() || now.contains("\n") || now.utf16.count > TextCapture.maxLine {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if let self, self.sent == now { self.reset() }
                }
            }
        }
    }

    func textViewDidChange(_ textView: UITextView) { sync() }
    func textViewDidChangeSelection(_ textView: UITextView) { sync() }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n" else { return true }
        // Return: Enter on the computer, and a new, empty line here.
        sync()
        typist.key(UsKeys.keyEnter)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.reset() } }
        return false
    }

    /// Backspace at the start of the line: the rest is on the computer.
    override func deleteBackward() {
        if selectedRange.location == 0 && selectedRange.length == 0 {
            typist.key(UsKeys.keyBackspace)
            return
        }
        super.deleteBackward()
    }

    // No menus or loupes for a field nobody sees.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    private static let maxLine = 400
}

/// `Typist`'s pacing on the main thread.
@MainActor
final class MainScheduler: Scheduler {
    func after(ms: Int, _ block: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { MainActor.assumeIsolated { block() } }
    }
}
