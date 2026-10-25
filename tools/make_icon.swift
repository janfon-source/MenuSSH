// Renders MenuSSH/AppIcon.icns.  Run from MenuSSHMac/:  swift tools/make_icon.swift
// With a path (swift tools/make_icon.swift preview.png), writes a 512px preview there instead.
import AppKit

// A terminal's charcoal, lightening toward the top.
let backTop = NSColor(red: 0.243, green: 0.267, blue: 0.298, alpha: 1)
let backBottom = NSColor(red: 0.071, green: 0.082, blue: 0.098, alpha: 1)
// The prompt in a phosphor green.
let promptColor = NSColor(red: 0.380, green: 0.890, blue: 0.540, alpha: 1)

/// The menu bar icon's chevron and cursor (StatusIcon.swift), without the window around them,
/// in its 18-point box; the square of the icon is the window.
func glyph() {
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
    let chevron = NSBezierPath()
    chevron.move(to: P(3.2, 13.0))
    chevron.line(to: P(8.2, 9.0))
    chevron.line(to: P(3.2, 5.0))
    chevron.lineWidth = 2.2
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.stroke()

    let cursor = NSBezierPath()
    cursor.move(to: P(10.4, 5.0))
    cursor.line(to: P(15.6, 5.0))
    cursor.lineWidth = 2.2
    cursor.lineCapStyle = .round
    cursor.stroke()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // macOS icon grid: ~10% transparent margin around a rounded square.
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let square = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: backTop, ending: backBottom)!.draw(in: square, angle: -90)

    // A title bar's three dots along the top.
    NSGraphicsContext.saveGraphicsState()
    square.addClip()
    for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        let d = s * 0.045
        color.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: s * 0.2 + CGFloat(i) * d * 1.7, y: s * 0.78, width: d, height: d)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // The prompt, filling the middle of the square, with a faint glow.
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = promptColor.withAlphaComponent(0.55)
    glow.shadowOffset = .zero
    glow.shadowBlurRadius = s * 0.03
    glow.set()
    let place = NSAffineTransform()
    place.translateX(by: s * 0.5, yBy: s * 0.46)
    place.scale(by: s * 0.5 / 18)
    place.translateX(by: -9.4, yBy: -9)
    place.concat()
    promptColor.set()
    glyph()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 1 {
    try! render(512).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    exit(0)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MenuSSH.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let out = URL(fileURLWithPath: "MenuSSH/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
