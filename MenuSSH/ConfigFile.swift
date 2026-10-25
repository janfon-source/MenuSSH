import Foundation

/// What the connection settings window edits in a Host block: the usual settings in fields of
/// their own, and every other line as written.
struct HostFields: Equatable {
    var patterns = ""
    var hostName = ""
    var user = ""
    var port = ""
    var identityFile = ""
    var proxyJump = ""
    /// Where MenuSSH starts on the server once connected, and on this Mac in SFTP mode. ssh has no
    /// such settings (and refuses names it doesn't know), so they're kept as comments in the block:
    /// `# MenuSSH StartFolder /var/www`, which ssh and other tools pass over.
    var startFolder = ""
    var localFolder = ""
    /// The block's other lines (more settings, comments), as written.
    var other = ""

    /// MenuSSH's own settings, kept as comments.
    static let appKeys: [(name: String, path: WritableKeyPath<HostFields, String>)] = [
        ("StartFolder", \.startFolder), ("LocalFolder", \.localFolder),
    ]

    /// The settings with fields, by their ssh_config names.
    static let keys: [(name: String, path: WritableKeyPath<HostFields, String>)] = [
        ("HostName", \.hostName), ("User", \.user), ("Port", \.port), ("IdentityFile", \.identityFile), ("ProxyJump", \.proxyJump),
    ]

    /// Names written outright, not patterns such as `*.example.com`.
    var aliases: [String] { patterns.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.contains(where: { "*?!".contains($0) }) } }
    var isPattern: Bool { aliases.isEmpty }
}

/// A Host block as it is in the file: the comment lines just above it, its Host line, and the
/// lines after it up to the next Host or Match.
struct HostEntry {
    var leading: [String] = []
    var header: String
    var body: [String]

    var patterns: [String] {
        let words = Self.split(header)
        return Array(words.dropFirst())
    }

    /// The fields: the first value of each usual setting (ssh uses the first), and the rest of the
    /// lines, without the blank lines at the end that separate it from the next block.
    var fields: HostFields {
        var fields = HostFields(patterns: patterns.joined(separator: " "))
        var others: [String] = []
        var seen = Set<String>()
        for line in body.prefix(body.count - trailingBlanks) {
            if let (key, value) = Self.appSetting(line), let known = HostFields.appKeys.first(where: { $0.name.lowercased() == key }) {
                fields[keyPath: known.path] = value
            } else if let (key, value) = Self.setting(line), let known = HostFields.keys.first(where: { $0.name.lowercased() == key }),
               !seen.contains(key) {
                seen.insert(key)
                fields[keyPath: known.path] = value
            } else {
                others.append(line)
            }
        }
        // Shown without the block's indentation, which goes back on when it's written.
        let indent = self.indent
        fields.other = others.map { $0.hasPrefix(indent) ? String($0.dropFirst(indent.count)) : $0 }.joined(separator: "\n")
        return fields
    }

    private var trailingBlanks: Int {
        body.reversed().prefix { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// The indentation the block's settings use (four spaces if none).
    private var indent: String {
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let prefix = String(line.prefix { $0 == " " || $0 == "\t" })
            if !prefix.isEmpty { return prefix }
        }
        return "    "
    }

    /// Writes the fields back. Nothing changes if they're the same, so a block only opened stays
    /// as it was, byte for byte; a changed one is written afresh: its Host line, the usual settings
    /// in a fixed order, then the other lines.
    mutating func apply(_ new: HostFields) {
        let old = fields
        guard new != old else { return }
        let indent = self.indent
        let blanks = max(trailingBlanks, 1)
        let patterns = new.patterns.split(whereSeparator: \.isWhitespace).map(String.init)
        if patterns != self.patterns { header = "Host " + patterns.joined(separator: " ") }
        var lines: [String] = []
        for key in HostFields.keys {
            let value = new[keyPath: key.path].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { lines.append(indent + key.name + " " + Self.quoted(value)) }
        }
        for key in HostFields.appKeys {
            let value = new[keyPath: key.path].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { lines.append(indent + "# MenuSSH " + key.name + " " + value) }
        }
        var others = new.other.components(separatedBy: "\n")
        while let last = others.last, last.trimmingCharacters(in: .whitespaces).isEmpty { others.removeLast() }
        lines += others.map { $0.isEmpty || $0.hasPrefix(" ") || $0.hasPrefix("\t") ? $0 : indent + $0 }
        body = lines + Array(repeating: "", count: blanks)
    }

    static func new(_ fields: HostFields) -> HostEntry {
        var entry = HostEntry(header: "Host " + fields.patterns, body: [""])
        entry.apply(fields)
        return entry
    }

    /// The words of a line, with quoted values kept whole.
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for c in line.trimmingCharacters(in: .whitespaces) {
            if c == "\"" { quoted.toggle() }
            else if !quoted && (c == " " || c == "\t" || (c == "=" && words.isEmpty)) {
                if !current.isEmpty { words.append(current); current = "" }
            } else { current.append(c) }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// "Key value", "Key=value" or "Key = value": the key in lower case and the value unquoted.
    static func setting(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
        var value = trimmed[split...].trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        return (trimmed[..<split].lowercased(), value)
    }

    /// `# MenuSSH StartFolder /var/www`: the key in lower case and the rest of the line.
    static func appSetting(_ line: String) -> (String, String)? {
        var rest = line.trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("#") else { return nil }
        rest = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("MenuSSH ") else { return nil }
        rest = rest.dropFirst("MenuSSH ".count).trimmingCharacters(in: .whitespaces)
        guard let space = rest.firstIndex(of: " ") else { return nil }
        let value = rest[space...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : (rest[..<space].lowercased(), value)
    }

    static func quoted(_ value: String) -> String {
        value.contains(where: { $0 == " " || $0 == "\t" }) ? "\"" + value + "\"" : value
    }
}

/// An ssh config file, kept as it is written: lines that aren't Host blocks (the settings before
/// the first Host, Match blocks, comments) are kept as text, and each Host block as a HostEntry,
/// so writing it back changes only what was edited.
final class ConfigFile {
    enum Section {
        case text([String])
        case host(HostEntry)
    }

    let url: URL
    var sections: [Section] = []
    private var endsWithNewline = true
    private(set) var changed = false

    /// A file that isn't there yet reads as empty.
    init(url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        endsWithNewline = text.isEmpty || text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        parse(lines)
    }

    private func parse(_ lines: [String]) {
        var text: [String] = []
        var entry: HostEntry?
        func finish() {
            if let current = entry { sections.append(.host(current)) } else if !text.isEmpty { sections.append(.text(text)) }
            entry = nil
            text = []
        }
        for line in lines {
            let key = HostEntry.setting(line)?.0
            if key == "host" || key == "match" {
                // Comments right above, not indented and with no blank line between, belong to it.
                var previous = entry?.body ?? text
                var leading: [String] = []
                while let last = previous.last, last.hasPrefix("#") {
                    leading.insert(previous.removeLast(), at: 0)
                }
                if entry != nil { entry?.body = previous } else { text = previous }
                finish()
                if key == "host" {
                    entry = HostEntry(leading: leading, header: line, body: [])
                } else {
                    text = leading + [line]   // Match blocks are kept as they are
                }
            } else if entry != nil {
                entry?.body.append(line)
            } else {
                text.append(line)
            }
        }
        finish()
    }

    var lines: [String] {
        sections.flatMap { section -> [String] in
            switch section {
            case .text(let lines): return lines
            case .host(let entry): return entry.leading + [entry.header] + entry.body
            }
        }
    }

    var hostIndices: [Int] {
        sections.indices.filter { if case .host = sections[$0] { return true } else { return false } }
    }

    func entry(at index: Int) -> HostEntry? {
        if case .host(let entry) = sections[index] { return entry }
        return nil
    }

    func update(at index: Int, _ fields: HostFields) {
        guard case .host(var entry) = sections[index] else { return }
        let before = entry.leading + [entry.header] + entry.body
        entry.apply(fields)
        if entry.leading + [entry.header] + entry.body != before {
            sections[index] = .host(entry)
            changed = true
        }
    }

    /// Adds a block, returning where it went: before the first `Host *`, since ssh takes the first
    /// value it finds for a setting and the defaults there would otherwise win; or else at the end,
    /// after a blank line.
    @discardableResult
    func add(_ fields: HostFields) -> Int {
        let entry = HostEntry.new(fields)
        if let index = sections.firstIndex(where: { if case .host(let e) = $0 { return e.patterns == ["*"] } else { return false } }) {
            sections.insert(.host(entry), at: index)
            changed = true
            return index
        }
        if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
            sections.append(.text([""]))
        }
        sections.append(.host(entry))
        changed = true
        return sections.count - 1
    }

    func remove(at index: Int) {
        sections.remove(at: index)
        changed = true
    }

    /// Moves a Host block, with the comments above it, to just before the block at `target`, or
    /// with nil, to after the last Host (still ahead of any Match blocks that follow). Each block
    /// keeps a blank line after it. Returns where it went.
    @discardableResult
    func moveHost(at index: Int, before target: Int?) -> Int {
        guard case .host(var entry) = sections[index], target != index else { return index }
        func endsBlank(_ lines: [String]) -> Bool { lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true }
        if !endsBlank(entry.body) { entry.body.append("") }
        sections.remove(at: index)
        var place: Int
        if let target {
            place = target > index ? target - 1 : target
        } else {
            place = (hostIndices.last ?? -1) + 1
        }
        // The block ahead of it gets a blank line too, if it lacks one.
        if place > 0 {
            switch sections[place - 1] {
            case .host(var above):
                if !endsBlank(above.body) { above.body.append(""); sections[place - 1] = .host(above) }
            case .text(let lines):
                if !endsBlank(lines) { sections[place - 1] = .text(lines + [""]) }
            }
        }
        sections.insert(.host(entry), at: place)
        changed = true
        return place
    }

    /// The files named by Include lines, for their Hosts to be edited too.
    var includedFiles: [URL] {
        var urls: [URL] = []
        for line in lines {
            guard let (key, value) = HostEntry.setting(line), key == "include" else { continue }
            for path in value.split(separator: " ") { urls += Self.expand(String(path), base: url.deletingLastPathComponent()) }
        }
        return urls
    }

    private static func expand(_ path: String, base: URL) -> [URL] {
        var full = (path as NSString).expandingTildeInPath
        if !full.hasPrefix("/") { full = (base.path as NSString).appendingPathComponent(full) }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(full, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { URL(fileURLWithPath: String(cString: $0)) } }
    }

    /// The folders set for a Host in ~/.ssh/config (or a file it includes), if any.
    static func startFolders(for alias: String) -> (remote: String?, local: String?) {
        guard let main = try? ConfigFile(url: SSHConfig.defaultURL) else { return (nil, nil) }
        for file in [main] + main.includedFiles.compactMap({ try? ConfigFile(url: $0) }) {
            for index in file.hostIndices {
                guard let fields = file.entry(at: index)?.fields, fields.aliases.contains(alias) else { continue }
                return (fields.startFolder.isEmpty ? nil : fields.startFolder, fields.localFolder.isEmpty ? nil : fields.localFolder)
            }
        }
        return (nil, nil)
    }

    /// Files already copied aside this time the app has run.
    private static var backedUp = Set<String>()

    /// Writes the file back. The first time in a run, the file as it was is copied beside it
    /// (config → config.menussh-backup). A config that's a link (to a dotfiles folder, say) is
    /// written where it leads, so the link stays.
    func save() throws {
        guard changed else { return }
        let target = url.resolvingSymlinksInPath()
        let files = FileManager.default
        if files.fileExists(atPath: target.path), !Self.backedUp.contains(target.path) {
            let backup = target.appendingPathExtension("menussh-backup")
            try? files.removeItem(at: backup)
            try files.copyItem(at: target, to: backup)
            Self.backedUp.insert(target.path)
        }
        let permissions = (try? files.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let text = lines.joined(separator: "\n") + (endsWithNewline || lines.isEmpty ? "\n" : "")
        try Data(text.utf8).write(to: target, options: .atomic)
        try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        changed = false
    }
}
