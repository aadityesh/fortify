// Renders the AppIcon asset (PNGs + Contents.json) into the given .appiconset folder:
// Fortify My Mac's lime (#D4F57A) fortress shield with a keyhole, on a black tile.
// Usage: swift scripts/make_icon.swift Resources/Assets.xcassets/AppIcon.appiconset
// Keep the geometry in sync with FortressShape in Sources/AppLock/Views/Components.swift.
import AppKit

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Fortress shield (battlements on top, pointed base) with a keyhole cut out,
/// in a unit square with y pointing down. Fill with the even-odd rule.
func fortressPath() -> CGPath {
    let p = CGMutablePath()
    let top: CGFloat = 0.2, notch: CGFloat = 0.28
    p.move(to: CGPoint(x: 0.2, y: top))
    for (a, b) in [(0.34, 0.43), (0.57, 0.66)] {
        p.addLine(to: CGPoint(x: a, y: top))
        p.addLine(to: CGPoint(x: a, y: notch))
        p.addLine(to: CGPoint(x: b, y: notch))
        p.addLine(to: CGPoint(x: b, y: top))
    }
    p.addLine(to: CGPoint(x: 0.8, y: top))
    p.addLine(to: CGPoint(x: 0.8, y: 0.5))
    p.addQuadCurve(to: CGPoint(x: 0.5, y: 0.85), control: CGPoint(x: 0.8, y: 0.75))
    p.addQuadCurve(to: CGPoint(x: 0.2, y: 0.5), control: CGPoint(x: 0.2, y: 0.75))
    p.closeSubpath()

    // Keyhole as one outline (round head over a tapered stem), so nothing overlaps.
    let center = CGPoint(x: 0.5, y: 0.508), r: CGFloat = 0.068, neck: CGFloat = 0.03
    let dy = (r * r - neck * neck).squareRoot()
    p.move(to: CGPoint(x: 0.5 + neck, y: center.y + dy))
    p.addArc(center: center, radius: r,
             startAngle: atan2(dy, neck), endAngle: atan2(dy, -neck), clockwise: true)
    p.addLine(to: CGPoint(x: 0.445, y: 0.69))
    p.addLine(to: CGPoint(x: 0.555, y: 0.69))
    p.closeSubpath()
    return p
}

let lime = CGColor(srgbRed: 0xD4 / 255, green: 0xF5 / 255, blue: 0x7A / 255, alpha: 1)

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext

    // macOS icon grid: ~10% margin, continuous-ish corner radius.
    let inset = size * 0.1
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tile = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)

    // Black tile (the app's #0A0C0A) with a whisper of lift at the top.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [CGColor(srgbRed: 0.09, green: 0.10, blue: 0.09, alpha: 1),
                 CGColor(srgbRed: 0.02, green: 0.025, blue: 0.02, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // Small sizes stay flat so the shape stays crisp.
    if px >= 64 {
        ctx.addPath(tile)
        ctx.setStrokeColor(lime.copy(alpha: 0.18)!)
        ctx.setLineWidth(size * 0.006)
        ctx.strokePath()
    }

    // Shield: unit square -> tile, flipped to y-up.
    var transform = CGAffineTransform(translationX: rect.minX, y: rect.maxY).scaledBy(x: rect.width, y: -rect.height)
    let shield = fortressPath().copy(using: &transform)!
    if px >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: size * 0.06, color: lime.copy(alpha: 0.35))
        ctx.addPath(shield)
        ctx.setFillColor(lime)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }
    ctx.addPath(shield)
    ctx.setFillColor(lime)
    ctx.fillPath(using: .evenOdd)

    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let file = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale).write(to: iconset.appendingPathComponent(file))
        images.append("""
            { "filename": "\(file)", "idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)" }
        """)
    }
}
let contents = "{\n  \"images\": [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\": { \"author\": \"xcode\", \"version\": 1 }\n}\n"
try contents.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
