// Rounds a screenshot's corners like an iPhone screen's, transparent outside,
// so it sits well on light and dark pages alike.
//   swift scripts/round-corners.swift <png>...
import AppKit

for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("can't read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    let w = cg.width, h = cg.height
    // About the iPhone's own screen corners, for its shorter side.
    let r = CGFloat(min(w, h)) * 0.13
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
    ctx.draw(cg, in: rect)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
