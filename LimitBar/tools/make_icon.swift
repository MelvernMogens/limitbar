import AppKit

// Renders LimitBar's app icon at every iconset size.
// Usage: swift tools/make_icon.swift <out.iconset>

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt squircle centred on a 1024 canvas
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()

    // charcoal gradient body
    NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.07, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // subtle top sheen
    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.07), NSColor(white: 1, alpha: 0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    ctx.restoreGState()

    // hairline rim
    NSColor(white: 1, alpha: 0.10).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    rim.lineWidth = 4
    rim.stroke()

    // three gauges: GLM white, Claude clay, Codex violet — fill = headroom left
    let small = px <= 64
    let colors = [NSColor(white: 0.93, alpha: 1),
                  NSColor(srgbRed: 0.88, green: 0.50, blue: 0.36, alpha: 1),
                  NSColor(srgbRed: 0.58, green: 0.52, blue: 1.0, alpha: 1)]
    let levels: [CGFloat] = [0.60, 0.84, 0.44]
    let barW: CGFloat = small ? 150 : 136
    let gap: CGFloat = small ? 96 : 66
    let totalW = barW * 3 + gap * 2
    let x0 = 512 - totalW / 2
    let h: CGFloat = small ? 560 : 520
    let y0 = 512 - h / 2                      // optically centred in the squircle
    for i in 0..<3 {
        let x = x0 + CGFloat(i) * (barW + gap)
        let r = barW / 2
        if !small {
            let track = NSRect(x: x, y: y0, width: barW, height: h)
            NSColor(white: 1, alpha: 0.13).setFill()
            NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()
        }
        let fill = NSRect(x: x, y: y0, width: barW, height: max(barW, h * levels[i]))
        let fp = NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r)
        if !small {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 34, color: colors[i].withAlphaComponent([0.26, 0.55, 0.34][i]).cgColor)
            colors[i].setFill()
            fp.fill()
            ctx.restoreGState()
        }
        NSGradient(colors: [colors[i].blended(withFraction: 0.22, of: .white)!,
                            colors[i].blended(withFraction: 0.06, of: .black)!])!
            .draw(in: fp, angle: -90)
        if !small {
            // inner top highlight for a little depth
            ctx.saveGState()
            fp.addClip()
            // soft top-down gloss fading out, instead of a hard sticker
            NSGradient(colors: [NSColor(white: 1, alpha: 0.30), NSColor(white: 1, alpha: 0)])!
                .draw(in: NSRect(x: x, y: fill.maxY - barW * 1.1, width: barW, height: barW * 1.1), angle: -90)
            // left-edge sheen for a rounded capsule feel
            NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])!
                .draw(in: NSRect(x: x, y: fill.minY, width: barW * 0.5, height: fill.height), angle: 0)
            ctx.restoreGState()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (base, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = sc == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * sc).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
print("ok")
