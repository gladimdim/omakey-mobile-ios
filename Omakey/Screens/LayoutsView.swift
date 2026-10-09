import OmakeyCore
import SwiftUI

/// The layouts to type on; tapping one makes it the keyboard's. Previews,
/// sharing and importing come in M9.
struct LayoutsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var p: Palette { model.palette }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(id: LayoutStore.portraitId, name: LayoutStore.portraitName,
                        detail: "Hold the phone upright. Your own keyboard types straight into the computer, autocorrect and all, with the touchpad above it.")
                    ForEach(model.layouts.all(), id: \.layout.id) { e in
                        row(id: e.layout.id, name: e.layout.name,
                            detail: "\(e.layout.keys.count) keys" + (e.layout.author.map { " · by \($0)" } ?? "") + (e.builtIn ? "" : " · imported"))
                    }
                } footer: {
                    Text("Tap a layout to type on it.").font(.mono(12))
                }
            }
            .scrollContentBackground(.hidden)
            .background(p.bg.ignoresSafeArea())
            .navigationTitle("Layouts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(p.accent)
        .preferredColorScheme(p.colorScheme)
    }

    private func row(id: String, name: String, detail: String) -> some View {
        Button {
            model.selectLayout(id)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.mono(16, bold: true)).foregroundStyle(p.fg)
                    Text(detail).font(.mono(12)).foregroundStyle(p.fgDim)
                }
                Spacer()
                if model.layouts.selectedId == id { Image(systemName: "checkmark").foregroundStyle(p.ok) }
            }
        }
        .listRowBackground(p.surface)
        .accessibilityIdentifier("layout.\(id)")
    }
}
