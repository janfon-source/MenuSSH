import AppKit

/// A corner handle for resizing the popover, which has no resizable frame of its own.
/// Reports how far the pointer has moved since the drag began, in screen points
/// (width grows to the right, height grows downward).
final class ResizeGrip: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onReset: (() -> Void)?

    private var start: NSPoint?

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }
    override var mouseDownCanMoveWindow: Bool { false }
    // A pinned popover may not be key when the user reaches for the grip; the first click should still drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        applyLanguage()
        NotificationCenter.default.addObserver(forName: Language.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyLanguage()
        }
    }

    private func applyLanguage() {
        toolTip = tr("拖曳可調整視窗大小，按兩下恢復預設大小", "Drag to resize; double-click to restore the default size")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        // Three short diagonals, the classic size-grip look.
        NSColor.secondaryLabelColor.setStroke()
        let b = bounds
        for i in 0..<3 {
            let inset = CGFloat(i) * 4 + 2
            let path = NSBezierPath()
            path.move(to: NSPoint(x: b.maxX - inset, y: b.minY + 1))
            path.line(to: NSPoint(x: b.maxX - 1, y: b.minY + inset))
            path.lineWidth = 1.2
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    private var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) { return .frameResize(position: .bottomRight, directions: .all) }
        return .crosshair
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func mouseDown(with event: NSEvent) {
        resizeCursor.set()
        if event.clickCount == 2 {
            start = nil
            onReset?()
            return
        }
        start = screenPoint(event)
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        resizeCursor.set()   // the window moving under the pointer would otherwise reset it
        let p = screenPoint(event)
        onDrag?(CGSize(width: p.x - start.x, height: start.y - p.y))
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
    }

    /// Screen coordinates stay put while the popover window itself changes size underneath.
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
}
