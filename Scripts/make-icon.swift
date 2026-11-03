import AppKit

// Draws the Zapper icon: a navy squircle holding a glowing D-pad ring,
// the same motif as the app's main control.
//
// Regenerate Resources/AppIcon.icns with:
//   swiftc -o /tmp/make-icon Scripts/make-icon.swift && /tmp/make-icon /tmp/zapper-icon \
//     && iconutil -c icns /tmp/zapper-icon/AppIcon.iconset -o Resources/AppIcon.icns
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    // Squircle body on Apple's icon grid: 824pt inside a 1024 canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45).cgColor)
    rgb(12, 18, 36).setFill()
    shape.fill()
    ctx.restoreGState()

    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [rgb(36, 56, 104), rgb(16, 26, 54), rgb(8, 12, 26)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -90)
    // Accent light from the top right, as in the app's panel.
    NSGradient(colors: [rgb(84, 140, 255, 0.45), rgb(84, 140, 255, 0)])!
        .draw(fromCenter: NSPoint(x: 760, y: 880), radius: 0,
              toCenter: NSPoint(x: 760, y: 880), radius: 520, options: [])
    ctx.restoreGState()

    // Fine inner rim so the edge reads on dark Docks.
    rgb(255, 255, 255, 0.10).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
    rim.lineWidth = 3
    rim.stroke()

    let c = NSPoint(x: 512, y: 500)

    // Glow under the ring.
    NSGradient(colors: [rgb(84, 140, 255, 0.40), rgb(84, 140, 255, 0)])!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: 380, options: [])

    // Ring.
    let ringR: CGFloat = 268
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
    NSGradient(colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0.05)])!.draw(in: ring, angle: -90)
    rgb(255, 255, 255, 0.18).setStroke()
    ring.lineWidth = 4
    ring.stroke()

    // Lit "up" segment, the remote mid-press.
    let seg = NSBezierPath()
    seg.appendArc(withCenter: c, radius: 205, startAngle: 50, endAngle: 130)
    seg.lineWidth = 92
    seg.lineCapStyle = .round
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: rgb(84, 140, 255, 0.9).cgColor)
    rgb(84, 140, 255, 0.55).setStroke()
    seg.stroke()
    ctx.restoreGState()

    // Chevrons.
    func chevron(at p: NSPoint, angle: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: -26, y: -14))
        path.line(to: NSPoint(x: 0, y: 14))
        path.line(to: NSPoint(x: 26, y: -14))
        var t = AffineTransform(translationByX: p.x, byY: p.y)
        t.rotate(byDegrees: angle)
        path.transform(using: t)
        path.lineWidth = 16
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        rgb(255, 255, 255, alpha).setStroke()
        path.stroke()
    }
    let d: CGFloat = 205
    chevron(at: NSPoint(x: c.x, y: c.y + d), angle: 0, alpha: 0.95)
    chevron(at: NSPoint(x: c.x, y: c.y - d), angle: 180, alpha: 0.55)
    chevron(at: NSPoint(x: c.x - d, y: c.y), angle: 90, alpha: 0.55)
    chevron(at: NSPoint(x: c.x + d, y: c.y), angle: -90, alpha: 0.55)

    // OK button.
    let okR: CGFloat = 112
    let ok = NSBezierPath(ovalIn: NSRect(x: c.x - okR, y: c.y - okR, width: okR * 2, height: okR * 2))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46, color: rgb(84, 140, 255, 0.95).cgColor)
    rgb(84, 140, 255).setFill()
    ok.fill()
    ctx.restoreGState()
    NSGradient(colors: [rgb(128, 190, 255), rgb(70, 120, 250)])!.draw(in: ok, angle: -90)
    rgb(255, 255, 255, 0.35).setStroke()
    ok.lineWidth = 4
    ok.stroke()
    // Specular highlight on the button.
    let shine = NSBezierPath(ovalIn: NSRect(x: c.x - 70, y: c.y + 30, width: 140, height: 62))
    NSGradient(colors: [rgb(255, 255, 255, 0.45), rgb(255, 255, 255, 0)])!.draw(in: shine, angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
let iconset = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = CGFloat(pt * scale)
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try! drawIcon(size: px).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: iconset + "/" + name))
}
try! drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: out + "/preview.png"))
print("ok")
