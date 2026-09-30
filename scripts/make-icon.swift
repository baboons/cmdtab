// Renders CmdTab's app icon into an .iconset directory.
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws on a 1024×1024 canvas (origin bottom-left).
func draw() {
    // Apple's icon grid: 824pt body centered in 1024.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x1B1D2A).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x353A5E), color(0x1A1C2B), color(0x101119)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: squircle, angle: -90)

    // Soft accent glow behind the cards.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [color(0x7C6CFF, 0.55), color(0x7C6CFF, 0)])!
        .draw(fromCenter: NSPoint(x: 560, y: 470), radius: 0, toCenter: NSPoint(x: 560, y: 470), radius: 420, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Hairline highlight along the top edge.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
    rim.lineWidth = 4
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: rim, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Stacked windows, back to front.
    let cards: [(NSRect, CGFloat)] = [
        (NSRect(x: 330, y: 470, width: 440, height: 300), 0.16),
        (NSRect(x: 290, y: 410, width: 460, height: 314), 0.30),
    ]
    for (rect, alpha) in cards {
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44).fill()
    }

    let front = NSRect(x: 236, y: 250, width: 552, height: 392)
    let frontPath = NSBezierPath(roundedRect: front, xRadius: 52, yRadius: 52)
    NSGraphicsContext.saveGraphicsState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    cardShadow.shadowBlurRadius = 40
    cardShadow.shadowOffset = NSSize(width: 0, height: -16)
    cardShadow.set()
    NSColor.white.setFill()
    frontPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0xFFFFFF), color(0xE7E9F4)])!.draw(in: frontPath, angle: -90)

    // Search field on the front card.
    let field = NSRect(x: front.minX + 44, y: front.maxY - 112, width: front.width - 88, height: 68)
    color(0x1B1D2A, 0.07).setFill()
    NSBezierPath(roundedRect: field, xRadius: 34, yRadius: 34).fill()
    // Magnifier
    let lens = NSBezierPath(ovalIn: NSRect(x: field.minX + 24, y: field.midY - 8, width: 26, height: 26))
    lens.lineWidth = 7
    color(0x6B6F85).setStroke()
    lens.stroke()
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: field.minX + 46, y: field.midY - 4))
    handle.line(to: NSPoint(x: field.minX + 58, y: field.midY - 16))
    handle.lineWidth = 8
    handle.lineCapStyle = .round
    handle.stroke()
    // Caret
    color(0x6E5BFF).setFill()
    NSBezierPath(roundedRect: NSRect(x: field.minX + 82, y: field.midY - 18, width: 7, height: 36), xRadius: 3.5, yRadius: 3.5).fill()

    // ⌘ glyph.
    let glyph = NSAttributedString(string: "⌘", attributes: [
        .font: NSFont.systemFont(ofSize: 210, weight: .semibold),
        .foregroundColor: color(0x6E5BFF),
    ])
    let size = glyph.size()
    glyph.draw(at: NSPoint(x: front.midX - size.width / 2, y: front.minY + 26))
}

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let scale = CGFloat(px) / 1024
    ctx.cgContext.scaleBy(x: scale, y: scale)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("Wrote \(out.path)")
