import AppKit

/// A tab in the strip under the toolbar: its title and close button on a rounded background,
/// tinted for the tab showing, as wide as its title needs up to a limit. As in 隨手SQLite; here
/// one tab (this Mac's) stays first and can't be moved.
final class TabChip: NSView {
    private let active: Bool
    /// Whether it can be dragged along the strip; the tabs that can't stay where they are.
    let movable: Bool

    init(views: [NSView], active: Bool, movable: Bool = true) {
        self.active = active
        self.movable = movable
        super.init(frame: .zero)
        let row = NSStackView(views: views)
        row.spacing = 4
        // A close button brings its own room on the right; without one, both sides match.
        row.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: views.last is NSButton ? 6 : 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.init(200), for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        (active ? NSColor.controlAccentColor.withAlphaComponent(0.25) : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    /// A click on the tab shows it.
    var onSelect: (() -> Void)?
    /// The tab dragged from one place among the movable tabs to another, by their order.
    var onMove: ((_ from: Int, _ to: Int) -> Void)?

    /// Follows the mouse: a click picks the tab; once it moves a few points, the tab is dragged
    /// along the strip, the others making way as it passes their middles, and dropped where it is.
    /// It never goes ahead of the tabs that can't move.
    override func mouseDown(with event: NSEvent) {
        guard movable, let strip = superview as? NSStackView, let window else { return onSelect?() ?? () }
        let tabs = { strip.arrangedSubviews.compactMap { $0 as? TabChip }.filter(\.movable) }
        let fixed = strip.arrangedSubviews.prefix { ($0 as? TabChip)?.movable == false }.count
        guard let from = tabs().firstIndex(of: self) else { return }
        let start = event.locationInWindow
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            if !dragging {
                guard abs(next.locationInWindow.x - start.x) > 4 else { continue }
                dragging = true
                alphaValue = 0.7
                NSCursor.closedHand.push()
            }
            let x = strip.convert(next.locationInWindow, from: nil).x
            let others = tabs().filter { $0 !== self }
            let target = others.firstIndex { x < $0.frame.midX } ?? others.count
            if tabs().firstIndex(of: self) != target {
                strip.removeArrangedSubview(self)
                strip.insertArrangedSubview(self, at: fixed + target)
                strip.layoutSubtreeIfNeeded()
            }
        }
        guard dragging else { return onSelect?() ?? () }
        alphaValue = 1
        NSCursor.pop()
        onMove?(from, tabs().firstIndex(of: self) ?? from)
    }
}
