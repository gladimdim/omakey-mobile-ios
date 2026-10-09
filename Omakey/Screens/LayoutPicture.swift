import OmakeyCore
import UIKit

/// A layout drawn into a picture, the way the keyboard looks at rest, for
/// the Layouts page and the import preview. Drawn off the main thread and
/// kept for the session, so the page opens and scrolls without building a
/// live keyboard (some 450 layers) for every card.
enum LayoutPicture {
    /// NSCache is thread-safe.
    private final class Cache: @unchecked Sendable {
        let pictures: NSCache<NSString, UIImage> = {
            let c = NSCache<NSString, UIImage>()
            c.countLimit = 48
            return c
        }()
    }

    private static let cache = Cache()

    /// What tells one picture from another: the layout as written, the colors, the size.
    static func key(_ layout: Layout, _ theme: Theme, width: CGFloat, scale: CGFloat) -> String {
        let colors = [theme.bg, theme.key, theme.keyMod, theme.keyAccent, theme.fg, theme.fgDim, theme.fgOnAccent, theme.layer]
        return "\(layout.id) \(layout.source.hashValue) \(colors) \(Int((width * scale).rounded()))"
    }

    /// Already drawn, if it was.
    static func cached(_ key: String) -> UIImage? { cache.pictures.object(forKey: key as NSString) }

    /// The picture, drawn now off the main thread unless it was already.
    static func picture(_ layout: Layout, _ theme: Theme, width: CGFloat, scale: CGFloat) async -> UIImage? {
        guard width > 1 else { return nil }
        let k = key(layout, theme, width: width, scale: scale)
        if let p = cached(k) { return p }
        let p = await Task.detached(priority: .userInitiated) { draw(layout, theme, width: width, scale: scale) }.value
        cache.pictures.setObject(p, forKey: k as NSString)
        return p
    }

    /// Keys of a picture go nowhere.
    private final class Silent: KeyboardSink {
        func keyDown(_ code: Int) {}
        func keyUp(_ code: Int) {}
    }

    /// As `KeyboardView` shows it with nothing pressed: the same geometry,
    /// legends and colors. Any thread.
    nonisolated static func draw(_ layout: Layout, _ theme: Theme, width: CGFloat, scale: CGFloat) -> UIImage {
        let size = CGSize(width: width, height: (width * CGFloat(layout.height / layout.width)).rounded(.up))
        let g = KeyGeometry(layout: layout, size: size)
        let model = KeyboardModel(layout: layout, sink: Silent())
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let left = NSMutableParagraphStyle()
        left.alignment = .left
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        let unit = g.unit
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            UIColor(rgb: theme.bg).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            for (i, k) in layout.keys.enumerated() {
                let placed = g.place(k)
                let fill: UInt32 = switch k.style {
                case .accent: theme.keyAccent
                case .mod: theme.keyMod
                case .fkey: theme.keyFkey
                default: theme.key
                }
                c.addPath(placed.shape)
                c.setFillColor(UIColor(rgb: fill).cgColor)
                c.fillPath()
                let m = placed.main
                func text(_ s: String, _ font: UIFont, _ color: UInt32, _ r: CGRect, _ style: NSParagraphStyle) {
                    (s as NSString).draw(in: r.offsetBy(dx: m.minX, dy: m.minY),
                                         withAttributes: [.font: font, .foregroundColor: UIColor(rgb: color), .paragraphStyle: style])
                }
                let label = model.labelFor(i)
                let font = KeyGeometry.labelFont(label, unit: unit, width: m.width)
                text(label, font, k.style == .accent ? theme.fgOnAccent : theme.fg,
                     KeyGeometry.labelFrame(font, width: m.width, height: m.height), center)
                if let sub = model.subFor(i) {
                    let f = KeyGeometry.subFont(unit: unit)
                    text(sub, f, theme.fgDim, KeyGeometry.subFrame(f, unit: unit, width: m.width), left)
                }
                if let fn = k.layers["fn"]?.ownLabel, KeyGeometry.showsFn(unit: unit, width: m.width) {
                    let f = KeyGeometry.fnFont(unit: unit)
                    text(fn, f, theme.layer, KeyGeometry.fnFrame(f, unit: unit, width: m.width, height: m.height), right)
                }
            }
        }
    }
}
