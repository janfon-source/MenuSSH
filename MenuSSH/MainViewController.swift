import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// A server in the list on the left: a Host from ~/.ssh/config, or one typed into the search field.
struct HostItem: Equatable {
    var name: String
    var summary: String
    /// Typed in rather than from ~/.ssh/config; it can be taken off the list.
    var typed: Bool
}

/// The popover's content: the host menu at the top left picks a server, shown as an SSH session or
/// as its files beside this Mac's, to transfer, rename, delete and open.
final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                NSTextFieldDelegate, NSFilePromiseProviderDelegate {
    weak var popover: NSPopover?
    /// The window the content moves to while pinned, which can be dragged anywhere.
    weak var pinnedWindow: NSWindow?
    /// Called when the pin is switched on or off, to move the content between popover and window.
    var onPinChange: ((Bool) -> Void)?
    private var inPinnedWindow: Bool { pinnedWindow != nil && view.window === pinnedWindow }

    private enum Keys {
        static let size = "menussh.size"
        static let pinned = "menussh.pinned"
        static let typedHosts = "menussh.typedHosts"
        static let lastFolders = "menussh.lastFolders"
        static let showHidden = "menussh.showHidden"
    }

    /// What the right side shows for the server picked: an SSH session, or its files.
    enum Mode: Int { case ssh, sftp }
    /// SSH to begin with: the app starts on this Mac's terminal, with nothing connected.
    private(set) var mode = Mode.ssh {
        didSet { showMode() }
    }
    /// The SSH session for each server, kept running while others are showing.
    private var sessions: [String: TerminalSession] = [:]
    private var session: TerminalSession? { sessions[sessionKey(connection)] }
    /// This Mac's own shell, kept among the sessions under a key no server has.
    private static let localKey = "\u{0}local"
    private func sessionKey(_ connection: SSHConnection?) -> String { connection?.key ?? Self.localKey }
    /// Sessions connecting now, not to be started twice.
    private var startingKeys: Set<String> = []

    static let defaultSize = NSSize(width: 1000, height: 580)
    static let minSize = NSSize(width: 620, height: 360)

    // MARK: State

    private var hosts: [HostItem] = []
    private var connections: [String: SSHConnection] = [:]
    /// The server whose files are showing.
    private var connection: SSHConnection?
    /// The folder showing on it, as the server names it.
    private var folder: String?
    private var files: [RemoteFile] = []
    /// `files` without hidden ones (unless they're shown), sorted.
    private var shownFiles: [RemoteFile] = []
    private var showHidden = UserDefaults.standard.bool(forKey: Keys.showHidden)
    private var sortKey = "name"
    private var ascending = true

    /// Listing, renaming, deleting: one at a time, with the window covered meanwhile.
    private let work = DispatchQueue(label: "menussh.work")
    /// Uploads and downloads: one at a time too, but the window stays usable.
    private let transferQueue = TransferQueue()
    /// Synchronized browsing: a change of folder on either side is copied on the other.
    private var syncBrowsing = false {
        didSet { updateSyncButton() }
    }
    /// A change of folder being made to follow the other side, which mustn't be copied back.
    private var following = false
    /// Servers whose connection was closed (the SSH session ended, or Disconnect): SFTP is off for
    /// them until they're connected again.
    private var closedKeys: Set<String> = []
    /// Sessions being restarted, whose ending isn't a closing.
    private var restartingKeys: Set<String> = []
    /// The folders set in the connection settings for each server, read when it's picked.
    private var startFolders: [String: (remote: String?, local: String?)] = [:]

    /// Whether SFTP can be used: only with a server connected (not this Mac's own terminal).
    private var sftpAvailable: Bool { connection.map { !closedKeys.contains($0.key) } ?? false }

    /// Answers typed this connection that the user asked to remember, saved once it works.
    private var pendingPasswords: [String: [(account: String, password: String)]] = [:]
    /// Saved answers already given this connection; if ssh asks again, they were wrong.
    private var triedPasswords: Set<String> = []

    // MARK: Views

    private let fileTable = FileTable()
    /// The server showing, which drops down every host to connect to, and what can be done with it.
    private var hostButton: NSButton!
    /// The tabs: this Mac's first, then a server's for each one opened, by host name, in the order shown.
    private let tabStrip = NSStackView()
    private var tabHosts: [String] = []
    /// What each server's tab was showing when another was picked, to show again when it's back.
    private var tabModes: [String: Mode] = [:]
    private var tabFolders: [String: String] = [:]
    /// Servers connected in this window (and not closed since), for the dots in the host menu.
    private var openedKeys: Set<String> = []
    private let pathField = NSTextField()
    private let remoteHeading = NSTextField(labelWithString: "")
    private let localPane = LocalPane()
    private lazy var transfersView = TransfersView(queue: transferQueue)
    /// The files: this Mac's beside the server's, over the transfers.
    private let fileSplit = NSSplitView()
    private let dualSplit = NSSplitView()
    private var transfersButton: NSButton!
    private var transfersHeight: CGFloat = 150
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let transferLabel = NSTextField(labelWithString: "")
    private let transferBar = NSProgressIndicator()
    private var transferStop: NSButton!
    private var pinButton: NSButton!
    private var hiddenButton: NSButton!
    private var syncButton: NSButton!
    /// Up, home, folders and refresh, on the bar over the server's files.
    private var remoteBarButtons: [NSButton] = []
    private var reconnectButton: NSButton!
    private let modeControl = NSSegmentedControl()
    /// Toolbar buttons that need a server's files showing; hidden in SSH mode.
    private var serverButtons: [NSButton] = []
    /// The dividers among them, hidden with them.
    private var fileDividers: [NSView] = []
    private var externalTerminalButton: NSButton!
    private var filePane: NSView!
    /// Holds the files and the terminals, one showing at a time.
    private let rightPane = NSView()
    private let busyOverlay = BusyOverlay()
    private var localized: [(view: NSView, zh: String, en: String)] = []
    private var escapeMonitor: Any?
    private var sizeAtDragStart = NSSize.zero

    /// False while there's no menu bar icon for the popover to hang from, so the window stays pinned.
    var canUnpin = true

    var pinned = UserDefaults.standard.bool(forKey: Keys.pinned) {
        didSet {
            UserDefaults.standard.set(pinned, forKey: Keys.pinned)
            applyPopoverBehavior()
            updatePinButton()
            onPinChange?(pinned)
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: savedSize))

        pinButton = toolButton("pin", "釘選：視窗固定顯示，可拖曳上緣或空白處移動（按 Esc 仍可隱藏）；解除後回到選單列下方原本的大小",
                               "Pin: keep the window open and drag it anywhere by its top edge (Esc still hides it); unpinning puts it back under the menu bar at its earlier size",
                               #selector(togglePin(_:)))
        hiddenButton = toolButton("eye.slash", "顯示或隱藏以 . 開頭的隱藏檔（⇧⌘.）", "Show or Hide Hidden Files, Whose Names Start with . (⇧⌘.)",
                                  #selector(toggleHidden(_:)))
        hostButton = toolButton("server.rack", "選擇連線", "Choose a Connection", #selector(showHostMenu(_:)))
        externalTerminalButton = toolButton("macwindow.on.rectangle", "在外部的終端機 App 開啟 SSH 連線（⌘T）",
                                            "Open an SSH Session in the Terminal App (⌘T)", #selector(openTerminalHere(_:)))
        reconnectButton = toolButton("arrow.triangle.2.circlepath", "重新連線：結束這個 SSH 連線，再開一個新的（⇧⌘R）",
                                     "Reconnect: end this SSH session and start a new one (⇧⌘R)", #selector(reconnect(_:)))
        modeControl.segmentStyle = .rounded
        modeControl.segmentCount = 2
        modeControl.trackingMode = .selectOne
        modeControl.setLabel("SSH", forSegment: 0)
        modeControl.setLabel("SFTP", forSegment: 1)
        for i in 0..<2 { modeControl.setWidth(54, forSegment: i) }
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.selectedSegment = mode.rawValue
        syncButton = toolButton("lock.open", "同步瀏覽：鎖定後，在本機或遠端切換資料夾（進入、回上一層、跳到別處），另一邊會跟著切換到對應的資料夾（⌥⌘Y）",
                                "Synchronized Browsing: once locked, changing folders on this Mac or the server (going in, up, or anywhere) changes the other side to the matching folder (⌥⌘Y)",
                                #selector(toggleSyncBrowsing(_:)))
        serverButtons = [
            toolButton("square.and.arrow.up", "上傳：把左邊本機選取的項目傳到右邊的遠端資料夾（⌘U）；也可以直接拖曳過去",
                       "Upload: the items selected on this Mac (left) to the server’s folder (right) (⌘U); or drag them across", #selector(upload(_:))),
            toolButton("square.and.arrow.down", "下載：把右邊遠端選取的項目傳到左邊的本機資料夾（⌘D）；也可以直接拖曳過去",
                       "Download: the items selected on the server (right) to the folder on this Mac (left) (⌘D); or drag them across", #selector(download(_:))),
            toolButton("folder.badge.plus", "新增資料夾（⇧⌘N）", "New Folder (⇧⌘N)", #selector(newFolder(_:))),
            toolButton("trash", "刪除選取的項目（⌘⌫）", "Delete the Selected Items (⌘⌫)", #selector(deleteFiles(_:))),
            hiddenButton,
            syncButton,
        ]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        fileDividers = [divider()]
        var items: [NSView] = [hostButton, divider(), modeControl, divider(), externalTerminalButton, reconnectButton]
        items.append(fileDividers[0])
        items += serverButtons.map { $0 as NSView }
        items.append(spacer)
        items.append(pinButton)
        items.append(toolButton("ellipsis.circle", "更多", "More", #selector(showMoreMenu(_:))))
        let toolbar = NSStackView(views: items)
        toolbar.spacing = 2
        // The terminal and the files below reach for all the height there is; this keeps the
        // toolbar from being squeezed out.
        toolbar.heightAnchor.constraint(equalToConstant: 28).isActive = true

        pathField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathField.lineBreakMode = .byTruncatingHead
        pathField.usesSingleLineMode = true
        pathField.heightAnchor.constraint(equalToConstant: 22).isActive = true
        pathField.cell?.isScrollable = true
        pathField.delegate = self
        pathField.target = self
        pathField.action = #selector(goToTypedPath(_:))
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabStrip.spacing = 4
        tabStrip.setHuggingPriority(.required, for: .vertical)
        tabStrip.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let header = NSStackView(views: [toolbar, tabStrip])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)

        filePane = makeFilePane()
        filePane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(filePane)
        pin(filePane, in: rightPane)

        let footer = makeFooter()
        let topLine = NSBox(), bottomLine = NSBox()
        topLine.boxType = .separator
        bottomLine.boxType = .separator
        let column = NSStackView(views: [header, topLine, rightPane, bottomLine, footer])
        column.orientation = .vertical
        column.distribution = .fill
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            toolbar.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -20),
            tabStrip.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -20),
            rightPane.widthAnchor.constraint(equalTo: column.widthAnchor),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        // The header and footer keep their own height; the lists take the rest. Split views ask to
        // keep their panes' sizes at priority 250, so the body reaches for all the height above that.
        header.setHuggingPriority(.required, for: .vertical)
        header.setClippingResistancePriority(.required, for: .vertical)
        footer.setHuggingPriority(.required, for: .vertical)
        let fill = rightPane.heightAnchor.constraint(equalToConstant: 10_000)
        fill.priority = .init(300)
        fill.isActive = true

        busyOverlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(busyOverlay)
        NSLayoutConstraint.activate([
            busyOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            busyOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            busyOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            busyOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        preferredContentSize = root.frame.size
        NotificationCenter.default.addObserver(forName: Language.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyLanguage()
        }
        installEscapeMonitor()
        updatePinButton()
        reloadHosts()
        applyLanguage()
        // This Mac and the server get half each, once the window has its size.
        DispatchQueue.main.async { self.dualSplit.setPosition(self.dualSplit.bounds.width / 2, ofDividerAt: 0) }
        rebuildTabs()
        showMode()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.uploadEditedFiles() }
    }

    /// Fills `container` with `view`.
    private func pin(_ view: NSView, in container: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Hosts menu and mode

    /// Where a server's files start: the folder set for it, or else the last one seen there. One
    /// under the home folder (~/site) is given as a path from it, where sftp starts.
    private func remoteStart(for connection: SSHConnection) -> String? {
        // A tab picked again: where its files were.
        if let name = hostName(of: connection), let saved = tabFolders[name] { return saved }
        guard let set = startFolders[connection.key]?.remote else { return lastFolders[connection.key] }
        if set == "~" { return nil }
        return set.hasPrefix("~/") ? String(set.dropFirst(2)) : set
    }

    /// The connection to a server was closed: its SSH session ended (signed out, or dropped), or
    /// it was stopped. The shared connection stops taking anything new, SFTP is off for the server,
    /// and the window goes back to this Mac's own terminal. Choosing the server again reconnects.
    private func connectionClosed(_ connection: SSHConnection) {
        closedKeys.insert(connection.key)
        openedKeys.remove(connection.key)
        work.async { connection.stop() }
        for item in transferQueue.items where item.connection === connection && item.state == .waiting { transferQueue.cancel(item) }
        if connection === self.connection {
            showLocal()
            statusLabel.stringValue = tr("已中斷與 \(connection.destination) 的連線，回到本機終端機。從連線選單再選一次可重新連線。",
                                         "Disconnected from \(connection.destination); back to this Mac’s terminal. Choose it from the connection menu to connect again.")
        }
        if let name = hostName(of: connection) {
            tabHosts.removeAll { $0 == name }
            tabModes[name] = nil
            tabFolders[name] = nil
        }
        rebuildTabs()
        updateServerUI()
    }

    private func connectionOpened(_ connection: SSHConnection) {
        // Just connected (not each folder listed since): this Mac's side goes to the folder set for it.
        let fresh = !openedKeys.contains(connection.key)
        if fresh { goToLocalStart(for: connection) }
        openedKeys.insert(connection.key)
        closedKeys.remove(connection.key)
        updateServerUI()
    }

    /// This Mac's side of SFTP goes to the folder set for the server in the connection settings, if any.
    private func goToLocalStart(for connection: SSHConnection) {
        guard connection === self.connection, let local = startFolders[connection.key]?.local else { return }
        let url = URL(fileURLWithPath: (local as NSString).expandingTildeInPath)
        guard url.standardizedFileURL != localPane.folder.standardizedFileURL else { return }
        if !localPane.go(to: url, following: true) {
            statusLabel.stringValue = tr("連線設定中的本機資料夾「\(local)」不存在", "The folder on this Mac set for this connection, “\(local)”, isn’t there")
        }
    }

    /// Stops the connection to the server showing: its SSH session ends, which closes it.
    @objc func stopConnection(_ sender: Any?) {
        guard let connection else { return }
        close(connection)
    }

    /// Closes a server's connection, and so its tab.
    private func close(_ connection: SSHConnection) {
        if let session = sessions[connection.key], session.isRunning {
            session.close()   // its ending closes the connection
        } else {
            connectionClosed(connection)
        }
    }

    // MARK: - Tabs

    private func hostName(of connection: SSHConnection) -> String? {
        connections.first { $0.value === connection }?.key
    }

    /// What the server showing was showing, for when its tab is picked again.
    private func saveTabState() {
        guard let connection, let name = hostName(of: connection) else { return }
        tabModes[name] = mode
        tabFolders[name] = folder
    }

    private func rebuildTabs() {
        for view in tabStrip.arrangedSubviews { view.removeFromSuperview() }
        tabStrip.addArrangedSubview(localTab())
        for (index, name) in tabHosts.enumerated() { tabStrip.addArrangedSubview(serverTab(index, name)) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        tabStrip.addArrangedSubview(spacer)
    }

    private func tabTitle(_ text: String, active: Bool) -> NSTextField {
        // A label, not a button, so the tab itself takes the mouse: a click picks it, a drag moves it.
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
        title.textColor = active ? .labelColor : .secondaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        return title
    }

    /// This Mac's tab: always first, and it can't be closed or moved.
    private func localTab() -> NSView {
        let active = connection == nil
        let chip = TabChip(views: [tabTitle(tr("本機", "This Mac"), active: active)], active: active, movable: false)
        chip.toolTip = tr("這台 Mac 的終端機", "This Mac’s terminal")
        chip.onSelect = { [weak self] in self?.showLocal() }
        return chip
    }

    private func serverTab(_ index: Int, _ name: String) -> NSView {
        let connection = connections[name]
        let active = connection != nil && connection === self.connection
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: tr("關閉", "Close"))!
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))!, target: self, action: #selector(closeTab(_:)))
        close.isBordered = false
        close.tag = index
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = tr("關閉標籤頁，中斷這個連線", "Close the Tab, Ending This Connection")
        close.setContentHuggingPriority(.required, for: .horizontal)
        let chip = TabChip(views: [tabTitle(name, active: active), close], active: active)
        chip.toolTip = (hosts.first { $0.name == name }?.summary ?? name) + tr("（拖曳可調整順序）", " (drag to reorder)")
        chip.onSelect = { [weak self] in
            guard let self, let host = self.hosts.first(where: { $0.name == name }) else { return }
            self.browse(host: host)
        }
        chip.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        return chip
    }

    @objc private func closeTab(_ sender: NSButton) {
        guard tabHosts.indices.contains(sender.tag), let connection = connections[tabHosts[sender.tag]] else { return }
        close(connection)
    }

    private func moveTab(from: Int, to: Int) {
        guard tabHosts.indices.contains(from), tabHosts.indices.contains(to), from != to else { return rebuildTabs() }
        tabHosts.insert(tabHosts.remove(at: from), at: to)
        rebuildTabs()
    }

    /// ⌃Tab and ⌃⇧Tab: the next tab along, or the one before, going round.
    @objc func nextTab(_ sender: Any?) { stepTab(1) }
    @objc func previousTab(_ sender: Any?) { stepTab(-1) }

    private func stepTab(_ step: Int) {
        let all: [String?] = [nil] + tabHosts.map { Optional($0) }
        let current = connection.flatMap { hostName(of: $0) }
        let index = all.firstIndex { $0 == current } ?? 0
        let next = all[(index + step + all.count) % all.count]
        if let next, let host = hosts.first(where: { $0.name == next }) { browse(host: host) } else if next == nil { showLocal() }
    }

    /// This Mac's own terminal, with no server: what the window shows when nothing is connected.
    @objc private func showLocal() {
        if connection != nil {
            saveTabState()
            stopSyncBrowsing(nil)
            connection = nil
            folder = nil
            files = []
            reloadFiles()
        }
        mode = .ssh
        rebuildTabs()
    }

    /// The connection button's menu: every host, the connected ones marked, then a host typed in,
    /// the settings, and what can be done with the one showing. Built each time it opens.
    @objc private func showHostMenu(_ sender: NSButton) {
        let menu = NSMenu()
        buildHostMenu(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func buildHostMenu(_ menu: NSMenu) {
        func add(_ title: String, _ action: Selector, _ object: Any? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            return item
        }
        add(tr("本機（這台 Mac）", "This Mac"), #selector(showLocal)).state = connection == nil ? .on : .off
        func header(_ title: String) {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        let configured = hosts.filter { !$0.typed }, typed = hosts.filter(\.typed)
        for (title, group) in [("~/.ssh/config", configured), (tr("自行輸入", "Typed In"), typed)] where !group.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            header(title)
            for host in group {
                let item = add(host.name, #selector(pickHostFromMenu(_:)), host.name)
                item.toolTip = host.summary
                item.indentationLevel = 1
                let current = connections[host.name].map { $0 === connection } == true
                item.state = current ? .on : .off
                // Connected: a green dot after the name.
                if let c = connections[host.name], openedKeys.contains(c.key) {
                    let title = NSMutableAttributedString(string: host.name + "  ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
                    title.append(NSAttributedString(string: "●", attributes: [.foregroundColor: NSColor.systemGreen,
                                                                               .font: NSFont.menuFont(ofSize: 9)]))
                    item.attributedTitle = title
                    item.setAccessibilityLabel(host.name + tr("，已連線", ", connected"))
                }
            }
        }
        if hosts.isEmpty { header(tr("~/.ssh/config 裡還沒有主機", "No hosts in ~/.ssh/config yet")) }
        menu.addItem(.separator())
        _ = add(tr("連線到其他主機…", "Connect to Another Host…"), #selector(connectToTypedHost(_:)))
        _ = add(tr("新增連線設定…", "Add a Connection…"), #selector(addHost(_:)))
        _ = add(tr("管理連線設定…", "Connection Settings…"), #selector(manageConnections(_:)))
        guard let connection, let host = hosts.first(where: { connections[$0.name] === connection }) else { return }
        menu.addItem(.separator())
        header(host.name)
        _ = add(tr("在\(TerminalApp.current.title)開啟 SSH 連線", "Open an SSH Session in \(TerminalApp.current.title)"), #selector(openTerminalHere(_:)))
        _ = add(tr("拷貝 ssh 指令", "Copy the ssh Command"), #selector(copySSHCommand(_:)))
        if Passwords.hasAny(for: connection.key) { _ = add(tr("忘記儲存的密碼", "Forget Saved Passwords"), #selector(forgetPasswords(_:))) }
        if host.typed { _ = add(tr("從清單移除", "Remove from the List"), #selector(removeTypedHost(_:))) }
        _ = add(tr("關閉標籤頁（中斷連線）", "Close the Tab (End the Connection)"), #selector(stopConnection(_:)))
    }

    @objc private func pickHostFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let host = hosts.first(where: { $0.name == name }) else { return }
        browse(host: host)
    }

    /// A server that isn't in ~/.ssh/config: user@host, or user@host:port. It's kept in the menu.
    @objc private func connectToTypedHost(_ sender: Any?) {
        guard let text = askForName(tr("連線到其他主機", "Connect to Another Host"),
                                    tr("輸入 user@host，或 user@host:port（不在 ~/.ssh/config 裡的主機）。要長期使用的話，可以用「新增連線設定」存起來。",
                                       "Type user@host, or user@host:port (a host not in ~/.ssh/config). To keep one for good, use Add a Connection."),
                                    initial: "", button: tr("連線", "Connect")) else { return }
        guard !text.contains(" ") else { return NSSound.beep() }
        if !typedHosts.contains(text) { typedHosts.append(text) }
        reloadHosts()
        if let host = hosts.first(where: { $0.name == text }) { browse(host: host) }
    }

    /// Whether a command from the menu bar or the keyboard is for the files on the left: when
    /// that list has the focus. Toolbar buttons and the server list's own menu are the server's.
    private func forLocal(_ sender: Any?) -> Bool {
        guard mode == .sftp, view.window?.firstResponder === localPane.table, !(sender is NSButton) else { return false }
        if let item = sender as? NSMenuItem, item.menu === fileTable.menu { return false }
        return true
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let chosen = Mode(rawValue: sender.selectedSegment) ?? .ssh
        if chosen == .sftp && !sftpAvailable { return sender.selectedSegment = mode.rawValue }
        mode = chosen
    }

    @objc func showSSH(_ sender: Any?) { mode = .ssh }
    @objc func showSFTP(_ sender: Any?) {
        guard sftpAvailable else { return NSSound.beep() }
        mode = .sftp
    }

    /// Shows the SSH session or the files of the server picked, starting either if needed.
    private func showMode() {
        modeControl.selectedSegment = mode.rawValue
        let ssh = mode == .ssh
        for button in serverButtons { button.isHidden = ssh }
        for divider in fileDividers { divider.isHidden = ssh }
        reconnectButton.isHidden = !ssh
        pathField.isHidden = ssh
        for session in sessions.values { session.view.isHidden = !ssh || session !== self.session }
        if ssh {
            showSession(for: connection)
        } else if let connection, folder == nil {
            // Just connected: the files start at the folder set for the server, and from then on
            // go their own way, apart from the shell's.
            load(remoteStart(for: connection), fallBackHome: true)
        }
        updateServerUI()
        focus(reloading: false)
    }

    // MARK: - SSH sessions

    /// Shows the server's SSH session (or with none, this Mac's terminal), starting it if it isn't
    /// running: a server's is connected again when it's chosen after it ended; this Mac's starts
    /// again with Return.
    private func showSession(for connection: SSHConnection?) {
        let key = sessionKey(connection)
        let session: TerminalSession
        if let existing = sessions[key] {
            session = existing
        } else {
            session = TerminalSession(connection: connection)
            session.view.translatesAutoresizingMaskIntoConstraints = false
            rightPane.addSubview(session.view)
            pin(session.view, in: rightPane)
            session.onChange = { [weak self, weak session] in
                if session === self?.session { self?.updateServerUI() }
            }
            session.onRestart = { [weak self, weak session] in
                guard let self, let session else { return }
                self.start(session)
            }
            session.onEnded = { [weak self, weak session] _ in
                guard let self, let session, let connection = session.connection else { return }
                if self.restartingKeys.remove(connection.key) == nil { self.connectionClosed(connection) }
            }
            sessions[key] = session
        }
        for other in sessions.values { other.view.isHidden = other !== session }
        if connection == nil ? !session.hasStarted : !session.isRunning { start(session) }
        view.window?.makeFirstResponder(session.view)
    }

    /// Connects (asking for a password here, or using the saved one) and signs in on the session's
    /// terminal, in the folder the files were last showing on that server.
    private func start(_ session: TerminalSession) {
        guard let connection = session.connection else { return session.start(folder: nil) }
        guard !startingKeys.contains(connection.key) else { return }
        startingKeys.insert(connection.key)
        // The folder the files are showing, or else the one set for the server, or the last one seen there.
        let folder = (connection === self.connection ? self.folder : nil) ?? startFolders[connection.key]?.remote ?? lastFolders[connection.key]
        triedPasswords = []
        pendingPasswords[connection.key] = nil
        let message = tr("正在連線到 \(connection.destination)…", "Connecting to \(connection.destination)…")
        perform(connection.isConnected ? nil : message, { try connection.connect($0) }) { [weak self] result in
            guard let self else { return }
            self.startingKeys.remove(connection.key)
            switch result {
            case .success:
                self.savePendingPasswords(for: connection)
                self.connectionOpened(connection)
                session.start(folder: folder)
            case .failure(let error):
                self.pendingPasswords[connection.key] = nil
                session.show(error: tr("無法連線到 \(connection.destination)", "Couldn’t connect to \(connection.destination)")
                             + "\n" + error.localizedDescription)
            }
            if session === self.session { self.view.window?.makeFirstResponder(session.view) }
        }
    }

    /// Ends the SSH session showing and starts a new one.
    @objc func reconnect(_ sender: Any?) {
        guard let session else { return }
        if session.isRunning {
            restartingKeys.insert(sessionKey(session.connection))
            session.close()
            // The hang-up ends it in a moment; start again once it has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.start(session) }
        } else {
            start(session)
        }
    }

    @objc func clearScrollback(_ sender: Any?) { session?.view.clearScrollback(sender) }

    @objc func biggerText(_ sender: Any?) { setFontSize(TerminalView.fontSize + 1) }
    @objc func smallerText(_ sender: Any?) { setFontSize(TerminalView.fontSize - 1) }
    @objc func actualSizeText(_ sender: Any?) { setFontSize(13) }

    private func setFontSize(_ size: CGFloat) {
        TerminalView.fontSize = size
        for session in sessions.values { session.view.updateFont() }
    }

    @objc func toggleOptionAsMeta(_ sender: Any?) { TerminalView.optionAsMeta.toggle() }

    /// SFTP mode: this Mac's files on the left, the server's on the right, the transfers below.
    private func makeFilePane() -> NSView {
        localPane.onUpload = { [weak self] urls in
            guard let self, let folder = self.folder else { return NSSound.beep() }
            self.upload(urls, to: folder)
        }
        localPane.onRemoteDrop = { [weak self] target in
            guard let self else { return }
            self.download(self.draggedFiles, to: target)
        }
        localPane.isRemoteDrag = { [weak self] info in info.draggingSource as? NSTableView === self?.fileTable }
        localPane.askName = { [weak self] title, message, initial, button in
            self?.askForName(title, message, initial: initial, button: button)
        }
        localPane.showError = { [weak self] title, error in self?.showError(title, error) }
        localPane.keepingOpen = { [weak self] body in self?.keepingPopoverOpen(body) ?? body() }
        localPane.onSelectionChange = { [weak self] in self?.updateServerUI() }
        localPane.onFolderChange = { [weak self] old, new in self?.localMoved(from: old, to: new) }
        localPane.showHidden = showHidden

        dualSplit.isVertical = true
        dualSplit.dividerStyle = .thin
        dualSplit.addArrangedSubview(localPane)
        dualSplit.addArrangedSubview(makeRemotePane())
        dualSplit.setHoldingPriority(.init(250), forSubviewAt: 0)
        dualSplit.setHoldingPriority(.init(250), forSubviewAt: 1)

        transferQueue.onChange = { [weak self] item in self?.transfersChanged(item) }
        transferQueue.onFailure = { [weak self] item, message in
            self?.statusLabel.stringValue = tr("「\(item.name)」傳輸失敗：", "“\(item.name)” failed: ") + message
        }
        transfersView.onHide = { [weak self] in self?.setTransfers(shown: false) }
        fileSplit.isVertical = false
        fileSplit.dividerStyle = .thin
        fileSplit.addArrangedSubview(dualSplit)
        fileSplit.addArrangedSubview(transfersView)
        fileSplit.setHoldingPriority(.init(240), forSubviewAt: 0)
        fileSplit.setHoldingPriority(.init(260), forSubviewAt: 1)
        transfersView.isHidden = true
        return fileSplit
    }

    /// The server's files, under a bar with its folder.
    private func makeRemotePane() -> NSView {
        FileList.addColumns(to: fileTable)
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.target = self
        fileTable.doubleAction = #selector(fileDoubleClicked(_:))
        // Files from the Finder or the list on the left upload; the promise types, so rows dragged
        // within the list can move into a folder.
        fileTable.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        fileTable.setDraggingSourceOperationMask(.copy, forLocal: false)
        fileTable.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        fileTable.onOpen = { [weak self] in self?.openSelected(nil) }
        fileTable.onDelete = { [weak self] in self?.deleteFiles(nil) }
        let menu = NSMenu()
        menu.delegate = self
        fileTable.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = fileTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        FileList.fitColumnsToWidth(fileTable)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isSelectable = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        remoteHeading.font = .systemFont(ofSize: 11, weight: .semibold)
        remoteHeading.textColor = .secondaryLabelColor
        remoteHeading.setContentHuggingPriority(.required, for: .horizontal)
        remoteHeading.lineBreakMode = .byTruncatingTail
        remoteBarButtons = [
            barButton("arrow.up", "上一層資料夾（⌘↑）", "Enclosing Folder (⌘↑)", #selector(goUp(_:))),
            barButton("house", "家目錄（⇧⌘H）", "Home Folder (⇧⌘H)", #selector(goHome(_:))),
            barButton("folder", "前往資料夾：上層資料夾、最近去過的資料夾，或輸入路徑（⇧⌘G）",
                      "Go to a Folder: the ones above, recent ones, or a path typed in (⇧⌘G)", #selector(showRemoteFolderMenu(_:))),
            barButton("arrow.clockwise", "重新整理（⌘R）", "Refresh (⌘R)", #selector(refresh(_:))),
        ]
        let bar = NSStackView(views: [remoteHeading, pathField] + remoteBarButtons)
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        bar.setHuggingPriority(.required, for: .vertical)
        let list = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(scroll)
        list.addSubview(emptyLabel)
        pin(scroll, in: list)
        let pane = NSStackView(views: [bar, list])
        pane.orientation = .vertical
        pane.spacing = 0
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalTo: pane.widthAnchor),
            list.widthAnchor.constraint(equalTo: pane.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -40),
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        return pane
    }

    // MARK: - Transfers

    /// Shows or hides the list of transfers under the files.
    private func setTransfers(shown: Bool) {
        guard transfersView.isHidden == shown else { return }
        if !shown { transfersHeight = max(transfersView.frame.height, 90) }
        transfersView.isHidden = !shown
        fileSplit.adjustSubviews()
        if shown { fileSplit.setPosition(fileSplit.bounds.height - transfersHeight, ofDividerAt: 0) }
        transfersButton.contentTintColor = shown ? .controlAccentColor : .secondaryLabelColor
    }

    @objc func toggleTransfers(_ sender: Any?) {
        setTransfers(shown: transfersView.isHidden)
    }

    private func transfersChanged(_ item: TransferItem?) {
        transfersView.update(item)
        if item == nil, transferQueue.hasActive, mode == .sftp { setTransfers(shown: true) }
        showTransfer()
    }

    private func makeFooter() -> NSStackView {
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        transferLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        transferLabel.textColor = .secondaryLabelColor
        transferLabel.lineBreakMode = .byTruncatingMiddle
        transferLabel.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        transferBar.style = .bar
        transferBar.controlSize = .small
        transferBar.minValue = 0
        transferBar.maxValue = 100
        transferBar.widthAnchor.constraint(equalToConstant: 110).isActive = true
        transferStop = smallButton("xmark.circle.fill", "停止傳輸（之後排隊的也一併取消）", "Stop the Transfer (and the ones waiting)",
                                   #selector(stopTransfers(_:)))
        transfersButton = smallButton("arrow.up.arrow.down.circle", "顯示或收起傳輸清單（⌥⌘L）", "Show or Hide the Transfers (⌥⌘L)",
                                      #selector(toggleTransfers(_:)))
        let grip = ResizeGrip()
        grip.onBegin = { [weak self] in self?.sizeAtDragStart = self?.view.frame.size ?? .zero }
        grip.onDrag = { [weak self] delta in
            guard let self else { return }
            // The popover stays centered under the menu bar icon, so its right edge moves half as
            // far as the width changes; doubling keeps the corner under the pointer.
            let factor: CGFloat = self.inPinnedWindow ? 1 : 2
            self.resize(to: NSSize(width: self.sizeAtDragStart.width + delta.width * factor,
                                   height: self.sizeAtDragStart.height + delta.height))
        }
        grip.onReset = { [weak self] in self?.resetSize(nil) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [statusLabel, spacer, transferLabel, transferBar, transferStop, transfersButton, grip])
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 6, right: 12)
        showTransfer()
        return footer
    }

    private func toolButton(_ symbol: String, _ zh: String, _ en: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        localized.append((button, zh, en))
        return button
    }

    /// A button on a pane's folder bar, as on the left side's.
    private func barButton(_ symbol: String, _ zh: String, _ en: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))!
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        localized.append((button, zh, en))
        return button
    }

    private func smallButton(_ symbol: String, _ zh: String, _ en: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))!
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        localized.append((button, zh, en))
        return button
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 9).isActive = true
        box.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return box
    }

    /// Relabels everything on screen; menus are built each time they open.
    private func applyLanguage() {
        for (view, zh, en) in localized {
            view.toolTip = tr(zh, en)
            view.setAccessibilityLabel(view.toolTip)
        }
        pathField.placeholderString = tr("路徑，按 Return 前往", "Path; press Return to go there")
        FileList.relabel(fileTable)
        localPane.applyLanguage()
        transfersView.applyLanguage()
        reloadHosts()
        updateServerUI()
    }

    func focus() { focus(reloading: true) }

    private func focus(reloading: Bool) {
        // The config may have changed since the window was last up.
        if reloading { reloadHosts() }
        let target: NSView = mode == .ssh ? (session?.view ?? view) : fileTable
        view.window?.makeFirstResponder(target)
    }

    // MARK: - Hosts

    private var typedHosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.typedHosts) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.typedHosts) }
    }

    /// Reads ~/.ssh/config again.
    private func reloadHosts() {
        let config = SSHConfig.hosts().map { HostItem(name: $0.alias, summary: $0.summary, typed: false) }
        hosts = config + typedHosts.filter { name in !config.contains { $0.name == name } }
            .map { HostItem(name: $0, summary: tr("自行輸入", "Typed in"), typed: true) }
        if hosts.isEmpty && connection == nil {
            showEmpty(tr("~/.ssh/config 裡還沒有主機。按左上角的連線按鈕，選「新增連線設定…」或「連線到其他主機…」。",
                         "There are no Hosts in ~/.ssh/config yet. Click the connection button at the top left and choose Add a Connection… or Connect to Another Host…."))
        }
    }

    private func connection(for host: HostItem) -> SSHConnection {
        if let existing = connections[host.name] { return existing }
        let connection = host.typed ? SSHConnection(typed: host.name) : SSHConnection(destination: host.name)
        connection.onPrompt = { [weak self, weak connection] prompt in
            guard let self, let connection else { return nil }
            return self.answer(prompt, for: connection)
        }
        connections[host.name] = connection
        return connection
    }

    @objc private func copySSHCommand(_ sender: Any?) {
        guard let connection else { return }
        let command = "ssh " + (connection.port.map { "-p \($0) " } ?? "") + connection.destination
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    @objc private func forgetPasswords(_ sender: Any?) {
        guard let connection else { return }
        Passwords.deleteAll(for: connection.key)
    }

    @objc private func removeTypedHost(_ sender: Any?) {
        guard let connection, let host = hosts.first(where: { connections[$0.name] === connection }), host.typed else { return }
        stopConnection(nil)
        typedHosts.removeAll { $0 == host.name }
        reloadHosts()
    }

    // MARK: - Connecting and asking

    /// Shows a host's files, starting in the folder last seen there.
    /// Shows a server: its tab if it has one, as it was left; else a new tab, connecting it.
    private func browse(host: HostItem) {
        let connection = connection(for: host)
        let switching = connection !== self.connection
        if switching { saveTabState() }
        self.connection = connection
        if switching {
            stopSyncBrowsing(tr("換了主機，已解除同步瀏覽", "Another host: synchronized browsing is off"), beep: false)
            let isNew = !tabHosts.contains(host.name)
            if isNew {
                tabHosts.append(host.name)
                // The folders set for it in the connection settings, read afresh for each new tab.
                startFolders[connection.key] = host.typed ? (nil, nil) : ConfigFile.startFolders(for: host.name)
                goToLocalStart(for: connection)
            }
            folder = nil
            files = []
            reloadFiles()
            rebuildTabs()
            // A tab comes back as it was; a new one keeps the mode showing.
            let wanted = isNew ? mode : tabModes[host.name] ?? .ssh
            if mode != wanted { return mode = wanted }   // showMode does the rest
        }
        if mode == .ssh {
            showSession(for: connection)
            updateServerUI()
        } else {
            for session in sessions.values { session.view.isHidden = true }
            load(folder ?? remoteStart(for: connection), fallBackHome: true)
        }
    }

    private var lastFolders: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Keys.lastFolders) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastFolders) }
    }

    /// Answers ssh while connecting: whether to trust a server seen for the first time, or a
    /// password, passphrase or code, which can be remembered.
    private func answer(_ prompt: AskpassPrompt, for connection: SSHConnection) -> String? {
        let alert = NSAlert()
        if prompt.isHostKey || prompt.style == "confirm" {
            alert.messageText = prompt.isHostKey ? tr("第一次連線到 \(connection.destination)", "Connecting to \(connection.destination) for the First Time")
                                                 : tr("SSH 需要確認", "SSH Asks for Confirmation")
            alert.informativeText = prompt.text + (prompt.isHostKey
                ? "\n\n" + tr("確認這是你要連的伺服器後再繼續；繼續後會記在 ~/.ssh/known_hosts，之後不再詢問。",
                              "Go on only if this is the server you mean to reach. It’s then recorded in ~/.ssh/known_hosts and not asked again.")
                : "")
            alert.addButton(withTitle: prompt.isHostKey ? tr("連線", "Connect") : tr("好", "OK"))
            alert.addButton(withTitle: tr("取消", "Cancel"))
            return keepingPopoverOpen({ alert.runModal() }) == .alertFirstButtonReturn ? (prompt.isHostKey ? "yes" : "") : nil
        }

        let account = Passwords.account(connection.key, prompt)
        if let saved = Passwords.password(for: account), !triedPasswords.contains(account) {
            triedPasswords.insert(account)
            return saved
        }
        let wrong = triedPasswords.contains(account)
        alert.messageText = prompt.isPassword ? tr("登入 \(connection.destination)", "Sign In to \(connection.destination)")
                                              : tr("SSH 需要輸入", "SSH Needs an Answer")
        alert.informativeText = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
            + (wrong ? "\n\n" + tr("先前儲存的密碼不對，請重新輸入。", "The saved password didn’t work; type it again.") : "")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
        let remember = NSButton(checkboxWithTitle: tr("記住（加密存在這台 Mac 上）", "Remember (encrypted, on this Mac)"), target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 280, height: 20)
        remember.state = .on
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        box.addSubview(field)
        box.addSubview(remember)
        alert.accessoryView = box
        alert.addButton(withTitle: tr("登入", "Sign In"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        guard keepingPopoverOpen({ alert.runModal() }) == .alertFirstButtonReturn else { return nil }
        if remember.state == .on {
            pendingPasswords[connection.key, default: []].append((account, field.stringValue))
        }
        return field.stringValue
    }

    /// The connection worked: keep the answers the user asked to remember.
    private func savePendingPasswords(for connection: SSHConnection) {
        for (account, password) in pendingPasswords[connection.key] ?? [] { Passwords.save(password, for: account) }
        pendingPasswords[connection.key] = nil
    }

    // MARK: - Folders

    /// Lists a folder on the server showing (nil for home) and shows it, selecting `select` by name.
    /// `then` is told whether it worked, and errors are left to it.
    private func load(_ path: String?, select: [String] = [], fallBackHome: Bool = false, quietly: Bool = false,
                      then: ((Bool) -> Void)? = nil) {
        guard let connection else { return }
        let connecting = !connection.isConnected
        triedPasswords = []
        pendingPasswords[connection.key] = nil
        let message = connecting ? tr("正在連線到 \(connection.destination)…", "Connecting to \(connection.destination)…")
                                 : tr("正在讀取資料夾…", "Reading the folder…")
        perform(quietly ? nil : message, { cancel in
            do {
                return try connection.list(path, cancel)
            } catch let error as SSHError where fallBackHome && path != nil && error.message != SSHError.cancelled.message && connection.isConnected {
                // The folder remembered from last time is gone: start at home instead.
                return try connection.list(nil, cancel)
            }
        }) { [weak self] result in
            guard let self, connection === self.connection else { return }
            switch result {
            case .success(let listing):
                self.savePendingPasswords(for: connection)
                self.connectionOpened(connection)
                let old = self.folder
                self.folder = listing.path
                self.files = listing.files
                self.lastFolders[connection.key] = listing.path
                self.remember(listing.path, for: connection)
                self.reloadFiles(select: select)
                if let old, old != listing.path { self.remoteMoved(from: old, to: listing.path) }
                then?(true)
            case .failure(let error):
                self.pendingPasswords[connection.key] = nil
                if let then { return then(false) }
                if self.folder == nil || connecting {
                    self.files = []
                    self.folder = nil
                    self.reloadFiles()
                    self.showEmpty(tr("無法連線到 \(connection.destination)", "Couldn’t connect to \(connection.destination)")
                                   + "\n\n" + error.localizedDescription)
                } else if (error as? SSHError)?.message != SSHError.cancelled.message {
                    self.showError(tr("無法開啟資料夾", "Couldn’t Open the Folder"), error)
                }
            }
        }
    }

    @objc func refresh(_ sender: Any?) {
        if forLocal(sender) { return localPane.refresh(sender) }
        guard connection != nil else { return reloadHosts() }
        load(folder, select: selectedFiles.map(\.name))
    }

    @objc func goUp(_ sender: Any?) {
        if forLocal(sender) { return localPane.goUp(sender) }
        guard let folder, folder != "/" else { return NSSound.beep() }
        load(SSHConnection.parent(of: folder), select: [(folder as NSString).lastPathComponent])
    }

    @objc func goHome(_ sender: Any?) {
        if forLocal(sender) { return localPane.goHome(sender) }
        load(nil)
    }

    @objc private func goToTypedPath(_ sender: Any?) {
        let text = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard connection != nil, !text.isEmpty else { return }
        load(text == "~" ? nil : text)
        view.window?.makeFirstResponder(fileTable)
    }

    // MARK: - Remote folder menu

    private static let recentFoldersKey = "menussh.recentFolders"

    /// The folders last visited on a server, newest first.
    private func recentFolders(for connection: SSHConnection) -> [String] {
        (UserDefaults.standard.dictionary(forKey: Self.recentFoldersKey) as? [String: [String]])?[connection.key] ?? []
    }

    private func remember(_ folder: String, for connection: SSHConnection) {
        var all = UserDefaults.standard.dictionary(forKey: Self.recentFoldersKey) as? [String: [String]] ?? [:]
        all[connection.key] = Array(([folder] + (all[connection.key] ?? []).filter { $0 != folder }).prefix(12))
        UserDefaults.standard.set(all, forKey: Self.recentFoldersKey)
    }

    /// The server's counterpart to choosing a folder on this Mac: the folders above this one, the
    /// ones visited lately, or a path typed in.
    @objc private func showRemoteFolderMenu(_ sender: NSButton) {
        guard let connection, let folder else { return }
        let menu = NSMenu()
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 16, height: 16)
        func add(_ title: String, _ path: String) {
            let item = menu.addItem(withTitle: title, action: #selector(pickRemoteFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.toolTip = path
            item.image = icon
            item.state = path == folder ? .on : .off
        }
        var path = folder
        add(path == "/" ? "/" : (path as NSString).lastPathComponent, path)
        while path != "/" {
            path = SSHConnection.parent(of: path)
            add(path == "/" ? "/" : (path as NSString).lastPathComponent, path)
        }
        let recent = recentFolders(for: connection).filter { $0 != folder }
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = menu.addItem(withTitle: tr("最近去過", "Recent Folders"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            for path in recent { add(path, path) }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("輸入路徑…", "Type a Path…"), action: #selector(goToFolder(_:)), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func pickRemoteFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        load(path)
    }

    // MARK: - Synchronized browsing

    @objc func toggleSyncBrowsing(_ sender: Any?) {
        guard !syncBrowsing else { return stopSyncBrowsing(nil) }
        guard let folder else { return NSSound.beep() }
        syncBrowsing = true
        statusLabel.stringValue = tr("同步瀏覽已鎖定：", "Synchronized browsing: ")
            + (localPane.folder.path as NSString).abbreviatingWithTildeInPath + " ⇄ " + folder
    }

    /// `reason`: why it had to stop, which is said with a beep; nil when the user turned it off.
    private func stopSyncBrowsing(_ reason: String?, beep: Bool = true) {
        guard syncBrowsing else { return }
        syncBrowsing = false
        statusLabel.stringValue = reason ?? tr("同步瀏覽已解除", "Synchronized browsing is off")
        if reason != nil && beep { NSSound.beep() }
    }

    private func updateSyncButton() {
        syncButton.image = NSImage(systemSymbolName: syncBrowsing ? "lock.fill" : "lock.open", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        syncButton.contentTintColor = syncBrowsing ? .controlAccentColor : .secondaryLabelColor
        remoteHeading.toolTip = syncBrowsing ? tr("同步瀏覽中", "Browsing in sync") : nil
        updateServerUI()
    }

    /// The folder on this Mac changed: the server's follows.
    private func localMoved(from old: URL, to new: URL) {
        guard syncBrowsing, !following, mode == .sftp, let folder else { return }
        guard let target = FileList.apply(FileList.move(from: old.path, to: new.path), to: folder) else {
            return stopSyncBrowsing(tr("遠端沒有對應的上層資料夾，已解除同步瀏覽。", "The server has no matching folder above; synchronized browsing is off."))
        }
        following = true
        load(target, quietly: true) { [weak self] ok in
            self?.following = false
            if !ok {
                self?.stopSyncBrowsing(tr("遠端沒有對應的資料夾「\(target)」，已解除同步瀏覽。",
                                          "The server has no folder “\(target)” to match; synchronized browsing is off."))
            }
        }
    }

    /// The folder on the server changed: this Mac's follows.
    private func remoteMoved(from old: String, to new: String) {
        guard syncBrowsing, !following else { return }
        guard let target = FileList.apply(FileList.move(from: old, to: new), to: localPane.folder.path),
              localPane.go(to: URL(fileURLWithPath: target), following: true) else {
            let path = FileList.apply(FileList.move(from: old, to: new), to: localPane.folder.path) ?? "/"
            return stopSyncBrowsing(tr("本機沒有對應的資料夾「\((path as NSString).abbreviatingWithTildeInPath)」，已解除同步瀏覽。",
                                       "This Mac has no folder “\((path as NSString).abbreviatingWithTildeInPath)” to match; synchronized browsing is off."))
        }
    }

    @objc func goToFolder(_ sender: Any?) {
        view.window?.makeFirstResponder(pathField)
    }

    @objc func toggleHidden(_ sender: Any?) {
        showHidden.toggle()
        UserDefaults.standard.set(showHidden, forKey: Keys.showHidden)
        localPane.showHidden = showHidden
        reloadFiles(select: selectedFiles.map(\.name))
    }

    private var selectedFiles: [RemoteFile] {
        fileTable.selectedRowIndexes.filter { $0 < shownFiles.count }.map { shownFiles[$0] }
    }

    /// Right-click acts on the row clicked, and on the whole selection if that row is in it.
    private var actedOnFiles: [RemoteFile] {
        let row = fileTable.clickedRow
        guard row >= 0, row < shownFiles.count else { return selectedFiles }
        return fileTable.selectedRowIndexes.contains(row) ? selectedFiles : [shownFiles[row]]
    }

    private func reloadFiles(select: [String] = []) {
        shownFiles = FileList.sorted(files, key: sortKey, ascending: ascending, showHidden: showHidden)
        fileTable.reloadData()
        let rows = IndexSet(select.compactMap { name in shownFiles.firstIndex { $0.name == name } })
        fileTable.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { fileTable.scrollRowToVisible(first) }
        updateServerUI()
    }

    private func updateServerUI() {
        modeControl.setEnabled(sftpAvailable, forSegment: 1)
        modeControl.setToolTip(sftpAvailable ? tr("SFTP：本機與遠端的檔案（⌘2）", "SFTP: files on this Mac and the server (⌘2)")
                                             : tr("連線已關閉，重新連線後才能使用 SFTP", "The connection is closed; SFTP comes back once connected again"),
                               forSegment: 1)
        let on = connection != nil && folder != nil
        for button in serverButtons + remoteBarButtons { button.isEnabled = on }
        hiddenButton.image = NSImage(systemSymbolName: showHidden ? "eye" : "eye.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        hiddenButton.contentTintColor = showHidden ? .controlAccentColor : .secondaryLabelColor
        let connected = connection.map { openedKeys.contains($0.key) } ?? false
        hostButton.toolTip = connection.map {
            tr("連線：\($0.destination)\(connected ? "（已連線）" : "")。按一下選擇其他主機或管理連線",
               "Connection: \($0.destination)\(connected ? " (connected)" : ""). Click to choose another host or manage connections")
        } ?? tr("本機終端機。按一下選擇要連線的主機", "This Mac’s terminal. Click to choose a host to connect to")
        hostButton.setAccessibilityLabel(hostButton.toolTip)
        hostButton.contentTintColor = connected ? .controlAccentColor : .secondaryLabelColor
        pathField.stringValue = folder ?? ""
        pathField.isEnabled = on
        remoteHeading.stringValue = (syncBrowsing ? "🔒 " : "") + (connection.map { tr("遠端", "Server") + " · " + $0.destination } ?? tr("遠端", "Server"))
        externalTerminalButton.isEnabled = connection != nil
        reconnectButton.isEnabled = session?.hasStarted == true
        filePane.isHidden = mode == .ssh
        if mode == .ssh {
            let session = self.session
            // The server's name (or This Mac) first, now that the toolbar shows only an icon for
            // it; then the title the shell gives, usually user@host:folder.
            let name = connection?.destination ?? tr("本機", "This Mac")
            let title = name + " · " + (session?.title.isEmpty == false ? session!.title + " · " : "")
            let size = session.map { "\($0.emulator.cols)×\($0.emulator.rows)" } ?? ""
            if session?.isRunning == true {
                statusLabel.stringValue = title + (connection == nil ? size : tr("SSH 已連線 · ", "SSH connected · ") + size)
            } else if !statusLabel.stringValue.hasPrefix(tr("已中斷", "Disconnected")) {
                statusLabel.stringValue = name + " · " + (connection == nil ? tr("已結束", "Ended") : tr("SSH 未連線", "SSH not connected"))
            }
            return
        }
        if on {
            emptyLabel.isHidden = !shownFiles.isEmpty
            let hidden = files.count - shownFiles.count
            emptyLabel.stringValue = tr("這個資料夾是空的。", "This folder is empty.")
                + (hidden > 0 ? "\n" + tr("（有 \(hidden) 個隱藏檔，按 👁 顯示）", "(\(hidden) hidden; click 👁 to show them)") : "")
            let local = localPane.selected.count
            statusLabel.stringValue = tr("遠端 \(shownFiles.count) 個項目", "Server: \(shownFiles.count) items")
                + (hidden > 0 ? tr("，另有 \(hidden) 個隱藏", ", \(hidden) hidden") : "")
                + (fileTable.numberOfSelectedRows > 0 ? tr("，選取 \(fileTable.numberOfSelectedRows) 個", ", \(fileTable.numberOfSelectedRows) selected") : "")
                + (local > 0 ? tr(" · 本機選取 \(local) 個", " · This Mac: \(local) selected") : "")
        } else if connection == nil {
            showEmpty(hosts.isEmpty ? emptyLabel.stringValue : tr("從左上角的主機選單選一台主機：SSH 模式直接登入，SFTP 模式瀏覽它的檔案。",
                                                                    "Choose a host from the menu at the top left: SSH mode signs in to it, SFTP mode browses its files."))
            statusLabel.stringValue = tr("\(hosts.count) 台主機", "\(hosts.count) hosts")
        }
    }

    private func showEmpty(_ text: String) {
        emptyLabel.stringValue = text
        emptyLabel.isHidden = false
    }

    // MARK: - Opening

    @objc private func fileDoubleClicked(_ sender: Any?) {
        guard fileTable.clickedRow >= 0 else { return }
        openSelected(sender)
    }

    /// Opens what's selected: a folder (the first, if several) is shown; files are downloaded and
    /// opened in their apps, and changes saved there go back to the server.
    @objc func openSelected(_ sender: Any?) {
        if forLocal(sender) { return localPane.openSelected(sender) }
        let chosen = actedOnFiles
        if let folder = chosen.first(where: \.isFolder) { return load(folder.path) }
        let links = chosen.filter { $0.kind == .link }
        if let link = links.first, let connection {
            // A link may lead to a folder or a file; cd tells.
            perform(tr("正在讀取…", "Reading…"), { cancel in connection.isFolder(link.path, cancel) }) { [weak self] result in
                if case .success(true) = result { self?.load(link.path) } else { self?.edit(chosen) }
            }
            return
        }
        edit(chosen)
    }

    /// A file opened from the server: where its copy is on this Mac, and when that was last saved.
    private struct EditedFile {
        let connection: SSHConnection
        let remotePath: String
        var modified: Date
    }
    private var editedFiles: [URL: EditedFile] = [:]

    private static var editFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MenuSSH/Open", isDirectory: true)
    }

    private func edit(_ chosen: [RemoteFile]) {
        guard let connection, !chosen.isEmpty else { return }
        let files = chosen.filter { $0.kind == .file || $0.kind == .link }
        guard !files.isEmpty else { return NSSound.beep() }
        transferQueue.add(files.map { file in
            // Each in a folder of its own, so files with the same name from different places don't meet.
            let url = Self.editFolder.appendingPathComponent(UUID().uuidString.prefix(8) + "/" + file.name)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return TransferItem(name: file.name, direction: .download, connection: connection,
                                commands: ["get " + SSHConnection.quote(file.path) + " " + SSHConnection.quote(url.path)],
                                destination: tr("開啟", "Open")) { [weak self] error in
                guard let self, error == nil else { return }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                self.editedFiles[url] = EditedFile(connection: connection, remotePath: file.path, modified: modified)
                NSWorkspace.shared.open(url)
                self.statusLabel.stringValue = tr("在其他 App 儲存的修改會自動上傳回伺服器。", "Changes saved in the other app are uploaded back to the server.")
            }
        })
    }

    /// Every couple of seconds: files opened from the server and saved since go back up.
    private func uploadEditedFiles() {
        for (url, edited) in editedFiles {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                editedFiles[url] = nil   // the copy is gone
                continue
            }
            guard modified > edited.modified else { continue }
            editedFiles[url]?.modified = modified
            let name = url.lastPathComponent
            transferQueue.add([TransferItem(name: name, direction: .upload, connection: edited.connection,
                                            commands: ["put " + SSHConnection.quote(url.path) + " " + SSHConnection.quote(edited.remotePath)],
                                            destination: edited.connection.destination + ":" + SSHConnection.parent(of: edited.remotePath),
                                            refresh: SSHConnection.parent(of: edited.remotePath)) { [weak self] error in
                if error == nil { self?.statusLabel.stringValue = tr("已上傳 \(name) 的修改", "Uploaded the changes to \(name)") }
            }])
        }
    }

    // MARK: - Terminal

    @objc func openTerminalHere(_ sender: Any?) {
        guard let connection else { return }
        let folder = actedOnFiles.count == 1 && actedOnFiles[0].isFolder && sender is NSMenuItem ? actedOnFiles[0].path : self.folder
        openTerminal(connection, folder: folder)
    }

    func openTerminal(_ connection: SSHConnection, folder: String?) {
        do {
            try TerminalApp.current.open(connection, folder: folder)
            if !inPinnedWindow { popover?.performClose(nil) }
        } catch {
            showError(tr("無法開啟終端機", "Couldn’t Open the Terminal"), error)
        }
    }

    // MARK: - Uploading and downloading

    /// The footer's summary: the transfer under way, how far it's got, and how many wait.
    private func showTransfer() {
        let running = transferQueue.running
        transferBar.isHidden = running == nil
        transferStop.isHidden = running == nil
        transferLabel.isHidden = running == nil
        transfersButton.isHidden = transferQueue.items.isEmpty
        guard let running else { return }
        var text = (running.direction == .upload ? "↑ " : "↓ ") + running.name
        if let progress = running.progress {
            text += " · \(progress.percent)% · \(progress.rate)"
            transferBar.isIndeterminate = false
            transferBar.doubleValue = Double(progress.percent)
        } else {
            transferBar.isIndeterminate = true
            transferBar.startAnimation(nil)
        }
        let waiting = transferQueue.waitingCount
        if waiting > 0 { text += tr("（還有 \(waiting) 項排隊）", " (\(waiting) waiting)") }
        transferLabel.stringValue = text
    }

    @objc func stopTransfers(_ sender: Any?) {
        transferQueue.cancelAll()
    }

    /// The toolbar's upload: what's selected on the left, or else files chosen in a panel.
    @objc func upload(_ sender: Any?) {
        guard let folder else { return }
        if mode == .sftp, !localPane.selected.isEmpty {
            return upload(localPane.selected.map { URL(fileURLWithPath: $0.path) }, to: folder)
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = localPane.folder
        panel.prompt = tr("上傳", "Upload")
        panel.message = tr("上傳到 \(connection?.destination ?? ""):\(folder)", "Upload to \(connection?.destination ?? ""):\(folder)")
        guard keepingPopoverOpen({ panel.runModal() }) == .OK else { return }
        upload(panel.urls, to: folder)
    }

    /// Uploads files and folders from this Mac into a folder on the server, one transfer each,
    /// asking first before replacing what's there (when it's the folder showing, whose names are known).
    private func upload(_ urls: [URL], to remoteFolder: String) {
        guard let connection, !urls.isEmpty else { return }
        var urls = urls
        if remoteFolder == folder {
            let clashes = urls.filter { url in files.contains { $0.name == url.lastPathComponent } }
            if !clashes.isEmpty {
                let alert = NSAlert()
                alert.messageText = tr("要取代伺服器上同名的項目嗎？", "Replace the Items with the Same Names on the Server?")
                alert.informativeText = clashes.map(\.lastPathComponent).prefix(10).joined(separator: "\n")
                    + (clashes.count > 10 ? "\n…" : "")
                    + "\n\n" + tr("資料夾會合併：同名的檔案被取代，其他的留著。", "Folders are merged: files with the same names are replaced, and the rest stay.")
                alert.addButton(withTitle: tr("取代", "Replace"))
                alert.addButton(withTitle: tr("略過這些", "Skip These"))
                alert.addButton(withTitle: tr("取消", "Cancel"))
                switch keepingPopoverOpen({ alert.runModal() }) {
                case .alertFirstButtonReturn: break
                case .alertSecondButtonReturn: urls.removeAll { clashes.contains($0) }
                default: return
                }
                if urls.isEmpty { return }
            }
        }
        transferQueue.add(urls.map { url in
            let name = url.lastPathComponent
            return TransferItem(name: name, direction: .upload, connection: connection,
                                commands: ["put -r " + SSHConnection.quote(url.path) + " " + SSHConnection.quote(SSHConnection.join(remoteFolder, name))],
                                destination: connection.destination + ":" + remoteFolder, refresh: remoteFolder) { [weak self] error in
                guard error == nil, let self, remoteFolder == self.folder, connection === self.connection, !self.busyOverlay.isShowing else { return }
                self.load(remoteFolder, select: self.selectedFiles.map(\.name) + [name], quietly: true)
            }
        })
    }

    /// The toolbar's download: what's selected on the right, into the folder on the left.
    @objc func download(_ sender: Any?) {
        download(actedOnFiles, to: localPane.folder)
    }

    @objc func downloadTo(_ sender: Any?) {
        let chosen = actedOnFiles
        guard !chosen.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = localPane.folder
        panel.prompt = tr("下載到這裡", "Download Here")
        guard keepingPopoverOpen({ panel.runModal() }) == .OK, let url = panel.url else { return }
        download(chosen, to: url)
    }

    /// Downloads into a folder on this Mac, one transfer each. When names are taken there, asks
    /// whether to replace them or keep both (the new ones numbered, as the Finder does).
    private func download(_ chosen: [RemoteFile], to localFolder: URL) {
        guard let connection, !chosen.isEmpty else { return }
        let clashes = chosen.filter { FileManager.default.fileExists(atPath: localFolder.appendingPathComponent($0.name).path) }
        var keepBoth = false
        if !clashes.isEmpty {
            let alert = NSAlert()
            alert.messageText = tr("「\(localFolder.lastPathComponent)」裡已經有同名的項目", "“\(localFolder.lastPathComponent)” Already Has Items with These Names")
            alert.informativeText = clashes.prefix(10).map(\.name).joined(separator: "\n") + (clashes.count > 10 ? "\n…" : "")
            alert.addButton(withTitle: tr("兩者都保留", "Keep Both"))
            alert.addButton(withTitle: tr("取代", "Replace"))
            alert.addButton(withTitle: tr("取消", "Cancel"))
            switch keepingPopoverOpen({ alert.runModal() }) {
            case .alertFirstButtonReturn: keepBoth = true
            case .alertSecondButtonReturn: keepBoth = false
            default: return
            }
        }
        var taken = Set<String>()
        transferQueue.add(chosen.map { file in
            let target = keepBoth ? Self.unusedName(file.name, in: localFolder, besides: taken) : localFolder.appendingPathComponent(file.name)
            taken.insert(target.lastPathComponent)
            return TransferItem(name: file.name, direction: .download, connection: connection,
                                commands: ["get -r " + SSHConnection.quote(file.path) + " " + SSHConnection.quote(target.path)],
                                destination: (localFolder.path as NSString).abbreviatingWithTildeInPath, localURL: target) { error in
                guard error == nil else { return }
                // The Downloads stack in the Dock bounces, as it does for Safari's downloads.
                DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: target.path)
            }
        })
    }

    private static func unusedName(_ name: String, in folder: URL, besides taken: Set<String>) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name
        var n = 2
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = base + " \(n)" + (ext.isEmpty ? "" : "." + ext)
            n += 1
        }
        return folder.appendingPathComponent(candidate)
    }

    // MARK: - Changing files

    @objc func newFolder(_ sender: Any?) {
        if forLocal(sender) { return localPane.newFolder(sender) }
        guard let connection, let folder else { return }
        guard let name = askForName(tr("新增資料夾", "New Folder"), tr("在 \(folder) 裡新增資料夾：", "A new folder in \(folder):"),
                                    initial: tr("未命名資料夾", "untitled folder"), button: tr("新增", "Create")) else { return }
        let path = SSHConnection.join(folder, name)
        perform(tr("正在新增資料夾…", "Creating the folder…"), { try connection.makeFolder(path, $0) }) { [weak self] result in
            if case .failure(let error) = result { self?.showError(tr("無法新增資料夾", "Couldn’t Create the Folder"), error) }
            self?.load(folder, select: [name], quietly: true)
        }
    }

    @objc func renameFile(_ sender: Any?) {
        if forLocal(sender) { return localPane.rename(sender) }
        guard let connection, let folder, let file = actedOnFiles.first, actedOnFiles.count == 1 else { return NSSound.beep() }
        guard let name = askForName(tr("重新命名", "Rename"), tr("「\(file.name)」的新名稱：", "New name for “\(file.name)”:"),
                                    initial: file.name, button: tr("重新命名", "Rename")), name != file.name else { return }
        perform(tr("正在重新命名…", "Renaming…"), { try connection.rename(file.path, to: SSHConnection.join(folder, name), $0) }) { [weak self] result in
            if case .failure(let error) = result { self?.showError(tr("無法重新命名", "Couldn’t Rename It"), error) }
            self?.load(folder, select: [name], quietly: true)
        }
    }

    @objc func deleteFiles(_ sender: Any?) {
        if forLocal(sender) { return localPane.moveToTrash(sender) }
        let chosen = actedOnFiles
        guard let connection, let folder, !chosen.isEmpty else { return NSSound.beep() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = chosen.count == 1 ? tr("要刪除「\(chosen[0].name)」嗎？", "Delete “\(chosen[0].name)”?")
                                              : tr("要刪除這 \(chosen.count) 個項目嗎？", "Delete These \(chosen.count) Items?")
        alert.informativeText = (chosen.count > 1 ? chosen.prefix(10).map(\.name).joined(separator: "\n") + (chosen.count > 10 ? "\n…" : "") + "\n\n" : "")
            + (chosen.contains(where: \.isFolder) ? tr("資料夾會連同裡面的所有內容一起刪除。", "Folders are deleted with everything in them. ") : "")
            + tr("伺服器上沒有垃圾桶，刪除後無法復原。", "Servers have no Trash: this can’t be undone.")
        alert.addButton(withTitle: tr("刪除", "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard keepingPopoverOpen({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        perform(tr("正在刪除…", "Deleting…"), { try connection.delete(chosen, $0) }) { [weak self] result in
            if case .failure(let error) = result { self?.showError(tr("無法刪除", "Couldn’t Delete"), error) }
            self?.load(folder, quietly: true)
        }
    }

    /// Moves items dragged onto a folder in the list into it.
    private func move(_ moving: [RemoteFile], into target: String) {
        guard let connection, let folder else { return }
        let moving = moving.filter { $0.path != target && SSHConnection.parent(of: $0.path) != target }
        guard !moving.isEmpty else { return }
        let commands = moving.map { "rename " + SSHConnection.quote($0.path) + " " + SSHConnection.quote(SSHConnection.join(target, $0.name)) }
        perform(tr("正在搬移…", "Moving…"), { try connection.sftp(commands, $0) }) { [weak self] result in
            if case .failure(let error) = result { self?.showError(tr("無法搬移", "Couldn’t Move Them"), error) }
            self?.load(folder, quietly: true)
        }
    }

    @objc func copyPath(_ sender: Any?) {
        if forLocal(sender) { return localPane.copyPath(sender) }
        let paths = actedOnFiles.isEmpty ? [folder].compactMap { $0 } : actedOnFiles.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    private func askForName(_ title: String, _ message: String, initial: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        // Selects the name without its extension, as the Finder does.
        DispatchQueue.main.async {
            let stem = (initial as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem.isEmpty ? initial : stem).utf16.count)
        }
        guard keepingPopoverOpen({ alert.runModal() }) == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else {
            NSSound.beep()
            return nil
        }
        return name
    }

    // MARK: - ~/.ssh/config

    @objc func editConfig(_ sender: Any?) {
        let url = SSHConfig.defaultURL
        do {
            try Self.ensureConfigExists()
            let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            if let editor {
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        } catch {
            showError(tr("無法開啟 ~/.ssh/config", "Couldn’t Open ~/.ssh/config"), error)
        }
    }

    private static func ensureConfigExists() throws {
        let url = SSHConfig.defaultURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    /// The connection settings window: the Hosts in ~/.ssh/config to add, edit and delete.
    @objc func manageConnections(_ sender: Any?) {
        showConnectionManager(select: connection.flatMap { c in hosts.first { connections[$0.name] === c && !$0.typed }?.name })
    }

    @objc func addHost(_ sender: Any?) {
        showConnectionManager(addNew: true)
    }

    private func showConnectionManager(select name: String? = nil, addNew: Bool = false) {
        guard let manager = keepingPopoverOpen({ ConfigManager(select: name, addNew: addNew) }) else { return }
        keepingPopoverOpen { manager.run() }
        guard manager.saved else { return }
        // The server showing may have new folders set: this Mac's side goes to its folder now.
        if let connection, let host = hosts.first(where: { connections[$0.name] === connection }), !host.typed {
            startFolders[connection.key] = ConfigFile.startFolders(for: host.name)
            goToLocalStart(for: connection)
        }
        // A changed Host connects with its new settings next time; one already connected keeps
        // its shared connection until that's closed.
        reloadHosts()
        statusLabel.stringValue = tr("已儲存 ~/.ssh/config（原檔備份為 config.menussh-backup）", "Saved ~/.ssh/config (the earlier one is kept as config.menussh-backup)")
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        shownFiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        FileList.cell(shownFiles[row], tableColumn?.identifier.rawValue ?? "")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateServerUI()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === fileTable, let first = tableView.sortDescriptors.first, let key = first.key else { return }
        sortKey = key
        ascending = first.ascending
        reloadFiles(select: selectedFiles.map(\.name))
    }

    // MARK: Dragging

    /// Rows dragged out: to the Finder, as files it's promised and that are downloaded when dropped.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === fileTable, row < shownFiles.count else { return nil }
        let file = shownFiles[row]
        let type = file.isFolder ? UTType.folder : UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = connection.map { Promised(connection: $0, path: file.path) }
        return provider
    }

    /// What a row dragged out stands for: the file, and the server it's on.
    private struct Promised {
        let connection: SSHConnection
        let path: String
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        ((provider.userInfo as? Promised)?.path as NSString? ?? "file").lastPathComponent
    }

    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let promised = provider.userInfo as? Promised else { return completionHandler(SSHError.cancelled) }
        let connection = promised.connection, path = promised.path
        let name = (path as NSString).lastPathComponent
        DispatchQueue.main.async { self.statusLabel.stringValue = tr("正在下載 \(name)…", "Downloading \(name)…") }
        do {
            try connection.transfer(["get -r " + SSHConnection.quote(path) + " " + SSHConnection.quote(url.path)], Cancellation()) { _ in }
            DispatchQueue.main.async { self.statusLabel.stringValue = tr("已下載 \(name)", "Downloaded \(name)") }
            completionHandler(nil)
        } catch {
            DispatchQueue.main.async { self.showError(tr("無法下載 \(name)", "Couldn’t Download \(name)"), error) }
            completionHandler(error)
        }
    }

    /// The rows being dragged, for a drop on a folder in the same list.
    private var draggedFiles: [RemoteFile] = []

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        draggedFiles = rowIndexes.filter { $0 < shownFiles.count }.map { shownFiles[$0] }
    }

    /// Files from the Finder upload into the folder they're dropped on, or the one showing; rows
    /// from this list move into a folder they're dropped on.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === fileTable, folder != nil else { return [] }
        let onFolder = dropOperation == .on && row < shownFiles.count && shownFiles[row].isFolder
        if info.draggingSource as? NSTableView === fileTable {
            return onFolder && !draggedFiles.contains(shownFiles[row]) ? .move : []
        }
        if !onFolder { tableView.setDropRow(-1, dropOperation: .on) }
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let folder else { return false }
        let target = row >= 0 && row < shownFiles.count && shownFiles[row].isFolder ? shownFiles[row].path : folder
        if info.draggingSource as? NSTableView === fileTable {
            move(draggedFiles, into: target)
            return true
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        // After the drop has finished, so the alert asking about replacing doesn't hold up the Finder.
        DispatchQueue.main.async { self.upload(urls, to: target) }
        return true
    }

    // MARK: - Running work

    /// Runs work off the main thread with the window covered (after a moment, with what's going
    /// on and Cancel), then hands the result back on the main thread. With no message, the window
    /// isn't covered.
    private func perform<T>(_ message: String?, _ body: @escaping (Cancellation) throws -> T,
                            then done: @escaping (Result<T, Error>) -> Void) {
        let cancellation = Cancellation()
        if let message {
            busyOverlay.show(message)
            busyOverlay.onCancel = { cancellation.cancel() }
            // A password dialog belongs to the app; the popover mustn't close when it comes up.
            popover?.behavior = .applicationDefined
        }
        work.async {
            let result = Result { try body(cancellation) }
            DispatchQueue.main.async {
                if message != nil {
                    self.busyOverlay.hide()
                    self.applyPopoverBehavior()
                }
                done(result)
            }
        }
    }

    // MARK: - Popover

    private var savedSize: NSSize {
        get { UserDefaults.standard.string(forKey: Keys.size).map { clamp(NSSizeFromString($0)) } ?? Self.defaultSize }
        set { UserDefaults.standard.set(NSStringFromSize(newValue), forKey: Keys.size) }
    }

    private func clamp(_ size: NSSize) -> NSSize {
        let screen = (isViewLoaded ? view.window?.screen : nil)?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size
            ?? NSSize(width: 1440, height: 900)
        return NSSize(width: min(max(size.width, Self.minSize.width), screen.width - 40),
                      height: min(max(size.height, Self.minSize.height), screen.height - 30))
    }

    private func resize(to size: NSSize) {
        let size = clamp(size)
        // The pinned window has a size of its own (saved with its place); the popover's size is
        // left as it was, for when the pin comes off.
        if inPinnedWindow, let window = view.window {
            var frame = window.frame
            let top = frame.maxY
            frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
            frame.origin.y = top - frame.height
            preferredContentSize = size
            window.setFrame(frame, display: true)
            return
        }
        preferredContentSize = size
        popover?.contentSize = size
        savedSize = size
        view.window?.invalidateCursorRects(for: view)
    }

    @objc func resetSize(_ sender: Any?) {
        resize(to: Self.defaultSize)
    }

    /// Back in the popover after being pinned: the size it had before.
    func restorePopoverSize() {
        resize(to: savedSize)
    }

    func applyPopoverBehavior() {
        popover?.behavior = pinned ? .applicationDefined : .transient
    }

    private func updatePinButton() {
        pinButton?.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        pinButton?.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
    }

    @objc func togglePin(_ sender: Any?) {
        guard !pinned || canUnpin else { return NSSound.beep() }
        pinned.toggle()
    }

    /// Hides the window; a pinned one stays pinned, and comes back where it was.
    @objc func closePopover(_ sender: Any?) {
        if inPinnedWindow { return view.window!.orderOut(sender) }
        popover?.performClose(sender)
    }

    /// Esc hides the window, except while editing text, where it ends the edit.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // While something runs, keys do nothing here but Esc, which cancels it.
            if let self, self.busyOverlay.isShowing, event.window === self.view.window {
                if event.keyCode == 53 { self.busyOverlay.cancel(nil) }
                return nil
            }
            guard let self, event.keyCode == 53, let window = self.view.window, event.window === window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty,
                  !(window.firstResponder is NSText), !(window.firstResponder is TerminalView) else { return event }
            self.closePopover(nil)
            return nil
        }
    }

    /// Keeps the popover open, and below them, while a panel or alert is up.
    private func keepingPopoverOpen<T>(_ body: () -> T) -> T {
        popover?.behavior = .applicationDefined
        NSApp.activate(ignoringOtherApps: true)
        let window = view.window, level = window?.level
        window?.level = .normal
        defer {
            if let level { window?.level = level }
            if !busyOverlay.isShowing { applyPopoverBehavior() }
            window?.makeKey()
        }
        return body()
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        keepingPopoverOpen { _ = alert.runModal() }
    }

    // MARK: - More menu

    @objc func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        add(menu, tr("新增連線設定…", "Add a Connection…"), #selector(addHost(_:)))
        add(menu, tr("管理連線設定…", "Connection Settings…"), #selector(manageConnections(_:)), key: "K")
        add(menu, tr("用文字編輯器開啟 ~/.ssh/config", "Open ~/.ssh/config in a Text Editor"), #selector(editConfig(_:)))
        menu.addItem(.separator())
        let terminals = NSMenu()
        for app in TerminalApp.installed {
            let item = add(terminals, app.title, #selector(selectTerminal(_:)))
            item.representedObject = app.rawValue
            item.state = app == TerminalApp.current ? .on : .off
        }
        menu.addItem(withTitle: tr("SSH 連線開在", "Open SSH Sessions In"), action: nil, keyEquivalent: "").submenu = terminals
        menu.addItem(.separator())
        add(menu, tr("恢復預設視窗大小", "Restore Default Window Size"), #selector(resetSize(_:)))
        let themes = NSMenu()
        for theme in Theme.allCases {
            let item = add(themes, theme.title, #selector(selectTheme(_:)))
            item.representedObject = theme.rawValue
            item.state = theme == Theme.current ? .on : .off
        }
        menu.addItem(withTitle: tr("主題", "Theme"), action: nil, keyEquivalent: "").submenu = themes
        let languages = NSMenu()
        for language in Language.allCases {
            let item = add(languages, language.title, #selector(selectLanguage(_:)))
            item.representedObject = language.rawValue
            item.state = language == Language.current ? .on : .off
        }
        menu.addItem(withTitle: tr("語言", "Language"), action: nil, keyEquivalent: "").submenu = languages
        menu.addItem(.separator())
        add(menu, tr("登入時自動開啟", "Open at Login"), #selector(toggleLaunchAtLogin(_:))).state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        // One of the two stays on, or there'd be no way back: the last one on can't be turned off.
        let dock = add(menu, tr("顯示在 Dock", "Show in Dock"), #selector(toggleShowInDock(_:)))
        dock.state = Presence.showInDock ? .on : .off
        let menuBar = add(menu, tr("顯示在選單列", "Show in Menu Bar"), #selector(toggleShowInMenuBar(_:)))
        menuBar.state = Presence.showInMenuBar ? .on : .off
        let hint = NSMenuItem(title: tr("Dock 和選單列至少要顯示一個", "Shows in the Dock, the menu bar, or both"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        add(menu, tr("關於隨手SSH", "About MenuSSH"), #selector(showAbout(_:)))
        menu.addItem(withTitle: tr("結束隨手SSH", "Quit MenuSSH"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func selectTerminal(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let app = TerminalApp(rawValue: raw) else { return }
        TerminalApp.current = app
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = Theme(rawValue: raw) else { return }
        Theme.current = theme
        Theme.apply(to: popover)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = Language(rawValue: raw) else { return }
        Language.current = language
    }

    @objc private func toggleShowInDock(_ sender: Any?) { Presence.showInDock.toggle() }
    @objc private func toggleShowInMenuBar(_ sender: Any?) { Presence.showInMenuBar.toggle() }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            showError(tr("無法變更「登入時自動開啟」", "Couldn’t change “Open at Login”"), error)
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        closePopover(nil)
        NSApp.activate(ignoringOtherApps: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(string: "Created by : Jeff Lee\n", attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        credits.append(NSAttributedString(string: "janfon-source / ", attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
        credits.append(NSAttributedString(string: "MenuSSH", attributes: [
            .font: font,
            .link: URL(string: "https://github.com/janfon-source/MenuSSH")!,
            .paragraphStyle: paragraph,
        ]))
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: tr("隨手SSH", "MenuSSH"), .credits: credits])
    }
}

// MARK: - Right-click menus

extension MainViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ zh: String, _ en: String, _ action: Selector) {
            menu.addItem(withTitle: tr(zh, en), action: action, keyEquivalent: "").target = self
        }
        guard folder != nil else { return }
        let chosen = actedOnFiles
        if !chosen.isEmpty {
            item("開啟", "Open", #selector(openSelected(_:)))
            item("下載", "Download", #selector(download(_:)))
            item("下載到…", "Download To…", #selector(downloadTo(_:)))
            menu.addItem(.separator())
            if chosen.count == 1 { item("重新命名…", "Rename…", #selector(renameFile(_:))) }
            item("刪除…", "Delete…", #selector(deleteFiles(_:)))
            item("拷貝路徑", "Copy Path", #selector(copyPath(_:)))
            menu.addItem(.separator())
        }
        item("上傳到這裡…", "Upload Here…", #selector(upload(_:)))
        item("新增資料夾…", "New Folder…", #selector(newFolder(_:)))
        item(chosen.count == 1 && chosen[0].isFolder ? "在終端機開啟這個資料夾" : "在終端機開啟目前的資料夾",
             chosen.count == 1 && chosen[0].isFolder ? "Open This Folder in the Terminal" : "Open This Folder in the Terminal",
             #selector(openTerminalHere(_:)))
        item("重新整理", "Refresh", #selector(refresh(_:)))
    }
}

extension MainViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if busyOverlay.isShowing { return false }
        let files = mode == .sftp && folder != nil
        if forLocal(menuItem) {
            switch menuItem.action {
            case #selector(deleteFiles(_:)), #selector(openSelected(_:)), #selector(copyPath(_:)):
                return !localPane.actedOn.isEmpty
            case #selector(renameFile(_:)):
                return localPane.actedOn.count == 1
            case #selector(refresh(_:)), #selector(goUp(_:)), #selector(goHome(_:)), #selector(newFolder(_:)):
                return true
            default: break
            }
        }
        switch menuItem.action {
        case #selector(toggleTransfers(_:)):
            return mode == .sftp
        case #selector(toggleSyncBrowsing(_:)):
            menuItem.state = syncBrowsing ? .on : .off
            return files
        case #selector(upload(_:)):
            return files
        case #selector(showSSH(_:)):
            menuItem.state = mode == .ssh ? .on : .off
            return true
        case #selector(showSFTP(_:)):
            menuItem.state = mode == .sftp ? .on : .off
            return sftpAvailable
        case #selector(stopConnection(_:)):
            return connection != nil
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return !tabHosts.isEmpty
        case #selector(toggleOptionAsMeta(_:)):
            menuItem.state = TerminalView.optionAsMeta ? .on : .off
            return true
        case #selector(reconnect(_:)), #selector(clearScrollback(_:)):
            return mode == .ssh && session?.hasStarted == true
        case #selector(openTerminalHere(_:)):
            return connection != nil
        case #selector(goHome(_:)), #selector(refresh(_:)), #selector(upload(_:)),
             #selector(newFolder(_:)), #selector(goToFolder(_:)), #selector(toggleHidden(_:)):
            return files
        case #selector(goUp(_:)):
            return files && folder != "/"
        case #selector(download(_:)), #selector(downloadTo(_:)), #selector(deleteFiles(_:)), #selector(copyPath(_:)), #selector(openSelected(_:)):
            return files && !actedOnFiles.isEmpty
        case #selector(renameFile(_:)):
            return files && actedOnFiles.count == 1
        case #selector(stopTransfers(_:)):
            return transferQueue.hasActive
        case #selector(toggleShowInDock(_:)):
            return !Presence.showInDock || Presence.showInMenuBar
        case #selector(toggleShowInMenuBar(_:)):
            return !Presence.showInMenuBar || Presence.showInDock
        default:
            return true
        }
    }
}

/// A list of files: Return or ⌘↓ opens, ⌘⌫ (or Delete) deletes.
final class FileTable: NSTableView {
    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?
    /// ⌫ alone deletes too; off where deleting should take ⌘⌫, as in the Finder.
    var deletesWithPlainBackspace = true

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        switch event.keyCode {
        case 36, 76: onOpen?()                                         // Return, Enter
        case 125 where flags == .command: onOpen?()                    // ⌘↓
        case 51 where flags == .command || (flags.isEmpty && deletesWithPlainBackspace): onDelete?()   // ⌘⌫, ⌫
        case 117 where deletesWithPlainBackspace: onDelete?()          // ⌦
        default: super.keyDown(with: event)
        }
    }
}
