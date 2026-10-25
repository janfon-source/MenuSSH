import AppKit

/// One file or folder going up or down, waiting, under way, or finished.
final class TransferItem {
    enum Direction { case upload, download }
    enum State: Equatable { case waiting, running, done, failed(String), cancelled }

    let name: String
    let direction: Direction
    let connection: SSHConnection
    let commands: [String]
    /// Where it's going, shown under the name: a folder on the server or on this Mac.
    let destination: String
    /// Where a download lands, for Show in Finder.
    let localURL: URL?
    /// The folder on the server it changes, to show again when it's done.
    var refresh: String?
    /// Called on the main thread once it's finished, failed or been cancelled.
    var done: ((Error?) -> Void)?

    fileprivate(set) var state = State.waiting
    fileprivate(set) var progress: TransferProgress?
    fileprivate(set) var started: Date?
    fileprivate(set) var finished: Date?
    fileprivate var cancellation = Cancellation()

    init(name: String, direction: Direction, connection: SSHConnection, commands: [String], destination: String,
         localURL: URL? = nil, refresh: String? = nil, done: ((Error?) -> Void)? = nil) {
        self.name = name
        self.direction = direction
        self.connection = connection
        self.commands = commands
        self.destination = destination
        self.localURL = localURL
        self.refresh = refresh
        self.done = done
    }

    var isActive: Bool { state == .waiting || state == .running }
}

/// Runs transfers one after another, off the main thread, and says when any of them changes.
final class TransferQueue {
    private(set) var items: [TransferItem] = []
    /// The list changed (nil), or one item in it did.
    var onChange: ((TransferItem?) -> Void)?
    /// A transfer failed (not one that was cancelled).
    var onFailure: ((TransferItem, String) -> Void)?
    private let queue = DispatchQueue(label: "menussh.transfers")
    private(set) var running: TransferItem?

    var waitingCount: Int { items.filter { $0.state == .waiting }.count }
    var hasActive: Bool { items.contains(where: \.isActive) }

    func add(_ new: [TransferItem]) {
        guard !new.isEmpty else { return }
        items += new
        onChange?(nil)
        startNext()
    }

    func cancel(_ item: TransferItem) {
        switch item.state {
        case .waiting:
            item.state = .cancelled
            item.finished = Date()
            item.done?(SSHError.cancelled)
            onChange?(item)
        case .running:
            item.cancellation.cancel()
        default: break
        }
    }

    func cancelAll() {
        for item in items where item.state == .waiting { cancel(item) }
        if let running { cancel(running) }
    }

    /// Puts a failed or cancelled transfer back at the end of the queue.
    func retry(_ item: TransferItem) {
        guard !item.isActive else { return }
        item.state = .waiting
        item.progress = nil
        item.started = nil
        item.finished = nil
        item.cancellation = Cancellation()
        items.removeAll { $0 === item }
        items.append(item)
        onChange?(nil)
        startNext()
    }

    func clearFinished() {
        items.removeAll { !$0.isActive }
        onChange?(nil)
    }

    private func startNext() {
        guard running == nil, let item = items.first(where: { $0.state == .waiting }) else { return }
        running = item
        item.state = .running
        item.started = Date()
        onChange?(item)
        queue.async { [weak self] in
            var failure: Error?
            do {
                try item.connection.transfer(item.commands, item.cancellation) { progress in
                    DispatchQueue.main.async {
                        item.progress = progress
                        self?.onChange?(item)
                    }
                }
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                guard let self else { return }
                item.finished = Date()
                if let failure {
                    let message = failure.localizedDescription
                    item.state = message == SSHError.cancelled.message ? .cancelled : .failed(message)
                    if case .failed(let message) = item.state { self.onFailure?(item, message) }
                } else {
                    item.state = .done
                }
                self.running = nil
                item.done?(failure)
                self.onChange?(item)
                self.startNext()
            }
        }
    }
}

/// The list of transfers under the files: each with its direction, name, destination, progress
/// bar, and how it's going (percent, speed, time left; or done, failed, cancelled, waiting), with
/// a button to stop it, try it again, or show a download in the Finder.
final class TransfersView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let queue: TransferQueue
    var onHide: (() -> Void)?
    private let table = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var clearButton: NSButton!
    private var stopButton: NSButton!
    private var hideButton: NSButton!

    init(queue: TransferQueue) {
        self.queue = queue
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        clearButton = NSButton(title: "", target: self, action: #selector(clearFinished(_:)))
        stopButton = NSButton(title: "", target: self, action: #selector(stopAll(_:)))
        for button in [clearButton!, stopButton!] {
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        hideButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!, target: self,
                              action: #selector(hide(_:)))
        hideButton.isBordered = false
        hideButton.contentTintColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [titleLabel, spacer, stopButton, clearButton, hideButton])
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 2, right: 8)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transfer"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.style = .plain
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        header.setHuggingPriority(.required, for: .vertical)
        applyLanguage()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyLanguage() {
        clearButton.title = tr("清除已完成", "Clear Finished")
        stopButton.title = tr("全部停止", "Stop All")
        hideButton.toolTip = tr("收起傳輸清單", "Hide the Transfers")
        update(nil)
    }

    /// Redraws one row, or the whole list.
    func update(_ item: TransferItem?) {
        if let item, let row = queue.items.firstIndex(where: { $0 === item }), row < table.numberOfRows {
            table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        } else {
            table.reloadData()
            if let row = queue.items.firstIndex(where: \.isActive) { table.scrollRowToVisible(row) }
        }
        let active = queue.items.filter(\.isActive).count
        titleLabel.stringValue = tr("傳輸", "Transfers") + (active > 0 ? tr("（進行中 \(active) 項）", " (\(active) to go)") : "")
        stopButton.isEnabled = active > 0
        clearButton.isEnabled = queue.items.contains { !$0.isActive }
    }

    @objc private func clearFinished(_ sender: Any?) { queue.clearFinished() }
    @objc private func stopAll(_ sender: Any?) { queue.cancelAll() }
    @objc private func hide(_ sender: Any?) { onHide?() }

    func numberOfRows(in tableView: NSTableView) -> Int { queue.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = queue.items[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill",
                                              accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))!)
        icon.contentTintColor = item.direction == .upload ? .systemOrange : .systemBlue
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: detailText(item))
        detail.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = { if case .failed = item.state { return .systemRed } else { return .secondaryLabelColor } }()
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = detail.stringValue
        for label in [name, detail] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 100
        bar.widthAnchor.constraint(equalToConstant: 120).isActive = true
        switch item.state {
        case .running:
            if let progress = item.progress {
                bar.isIndeterminate = false
                bar.doubleValue = Double(progress.percent)
            } else {
                bar.isIndeterminate = true
                bar.startAnimation(nil)
            }
        case .done:
            bar.isIndeterminate = false
            bar.doubleValue = 100
        default:
            bar.isIndeterminate = false
            bar.doubleValue = 0
            bar.isHidden = item.state != .waiting
        }

        let button = NSButton(image: NSImage(), target: self, action: #selector(rowButton(_:)))
        button.isBordered = false
        button.tag = row
        button.contentTintColor = .secondaryLabelColor
        let symbol: String
        switch item.state {
        case .waiting, .running:
            symbol = "xmark.circle.fill"
            button.toolTip = tr("停止", "Stop")
        case .failed, .cancelled:
            symbol = "arrow.clockwise.circle.fill"
            button.toolTip = tr("再試一次", "Try Again")
        case .done:
            symbol = item.localURL != nil ? "magnifyingglass.circle.fill" : "checkmark.circle.fill"
            button.toolTip = item.localURL != nil ? tr("在 Finder 中顯示", "Show in Finder") : tr("完成", "Done")
            if item.localURL == nil { button.contentTintColor = .systemGreen }
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.toolTip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let row = NSStackView(views: [icon, text, bar, button])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        return row
    }

    private func detailText(_ item: TransferItem) -> String {
        let arrow = "→ " + item.destination
        switch item.state {
        case .waiting:
            return tr("排隊中", "Waiting") + " · " + arrow
        case .running:
            guard let p = item.progress else { return tr("開始中…", "Starting…") + " · " + arrow }
            // A folder goes a file at a time: say which.
            let file = p.file.isEmpty || p.file == item.name ? "" : p.file + " · "
            return file + "\(p.percent)% · \(p.transferred) · \(p.rate) · " + tr("剩餘 \(p.eta)", "\(p.eta) left")
        case .done:
            let seconds = max(0, Int((item.finished ?? Date()).timeIntervalSince(item.started ?? Date())))
            return tr("完成", "Done") + (item.progress.map { " · " + $0.transferred } ?? "")
                + " · " + tr("\(seconds) 秒", "\(seconds) s") + " · " + arrow
        case .failed(let message):
            return tr("失敗：", "Failed: ") + message.replacingOccurrences(of: "\n", with: " ")
        case .cancelled:
            return tr("已取消", "Cancelled") + " · " + arrow
        }
    }

    @objc private func rowButton(_ sender: NSButton) {
        guard sender.tag < queue.items.count else { return }
        let item = queue.items[sender.tag]
        switch item.state {
        case .waiting, .running: queue.cancel(item)
        case .failed, .cancelled: queue.retry(item)
        case .done: if let url = item.localURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
