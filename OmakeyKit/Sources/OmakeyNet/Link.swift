import OmakeyProtocol

public enum LinkState: Sendable, Equatable {
    case connecting
    case connected
    /// omakeyd doesn't know this phone.
    case rejected
}

/// What a link reports. Called on the link's own thread, never with a lock
/// held; implementations hop to the main thread themselves.
public protocol LinkListener: AnyObject, Sendable {
    func linkState(_ state: LinkState, hostName: String?)
    func linkPing(_ ms: Int)
    /// The computer's lock lights: `Ack.ledCaps` and friends.
    func linkLeds(_ leds: Int)
    /// The computer's Omarchy theme, when its omakeyd sends one.
    func linkTheme(_ theme: DesktopTheme)
    /// A clipboard transfer from `Link.clip` ended.
    func linkClip(_ outcome: ClipTransfer.Outcome)
}

public extension LinkListener {
    func linkLeds(_ leds: Int) {}
    func linkTheme(_ theme: DesktopTheme) {}
    func linkClip(_ outcome: ClipTransfer.Outcome) {}
}

/// A live connection the keyboard types through. The touch thread changes
/// the shared `KeyState` and calls `send`; the link gets the change to the
/// computer.
public protocol Link: AnyObject, Sendable {
    func start()
    /// Lets go of the computer (it releases every key). May wait briefly for the link's thread to end.
    func stop()
    /// A key changed: get it to the computer now. Safe from any thread.
    func send()
    /// Start a clipboard transfer with omakeyd, replacing any under way; its
    /// outcome comes to `LinkListener.linkClip`. False when this connection
    /// has no clipboard (`Wire.featureClipboard`).
    func clip(_ transfer: ClipTransfer) -> Bool
    /// WELCOME feature bits of the connection, e.g. `Wire.featurePointer`.
    var features: Int { get }
    /// How it's connected, for the status pill: "Wi-Fi".
    var transport: String { get }
}
