import OmakeyCore
import SwiftUI
import UIKit

/// A layout drawn at the width it's given, as tall as its own proportions
/// ask: a picture of it (`LayoutPicture`), drawn off the main thread the
/// first time and kept, the background color meanwhile.
struct LayoutPreview: View {
    let layout: Layout
    let theme: Theme
    @Environment(\.displayScale) private var scale
    @State private var picture: (key: String, image: UIImage)?

    var body: some View {
        Color(rgb: theme.bg)
            .aspectRatio(CGFloat(layout.width / layout.height), contentMode: .fit)
            .overlay {
                GeometryReader { g in
                    let key = LayoutPicture.key(layout, theme, width: g.size.width, scale: scale)
                    let image = LayoutPicture.cached(key) ?? (picture?.key == key ? picture?.image : nil)
                    ZStack {
                        if let image {
                            Image(uiImage: image).resizable().transition(.opacity.animation(.easeOut(duration: 0.12)))
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                    .task(id: key) {
                        guard image == nil, let drawn = await LayoutPicture.picture(layout, theme, width: g.size.width, scale: scale) else { return }
                        picture = (key, drawn)
                    }
                }
            }
            .padding(6)
            .background(Color(rgb: theme.bg), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

/// A sketch of portrait mode for its card: a phone, the touchpad on top, the phone's keyboard below.
struct PortraitSketch: View {
    let theme: Theme

    var body: some View {
        Canvas { ctx, size in
            let h = size.height, w = h * 0.5
            let phone = CGRect(x: (size.width - w) / 2, y: 0, width: w, height: h)
            ctx.fill(Path(roundedRect: phone, cornerRadius: 12), with: .color(Color(rgb: theme.bg)))
            ctx.stroke(Path(roundedRect: phone, cornerRadius: 12), with: .color(Color(rgb: theme.fgDim)), lineWidth: 1.5)
            let inner = phone.insetBy(dx: 5, dy: 8)
            // The touchpad: side buttons and the surface.
            let pad = CGRect(x: inner.minX, y: inner.minY + 8, width: inner.width, height: inner.height * 0.42)
            let col = pad.width * 0.18
            for x in [pad.minX, pad.maxX - col] {
                for i in 0..<4 {
                    let cellH = (pad.height - 9) / 4
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: pad.minY + CGFloat(i) * (cellH + 3), width: col, height: cellH), cornerRadius: 2),
                             with: .color(Color(rgb: theme.keyMod)))
                }
            }
            ctx.fill(Path(roundedRect: CGRect(x: pad.minX + col + 3, y: pad.minY, width: pad.width - col * 2 - 6, height: pad.height), cornerRadius: 4),
                     with: .color(Color(rgb: theme.surface)))
            // The key strips.
            var y = pad.maxY + 5
            for _ in 0..<2 {
                let n = 8
                let kw = (inner.width - CGFloat(n - 1) * 2) / CGFloat(n)
                for i in 0..<n {
                    ctx.fill(Path(roundedRect: CGRect(x: inner.minX + CGFloat(i) * (kw + 2), y: y, width: kw, height: 7), cornerRadius: 1.5),
                             with: .color(Color(rgb: theme.key)))
                }
                y += 10
            }
            // The phone's keyboard.
            let kb = CGRect(x: phone.minX + 2, y: y + 3, width: phone.width - 4, height: phone.maxY - y - 6)
            ctx.fill(Path(roundedRect: kb, cornerRadius: 6), with: .color(Color(rgb: theme.keyMod)))
            for (r, n) in [10, 9, 7, 4].enumerated() {
                let rowH = (kb.height - 12) / 4
                let kw = (kb.width - 8 - CGFloat(n - 1) * 2) / CGFloat(n)
                let left = kb.minX + 4 + (r == 1 ? kw / 2 : 0)
                for i in 0..<n {
                    ctx.fill(Path(roundedRect: CGRect(x: left + CGFloat(i) * (kw + 2), y: kb.minY + 4 + CGFloat(r) * (rowH + 1), width: kw, height: rowH - 1),
                                  cornerRadius: 1.5), with: .color(Color(rgb: theme.key)))
                }
            }
        }
        .frame(height: 190)
        .accessibilityHidden(true)
    }
}

/// A layout before it's imported: what it looks like, and what it would replace.
struct ImportPreviewSheet: View {
    let pending: AppModel.PendingLayout
    let message: String
    let palette: Palette
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LayoutPreview(layout: pending.layout, theme: palette.theme)
                    Text(message).monoFont(13).foregroundStyle(palette.fg)
                }
                .padding(20)
            }
            .background(palette.bg.ignoresSafeArea())
            .navigationTitle(pending.layout.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pending.replaces != nil ? "Replace" : "Import") {
                        onImport()
                        dismiss()
                    }
                    .accessibilityIdentifier("import.confirm")
                }
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(palette.colorScheme)
    }
}
