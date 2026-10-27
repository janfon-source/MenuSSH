import AppKit

/// A pane's folder field with its name inside it, at the left ("This Mac", "Server"), drawn as one
/// text field. The label and the field are the caller's, so it keeps setting their text as before.
final class PathBar: NSView {
    private let field: NSTextField

    init(label: NSTextField, field: NSTextField) {
        self.field = field
        super.init(frame: .zero)
        wantsLayer = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [label, field])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    /// A click on the label types into the field, as anywhere in a text field would.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }
}
