import AppKit

/// A window for the connections in ~/.ssh/config (and the files it includes): the Hosts on the
/// left to add, duplicate and delete; the one selected in a form on the right. Nothing is written
/// until Save, and then only the blocks changed: comments, Match blocks and the rest of the file
/// stay as they are, and the file as it was is kept beside it as config.menussh-backup.
final class ConfigManager: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                           NSTextFieldDelegate, NSTextViewDelegate {
    private let panel: NSPanel
    private var files: [ConfigFile] = []
    /// Each Host block in the list: its file and its place there.
    private var items: [(file: ConfigFile, index: Int)] = []
    private let table = NSTableView()
    private var removeButton: NSButton!
    private var duplicateButton: NSButton!
    private var saveButton: NSButton!
    private let fileLabel = NSTextField(labelWithString: "")
    private let form = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var fields: [WritableKeyPath<HostFields, String>: NSTextField] = [:]
    private let otherView = NSTextView.scrollableTextView()
    private var otherText: NSTextView { otherView.documentView as! NSTextView }
    /// Showing a block in the form, not the user typing.
    private var filling = false
    /// Whether anything was saved, for the window to read the hosts again.
    private(set) var saved = false

    /// Nil, after saying why, when ~/.ssh/config can't be read: editing it then could lose what's in it.
    init?(select name: String? = nil, addNew: Bool = false) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = tr("管理連線設定（~/.ssh/config）", "Connection Settings (~/.ssh/config)")
        panel.minSize = NSSize(width: 640, height: 400)
        panel.delegate = self
        do {
            try load()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = tr("無法讀取 ~/.ssh/config", "Couldn’t Read ~/.ssh/config")
            alert.runModal()
            return nil
        }
        build()
        if addNew {
            add(nil)
        } else if let row = items.firstIndex(where: { $0.file.entry(at: $0.index)?.fields.aliases.contains(name ?? "") == true }) ?? (items.isEmpty ? nil : 0) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        showSelected()
    }

    /// Shows the window until it's closed.
    func run() {
        panel.center()
        NSApp.runModal(for: panel)
    }

    private func load() throws {
        let main = try ConfigFile(url: SSHConfig.defaultURL)
        files = [main]
        for url in main.includedFiles where !files.contains(where: { $0.url.path == url.path }) {
            if let file = try? ConfigFile(url: url) { files.append(file) }
        }
        rebuildItems()
    }

    private func rebuildItems() {
        items = files.flatMap { file in file.hostIndices.map { (file, $0) } }
    }

    // MARK: Layout

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .sourceList
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        // Dragged into the order they're in the file, which is the order of the connection menu.
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        func button(_ symbol: String, _ zh: String, _ en: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tr(zh, en))!,
                                  target: self, action: action)
            button.bezelStyle = .smallSquare
            button.toolTip = tr(zh, en)
            return button
        }
        removeButton = button("minus", "刪除這個連線設定", "Delete This Connection", #selector(remove(_:)))
        duplicateButton = button("plus.square.on.square", "複製一份", "Duplicate", #selector(duplicate(_:)))
        let dragHint = NSTextField(labelWithString: tr("拖曳可調整順序", "Drag to reorder"))
        dragHint.font = .systemFont(ofSize: 11)
        dragHint.textColor = .secondaryLabelColor
        let listButtons = NSStackView(views: [button("plus", "新增連線設定", "Add a Connection", #selector(add(_:))),
                                              removeButton, duplicateButton, NSView(), dragHint])
        listButtons.spacing = 4
        let left = NSStackView(views: [scroll, listButtons])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        scroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        left.widthAnchor.constraint(equalToConstant: 230).isActive = true

        buildForm()

        let openInEditor = NSButton(title: tr("用文字編輯器開啟…", "Open in Text Editor…"), target: self, action: #selector(openInEditor(_:)))
        let cancel = NSButton(title: tr("取消", "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: tr("儲存", "Save"), target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let actions = NSStackView(views: [openInEditor, spacer, cancel, saveButton])

        let right = NSView()
        form.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.stringValue = tr("按左下角的 ＋ 新增一個連線設定。", "Click ＋ at the bottom left to add a connection.")
        right.addSubview(form)
        right.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            form.topAnchor.constraint(equalTo: right.topAnchor),
            form.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: right.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: right.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: right.widthAnchor, constant: -40),
        ])

        let columns = NSStackView(views: [left, right])
        columns.spacing = 16
        columns.alignment = .top
        left.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true

        let stack = NSStackView(views: [columns, actions])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            columns.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        columns.setContentHuggingPriority(.init(1), for: .vertical)
    }

    private func buildForm() {
        let rows: [(String, String, WritableKeyPath<HostFields, String>, String)] = [
            (tr("名稱（Host）", "Name (Host)"), tr("連線時用的名稱，例如 web；可以有多個，用空格分開，也可以是 *.example.com 這樣的樣式",
                                                  "The name to connect with, such as web; several separated by spaces, or a pattern such as *.example.com"),
             \.patterns, "web"),
            (tr("主機位址（HostName）", "Address (HostName)"), tr("伺服器的網域名稱或 IP；空白時用上面的名稱", "The server’s domain name or IP; the name above when empty"),
             \.hostName, "example.com / 192.168.1.10"),
            (tr("帳號（User）", "User"), tr("登入的帳號；空白時用這台 Mac 的帳號名稱", "The account to sign in as; this Mac’s account name when empty"),
             \.user, NSUserName()),
            (tr("連接埠（Port）", "Port"), tr("空白時是 22", "22 when empty"), \.port, "22"),
            (tr("金鑰檔（IdentityFile）", "Key File (IdentityFile)"), tr("登入用的私密金鑰；空白時用預設的金鑰或 ssh-agent",
                                                                       "The private key to sign in with; the default keys or ssh-agent when empty"),
             \.identityFile, "~/.ssh/id_ed25519"),
            (tr("跳板主機（ProxyJump）", "Jump Host (ProxyJump)"), tr("先連到這台再轉過去，例如 bastion 或 user@gateway",
                                                                      "Go through this host first, such as bastion or user@gateway"),
             \.proxyJump, tr("選填", "optional")),
            (tr("連線後的遠端資料夾", "Server Folder to Start In"),
             tr("連線後 SSH 和 SFTP 都從這個資料夾開始，例如 /var/www 或 ~/site；空白時回到上次看的資料夾",
                "SSH and SFTP start in this folder once connected, such as /var/www or ~/site; the folder last seen there when empty"),
             \.startFolder, tr("選填，例如 /var/www", "optional, e.g. /var/www")),
            (tr("SFTP 本機資料夾", "Folder on This Mac (SFTP)"),
             tr("連線後 SFTP 左側（本機）切到這個資料夾，可搭配同步瀏覽", "The left (this Mac) side of SFTP goes to this folder once connected; handy with synchronized browsing"),
             \.localFolder, tr("選填，例如 ~/Sites/web", "optional, e.g. ~/Sites/web")),
        ]
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for (label, help, path, placeholder) in rows {
            let field = NSTextField()
            field.placeholderString = placeholder
            field.toolTip = help
            field.delegate = self
            fields[path] = field
            let title = NSTextField(labelWithString: label)
            title.toolTip = help
            var cell: NSView = field
            if path == \.identityFile || path == \.localFolder {
                let choose = NSButton(title: tr("選擇…", "Choose…"), target: self,
                                      action: path == \.identityFile ? #selector(chooseKey(_:)) : #selector(chooseLocalFolder(_:)))
                choose.controlSize = .small
                let row = NSStackView(views: [field, choose])
                row.spacing = 6
                cell = row
            }
            grid.addRow(with: [title, cell])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let otherTitle = NSTextField(labelWithString: tr("其他設定", "Other Settings"))
        otherTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let otherHint = NSTextField(wrappingLabelWithString: tr("每行一個，例如 ForwardAgent yes、LocalForward 8080 localhost:80、ServerAliveInterval 30；以 # 開頭的是註解。原樣保留在檔案裡。",
                                                                "One per line, such as ForwardAgent yes, LocalForward 8080 localhost:80, ServerAliveInterval 30; lines starting with # are comments. Kept in the file as written."))
        otherHint.font = .systemFont(ofSize: 11)
        otherHint.textColor = .secondaryLabelColor
        otherText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        otherText.isAutomaticQuoteSubstitutionEnabled = false
        otherText.isAutomaticDashSubstitutionEnabled = false
        otherText.isAutomaticTextReplacementEnabled = false
        otherText.isAutomaticSpellingCorrectionEnabled = false
        otherText.isContinuousSpellCheckingEnabled = false
        otherText.delegate = self
        otherView.borderType = .bezelBorder
        otherView.setContentHuggingPriority(.init(1), for: .vertical)
        fileLabel.font = .systemFont(ofSize: 11)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle

        for view in [grid, otherTitle, otherHint, otherView, fileLabel] as [NSView] { form.addArrangedSubview(view) }
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.setCustomSpacing(14, after: grid)
        for view in [otherHint, otherView] { view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        otherView.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        for (path, field) in fields {
            let narrow = path == \.identityFile || path == \.localFolder
            field.widthAnchor.constraint(equalToConstant: narrow ? 270 : 340).isActive = true
        }
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let (file, index) = items[row]
        let fields = file.entry(at: index)?.fields ?? HostFields()
        let icon = NSImageView(image: NSImage(systemSymbolName: fields.isPattern ? "asterisk.circle" : "server.rack", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: fields.patterns.isEmpty ? tr("（未命名）", "(untitled)") : fields.patterns)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        var summary = fields.isPattern ? tr("套用到符合的主機", "Applies to the hosts it matches")
            : (fields.user.isEmpty ? "" : fields.user + "@") + (fields.hostName.isEmpty ? fields.aliases.first ?? "" : fields.hostName)
                + (fields.port.isEmpty ? "" : ":" + fields.port)
        if file !== files.first { summary += " · " + file.url.lastPathComponent }
        let detail = NSTextField(labelWithString: summary)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for label in [name, detail] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let cell = NSStackView(views: [icon, text])
        cell.spacing = 6
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelected() }

    // MARK: Dragging into order

    private static let rowType = NSPasteboard.PasteboardType("com.jeff.menussh.host-row")

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    /// Where a row dropped above `row` goes in its file: before the block at that row, or after
    /// the file's last block (nil). Nil overall when that's in another file, which isn't allowed.
    private func destination(of source: Int, above row: Int) -> (file: ConfigFile, before: Int?)? {
        let file = items[source].file
        if row < items.count, items[row].file === file { return (file, items[row].index) }
        if row > 0, items[row - 1].file === file { return (file, nil) }
        return nil
    }

    private func draggedRow(_ info: NSDraggingInfo) -> Int? {
        info.draggingPasteboard.string(forType: Self.rowType).flatMap(Int.init).flatMap { $0 < items.count ? $0 : nil }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above, let source = draggedRow(info), row != source, row != source + 1,
              destination(of: source, above: row) != nil else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let source = draggedRow(info), let (file, before) = destination(of: source, above: row) else { return false }
        let moved = file.moveHost(at: items[source].index, before: before)
        rebuildItems()
        table.reloadData()
        if let newRow = items.firstIndex(where: { $0.file === file && $0.index == moved }) {
            table.selectRowIndexes([newRow], byExtendingSelection: false)
            table.scrollRowToVisible(newRow)
        }
        showSelected()
        warnIfDefaultsMovedUp(file: file, at: moved)
        return true
    }

    /// ssh takes the first value it finds, so a pattern block (Host *) above named hosts overrides
    /// their own settings: said once it happens.
    private func warnIfDefaultsMovedUp(file: ConfigFile, at index: Int) {
        guard let moved = file.entry(at: index)?.fields, moved.isPattern,
              file.hostIndices.contains(where: { $0 > index && file.entry(at: $0)?.fields.isPattern == false }) else { return }
        let alert = NSAlert()
        alert.messageText = tr("「\(moved.patterns)」現在在其他主機上方", "“\(moved.patterns)” Is Now Above Other Hosts")
        alert.informativeText = tr("ssh 對同一個設定採用第一個找到的值，所以這裡的設定會蓋過下方主機自己的設定。預設值通常放在最後面。",
                                   "ssh uses the first value it finds for each setting, so the settings here now override those of the hosts below. Defaults usually go last.")
        alert.runModal()
    }

    private var selected: (file: ConfigFile, index: Int)? {
        let row = table.selectedRow
        return row >= 0 && row < items.count ? items[row] : nil
    }

    /// Fills the form with the block selected.
    private func showSelected() {
        removeButton.isEnabled = selected != nil
        duplicateButton.isEnabled = selected != nil
        form.isHidden = selected == nil
        emptyLabel.isHidden = selected != nil
        guard let (file, index) = selected, let entry = file.entry(at: index) else { return }
        filling = true
        let values = entry.fields
        for (path, field) in fields { field.stringValue = values[keyPath: path] }
        otherText.string = values.other
        filling = false
        fileLabel.stringValue = tr("在 ", "In ") + (file.url.path as NSString).abbreviatingWithTildeInPath
            + (file.changed ? tr("（尚未儲存）", " (not saved yet)") : "")
    }

    /// The form's values, written into the block selected as they're typed.
    private func commit() {
        guard !filling, let (file, index) = selected else { return }
        var values = HostFields()
        for (path, field) in fields { values[keyPath: path] = field.stringValue.trimmingCharacters(in: .whitespaces) }
        values.other = otherText.string
        file.update(at: index, values)
        table.reloadData(forRowIndexes: [table.selectedRow], columnIndexes: [0])
        fileLabel.stringValue = tr("在 ", "In ") + (file.url.path as NSString).abbreviatingWithTildeInPath
            + (file.changed ? tr("（尚未儲存）", " (not saved yet)") : "")
    }

    func controlTextDidChange(_ notification: Notification) { commit() }
    func textDidChange(_ notification: Notification) { commit() }

    // MARK: Actions

    @objc private func add(_ sender: Any?) {
        insert(HostFields(patterns: uniqueName("new-host")))
    }

    @objc private func duplicate(_ sender: Any?) {
        guard let (file, index) = selected, var values = file.entry(at: index)?.fields else { return }
        values.patterns = uniqueName((values.aliases.first ?? "host") + "-copy")
        insert(values)
    }

    /// Adds a block to ~/.ssh/config, selects it, and puts the cursor in its name.
    private func insert(_ values: HostFields) {
        guard let main = files.first else { return }
        let index = main.add(values)
        rebuildItems()
        table.reloadData()
        if let row = items.firstIndex(where: { $0.file === main && $0.index == index }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        showSelected()
        panel.makeFirstResponder(fields[\.patterns])
        fields[\.patterns]?.currentEditor()?.selectAll(nil)
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(allAliases)
        var name = base, n = 2
        while taken.contains(name) { name = base + "-\(n)"; n += 1 }
        return name
    }

    private var allAliases: [String] {
        items.flatMap { $0.file.entry(at: $0.index)?.fields.aliases ?? [] }
    }

    @objc private func remove(_ sender: Any?) {
        guard let (file, index) = selected, let values = file.entry(at: index)?.fields else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("要刪除「\(values.patterns)」的連線設定嗎？", "Delete the Connection “\(values.patterns)”?")
        alert.informativeText = tr("按「儲存」後才會從 \((file.url.path as NSString).abbreviatingWithTildeInPath) 移除。",
                                   "It’s taken out of \((file.url.path as NSString).abbreviatingWithTildeInPath) when you save.")
        alert.addButton(withTitle: tr("刪除", "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let row = table.selectedRow
        file.remove(at: index)
        rebuildItems()
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes([min(row, items.count - 1)], byExtendingSelection: false) }
        showSelected()
    }

    @objc private func chooseKey(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = SSHConfig.defaultURL.deletingLastPathComponent()
        panel.message = tr("選擇私密金鑰檔（不是 .pub 的那個）", "Choose the private key file (not the .pub one)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fields[\.identityFile]?.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        commit()
    }

    @objc private func chooseLocalFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        let current = fields[\.localFolder]?.stringValue ?? ""
        panel.directoryURL = current.isEmpty ? FileManager.default.homeDirectoryForCurrentUser
                                             : URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fields[\.localFolder]?.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        commit()
    }

    @objc private func openInEditor(_ sender: Any?) {
        guard confirmDiscard() else { return }
        close()
        let url = SSHConfig.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Checks every block that changed, then writes the files that changed.
    @objc private func save(_ sender: Any?) {
        if let problem = validate() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("還不能儲存", "Can’t Save Yet")
            alert.informativeText = problem
            alert.runModal()
            return
        }
        do {
            for file in files { try file.save() }
            saved = true
            close()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = tr("無法儲存設定檔", "Couldn’t Save the Config File")
            alert.runModal()
        }
    }

    private func validate() -> String? {
        var seen: [String: Int] = [:]
        for (row, item) in items.enumerated() {
            guard let values = item.file.entry(at: item.index)?.fields else { continue }
            func problem(_ text: String) -> String {
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
                showSelected()
                return text
            }
            if values.patterns.trimmingCharacters(in: .whitespaces).isEmpty {
                return problem(tr("有一個連線設定沒有名稱。", "A connection has no name."))
            }
            if !values.port.isEmpty, Int(values.port).map({ (1...65535).contains($0) }) != true {
                return problem(tr("「\(values.patterns)」的連接埠要是 1 到 65535 的數字。", "The port of “\(values.patterns)” must be a number from 1 to 65535."))
            }
            if values.hostName.contains(where: \.isWhitespace) {
                return problem(tr("「\(values.patterns)」的主機位址不能有空格。", "The address of “\(values.patterns)” can’t contain spaces."))
            }
            for alias in values.aliases {
                if seen[alias] != nil {
                    return problem(tr("「\(alias)」這個名稱用了兩次；ssh 只會用第一個。", "The name “\(alias)” is used twice; ssh would only use the first."))
                }
                seen[alias] = row
            }
        }
        return nil
    }

    @objc private func cancel(_ sender: Any?) {
        guard confirmDiscard() else { return }
        close()
    }

    /// Asks before throwing away changes; true to go on.
    private func confirmDiscard() -> Bool {
        guard files.contains(where: \.changed) else { return true }
        let alert = NSAlert()
        alert.messageText = tr("要儲存對連線設定的變更嗎？", "Save the Changes to the Connections?")
        alert.addButton(withTitle: tr("儲存", "Save"))
        alert.addButton(withTitle: tr("不儲存", "Don’t Save"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save(nil)
            return false   // save() closes the window once it's written
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func close() {
        NSApp.stopModal()
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmDiscard() else { return false }
        NSApp.stopModal()
        return true
    }
}
