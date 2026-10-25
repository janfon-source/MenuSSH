import Foundation

/// A program running on a pseudo-terminal of its own, as it would in Terminal: its output comes
/// in as bytes, keys go to it as bytes, and it's told when the window changes size.
final class PseudoTerminal {
    private(set) var pid: pid_t = 0
    private var master: Int32 = -1
    private var reader: DispatchSourceRead?
    private var exitWatch: DispatchSourceProcess?
    private(set) var isRunning = false

    /// On the main thread, as output arrives.
    var onOutput: (([UInt8]) -> Void)?
    /// On the main thread, once the program has ended and its last output has been read.
    var onExit: ((Int32) -> Void)?

    // _IOW('t', 103, struct winsize): Swift can't see the macro.
    private static let setWindowSize: UInt = 0x8008_7467

    /// Runs `path` with `arguments`; `name` is what it's told it's called (argv[0]: "-zsh" makes a
    /// login shell), and `directory` where it starts.
    func start(_ path: String, _ arguments: [String], name: String? = nil, directory: String? = nil,
               environment: [String: String], cols: Int, rows: Int) throws {
        // Everything the child needs is made before fork: after it, the child only calls chdir and execve.
        let argv = Self.cStrings([name ?? path] + arguments)
        let envp = Self.cStrings(environment.map { "\($0)=\($1)" })
        let folder = directory.map { strdup($0) }
        defer {
            Self.free(argv)
            Self.free(envp)
            folder.map { Darwin.free($0) }
        }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let pid = forkpty(&fd, nil, nil, &size)
        if pid < 0 { throw SSHError(message: String(cString: strerror(errno))) }
        if pid == 0 {
            if let folder { _ = chdir(folder) }
            execve(path, argv, envp)
            _exit(127)
        }
        self.pid = pid
        master = fd
        isRunning = true
        // Later children mustn't hold this terminal open.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader.setEventHandler { [weak self] in self?.drain() }
        reader.resume()
        self.reader = reader

        let exitWatch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitWatch.setEventHandler { [weak self] in self?.ended() }
        exitWatch.resume()
        self.exitWatch = exitWatch
    }

    /// Reads all the output waiting.
    private func drain() {
        guard master >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(master, &buffer, buffer.count)
            if n > 0 {
                onOutput?(Array(buffer[0..<n]))
            } else {
                // EAGAIN: nothing more for now. 0 or EIO: the program's side has closed.
                if n == 0 || errno != EAGAIN { reader?.cancel(); reader = nil }
                return
            }
        }
    }

    private func ended() {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        drain()
        exitWatch?.cancel()
        exitWatch = nil
        reader?.cancel()
        reader = nil
        if master >= 0 { close(master) }
        master = -1
        isRunning = false
        // WIFEXITED / WEXITSTATUS, which Swift can't see either.
        let code = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        onExit?(code)
    }

    func write(_ bytes: [UInt8]) {
        guard master >= 0, !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if n > 0 { offset += n }
            else if errno == EAGAIN { usleep(1000) }
            else { return }
        }
    }

    /// Tells the program the new size; the kernel sends it SIGWINCH.
    func resize(cols: Int, rows: Int) {
        guard master >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, Self.setWindowSize, &size)
    }

    /// Hangs up, as closing a Terminal window does.
    func terminate() {
        guard isRunning else { return }
        kill(pid, SIGHUP)
    }

    private static func cStrings(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (i, s) in strings.enumerated() { array[i] = strdup(s) }
        array[strings.count] = nil
        return array
    }

    private static func free(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var i = 0
        while let s = array[i] {
            Darwin.free(s)
            i += 1
        }
        array.deallocate()
    }
}
