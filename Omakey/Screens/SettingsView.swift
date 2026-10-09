import SwiftUI

/// Settings. The theme, computers and default layout rows come with the layouts page (M9).
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var phoneName = ""
    @State private var haptics = true
    @State private var typedText = true

    private var p: Palette { model.palette }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("iPhone", text: $phoneName)
                        .font(.mono(16))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("omakey.settings.name")
                } header: {
                    Text("PHONE NAME").font(.mono(12, bold: true))
                } footer: {
                    Text("How your computer lists this phone. iOS doesn't tell apps the name you gave it, so set it here.")
                        .font(.mono(12))
                }
                Section {
                    Toggle(isOn: $haptics) {
                        row("Haptic feedback", "Touchpad clicks, scrolling and keys feel like a MacBook trackpad.")
                    }
                    Toggle(isOn: $typedText) {
                        row("Show typed text", "What you type runs along above the keyboard. Turn it off for passwords on a shared screen.")
                    }
                } header: {
                    Text("KEYBOARD").font(.mono(12, bold: true))
                }
                Section {
                    Text("Omakey \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.mono(12))
                        .foregroundStyle(p.fgDim)
                }
            }
            .tint(p.accent)
            .scrollContentBackground(.hidden)
            .background(p.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(p.colorScheme)
        .onAppear {
            phoneName = model.settings.phoneName
            haptics = model.settings.haptics
            typedText = model.settings.typedText
        }
        .onDisappear {
            model.settings.phoneName = phoneName
            model.settings.haptics = haptics
            model.settings.typedText = typedText
        }
    }

    private func row(_ title: String, _ about: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.mono(16, bold: true)).foregroundStyle(p.fg)
            Text(about).font(.mono(13)).foregroundStyle(p.fgDim)
        }
    }
}
