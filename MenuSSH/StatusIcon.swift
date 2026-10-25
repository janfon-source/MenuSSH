import AppKit

/// The menu bar icon: a terminal window with a `>_` prompt, in the same plain style as 隨手SQLite's
/// feather and 隨手記's pen; a template image, so it takes the menu bar's color.
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            glyph()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The window's outline with a thicker title bar, a chevron, and the cursor's underscore.
    static func glyph() {
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
        let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 15, height: 13), xRadius: 2.6, yRadius: 2.6)
        frame.lineWidth = 1.5
        frame.stroke()
        NSBezierPath(rect: NSRect(x: 1.5, y: 12.6, width: 15, height: 2)).fill()

        let chevron = NSBezierPath()
        chevron.move(to: P(4.6, 10.2))
        chevron.line(to: P(7.6, 7.7))
        chevron.line(to: P(4.6, 5.2))
        chevron.lineWidth = 1.6
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()

        let cursor = NSBezierPath()
        cursor.move(to: P(9.4, 5.2))
        cursor.line(to: P(13.4, 5.2))
        cursor.lineWidth = 1.6
        cursor.lineCapStyle = .round
        cursor.stroke()
    }
}
