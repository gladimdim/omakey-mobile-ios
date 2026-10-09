import OmakeyCore
import OmakeyProtocol
import SwiftUI

/// Settings: the layout the keyboard opens with, the theme, the computers,
/// the phone's name and the keyboard's options.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var phoneName = ""
    @State private var haptics = true
    @State private var typedText = true
    @State private var showingLayouts = false
    @State private var unlinking: HostRecord?

    private var p: Palette { model.palette }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "DEFAULT LAYOUT", palette: p)
                    Button { showingLayouts = true } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("⌨  \(model.layoutName)").font(.mono(16, bold: true)).foregroundStyle(p.fg)
                            Text("Every keyboard opens with it. Switch any time with ⌨ on the keyboard.")
                                .font(.mono(13)).foregroundStyle(p.fgDim)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.layout")

                    SectionHeader(title: "THEME", palette: p)
                    themes

                    SectionHeader(title: "COMPUTERS", palette: p)
                    computers

                    SectionHeader(title: "PHONE NAME", palette: p)
                    TextField("iPhone", text: $phoneName)
                        .font(.mono(16))
                        .foregroundStyle(p.fg)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("settings.name")
                    Text("How your computer lists this phone. iOS doesn't tell apps the name you gave it, so set it here.")
                        .font(.mono(12)).foregroundStyle(p.fgDim).padding(.top, 6)

                    SectionHeader(title: "KEYBOARD", palette: p)
                    toggle("Haptic feedback", "Touchpad clicks, scrolling and keys feel like a MacBook trackpad.", $haptics)
                    toggle("Show typed text", "What you type runs along above the keyboard. Turn it off for passwords on a shared screen.", $typedText)

                    Text("Omakey \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.mono(12)).foregroundStyle(p.fgDim)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 32)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(p.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(p.accent)
        .preferredColorScheme(p.colorScheme)
        .onAppear {
            phoneName = model.settings.phoneName
            haptics = model.settings.haptics
            typedText = model.settings.typedText
        }
        .onChange(of: phoneName) { _, v in model.settings.phoneName = v }
        .onChange(of: haptics) { _, v in model.settings.haptics = v }
        .onChange(of: typedText) { _, v in model.settings.typedText = v }
        .sheet(isPresented: $showingLayouts, onDismiss: model.refresh) { LayoutsView(model: model) }
        .alert("Unlink \(unlinking?.name ?? "")?", isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }),
               presenting: unlinking) { host in
            Button("Unlink", role: .destructive) { model.unlink(host) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This phone will need a new pairing code to connect again. Also remove it on the computer with `omakeyd forget`.")
        }
    }

    /// Two per row, each drawn in its own colors. First, the computer's own
    /// Omarchy theme, as it last came over with the keyboard.
    private var themes: some View {
        let desktop = model.settings.desktopTheme
        let fromComputer = Themes.fromComputer(desktop)
        let detail = desktop != nil ? "\(fromComputer.name) · \(model.settings.desktopThemeFrom ?? "computer")"
            : "Type on a computer to fetch its theme"
        let current = model.palette.theme.id
        let tiles: [(Theme, String, String?)] = [(fromComputer, "⇄ From computer", detail)] + Themes.all.map { ($0, $0.name, nil) }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(tiles, id: \.0.id) { theme, title, sub in
                themeTile(theme, title: title, sub: sub, selected: theme.id == current)
            }
        }
    }

    private func themeTile(_ t: Theme, title: String, sub: String?, selected: Bool) -> some View {
        Button {
            guard !selected else { return }
            model.settings.themeId = t.id
            model.refresh()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(selected ? "● \(title)" : title).font(.mono(14, bold: true)).foregroundStyle(Color(rgb: t.fg)).lineLimit(1)
                if let sub { Text(sub).font(.mono(11)).foregroundStyle(Color(rgb: t.fgDim)).lineLimit(2) }
                HStack(spacing: 5) {
                    ForEach([t.key, t.keyAccent, t.accent, t.layer, t.ok, t.error], id: \.self) { c in
                        Circle().fill(Color(rgb: c)).frame(width: 14, height: 14)
                    }
                }
                .padding(.top, 7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(rgb: t.bg), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? p.accent : Color(rgb: t.surface), lineWidth: selected ? 2.5 : 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + (selected ? ", selected" : ""))
        .accessibilityIdentifier("theme.\(t.id)")
    }

    @ViewBuilder
    private var computers: some View {
        if model.paired.isEmpty {
            Text("No computers yet. Pair one from the main screen.").font(.mono(14)).foregroundStyle(p.fgDim)
        }
        VStack(spacing: 8) {
            ForEach(model.paired, id: \.hostId) { h in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.name).font(.mono(16, bold: true)).foregroundStyle(p.fg).lineLimit(1)
                        Text("Omakey · Wi-Fi").font(.mono(13)).foregroundStyle(p.accent)
                        Text(h.addresses.first ?? "").font(.mono(12)).foregroundStyle(p.fgDim)
                    }
                    Spacer()
                    Button("Unlink") { unlinking = h }
                        .font(.mono(14, bold: true))
                        .foregroundStyle(p.error)
                        .accessibilityIdentifier("settings.unlink.\(h.hostId)")
                }
                .padding(14)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func toggle(_ title: String, _ about: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.mono(16, bold: true)).foregroundStyle(p.fg)
                Text(about).font(.mono(13)).foregroundStyle(p.fgDim)
            }
        }
        .padding(14)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 8)
    }
}
