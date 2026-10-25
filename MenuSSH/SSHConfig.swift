import Foundation

/// A Host from ~/.ssh/config, with what ssh would use to reach it.
struct SSHHost: Equatable {
    let alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?

    /// Where ssh would connect: user@hostname:port, as far as the config says.
    var summary: String {
        (user.map { "\($0)@" } ?? "") + (hostName ?? alias) + (port.map { ":\($0)" } ?? "")
    }
}

/// Reads ~/.ssh/config the way ssh does: for each Host, every block whose patterns match it
/// applies, in file order, and the first value found for a setting wins, so `Host *` defaults
/// further down fill only what's left. Include lines are followed; Match blocks are skipped.
enum SSHConfig {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// The Hosts named outright (not patterns such as `*.example.com`), in the order they appear.
    static func hosts(in url: URL = defaultURL) -> [SSHHost] {
        let blocks = read(url, depth: 0)
        var aliases: [String] = []
        for block in blocks {
            for pattern in block.patterns where !pattern.contains(where: { "*?!".contains($0) }) && !aliases.contains(pattern) {
                aliases.append(pattern)
            }
        }
        return aliases.map { alias in
            var host = SSHHost(alias: alias)
            var identitySet = false
            for block in blocks where block.matches(alias) {
                for (key, value) in block.settings {
                    switch key {
                    case "hostname" where host.hostName == nil: host.hostName = value
                    case "user" where host.user == nil: host.user = value
                    case "port" where host.port == nil: host.port = Int(value)
                    // A path with %-tokens such as %h is left to ssh, which fills them in: the form
                    // shows none rather than a later default ssh wouldn't use.
                    case "identityfile" where !identitySet:
                        identitySet = true
                        if !value.contains("%") { host.identityFile = value }
                    default: break
                    }
                }
            }
            return host
        }
    }

    private struct Block {
        var patterns: [String]
        var settings: [(key: String, value: String)] = []

        /// ssh's rule: some pattern matches and no negated one (!pattern) does.
        func matches(_ alias: String) -> Bool {
            var matched = false
            for pattern in patterns {
                if pattern.hasPrefix("!") {
                    if fnmatch(String(pattern.dropFirst()), alias, 0) == 0 { return false }
                } else if fnmatch(pattern, alias, 0) == 0 {
                    matched = true
                }
            }
            return matched
        }
    }

    /// The blocks in a config file and the files it includes. Lines before the first Host
    /// apply to every host, as a block matching "*".
    private static func read(_ url: URL, depth: Int) -> [Block] {
        guard depth < 8, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var blocks = [Block(patterns: ["*"])]
        var skipping = false   // inside a Match block
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // "Key value", "Key=value" or "Key = value"; values may be quoted.
            guard let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { continue }
            let key = trimmed[..<split].lowercased()
            var value = trimmed[split...].trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            switch key {
            case "host":
                blocks.append(Block(patterns: value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)))
                skipping = false
            case "match":
                skipping = true
            case "include":
                for path in value.split(separator: " ") {
                    for file in expand(String(path)) {
                        let included = read(file, depth: depth + 1)
                        // An included file's blocks sit in place; its leading settings belong to the block it's in.
                        if var current = blocks.popLast(), let first = included.first {
                            current.settings += first.settings
                            blocks.append(current)
                        }
                        blocks += included.dropFirst()
                    }
                }
            default:
                if !skipping, var current = blocks.popLast() {
                    current.settings.append((key, value))
                    blocks.append(current)
                }
            }
        }
        return blocks
    }

    /// An Include path: ~ for home, relative ones in ~/.ssh, wildcards expanded.
    private static func expand(_ path: String) -> [URL] {
        var full = (path as NSString).expandingTildeInPath
        if !full.hasPrefix("/") { full = (defaultURL.deletingLastPathComponent().path as NSString).appendingPathComponent(full) }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(full, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { URL(fileURLWithPath: String(cString: $0)) } }
    }
}
