import OmakeyCore
import UIKit

/// Where a layout's keys go in a given size, and how their legends are set:
/// shared by the live keyboard (`KeyboardView`) and its pictures
/// (`LayoutPicture`), so the two look the same. Pure; any thread.
struct KeyGeometry: Sendable {
    let unit: CGFloat
    let originX: CGFloat
    let originY: CGFloat
    /// Units the right side of a split layout is moved right by.
    let stretch: Float
    private let splitAt: Float?

    init(layout l: Layout, size: CGSize) {
        let w = size.width, h = size.height
        unit = min(w / CGFloat(l.width), h / CGFloat(l.height))
        let slack = w - unit * CGFloat(l.width)
        // A split layout keeps each side against its screen edge: the spare
        // width goes into the split instead of the margins.
        stretch = l.splitAt != nil && slack > 0 ? Float(slack / unit) : 0
        originX = stretch > 0 ? 0 : (w - unit * CGFloat(l.width)) / 2
        originY = (h - unit * CGFloat(l.height)) / 2
        splitAt = l.splitAt
    }

    func rect(_ r: KeyRect) -> CGRect {
        CGRect(x: originX + CGFloat(r.x) * unit, y: originY + CGFloat(r.y) * unit, width: CGFloat(r.w) * unit, height: CGFloat(r.h) * unit)
    }

    /// A key's label rectangle and its whole shape, in the same coordinates.
    func place(_ k: LayoutKey) -> (main: CGRect, shape: CGPath) {
        let gap = unit * 0.05
        let radius = unit * 0.12
        let drawn = k.rects.map { $0.stretched(splitAt: splitAt, stretch: stretch) }
        let main = rect(drawn[0]).insetBy(dx: gap, dy: gap)
        if drawn.count > 1 { return (main, outline(drawn, gap: gap, radius: radius)) }
        return (main, CGPath(roundedRect: main, cornerWidth: radius, cornerHeight: radius, transform: nil))
    }

    /// One outline for a key made of several rectangles: each is inset by the
    /// key gap except on sides where it meets another part, which it overlaps
    /// instead, so the parts read as a single key.
    private func outline(_ parts: [KeyRect], gap: CGFloat, radius: CGFloat) -> CGPath {
        let e: Float = 1e-4
        var path = CGMutablePath() as CGPath
        for (n, p) in parts.enumerated() {
            func meets(_ test: (KeyRect) -> Bool) -> Bool { parts.enumerated().contains { $0.offset != n && test($0.element) } }
            let overlapY = { (o: KeyRect) in o.y < p.y + p.h - e && p.y < o.y + o.h - e }
            let overlapX = { (o: KeyRect) in o.x < p.x + p.w - e && p.x < o.x + o.w - e }
            let l = meets { overlapY($0) && abs($0.x + $0.w - p.x) < e } ? -gap : gap
            let r = meets { overlapY($0) && abs(p.x + p.w - $0.x) < e } ? -gap : gap
            let t = meets { overlapX($0) && abs($0.y + $0.h - p.y) < e } ? -gap : gap
            let b = meets { overlapX($0) && abs(p.y + p.h - $0.y) < e } ? -gap : gap
            let full = rect(p)
            let one = CGRect(x: full.minX + l, y: full.minY + t, width: full.width - l - r, height: full.height - t - b)
            let piece = CGPath(roundedRect: one, cornerWidth: radius, cornerHeight: radius, transform: nil)
            path = path.isEmpty ? piece : path.union(piece)
        }
        return path
    }

    // MARK: - Legends, in a key's own coordinates (its main rectangle is w × h at the origin)

    /// The label, fitted to the key: big for one or two characters, smaller for words.
    static func labelFont(_ text: String, unit: CGFloat, width w: CGFloat) -> UIFont {
        let size = unit * (text.count <= 2 ? 0.4 : 0.24)
        let font = UIFont.mono(size, bold: true)
        let maxW = w - unit * 0.12
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return width > maxW && width > 0 ? UIFont.mono(size * maxW / width, bold: true) : font
    }

    static func labelFrame(_ font: UIFont, width w: CGFloat, height h: CGFloat) -> CGRect {
        CGRect(x: 0, y: (h - font.lineHeight) / 2, width: w, height: font.lineHeight)
    }

    /// The shifted character, small in the top left corner.
    static func subFont(unit: CGFloat) -> UIFont { .mono(unit * 0.2) }

    static func subFrame(_ font: UIFont, unit: CGFloat, width w: CGFloat) -> CGRect {
        CGRect(x: unit * 0.1, y: unit * 0.26 - font.ascender, width: max(w - unit * 0.2, 1), height: font.lineHeight)
    }

    /// The printed Fn legend, smaller still, bottom right; not on narrow keys.
    static func fnFont(unit: CGFloat) -> UIFont { .mono(unit * 0.16) }

    static func fnFrame(_ font: UIFont, unit: CGFloat, width w: CGFloat, height h: CGFloat) -> CGRect {
        CGRect(x: unit * 0.08, y: h - unit * 0.1 - font.ascender, width: max(w - unit * 0.16, 1), height: font.lineHeight)
    }

    static func showsFn(unit: CGFloat, width w: CGFloat) -> Bool { w > unit * 0.6 }
}
