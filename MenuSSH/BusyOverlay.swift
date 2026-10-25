import AppKit

/// What covers the window while a statement runs off the main thread: it takes every click, so
/// nothing else uses the connection meanwhile, and after a moment (so quick statements don't
/// flash it) shows a spinner, what's happening, how far it's got and, for statements that can be
/// stopped, a Cancel button.
final class BusyOverlay: NSView {
    private let panel = NSVisualEffectView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()
    private var reveal: DispatchWorkItem?
    private var started = Date()
    private var timer: Timer?

    /// Called by Cancel (or Esc); nil when what's running can't be stopped.
    var onCancel: (() -> Void)? {
        didSet { cancelButton.isHidden = onCancel == nil }
    }

    /// How long it waits before showing itself.
    static let delay: TimeInterval = 0.25

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        wantsLayer = true

        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.alphaValue = 0

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .center
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.isHidden = true

        let stack = NSStackView(views: [spinner, titleLabel, detailLabel, cancelButton])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 26, bottom: 16, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        addSubview(panel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            panel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var isShowing: Bool { !isHidden }

    /// Covers the window at once, and shows `title` after a moment.
    func show(_ title: String) {
        titleLabel.stringValue = title
        cancelButton.title = tr("取消", "Cancel")
        guard isHidden else { return }   // already up: just the new title
        isHidden = false
        detailLabel.stringValue = ""
        detailLabel.isHidden = true
        started = Date()
        let reveal = DispatchWorkItem { [weak self] in
            guard let self, !self.isHidden else { return }
            self.spinner.startAnimation(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.panel.animator().alphaValue = 1
                self.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
            }
            // Seconds go by under the title, so a long statement visibly hasn't stuck.
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.showElapsed() }
        }
        self.reveal = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: reveal)
    }

    /// Says how far it's got, under the title: rows read, say.
    var detail: String = "" {
        didSet { showElapsed() }
    }

    private func showElapsed() {
        let seconds = Int(Date().timeIntervalSince(started))
        let time = seconds >= 1 ? tr("\(seconds) 秒", "\(seconds) s") : ""
        detailLabel.stringValue = [detail, time].filter { !$0.isEmpty }.joined(separator: " · ")
        detailLabel.isHidden = detailLabel.stringValue.isEmpty
    }

    func hide() {
        reveal?.cancel()
        reveal = nil
        timer?.invalidate()
        timer = nil
        spinner.stopAnimation(nil)
        panel.alphaValue = 0
        layer?.backgroundColor = nil
        detail = ""
        onCancel = nil
        isHidden = true
    }

    @objc func cancel(_ sender: Any?) {
        guard let onCancel else { return NSSound.beep() }
        self.onCancel = nil
        cancelButton.isHidden = true
        titleLabel.stringValue = tr("正在取消…", "Cancelling…")
        onCancel()
    }

    // Every click lands here (or on Cancel), not on what's underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}
