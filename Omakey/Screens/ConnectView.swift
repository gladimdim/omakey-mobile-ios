import OmakeyNet
import OmakeyProtocol
import SwiftUI

/// The connect screen: paired computers, computers nearby, pairing by QR
/// code or pasted link, and the layout the keyboard opens with.
struct ConnectView: View {
    @Bindable var model: AppModel

    private var p: Palette { model.palette }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                SectionHeader(title: "SELECT COMPUTER TO USE", palette: p)
                pairedList
                SectionHeader(title: "NEARBY", palette: p)
                nearbyList
                SectionHeader(title: "PAIR A COMPUTER", palette: p)
                pairSection
                SectionHeader(title: "LAYOUT", palette: p)
                Button { model.showingLayouts = true } label: {
                    Text("⌨  \(model.layoutName)").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(OmakeyButtonStyle(palette: p))
                .accessibilityIdentifier("omakey.layout")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .background(p.bg.ignoresSafeArea())
        .preferredColorScheme(p.colorScheme)
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                ToastView(text: t.text, palette: p).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .alert(model.pendingPairing.map(model.pairingTitle) ?? "", isPresented: present($model.pendingPairing), presenting: model.pendingPairing) { pending in
            Button(pending.replaces != nil ? "Replace" : "Pair", role: pending.replaces != nil ? .destructive : nil) { model.pair(pending.host) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(model.pairingMessage(pending))
        }
        .alert(model.pendingLayout?.layout.name ?? "", isPresented: present($model.pendingLayout), presenting: model.pendingLayout) { pending in
            Button(pending.replaces != nil ? "Replace" : "Import") { model.confirmImport(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(model.layoutMessage(pending))
        }
        .alert("Unlink \(model.unlinking?.name ?? "")?", isPresented: present($model.unlinking), presenting: model.unlinking) { host in
            Button("Unlink", role: .destructive) { model.unlink(host) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This phone will need a new pairing code to connect again. Also remove it on the computer with `omakeyd forget`.")
        }
        .fullScreenCover(isPresented: $model.scanning) {
            QRScannerSheet(palette: p) { code in
                model.scanning = false
                model.handleText(code)
            } onCancel: {
                model.scanning = false
            }
        }
        .sheet(isPresented: $model.showingSettings, onDismiss: model.refresh) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.showingLayouts, onDismiss: model.refresh) {
            LayoutsView(model: model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Omakey")
                    .font(.mono(34, bold: true))
                    .foregroundStyle(p.fg)
                Spacer()
                Button { model.showingSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 24)).foregroundStyle(p.accent)
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("omakey.settings")
            }
            Text("Your phone is the keyboard.")
                .font(.mono(15))
                .foregroundStyle(p.fgDim)
        }
    }

    @ViewBuilder
    private var pairedList: some View {
        if model.paired.isEmpty {
            Text("No computers yet.").font(.mono(14)).foregroundStyle(p.fgDim)
        }
        VStack(spacing: 8) {
            ForEach(model.paired, id: \.hostId) { h in
                let address = model.address(of: h)
                let answer = model.online[h.hostId]
                let isOnline = answer.map { $0 != nil } ?? false
                let detail = switch answer {
                case .some(.some): "● Online · \(address)"
                case .some(.none): "○ Offline · \(address)"
                case .none: "Checking… · \(address)"
                }
                Button { model.openKeyboard(h.hostId) } label: {
                    Card(title: h.name, detail: detail, detailColor: isOnline ? p.ok : p.fgDim, border: isOnline ? p.ok : nil, palette: p)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Unlink", systemImage: "xmark.circle", role: .destructive) { model.unlinking = h }
                }
                .accessibilityIdentifier("omakey.host.\(h.hostId)")
                .accessibilityHint("Opens the keyboard. Touch and hold to unlink.")
            }
        }
    }

    @ViewBuilder
    private var nearbyList: some View {
        if model.localNetworkDenied {
            VStack(alignment: .leading, spacing: 10) {
                Text("Omakey can't reach your Wi-Fi")
                    .font(.mono(16, bold: true)).foregroundStyle(p.warn)
                Text("Local Network access is off for Omakey, so it can't find or type on your computer. Turn it on in Settings → Omakey → Local Network.")
                    .font(.mono(13)).foregroundStyle(p.fg)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(OmakeyButtonStyle(palette: p))
            }
            .padding(16)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.warn, lineWidth: 1.5))
            .padding(.bottom, 8)
        }
        let pairedIds = Set(model.paired.map(\.hostId))
        let strangers = model.nearby.filter { !pairedIds.contains($0.hostId ?? "") }.sorted { $0.name < $1.name }
        if strangers.isEmpty {
            Text("Looking for computers running omakeyd…").font(.mono(14)).foregroundStyle(p.fgDim)
        }
        VStack(spacing: 8) {
            ForEach(strangers, id: \.serviceName) { f in
                Button { model.scanning = true } label: {
                    Card(title: f.name, detail: "Not paired. Scan its pairing code to connect.", palette: p)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pairSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On Omarchy, click the keyboard icon in the bar and choose Pair a phone, or run `omakeyd pair` in a terminal. Then scan the code.")
                .font(.mono(13))
                .foregroundStyle(p.fgDim)
            HStack(spacing: 8) {
                Button("Scan QR code") { model.scanning = true }
                    .buttonStyle(OmakeyButtonStyle(primary: true, palette: p))
                    .accessibilityIdentifier("omakey.scan")
                // The system's paste control reads the clipboard without asking each time.
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.first ?? ""
                    Task { @MainActor in
                        if text.isEmpty { model.show("The clipboard is empty. Copy the pairing link first.") } else { model.handleText(text) }
                    }
                }
                .buttonBorderShape(.roundedRectangle(radius: 10))
                .tint(p.accent)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("omakey.paste")
            }
        }
    }

    /// A Binding<Bool> that's true while [item] is set; false clears it.
    private func present<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}
