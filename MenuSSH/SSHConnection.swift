import Foundation

struct SSHError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static let cancelled = SSHError(message: tr("已取消。", "Cancelled."))
}

/// A file or folder on the server, as sftp's `ls -l` lists it.
struct RemoteFile: Equatable {
    enum Kind { case file, folder, link, other }

    var name: String
    /// The full path on the server.
    var path: String
    var kind: Kind
    var size: Int64
    var modified: Date?
    /// As `ls -l` shows them: drwxr-xr-x.
    var permissions: String
    var owner: String

    var isFolder: Bool { kind == .folder }
    var isHidden: Bool { name.hasPrefix(".") }
}

/// What sftp's progress meter says about the file going across now.
struct TransferProgress {
    var file: String
    var percent: Int
    var transferred: String
    var rate: String
    var eta: String
}

/// Something running that Cancel can stop: the ssh, sftp or script process doing the work.
final class Cancellation {
    private let lock = NSLock()
    private var process: Process?
    private(set) var isCancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    fileprivate func attach(_ process: Process?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        return !isCancelled
    }
}

/// One server, reached with the Mac's own OpenSSH: one shared connection (ControlMaster) that
/// every sftp and ssh after it rides on, so a password is asked once and later steps start at
/// once. The connection is made with ssh asking for passwords through this app (SSH_ASKPASS, see
/// Askpass.swift); everything after it runs in batch mode and never stops to ask.
final class SSHConnection {
    /// A Host name from ~/.ssh/config, or user@host.
    let destination: String
    let port: Int?

    /// Where the shared connection's socket goes; %C is a hash of host, port and user, so the
    /// Terminal window opened for the same server finds it too.
    static let controlPath = "/tmp/menussh-%C"
    /// How long the shared connection stays up after its last use.
    static let persist = 1800

    /// Answers ssh's questions (a password, a new host key) while connecting; called on the main thread.
    var onPrompt: ((AskpassPrompt) -> String?)?

    /// For tests: more options for ssh and sftp, such as a config and key of their own.
    static var extraOptions: [String] = []

    init(destination: String, port: Int? = nil) {
        self.destination = destination
        self.port = port
    }

    /// "user@host:2222" typed into the host field: the port comes off the end.
    convenience init(typed: String) {
        let text = typed.trimmingCharacters(in: .whitespaces)
        if let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]), !text.contains("]") {
            self.init(destination: String(text[..<colon]), port: port)
        } else {
            self.init(destination: text)
        }
    }

    /// For the saved password and the remembered folder: the server as typed, with its port.
    var key: String { destination + (port.map { ":\($0)" } ?? "") }

    /// The options every ssh and sftp here starts with.
    var options: [String] {
        var options = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(Self.controlPath)",
            "-o", "ControlPersist=\(Self.persist)",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
        ]
        if let port { options += ["-o", "Port=\(port)"] }
        return Self.extraOptions + options
    }

    // MARK: Connecting

    /// Whether the shared connection is up (asks it over its socket; nothing goes to the server).
    var isConnected: Bool {
        (try? Self.run("/usr/bin/ssh", options + ["-O", "check", destination], timeout: 5).status) == 0
    }

    /// Makes the shared connection, unless it's up already. ssh asks for a password, a key's
    /// passphrase or whether to trust a new host key through `onPrompt`.
    func connect(_ cancellation: Cancellation) throws {
        if isConnected { return }
        let askpass = try Askpass.makeFolder()
        defer { try? FileManager.default.removeItem(at: askpass) }
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = Bundle.main.executablePath
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment[Askpass.folderVariable] = askpass.path
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        // -f: once signed in, ssh goes to the background, leaving the shared connection up.
        let result = try Self.run("/usr/bin/ssh", options + ["-f", "-N", destination], environment: environment,
                                  timeout: 900, cancellation: cancellation) { [weak self] in
            Askpass.answerPending(in: askpass) { prompt in
                DispatchQueue.main.sync { self?.onPrompt?(prompt) }
            }
        }
        if cancellation.isCancelled { throw SSHError.cancelled }
        guard result.status == 0 else { throw SSHError(message: Self.cleanError(result.error, status: result.status)) }
    }

    /// Stops the shared connection taking anything new; it ends once the Terminal windows riding
    /// on it close, which aren't cut off.
    func stop() {
        _ = try? Self.run("/usr/bin/ssh", options + ["-O", "stop", destination], timeout: 5)
    }

    /// Closes every shared connection this app left open (they outlive it by `persist` seconds),
    /// and with them any Terminal window riding on one. Only MenuSSH's own sockets are touched.
    static func closeAllShared(like pattern: String = controlPath) {
        let prefix = (pattern as NSString).lastPathComponent.replacingOccurrences(of: "%C", with: "")
        let folder = (pattern as NSString).deletingLastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        for name in names where name.hasPrefix(prefix) {
            let path = (folder as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { continue }
            // The host doesn't matter: the request goes over the socket named.
            _ = try? run("/usr/bin/ssh", ["-o", "ControlPath=" + path, "-O", "exit", "menussh"], timeout: 5)
        }
    }

    /// Closes the shared connection, and with it any Terminal window riding on it.
    func disconnect() {
        _ = try? Self.run("/usr/bin/ssh", options + ["-O", "exit", destination], timeout: 5)
    }

    // MARK: sftp

    /// Runs sftp commands one after another, stopping at the first that fails; returns what it printed.
    @discardableResult
    func sftp(_ commands: [String], _ cancellation: Cancellation) throws -> String {
        try connect(cancellation)
        let result = try Self.run("/usr/bin/sftp", ["-b", "-"] + options + [destination],
                                  input: commands.joined(separator: "\n") + "\n",
                                  environment: Self.utf8Environment, timeout: 120, cancellation: cancellation)
        if cancellation.isCancelled { throw SSHError.cancelled }
        guard result.status == 0 else { throw SSHError(message: Self.cleanError(result.error, status: result.status)) }
        return result.output
    }

    /// A folder's contents, and its full path (`nil` is the home folder, and `..` is resolved).
    func list(_ path: String?, _ cancellation: Cancellation) throws -> (path: String, files: [RemoteFile]) {
        let output = try sftp((path.map { ["cd " + Self.quote($0)] } ?? []) + ["pwd", "ls -lan"], cancellation)
        var folder = path ?? "/"
        var files: [RemoteFile] = []
        var inListing = false
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("sftp> ") {
                inListing = line.hasPrefix("sftp> ls")
            } else if line.hasPrefix("Remote working directory: ") {
                folder = String(line.dropFirst("Remote working directory: ".count))
            } else if inListing, var file = Self.parse(line), file.name != ".", file.name != ".." {
                file.path = Self.join(folder, file.name)
                files.append(file)
            }
        }
        return (folder, files)
    }

    /// Whether `path` is a folder: cd into it works.
    func isFolder(_ path: String, _ cancellation: Cancellation) -> Bool {
        (try? sftp(["cd " + Self.quote(path)], cancellation)) != nil
    }

    func makeFolder(_ path: String, _ cancellation: Cancellation) throws {
        try sftp(["mkdir " + Self.quote(path)], cancellation)
    }

    func rename(_ path: String, to newPath: String, _ cancellation: Cancellation) throws {
        try sftp(["rename " + Self.quote(path) + " " + Self.quote(newPath)], cancellation)
    }

    /// Deletes files, and folders with everything in them. sftp can only remove empty folders, so
    /// those go with `rm -rf` in the server's shell.
    func delete(_ files: [RemoteFile], _ cancellation: Cancellation) throws {
        let plain = files.filter { !$0.isFolder }
        if !plain.isEmpty { try sftp(plain.map { "rm " + Self.quote($0.path) }, cancellation) }
        let folders = files.filter(\.isFolder)
        if !folders.isEmpty {
            try shell("rm -rf -- " + folders.map { Self.shellQuote($0.path) }.joined(separator: " "), cancellation)
        }
    }

    /// Runs a command in the server's shell over the shared connection.
    @discardableResult
    func shell(_ command: String, _ cancellation: Cancellation) throws -> String {
        try connect(cancellation)
        let result = try Self.run("/usr/bin/ssh", options + ["-o", "BatchMode=yes", destination, command],
                                  environment: Self.utf8Environment, timeout: 600, cancellation: cancellation)
        if cancellation.isCancelled { throw SSHError.cancelled }
        guard result.status == 0 else { throw SSHError(message: Self.cleanError(result.error, status: result.status)) }
        return result.output
    }

    /// Uploads or downloads with sftp's `put` and `get`, reporting its progress meter as it goes.
    /// sftp only shows the meter on a terminal, so it runs under `script`, which gives it one.
    func transfer(_ commands: [String], _ cancellation: Cancellation, progress: @escaping (TransferProgress) -> Void) throws {
        try connect(cancellation)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("menussh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let batch = folder.appendingPathComponent("batch")
        try Data((["progress"] + commands).joined(separator: "\n").appending("\n").utf8).write(to: batch)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/usr/bin/sftp", "-b", batch.path] + options + [destination]
        process.environment = Self.utf8Environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var text = ""   // what's come so far and hasn't been taken as a whole line or meter yet
        var messages: [String] = []
        let lock = NSLock()
        func consume(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            text += String(decoding: data, as: UTF8.self)
            // The meter redraws its line after a carriage return; messages end in a line feed. By
            // scalars, since to Swift "\r\n" is one Character, neither "\r" nor "\n".
            while let end = text.unicodeScalars.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
                let line = String(text.unicodeScalars[..<end])
                text = String(text.unicodeScalars[text.unicodeScalars.index(after: end)...])
                if let meter = Self.parseProgress(line) { progress(meter) } else { messages.append(line) }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { consume($0.availableData) }
        guard cancellation.attach(process) else { throw SSHError.cancelled }
        try process.run()
        process.waitUntilExit()
        _ = cancellation.attach(nil)
        // What sftp said last (often why it failed) may not have been read yet.
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        consume(pipe.fileHandleForReading.readDataToEndOfFile())
        if cancellation.isCancelled { throw SSHError.cancelled }
        guard process.terminationStatus == 0 else {
            lock.lock()
            let said = (messages + [text]).map { $0.replacingOccurrences(of: "^D\u{8}\u{8}", with: "") }
                .filter { !$0.hasPrefix("sftp> ") && !$0.hasPrefix("Progress meter") }
            lock.unlock()
            throw SSHError(message: Self.cleanError(said.joined(separator: "\n"), status: process.terminationStatus))
        }
    }

    // MARK: Parsing

    /// One line of `ls -lan`: `drwxr-xr-x    ? 1000     1000         4096 Oct 22 23:17 name`.
    private static let lsLine = try! NSRegularExpression(
        pattern: #"^([-dlbcps][-rwxsStTl]{9}\S*)\s+\S+\s+(\S+)\s+\S+\s+(\d+)\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4}) (.+)$"#)

    static func parse(_ line: String) -> RemoteFile? {
        let ns = line as NSString
        guard let match = lsLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String { ns.substring(with: match.range(at: i)) }
        let permissions = group(1)
        let kind: RemoteFile.Kind
        switch permissions.first {
        case "d": kind = .folder
        case "l": kind = .link
        case "-": kind = .file
        default: kind = .other
        }
        return RemoteFile(name: group(7), path: group(7), kind: kind, size: Int64(group(3)) ?? 0,
                          modified: date(month: group(4), day: group(5), timeOrYear: group(6)),
                          permissions: String(permissions.prefix(10)), owner: group(2))
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `ls` gives the time for the last six months and the year before that; a date with a time
    /// is this year's, or last year's if that would put it in the future.
    private static func date(month: String, day: String, timeOrYear: String) -> Date? {
        guard let m = months.firstIndex(of: month), let d = Int(day) else { return nil }
        var parts = DateComponents(month: m + 1, day: d)
        let calendar = Calendar.current
        if timeOrYear.contains(":") {
            let hm = timeOrYear.split(separator: ":").compactMap { Int($0) }
            parts.hour = hm.first
            parts.minute = hm.last
            parts.year = calendar.component(.year, from: Date())
            if let date = calendar.date(from: parts), date > Date().addingTimeInterval(86_400) {
                parts.year! -= 1
            }
        } else {
            parts.year = Int(timeOrYear)
        }
        return calendar.date(from: parts)
    }

    /// `name    45%  512KB   1.2MB/s   00:03 ETA`
    private static let meter = try! NSRegularExpression(pattern: #"^(.*?)\s+(\d{1,3})%\s+(\S+)\s+(\S+/s)\s+(\S+)"#)

    static func parseProgress(_ line: String) -> TransferProgress? {
        let ns = line as NSString
        guard let match = meter.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String { ns.substring(with: match.range(at: i)) }
        return TransferProgress(file: group(1).trimmingCharacters(in: .whitespaces), percent: Int(group(2)) ?? 0,
                                transferred: group(3), rate: group(4), eta: group(5))
    }

    // MARK: Paths and quoting

    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// A path for an sftp command: in double quotes, which also keeps * ? [ from matching other names.
    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A path for the server's shell that keeps a leading ~ meaning the home folder.
    static func shellPath(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + shellQuote(String(path.dropFirst(2))) }
        return shellQuote(path)
    }

    /// A path for the server's shell.
    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// sftp prints names in other scripts as ? unless its locale is UTF-8, and the month names
    /// it prints must be English for the dates to be read.
    static var utf8Environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["LANG"] = "en_US.UTF-8"
        return environment
    }

    /// ssh's and sftp's messages, without the ones that don't help.
    static func cleanError(_ text: String, status: Int32) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") && !$0.hasPrefix("** ")
                && !$0.hasPrefix("sftp> ") && $0 != "^D"
        }
        guard !lines.isEmpty else { return tr("SSH 連線失敗（代碼 \(status)）。", "The SSH connection failed (code \(status)).") }
        var message = lines.prefix(6).joined(separator: "\n")
        if message.contains("Permission denied") {
            message += "\n\n" + tr("帳號、密碼或金鑰不對，或伺服器不接受這種登入方式。",
                                   "The account, password or key is wrong, or the server doesn’t accept this way of signing in.")
        }
        return message
    }

    // MARK: Running programs

    struct Result {
        var status: Int32
        var output: String
        var error: String
    }

    /// Runs a program and waits for it. Output goes to files rather than pipes, so a long listing
    /// can't fill a pipe and stall it; `whileRunning` is called every 50 ms until it ends.
    static func run(_ path: String, _ arguments: [String], input: String = "", environment: [String: String]? = nil,
                    timeout: TimeInterval, cancellation: Cancellation = Cancellation(),
                    whileRunning: (() -> Void)? = nil) throws -> Result {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("menussh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inURL = folder.appendingPathComponent("in"), outURL = folder.appendingPathComponent("out"),
            errURL = folder.appendingPathComponent("err")
        try Data(input.utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = try FileHandle(forReadingFrom: inURL)
        process.standardOutput = try FileHandle(forWritingTo: outURL)
        process.standardError = try FileHandle(forWritingTo: errURL)
        guard cancellation.attach(process) else { throw SSHError.cancelled }
        defer { _ = cancellation.attach(nil) }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw SSHError(message: tr("伺服器沒有回應（超過 \(Int(timeout)) 秒）。",
                                           "The server didn’t answer within \(Int(timeout)) seconds."))
            }
            whileRunning?()
            Thread.sleep(forTimeInterval: 0.05)
        }
        return Result(status: process.terminationStatus,
                      output: String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self),
                      error: String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self))
    }
}
