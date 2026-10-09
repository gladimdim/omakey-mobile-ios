import Foundation
import Observation
import OmakeyCore
import OmakeyNet
import OmakeyProtocol
import SwiftUI

/// The app's state behind the SwiftUI screens: paired computers, what's on
/// the network, pairing and layout imports waiting for a yes, and toasts.
@Observable
@MainActor
final class AppModel {
    struct PendingPairing: Identifiable {
        let id = UUID()
        let host: HostRecord
        /// The pairing it would replace with a different key.
        let replaces: HostRecord?
        /// It came from a web page or another app, not the scanner or Paste.
        let fromOutside: Bool
    }

    struct PendingLayout: Identifiable {
        let id = UUID()
        let json: String
        let layout: Layout
        /// The imported layout with the same id it would replace.
        let replaces: Layout?
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    @ObservationIgnored let settings = AppSettings()
    @ObservationIgnored let hosts = HostStore()
    @ObservationIgnored let layouts = LayoutStore()

    private(set) var palette: Palette
    private(set) var paired: [HostRecord] = []
    private(set) var layoutName = ""
    /// Computers advertising omakeyd.
    private(set) var nearby: [Found] = []
    /// Paired computers by host id: the address that answered, or nil when
    /// none did. Absent: not checked yet.
    private(set) var online: [String: Endpoint?] = [:]
    /// Local Network access is off: nothing on the Wi-Fi can be reached.
    private(set) var localNetworkDenied = false
    private(set) var toast: Toast?

    var pendingPairing: PendingPairing?
    var pendingLayout: PendingLayout?
    var unlinking: HostRecord?
    var scanning = false
    /// The page shown over the connect screen.
    var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case settings, layouts
        var id: String { rawValue }
    }

    @ObservationIgnored private var discovery: Discovery?
    @ObservationIgnored private var reach: Reachability?

    init() {
        palette = Palette(theme: Themes.byId(Themes.defaultId))
        refresh()
    }

    /// Read the stores again: after a pairing, an unlink, a layout or theme change.
    func refresh() {
        paired = hosts.all()
        layoutName = layouts.currentName
        palette = Palette(theme: currentTheme())
        updateReach()
    }

    func currentTheme() -> Theme {
        settings.themeId == Themes.fromComputerId ? Themes.fromComputer(settings.desktopTheme) : Themes.byId(settings.themeId)
    }

    // MARK: - The network

    /// Look for computers while the connect screen shows.
    func startBrowsing() {
        if discovery == nil {
            let d = Discovery { [weak self] found in
                self?.nearby = found
                self?.updateReach()
            }
            d.onStatus = { [weak self] status in self?.localNetworkDenied = status == .denied }
            discovery = d
            d.start()
        }
        if reach == nil {
            let r = Reachability(phoneName: settings.phoneName) { [weak self] result in self?.online = result }
            reach = r
            updateReach()
            r.start()
        }
    }

    func stopBrowsing() {
        discovery?.stop()
        discovery = nil
        reach?.stop()
        reach = nil
    }

    private func updateReach() {
        var seen = [String: Endpoint]()
        for f in nearby { if let id = f.hostId { seen[id] = f.endpoint } }
        reach?.update(paired: paired, nearby: seen)
    }

    /// Where a paired computer was last seen, for its card: where it answered, mDNS, or its pairing.
    func address(of h: HostRecord) -> String {
        if case .some(.some(let e)) = online[h.hostId] { return e.host }
        if let f = nearby.first(where: { $0.hostId == h.hostId }) { return f.endpoint.host }
        return h.addresses.first ?? ""
    }

    // MARK: - Links, pairing and imports

    func handleURL(_ url: URL) {
        if url.isFileURL {
            importLayout {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                if data.count > LayoutParser.maxBytes { throw LayoutError("Layout is larger than 256 KB") }
                return String(decoding: data, as: UTF8.self)
            }
        } else {
            handleText(url.absoluteString, fromOutside: true)
        }
    }

    /// A pairing link, a layout link, or layout JSON. [fromOutside]: it came
    /// from a web page or another app rather than this app's own scanner or
    /// Paste button.
    func handleText(_ raw: String, fromOutside: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("omakey://pair") {
            do {
                confirmPairing(try PairingURI.parse(text), fromOutside: fromOutside)
            } catch {
                show("\(error)")
            }
        } else if LayoutLink.isLayoutLink(text) {
            importLayout { try LayoutLink.decode(text) }
        } else if text.hasPrefix("{") {
            importLayout { text }
        } else {
            show("That isn't an Omakey pairing or layout link")
        }
    }

    /// A pairing link is that phone's credential for a computer, and a link
    /// from anywhere can claim to be any computer. Show what it is first,
    /// with the fingerprint omakeyd shows under its QR code, and warn loudly
    /// when it would replace an existing pairing with a different key.
    private func confirmPairing(_ host: HostRecord, fromOutside: Bool) {
        let existing = hosts.get(host.hostId)
        let replaces = existing.flatMap { $0.key == host.key && $0.deviceId == host.deviceId ? nil : $0 }
        pendingPairing = PendingPairing(host: host, replaces: replaces, fromOutside: fromOutside)
    }

    func pairingTitle(_ p: PendingPairing) -> String {
        p.replaces != nil ? "Replace pairing?" : "Pair with \(p.host.name)?"
    }

    func pairingMessage(_ p: PendingPairing) -> String {
        var s = "Computer: \(p.host.name)\nAddresses: \(p.host.addresses.joined(separator: ", "))\n"
        s += "\nFingerprint: \(p.host.fingerprint)\nIt must match the code under the QR code on your computer."
        if let old = p.replaces {
            s += "\n\n⚠ This replaces your existing pairing with \(old.name). Only continue if you just paired again on that "
                + "computer: otherwise someone may be trying to receive what you type."
        } else if p.fromOutside {
            s += "\n\nThis link came from another app or a web page."
        }
        return s
    }

    func pair(_ host: HostRecord) {
        hosts.put(host)
        refresh()
        show("Paired with \(host.name)")
        openKeyboard(host.hostId)
    }

    func unlink(_ host: HostRecord) {
        hosts.remove(host.hostId)
        refresh()
    }

    /// Validate, show the layout, and only then save it.
    func importLayout(_ read: () throws -> String) {
        do {
            let json = try read()
            let layout = try layouts.preview(json)
            pendingLayout = PendingLayout(json: json, layout: layout, replaces: layouts.importedWithId(layout.id))
        } catch let e as LayoutError {
            show(e.message)
        } catch {
            show("Can't read that file")
        }
    }

    func layoutMessage(_ p: PendingLayout) -> String {
        var s = "\(p.layout.keys.count) keys"
        if let a = p.layout.author { s += " · by \(a)" }
        if let d = p.layout.description { s += "\n\(d)" }
        if let r = p.replaces { s += "\n\nReplaces your imported layout \"\(r.name)\" (same id \"\(p.layout.id)\")." }
        return s
    }

    func confirmImport(_ p: PendingLayout) {
        do {
            try layouts.importLayout(p.json)
            show("Imported \"\(p.layout.name)\"")
            refresh()
        } catch {
            show("\(error)")
        }
    }

    func selectLayout(_ id: String) {
        layouts.selectedId = id
        refresh()
    }

    // MARK: - The keyboard

    func openKeyboard(_ hostId: String) {
        guard let host = hosts.get(hostId), let top = Self.topViewController() else { return }
        // The keyboard looks for its own computer; the connect screen rests.
        stopBrowsing()
        let portrait = layouts.portrait
        let keyboard = KeyboardViewController(model: self, host: host, portrait: portrait)
        keyboard.onClose = { [weak self] in
            Self.lockOrientation(.allButUpsideDown, turnTo: .portrait)
            self?.refresh()
            self?.startBrowsing()
        }
        Self.lockOrientation(portrait ? .portrait : .landscape, turnTo: portrait ? .portrait : .landscape)
        top.present(keyboard, animated: true)
    }

    /// The keyboard for [hostId] again, in the other orientation: portrait mode was picked or left.
    func reopenKeyboard(_ hostId: String, replacing keyboard: KeyboardViewController) {
        keyboard.onClose = nil
        keyboard.dismiss(animated: false) { [weak self] in self?.openKeyboard(hostId) }
    }

    /// Which way the screen may turn, and turn it now (iOS doesn't for a presented screen by itself).
    static func lockOrientation(_ mask: UIInterfaceOrientationMask, turnTo: UIInterfaceOrientationMask) {
        AppDelegate.orientations = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in scene.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: turnTo)) { _ in }
        }
    }

    /// Where to present from: the key window's frontmost view controller.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    // MARK: - Toasts

    func show(_ text: String) {
        let t = Toast(text: text)
        toast = t
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.toast == t { self?.toast = nil }
        }
    }
}
