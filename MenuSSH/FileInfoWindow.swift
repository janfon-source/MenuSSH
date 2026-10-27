import AppKit

/// What the info window was asked to change: a new name, new permissions (and whether a folder's
/// contents take them too). Nil for what stays as it was.
struct FileInfoChanges {
    var name: String?
    var permissions: Int?
    var recursive = false
}

/// A window with a file or folder's facts, on this Mac or the server: its name and permissions can
/// be changed, the rest is shown. A folder's size is worked out after it opens. It only collects
/// the changes; whoever opened it makes them, as the file is on one side or the other.
final class FileInfoWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let panel: NSPanel
    private let file: RemoteFile
    private let nameField = NSTextField()
    private let octalField = NSTextField()
    private let sizeLabel = NSTextField(labelWithString: "")
    private var boxes: [NSButton] = []   // owner rwx, group rwx, others rwx
    private let recursiveBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let originalMode: Int
    private(set) var changes: FileInfoChanges?

    /// `details`: more rows to show, as (title, value). `measure` works out a folder's size in the
    /// background and hands it back (nil if it can't be told).
    init(file: RemoteFile, place: String, details: [(String, String)],
         measure: ((@escaping (Int64?) -> Void) -> Void)?) {
        self.file = file
        originalMode = Self.mode(of: file.permissions)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = file.isFolder ? tr("資料夾資訊：\(file.name)", "Folder Info: \(file.name)")
                                    : tr("檔案資訊：\(file.name)", "File Info: \(file.name)")
        panel.delegate = self
        build(place: place, details: details)
        if file.isFolder, let measure {
            sizeLabel.stringValue = tr("計算中…", "Working it out…")
            measure { [weak self] size in
                self?.sizeLabel.stringValue = size.map { Self.describe($0) } ?? tr("無法得知", "Can’t be told")
            }
        }
    }

    /// Shows the window until it's closed; the changes asked for, if any, are then in `changes`.
    func run() {
        panel.center()
        panel.makeFirstResponder(nameField)
        NSApp.runModal(for: panel)
    }

    // MARK: Layout

    private func build(place: String, details: [(String, String)]) {
        let icon = NSImageView(image: FileList.icon(for: file))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        nameField.stringValue = file.name
        nameField.font = .systemFont(ofSize: 14, weight: .medium)
        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let top = NSStackView(views: [icon, nameField])
        top.spacing = 10

        let kind: String
        switch file.kind {
        case .folder: kind = tr("資料夾", "Folder")
        case .link: kind = tr("替身（符號連結）", "Symbolic link")
        case .file: kind = tr("檔案", "File")
        case .other: kind = tr("其他", "Other")
        }
        sizeLabel.stringValue = file.isFolder ? "—" : Self.describe(file.size)
        sizeLabel.isSelectable = true
        var rows: [(String, NSView)] = [
            (tr("種類", "Kind"), label(kind)),
            (tr("位置", "Where"), label(place, selectable: true)),
            (tr("大小", "Size"), sizeLabel),
        ]
        rows += details.map { ($0.0, label($0.1, selectable: true)) }
        let facts = NSGridView(views: rows.map { [label($0.0, secondary: true), $0.1] })
        facts.rowSpacing = 6
        facts.columnSpacing = 10
        facts.column(at: 0).xPlacement = .trailing

        // Permissions: a box for each of read, write and run, for the owner, the group and everyone
        // else; the number beside them follows, and can be typed instead.
        let header = [NSView()] + [tr("讀取", "Read"), tr("寫入", "Write"), tr("執行", "Run")].map { label($0, secondary: true) as NSView }
        var grid = [header]
        for (row, who) in [tr("擁有者", "Owner"), tr("群組", "Group"), tr("其他人", "Everyone")].enumerated() {
            var line: [NSView] = [label(who, secondary: true)]
            for column in 0..<3 {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(boxChanged(_:)))
                box.state = originalMode & Self.bit(row, column) != 0 ? .on : .off
                boxes.append(box)
                line.append(box)
            }
            grid.append(line)
        }
        let permissions = NSGridView(views: grid)
        permissions.rowSpacing = 4
        permissions.columnSpacing = 16
        permissions.column(at: 0).xPlacement = .trailing
        for column in 1...3 { permissions.column(at: column).xPlacement = .center }
        octalField.stringValue = String(originalMode, radix: 8)
        octalField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        octalField.alignment = .center
        octalField.delegate = self
        octalField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let permissionRow = NSStackView(views: [permissions, octalField])
        permissionRow.spacing = 20
        permissionRow.alignment = .centerY

        recursiveBox.title = tr("也套用到資料夾內所有項目", "Apply to everything in the folder too")
        recursiveBox.isHidden = !file.isFolder

        let cancel = NSButton(title: tr("取消", "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: tr("套用", "Apply"), target: self, action: #selector(apply(_:)))
        apply.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, apply])

        let permissionTitle = label(tr("權限", "Permissions"))
        permissionTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let stack = NSStackView(views: [top, line(), facts, line(), permissionTitle, permissionRow, recursiveBox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            facts.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40),
        ])
    }

    private func label(_ text: String, secondary: Bool = false, selectable: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = selectable
        if secondary { label.textColor = .secondaryLabelColor }
        label.preferredMaxLayoutWidth = 300
        return label
    }

    private func line() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return box
    }

    // MARK: Permissions

    /// The bit for a box: owner, group, others by row; read, write, run by column.
    private static func bit(_ row: Int, _ column: Int) -> Int { 1 << ((2 - row) * 3 + (2 - column)) }

    /// `drwxr-xr-x` as a number (0o755); an s or t still counts as x.
    static func mode(of permissions: String) -> Int {
        let letters = Array(permissions.dropFirst().prefix(9))
        var mode = 0
        for (i, letter) in letters.enumerated() where letter != "-" && letter != "S" && letter != "T" {
            mode |= 1 << (8 - i)
        }
        return mode
    }

    private var boxMode: Int {
        var mode = 0
        for row in 0..<3 { for column in 0..<3 where boxes[row * 3 + column].state == .on { mode |= Self.bit(row, column) } }
        return mode
    }

    @objc private func boxChanged(_ sender: NSButton) {
        octalField.stringValue = String(boxMode, radix: 8)
    }

    /// A number typed: the boxes follow, once it's a real one (three octal digits).
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === octalField,
              let mode = Int(octalField.stringValue, radix: 8), (0...0o777).contains(mode) else { return }
        for row in 0..<3 { for column in 0..<3 { boxes[row * 3 + column].state = mode & Self.bit(row, column) != 0 ? .on : .off } }
    }

    // MARK: Closing

    @objc private func apply(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else {
            NSSound.beep()
            panel.makeFirstResponder(nameField)
            return
        }
        let mode = boxMode
        var changes = FileInfoChanges()
        if name != file.name { changes.name = name }
        if mode != originalMode || (recursiveBox.state == .on && file.isFolder) {
            changes.permissions = mode
            changes.recursive = recursiveBox.state == .on && file.isFolder
        }
        self.changes = changes.name == nil && changes.permissions == nil ? nil : changes
        close()
    }

    @objc private func cancel(_ sender: Any?) {
        changes = nil
        close()
    }

    private func close() {
        NSApp.stopModal()
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.stopModal()
        return true
    }

    // MARK: Text

    /// 12.3 MB (12,345,678 bytes).
    static func describe(_ bytes: Int64) -> String {
        let short = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let exact = NumberFormatter.localizedString(from: NSNumber(value: bytes), number: .decimal)
        return short + tr("（\(exact) 位元組）", " (\(exact) bytes)")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
