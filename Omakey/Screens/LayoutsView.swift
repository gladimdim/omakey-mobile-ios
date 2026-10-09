import OmakeyCore
import SwiftUI
import UniformTypeIdentifiers

/// Every layout with a live preview of its keys. Tapping one makes it the
/// active layout and closes the page; each card can also be shared, and an
/// imported one removed. From the connect screen it can import a file too.
struct LayoutsView: View {
    @Bindable var model: AppModel
    /// Show "Import file…": not from the keyboard, as on Android.
    var canImport = false
    @Environment(\.dismiss) private var dismiss
    @State private var pickingFile = false
    @State private var pending: AppModel.PendingLayout?
    @State private var removing: Layout?

    private var p: Palette { model.palette }
    private var theme: Theme { model.palette.theme }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tap a layout to type on it.")
                        .monoFont(13)
                        .foregroundStyle(p.fgDim)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                        portraitCard
                        ForEach(model.layouts.all(), id: \.layout.id) { card($0) }
                    }
                }
                .padding(16)
            }
            .background(p.bg.ignoresSafeArea())
            .navigationTitle("Layouts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if canImport {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Import file…") { pickingFile = true }.accessibilityIdentifier("layouts.import")
                    }
                }
            }
        }
        .tint(p.accent)
        .preferredColorScheme(p.colorScheme)
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.json, .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            pending = model.prepareImport {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                if data.count > LayoutParser.maxBytes { throw LayoutError("Layout is larger than 256 KB") }
                return String(decoding: data, as: UTF8.self)
            }
        }
        .sheet(item: $pending) { pending in
            ImportPreviewSheet(pending: pending, message: model.layoutMessage(pending), palette: p) { model.confirmImport(pending) }
        }
        .alert("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { layout in
            Button("Remove", role: .destructive) {
                model.layouts.delete(layout.id)
                // The active layout may have fallen back to the default.
                model.refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's deleted from this phone. You can import it again from its file or link.")
        }
    }

    private func pick(_ id: String) {
        model.selectLayout(id)
        dismiss()
    }

    private func badge(_ label: String, _ color: Color) -> some View {
        Text(label)
            .monoFont(10, bold: true)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(p.bg, in: RoundedRectangle(cornerRadius: 8))
    }

    private func cardBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(p.surface)
            .overlay { if selected { RoundedRectangle(cornerRadius: 12).stroke(p.accent, lineWidth: 2) } }
    }

    /// Portrait mode, which isn't a layout: the phone's keyboard under the touchpad.
    private var portraitCard: some View {
        let selected = model.layouts.portrait
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(LayoutStore.portraitName).monoFont(16, bold: true).foregroundStyle(p.fg).lineLimit(1)
                Spacer(minLength: 4)
                badge("MODE", p.layer)
                if selected { badge("● IN USE", p.ok) }
            }
            PortraitSketch(theme: theme)
            Text("Hold the phone upright. Your own keyboard types straight into the computer, autocorrect and all, with the touchpad and its buttons above it. Types what a US or Ukrainian layout can.")
                .monoFont(13).foregroundStyle(p.fg)
        }
        .padding(14)
        .background(cardBackground(selected: selected))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { pick(LayoutStore.portraitId) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pick(LayoutStore.portraitId) }
        .accessibilityIdentifier("layout.\(LayoutStore.portraitId)")
    }

    private func card(_ entry: LayoutStore.Entry) -> some View {
        let layout = entry.layout
        let selected = !model.layouts.portrait && model.layouts.selected().id == layout.id
        return VStack(alignment: .leading, spacing: 10) {
            if entry.builtIn && layout.id == LayoutStore.defaultId {
                Text("★ Recommended by gladimdim").monoFont(12, bold: true).foregroundStyle(p.warn)
            }
            HStack(spacing: 6) {
                Text(layout.name).monoFont(16, bold: true).foregroundStyle(p.fg).lineLimit(1)
                Spacer(minLength: 4)
                if !entry.builtIn { badge("IMPORTED", p.fgDim) }
                if selected { badge("● IN USE", p.ok) }
            }
            LayoutPreview(layout: layout, theme: theme)
            if let d = layout.description {
                // In full: it says how the layout works (layers, thumb keys).
                Text(d).monoFont(13).foregroundStyle(p.fg)
            }
            HStack {
                Text("\(layout.keys.count) keys" + (layout.author.map { " · by \($0)" } ?? ""))
                    .monoFont(12).foregroundStyle(p.fgDim).lineLimit(1)
                Spacer()
                ShareLink(item: Self.shareText(layout), subject: Text("\(layout.name) — Omakey layout")) {
                    Text("Share").monoFont(13, bold: true)
                }
                .accessibilityIdentifier("layout.\(layout.id).share")
                if !entry.builtIn {
                    Button("Remove") { removing = layout }
                        .monoFont(13, bold: true)
                        .foregroundStyle(p.error)
                        .padding(.leading, 8)
                }
            }
        }
        .padding(14)
        .background(cardBackground(selected: selected))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { pick(layout.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(layout.name + (selected ? ", in use" : ""))
        .accessibilityAction { pick(layout.id) }
        .accessibilityIdentifier("layout.\(layout.id)")
    }

    /// Out through the share sheet: an `omakey://layout` link when it is
    /// short enough to paste anywhere, otherwise the JSON itself. Either
    /// imports on another phone or in the studio.
    static func shareText(_ layout: Layout) -> String {
        let link = LayoutLink.encode(layout.source)
        return link.count <= maxLink ? link : layout.source
    }

    private static let maxLink = 8000
}
