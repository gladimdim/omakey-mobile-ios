import OmakeyCore
import SwiftUI

/// Pointer speed presets for common monitors, for one computer.
struct PresetPicker: View {
    let title: String
    let current: String
    let palette: Palette
    let onPick: (PointerPresets.Preset) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(PointerPresets.all, id: \.name) { p in
                Button {
                    onPick(p)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(p.name)  ·  \(String(format: "%g", p.sensitivity))×")
                                .font(.mono(15, bold: true)).foregroundStyle(palette.fg)
                            Text(p.detail).font(.mono(12)).foregroundStyle(palette.fgDim)
                        }
                        Spacer()
                        if p.name == current { Image(systemName: "checkmark").foregroundStyle(palette.ok) }
                    }
                }
                .listRowBackground(palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(palette.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(palette.colorScheme)
    }
}
