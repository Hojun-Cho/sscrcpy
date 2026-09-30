import AppKit

// Renders the 1024x1024 app icon PNG to the path in the first argument.
// The Makefile scales it into AppIcon.icns, so no binary asset is checked in.
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset = 100.0
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.30, blue: 0.47, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.14, blue: 0.24, alpha: 1)])!
        .draw(in: shape, angle: -90)
    let body = NSRect(x: (size - 330) / 2, y: (size - 560) / 2, width: 330, height: 560)
    let phone = NSBezierPath(roundedRect: body, xRadius: 64, yRadius: 64)
    phone.lineWidth = 34
    NSColor.white.setStroke()
    phone.stroke()
    let c = NSPoint(x: size / 2 + 14, y: size / 2)
    let play = NSBezierPath()
    play.move(to: NSPoint(x: c.x - 62, y: c.y + 92))
    play.line(to: NSPoint(x: c.x + 88, y: c.y))
    play.line(to: NSPoint(x: c.x - 62, y: c.y - 92))
    play.close()
    play.lineJoinStyle = .round
    play.lineWidth = 28
    let green = NSColor(srgbRed: 0.27, green: 0.84, blue: 0.47, alpha: 1)
    green.setFill(); green.setStroke()
    play.fill(); play.stroke()
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
