import AppKit
import UniformTypeIdentifiers

/// What the two file lists, on this Mac and on the server, have in common: their columns, how a
/// row looks, and the order: folders first, then by the column chosen.
enum FileList {
    static func addColumns(to table: NSTableView, permissions: Bool = true) {
        // Narrow to start with, so all the columns fit even in half the window; the name column
        // takes whatever room is left over.
        var columns = [("name", 120.0, 80.0), ("size", 66.0, 44.0), ("modified", 118.0, 70.0)]
        if permissions { columns.append(("permissions", 84.0, 56.0)) }
        for (id, width, minWidth) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            column.minWidth = minWidth
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.style = .inset
        relabel(table)
    }

    /// Keeps the columns within the list's width: the name column takes what the others leave,
    /// and when that's too little for names, permissions go, then the date, then the size, coming
    /// back as the list widens. (Left to NSTableView, a list made narrower by a split view keeps
    /// its old width and the last columns are cut off.) Call once the table is in its scroll view.
    static func fitColumnsToWidth(_ table: NSTableView) {
        guard let clip = table.enclosingScrollView?.contentView else { return }
        // Done here instead, so the other columns keep the widths given them.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak table] _ in
            guard let table, let name = table.tableColumns.first else { return }
            let inset: CGFloat = table.effectiveStyle == .inset ? 24 : 0   // the inset style's margins
            func room() -> CGFloat {
                let shown = table.tableColumns.filter { !$0.isHidden }
                let others = shown.dropFirst().reduce(0) { $0 + $1.width }
                return clip.bounds.width - others - table.intercellSpacing.width * CGFloat(shown.count) - inset
            }
            for column in table.tableColumns.dropFirst() { column.isHidden = false }
            for id in ["permissions", "modified", "size"] where room() < 150 {
                table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))?.isHidden = true
            }
            name.width = max(name.minWidth, room())
        }
    }

    static func relabel(_ table: NSTableView) {
        let titles = ["name": tr("名稱", "Name"), "size": tr("大小", "Size"), "modified": tr("修改日期", "Modified"),
                      "permissions": tr("權限", "Permissions")]
        for column in table.tableColumns { column.title = titles[column.identifier.rawValue] ?? "" }
    }

    static func sorted(_ files: [RemoteFile], key: String, ascending: Bool, showHidden: Bool) -> [RemoteFile] {
        (showHidden ? files : files.filter { !$0.isHidden }).sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let order: ComparisonResult
            switch key {
            case "size": order = a.size == b.size ? .orderedSame : a.size < b.size ? .orderedAscending : .orderedDescending
            case "modified": order = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
            case "permissions": order = a.permissions.compare(b.permissions)
            default: order = .orderedSame
            }
            let result = order == .orderedSame ? a.name.localizedStandardCompare(b.name) : order
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static func cell(_ file: RemoteFile, _ column: String) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        switch column {
        case "name":
            let cell = NSTableCellView()
            let icon = NSImageView(image: self.icon(for: file))
            icon.translatesAutoresizingMaskIntoConstraints = false
            label.stringValue = file.name
            if file.isHidden { label.textColor = .secondaryLabelColor }
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case "size":
            label.stringValue = file.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
            label.alignment = .right
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case "modified":
            label.stringValue = file.modified.map { dateFormatter.string(from: $0) } ?? ""
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        default:
            label.stringValue = file.permissions
            label.textColor = .secondaryLabelColor
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        return label
    }

    private static var icons: [String: NSImage] = [:]

    static func icon(for file: RemoteFile) -> NSImage {
        let ext = (file.name as NSString).pathExtension.lowercased()
        let key = file.isFolder ? "/folder" : file.kind == .link ? "/link" : ext
        if let icon = icons[key] { return icon }
        let icon: NSImage
        switch file.kind {
        case .folder: icon = NSWorkspace.shared.icon(for: .folder)
        case .link: icon = NSWorkspace.shared.icon(for: .aliasFile)
        default: icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        icons[key] = icon
        return icon
    }

    /// How to get from one folder to another: so many levels up, then down through these.
    static func move(from old: String, to new: String) -> (up: Int, down: [String]) {
        let a = old.split(separator: "/").map(String.init), b = new.split(separator: "/").map(String.init)
        var common = 0
        while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
        return (a.count - common, Array(b[common...]))
    }

    /// The same move made from another folder, or nil if it climbs above the top.
    static func apply(_ move: (up: Int, down: [String]), to path: String) -> String? {
        var parts = path.split(separator: "/").map(String.init)
        guard move.up <= parts.count else { return nil }
        parts.removeLast(move.up)
        parts += move.down
        return "/" + parts.joined(separator: "/")
    }

    /// `drwxr-xr-x`, as `ls -l` writes a mode.
    static func permissions(_ mode: mode_t) -> String {
        let type: Character
        switch mode & S_IFMT {
        case S_IFDIR: type = "d"
        case S_IFLNK: type = "l"
        case S_IFREG: type = "-"
        default: type = "?"
        }
        var text = String(type)
        let bits: [(mode_t, Character)] = [(S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"), (S_IRGRP, "r"), (S_IWGRP, "w"),
                                           (S_IXGRP, "x"), (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x")]
        for (bit, letter) in bits { text.append(mode & bit != 0 ? letter : "-") }
        return text
    }

    /// A folder on this Mac, listed as the server's are. A link to a folder counts as a folder,
    /// and so does an app or other package, which opens rather than going in.
    static func listLocal(_ folder: URL) throws -> [RemoteFile] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).compactMap { name in
            let path = folder.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            var kind: RemoteFile.Kind
            switch info.st_mode & S_IFMT {
            case S_IFDIR: kind = .folder
            case S_IFREG: kind = .file
            case S_IFLNK:
                var target = stat()
                kind = stat(path, &target) == 0 && target.st_mode & S_IFMT == S_IFDIR ? .folder : .link
            default: kind = .other
            }
            if kind == .folder, !(name as NSString).pathExtension.isEmpty, NSWorkspace.shared.isFilePackage(atPath: path) {
                kind = .file
            }
            return RemoteFile(name: name, path: path, kind: kind, size: Int64(info.st_size),
                              modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                              permissions: permissions(info.st_mode), owner: "")
        }
    }
}
