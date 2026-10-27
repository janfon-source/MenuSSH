import AppKit

/// The left half of SFTP mode: a folder on this Mac, with a path bar of its own. Files dragged
/// from here to the server's list upload; rows dragged here from the server's list download into
/// this folder (or the folder they're dropped on). It follows changes made in the Finder.
final class LocalPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let table = FileTable()
    private let pathField = NSTextField()
    private let heading = NSTextField(labelWithString: "")
    private(set) var folder: URL
    private var files: [RemoteFile] = []
    private(set) var shown: [RemoteFile] = []
    private var sortKey = "name"
    private var ascending = true
    private var watcher: DispatchSourceFileSystemObject?
    private var localized: [(view: NSView, zh: String, en: String)] = []

    var showHidden = false {
        didSet { reload(select: selected.map(\.name)) }
    }

    /// Upload these to the server's folder showing.
    var onUpload: (([URL]) -> Void)?
    /// Rows from the server's list were dropped here: download them into this folder.
    var onRemoteDrop: ((URL) -> Void)?
    /// Whether a drag comes from the server's list.
    var isRemoteDrag: ((NSDraggingInfo) -> Bool)?
    /// A name typed into a dialog, and errors: the window's own, which keep the popover open.
    var askName: ((_ title: String, _ message: String, _ initial: String, _ button: String) -> String?)?
    var showError: ((_ title: String, _ error: Error) -> Void)?
    /// Runs a panel with the popover kept open behind it.
    var keepingOpen: ((() -> Void) -> Void)?
    var onSelectionChange: (() -> Void)?
    /// The folder showing changed, from the first to the second, by the user's doing.
    var onFolderChange: ((_ old: URL, _ new: URL) -> Void)?

    private static let folderKey = "menussh.localFolder"

    override init(frame: NSRect) {
        let saved = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0) }
        var isFolder: ObjCBool = false
        folder = saved.flatMap { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isFolder) && isFolder.boolValue ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser
        super.init(frame: frame)

        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.setContentHuggingPriority(.required, for: .horizontal)
        pathField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathField.lineBreakMode = .byTruncatingHead
        pathField.usesSingleLineMode = true
        pathField.cell?.isScrollable = true
        pathField.target = self
        pathField.action = #selector(goToTyped(_:))
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [PathBar(label: heading, field: pathField),
                                      button("folder", "選擇資料夾…", "Choose a Folder…", #selector(chooseFolder(_:))),
                                      button("arrow.clockwise", "重新整理", "Refresh", #selector(refresh(_:))),
                                      button("arrowshape.right", "上傳：把選取的項目傳到右邊的遠端資料夾（⌘U）",
                                             "Upload: the items selected here to the server’s folder on the right (⌘U)", #selector(upload(_:)))])
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 6)

        FileList.addColumns(to: table, permissions: false)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.onOpen = { [weak self] in self?.openSelected(nil) }
        table.onDelete = { [weak self] in self?.moveToTrash(nil) }
        table.deletesWithPlainBackspace = false   // only ⌘⌫, as in the Finder
        table.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        FileList.fitColumnsToWidth(table)

        let stack = NSStackView(views: [bar, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        bar.setHuggingPriority(.required, for: .vertical)
        applyLanguage()
        go(to: folder)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, _ zh: String, _ en: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))!
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        localized.append((button, zh, en))
        return button
    }

    func applyLanguage() {
        heading.stringValue = tr("本機", "This Mac")
        for (view, zh, en) in localized {
            view.toolTip = tr(zh, en)
            view.setAccessibilityLabel(view.toolTip)
        }
        FileList.relabel(table)
    }

    // MARK: Folders

    /// Shows a folder. `following`: the move copies one made on the server's side (synchronized
    /// browsing), so it isn't reported back, and a folder that isn't there fails quietly.
    @discardableResult
    func go(to url: URL, select: [String] = [], following: Bool = false) -> Bool {
        let url = url.standardizedFileURL
        do {
            files = try FileList.listLocal(url)
        } catch {
            if !following { showError?(tr("無法開啟資料夾", "Couldn’t Open the Folder"), error) }
            return false
        }
        let old = folder
        if url != folder { table.deselectAll(nil) }
        folder = url
        defer { if url != old && !following { onFolderChange?(old, url) } }
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        pathField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        reload(select: select)
        watch()
        return true
    }

    /// Lists the folder again when anything in it is added, removed or renamed.
    private func watch() {
        watcher?.cancel()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A burst of changes (a download writing) is read once it settles.
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.refreshQuietly), object: nil)
            self.perform(#selector(self.refreshQuietly), with: nil, afterDelay: 0.3)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    @objc private func refreshQuietly() {
        files = (try? FileList.listLocal(folder)) ?? files
        reload(select: selected.map(\.name))
    }

    private func reload(select: [String]) {
        shown = FileList.sorted(files, key: sortKey, ascending: ascending, showHidden: showHidden)
        table.reloadData()
        let rows = IndexSet(select.compactMap { name in shown.firstIndex { $0.name == name } })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { table.scrollRowToVisible(first) }
    }

    var selected: [RemoteFile] {
        table.selectedRowIndexes.filter { $0 < shown.count }.map { shown[$0] }
    }

    /// Right-click acts on the row clicked, and on the whole selection if that row is in it.
    var actedOn: [RemoteFile] {
        let row = table.clickedRow
        guard row >= 0, row < shown.count else { return selected }
        return table.selectedRowIndexes.contains(row) ? selected : [shown[row]]
    }

    @objc func refresh(_ sender: Any?) { go(to: folder, select: selected.map(\.name)) }

    @objc func goUp(_ sender: Any?) {
        guard folder.path != "/" else { return NSSound.beep() }
        go(to: folder.deletingLastPathComponent(), select: [folder.lastPathComponent])
    }

    @objc func goHome(_ sender: Any?) { go(to: FileManager.default.homeDirectoryForCurrentUser) }

    @objc private func goToTyped(_ sender: Any?) {
        let path = (pathField.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        go(to: URL(fileURLWithPath: path))
        window?.makeFirstResponder(table)
    }

    @objc func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = tr("選擇", "Choose")
        var response = NSApplication.ModalResponse.cancel
        if let keepingOpen { keepingOpen { response = panel.runModal() } } else { response = panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        go(to: url)
    }

    @objc func revealFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        openSelected(sender)
    }

    /// A folder is gone into; files open in their apps.
    @objc func openSelected(_ sender: Any?) {
        let chosen = actedOn
        if let folder = chosen.first(where: \.isFolder) { go(to: URL(fileURLWithPath: folder.path)); return }
        for file in chosen { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) }
    }

    @objc func upload(_ sender: Any?) {
        let chosen = actedOn
        guard !chosen.isEmpty else { return NSSound.beep() }
        onUpload?(chosen.map { URL(fileURLWithPath: $0.path) })
    }

    @objc func revealInFinder(_ sender: Any?) {
        let chosen = actedOn
        NSWorkspace.shared.activateFileViewerSelecting(chosen.isEmpty ? [folder] : chosen.map { URL(fileURLWithPath: $0.path) })
    }

    @objc func moveToTrash(_ sender: Any?) {
        let chosen = actedOn
        guard !chosen.isEmpty else { return NSSound.beep() }
        NSWorkspace.shared.recycle(chosen.map { URL(fileURLWithPath: $0.path) }) { [weak self] _, error in
            if let error { self?.showError?(tr("無法移到垃圾桶", "Couldn’t Move to the Trash"), error) }
            self?.refreshQuietly()
        }
    }

    @objc func newFolder(_ sender: Any?) {
        guard let name = askName?(tr("新增資料夾", "New Folder"), tr("在 \(folder.path) 裡新增資料夾：", "A new folder in \(folder.path):"),
                                  tr("未命名資料夾", "untitled folder"), tr("新增", "Create")) else { return }
        do {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: false)
            go(to: folder, select: [name])
        } catch {
            showError?(tr("無法新增資料夾", "Couldn’t Create the Folder"), error)
        }
    }

    @objc func rename(_ sender: Any?) {
        guard actedOn.count == 1, let file = actedOn.first,
              let name = askName?(tr("重新命名", "Rename"), tr("「\(file.name)」的新名稱：", "New name for “\(file.name)”:"),
                                  file.name, tr("重新命名", "Rename")), name != file.name else { return }
        do {
            try FileManager.default.moveItem(atPath: file.path, toPath: folder.appendingPathComponent(name).path)
            go(to: folder, select: [name])
        } catch {
            showError?(tr("無法重新命名", "Couldn’t Rename It"), error)
        }
    }

    /// The info window for the item selected: its facts, and its name and permissions to change.
    @objc func showInfo(_ sender: Any?) {
        guard actedOn.count == 1, let file = actedOn.first else { return NSSound.beep() }
        let url = URL(fileURLWithPath: file.path)
        let attributes = (try? FileManager.default.attributesOfItem(atPath: file.path)) ?? [:]
        func date(_ key: FileAttributeKey) -> String {
            (attributes[key] as? Date).map { FileInfoWindow.dateFormatter.string(from: $0) } ?? "—"
        }
        let owner = [attributes[.ownerAccountName] as? String, attributes[.groupOwnerAccountName] as? String]
            .compactMap { $0 }.joined(separator: " / ")
        let details: [(String, String)] = [
            (tr("建立日期", "Created"), date(.creationDate)),
            (tr("修改日期", "Modified"), date(.modificationDate)),
            (tr("擁有者／群組", "Owner / Group"), owner.isEmpty ? "—" : owner),
        ]
        let window = FileInfoWindow(file: file, place: (folder.path as NSString).abbreviatingWithTildeInPath, details: details) { done in
            DispatchQueue.global().async {
                let size = SSHConnection.localSize(of: url)
                DispatchQueue.main.async { done(size) }
            }
        }
        if let keepingOpen { keepingOpen { window.run() } } else { window.run() }
        guard let changes = window.changes else { return }
        var path = file.path
        do {
            if let name = changes.name {
                let renamed = folder.appendingPathComponent(name).path
                try FileManager.default.moveItem(atPath: path, toPath: renamed)
                path = renamed
            }
            if let mode = changes.permissions {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
                if changes.recursive, let inside = FileManager.default.enumerator(atPath: path) {
                    while let item = inside.nextObject() as? String {
                        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: (path as NSString).appendingPathComponent(item))
                    }
                }
            }
        } catch {
            showError?(tr("無法套用變更", "Couldn’t Make the Changes"), error)
        }
        go(to: folder, select: [(path as NSString).lastPathComponent])
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = actedOn.isEmpty ? [folder.path] : actedOn.map(\.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        FileList.cell(shown[row], tableColumn?.identifier.rawValue ?? "")
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onSelectionChange?() }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let first = tableView.sortDescriptors.first, let key = first.key else { return }
        sortKey = key
        ascending = first.ascending
        reload(select: selected.map(\.name))
    }

    /// Rows dragged out are plain files: to the server's list, or to the Finder.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        row < shown.count ? URL(fileURLWithPath: shown[row].path) as NSURL : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard isRemoteDrag?(info) == true else { return [] }
        let onFolder = dropOperation == .on && row < shown.count && shown[row].isFolder
        if !onFolder { tableView.setDropRow(-1, dropOperation: .on) }
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard isRemoteDrag?(info) == true else { return false }
        let target = row >= 0 && row < shown.count && shown[row].isFolder ? URL(fileURLWithPath: shown[row].path) : folder
        onRemoteDrop?(target)
        return true
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ zh: String, _ en: String, _ action: Selector) {
            menu.addItem(withTitle: tr(zh, en), action: action, keyEquivalent: "").target = self
        }
        let chosen = actedOn
        if !chosen.isEmpty {
            item("上傳到伺服器", "Upload to the Server", #selector(upload(_:)))
            item("開啟", "Open", #selector(openSelected(_:)))
            item("在 Finder 中顯示", "Show in Finder", #selector(revealInFinder(_:)))
            menu.addItem(.separator())
            if chosen.count == 1 {
                item(chosen[0].isFolder ? "資料夾資訊…" : "檔案資訊…", chosen[0].isFolder ? "Folder Info…" : "File Info…", #selector(showInfo(_:)))
                item("重新命名…", "Rename…", #selector(rename(_:)))
            }
            item("移到垃圾桶", "Move to Trash", #selector(moveToTrash(_:)))
            item("拷貝路徑", "Copy Path", #selector(copyPath(_:)))
            menu.addItem(.separator())
        }
        item("新增資料夾…", "New Folder…", #selector(newFolder(_:)))
        item("在 Finder 中顯示這個資料夾", "Show This Folder in Finder", #selector(revealFolder(_:)))
        item("重新整理", "Refresh", #selector(refresh(_:)))
    }
}
