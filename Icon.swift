// Draws the app icon: a window with its own menu strip ("File Edit View") on top, on a dark tile.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let tile = NSBezierPath(roundedRect: NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8), xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [color(0x3A2F5B), color(0x17132A)])!.draw(in: tile, angle: -90)

    // The window.
    let window = NSRect(x: s * 0.2, y: s * 0.24, width: s * 0.6, height: s * 0.42)
    NSGradient(colors: [color(0xEEF0F5), color(0xC9CEDB)])!.draw(in: NSBezierPath(roundedRect: window, xRadius: s * 0.03, yRadius: s * 0.03), angle: -90)
    // Its menu strip, attached on top like a tab.
    let strip = NSRect(x: window.minX + s * 0.02, y: window.maxY - s * 0.005, width: window.width - s * 0.04, height: s * 0.09)
    let stripPath = NSBezierPath(roundedRect: strip, xRadius: s * 0.025, yRadius: s * 0.025)
    color(0xFFB13B).setFill()
    stripPath.fill()
    // "File Edit View" as three bars.
    color(0x3A2F5B, 0.85).setFill()
    var x = strip.minX + s * 0.04
    for w in [0.07, 0.07, 0.08] {
        NSBezierPath(roundedRect: NSRect(x: x, y: strip.midY - s * 0.012, width: s * w, height: s * 0.024), xRadius: s * 0.012, yRadius: s * 0.012).fill()
        x += s * (w + 0.04)
    }
    // A few lines of content.
    color(0x8A93A8).setFill()
    for i in 0..<3 {
        NSBezierPath(roundedRect: NSRect(x: window.minX + s * 0.06, y: window.maxY - s * (0.11 + CGFloat(i) * 0.08), width: s * (i == 2 ? 0.28 : 0.44), height: s * 0.03),
                     xRadius: s * 0.015, yRadius: s * 0.015).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
