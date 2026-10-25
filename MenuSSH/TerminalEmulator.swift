import Foundation

/// How a character is drawn: colors and SGR flags.
struct TermAttr: Equatable {
    static let bold: UInt8 = 1, dim: UInt8 = 2, italic: UInt8 = 4, underline: UInt8 = 8,
               inverse: UInt8 = 16, hidden: UInt8 = 32, strike: UInt8 = 64

    /// 0 is the default color; `indexed | n` one of the 256; `rgb | 0xRRGGBB` a true color.
    static let indexed: UInt32 = 0x100_0000, rgb: UInt32 = 0x200_0000

    var fg: UInt32 = 0
    var bg: UInt32 = 0
    var flags: UInt8 = 0

    func has(_ flag: UInt8) -> Bool { flags & flag != 0 }
}

struct TermCell: Equatable {
    /// The character, as a Unicode scalar value; a space when empty.
    var ch: UInt32 = 32
    /// 1 for most characters; 2 for the left half of a wide one (CJK, emoji), 0 for its right half.
    var width: UInt8 = 1
    var attr = TermAttr()
    /// Combining marks after the character, rarely any.
    var combining: String?

    var text: String {
        guard let scalar = Unicode.Scalar(ch) else { return " " }
        return String(Character(scalar)) + (combining ?? "")
    }
}

struct TermLine {
    var cells: [TermCell]
    /// Ran on into the next line because it was full, rather than ending with a newline;
    /// copying joins such lines up again.
    var wrapped = false

    init(_ cols: Int, attr: TermAttr = TermAttr()) {
        cells = Array(repeating: TermCell(attr: TermAttr(bg: attr.bg)), count: cols)
    }

    var isBlank: Bool { cells.allSatisfy { $0.ch == 32 && $0.attr.bg == 0 } }
}

/// An xterm-compatible terminal: reads what the program sends (text, control characters and
/// escape sequences) and keeps the screen, the scrollback and the modes that result. Drawing
/// and keyboard input are TerminalView's.
final class TerminalEmulator {
    private(set) var cols: Int
    private(set) var rows: Int
    /// The screen: the main one, or the alternate one full-screen programs switch to.
    private(set) var lines: [TermLine]
    private var savedMain: [TermLine]?
    var isAlternate: Bool { savedMain != nil }
    /// Lines scrolled off the top of the main screen, oldest first.
    private(set) var history: [TermLine] = []
    /// How many lines have been dropped from the start of `history`, so a position counted from
    /// the very first line stays put as old ones go.
    private(set) var dropped = 0
    static let maxHistory = 10_000

    private(set) var cursorX = 0
    private(set) var cursorY = 0
    /// The last column was written: the next character goes on the next line.
    private var wrapPending = false
    private var attr = TermAttr()
    private var scrollTop = 0
    private var scrollBottom: Int
    private var tabStops: [Bool]

    // Modes
    private(set) var appCursorKeys = false
    private(set) var appKeypad = false
    private(set) var bracketedPaste = false
    private(set) var cursorVisible = true
    private(set) var focusReporting = false
    enum CursorShape { case block, underline, bar }
    private(set) var cursorShape = CursorShape.block
    enum MouseMode { case off, click, drag, any }
    private(set) var mouseMode = MouseMode.off
    private(set) var sgrMouse = false
    private var autowrap = true
    private var originMode = false
    private var insertMode = false

    // Character sets: G0 and G1, ASCII or DEC line drawing, and which is in use.
    private var charsets = [false, false]
    private var activeCharset = 0

    private struct Saved {
        var x = 0, y = 0, attr = TermAttr(), originMode = false, charsets = [false, false], activeCharset = 0
    }
    private var saved = Saved()
    private var lastPrinted: UInt32 = 32

    /// What the terminal answers back: cursor position reports, device attributes.
    var onResponse: ((String) -> Void)?
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?
    /// For OSC 11 and 10: the background and text colors, as rgb:RRRR/GGGG/BBBB.
    var colorReport: ((_ background: Bool) -> String)?

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        lines = Array(repeating: TermLine(cols), count: rows)
        scrollBottom = rows - 1
        tabStops = (0..<cols).map { $0 % 8 == 0 }
    }

    /// A line counting the scrollback first, then the screen.
    func line(_ index: Int) -> TermLine? {
        if index < 0 { return nil }
        if index < history.count { return history[index] }
        let row = index - history.count
        return row < lines.count ? lines[row] : nil
    }

    // MARK: Reading what the program sends

    private enum State { case ground, escape, escapeIntermediate(UInt8), csi, osc, oscEscape, ignore, ignoreEscape, charset(Int) }
    private var state = State.ground
    private var sequence: [UInt8] = []
    private var utf8Value: UInt32 = 0
    private var utf8Remaining = 0

    func feed(_ bytes: [UInt8]) {
        for byte in bytes { feed(byte) }
    }

    func feed(_ text: String) { feed(Array(text.utf8)) }

    private func feed(_ b: UInt8) {
        // CAN and SUB cut any sequence short; ESC starts a new one (except where it may end a string).
        switch state {
        case .osc, .oscEscape, .ignore, .ignoreEscape: break
        default:
            if b == 0x18 || b == 0x1a { state = .ground; return }
            if b == 0x1b { utf8Remaining = 0; state = .escape; return }
        }
        switch state {
        case .ground:
            if utf8Remaining > 0 {
                if b & 0xC0 == 0x80 {
                    utf8Value = utf8Value << 6 | UInt32(b & 0x3F)
                    utf8Remaining -= 1
                    if utf8Remaining == 0 { print(utf8Value) }
                    return
                }
                utf8Remaining = 0
                print(0xFFFD)
            }
            if b < 0x20 || b == 0x7F {
                control(b)
            } else if b < 0x80 {
                print(UInt32(b))
            } else if b & 0xE0 == 0xC0 {
                utf8Value = UInt32(b & 0x1F); utf8Remaining = 1
            } else if b & 0xF0 == 0xE0 {
                utf8Value = UInt32(b & 0x0F); utf8Remaining = 2
            } else if b & 0xF8 == 0xF0 {
                utf8Value = UInt32(b & 0x07); utf8Remaining = 3
            } else {
                print(0xFFFD)
            }
        case .escape:
            escape(b)
        case .escapeIntermediate(let first):
            if b < 0x20 { return control(b) }
            if b >= 0x30 {
                if first == UInt8(ascii: "#"), b == UInt8(ascii: "8") { fillWithE() }
                state = .ground
            }
        case .csi:
            if b >= 0x40 && b <= 0x7E {
                state = .ground
                csi(final: b)
            } else if b < 0x20 {
                control(b)
            } else {
                sequence.append(b)
            }
        case .osc:
            if b == 0x07 { state = .ground; osc() }
            else if b == 0x1B { state = .oscEscape }
            else { sequence.append(b) }
        case .oscEscape:
            state = .ground
            osc()
            if b != UInt8(ascii: "\\") { feed(0x1B); feed(b) }
        case .ignore:
            if b == 0x1B { state = .ignoreEscape } else if b == 0x07 { state = .ground }
        case .ignoreEscape:
            state = b == UInt8(ascii: "\\") ? .ground : .ignore
        case .charset(let g):
            if g < 2 { charsets[g] = b == UInt8(ascii: "0") }
            state = .ground
        }
    }

    private func control(_ b: UInt8) {
        switch b {
        case 0x07: onBell?()
        case 0x08:
            wrapPending = false
            if cursorX > 0 { cursorX -= 1 }
        case 0x09:
            wrapPending = false
            cursorX = nextTab(from: cursorX)
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D:
            wrapPending = false
            cursorX = 0
        case 0x0E: activeCharset = 1
        case 0x0F: activeCharset = 0
        default: break
        }
    }

    private func escape(_ b: UInt8) {
        state = .ground
        switch b {
        case UInt8(ascii: "["): sequence = []; state = .csi
        case UInt8(ascii: "]"): sequence = []; state = .osc
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"): state = .ignore
        case UInt8(ascii: "("): state = .charset(0)
        case UInt8(ascii: ")"): state = .charset(1)
        case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "/"): state = .charset(2)
        case UInt8(ascii: "#"), UInt8(ascii: "%"), UInt8(ascii: " "): state = .escapeIntermediate(b)
        case UInt8(ascii: "7"): saveCursor()
        case UInt8(ascii: "8"): restoreCursor()
        case UInt8(ascii: "D"): lineFeed()
        case UInt8(ascii: "E"): cursorX = 0; lineFeed()
        case UInt8(ascii: "M"): reverseIndex()
        case UInt8(ascii: "H"): if cursorX < cols { tabStops[cursorX] = true }
        case UInt8(ascii: "c"): reset()
        case UInt8(ascii: "="): appKeypad = true
        case UInt8(ascii: ">"): appKeypad = false
        default: break
        }
    }

    // MARK: Printing

    /// DEC Special Graphics, for the line drawing some programs still use: ` to ~.
    private static let lineDrawing: [UInt32] = Array("◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·".unicodeScalars.map(\.value))

    private func print(_ value: UInt32) {
        var value = value
        if charsets[activeCharset] {
            if value >= 0x60 && value <= 0x7E { value = Self.lineDrawing[Int(value - 0x60)] }
            else if value == 0x5F { value = 32 }
        }
        let width = Self.width(of: value)
        if width == 0 {
            // A combining mark joins the character before it.
            var x = wrapPending ? cursorX : cursorX - 1
            guard x >= 0, let scalar = Unicode.Scalar(value) else { return }
            if lines[cursorY].cells[x].width == 0, x > 0 { x -= 1 }
            lines[cursorY].cells[x].combining = (lines[cursorY].cells[x].combining ?? "") + String(Character(scalar))
            return
        }
        if wrapPending {
            wrapPending = false
            if autowrap {
                lines[cursorY].wrapped = true
                cursorX = 0
                lineFeed()
            }
        }
        if width == 2 && cursorX == cols - 1 {
            guard autowrap else { return }
            clearHalf(at: cursorX)
            lines[cursorY].cells[cursorX] = blank()
            lines[cursorY].wrapped = true
            cursorX = 0
            lineFeed()
        }
        if insertMode { insertBlanks(width) }
        clearHalf(at: cursorX)
        if width == 2 { clearHalf(at: cursorX + 1) }
        lines[cursorY].cells[cursorX] = TermCell(ch: value, width: UInt8(width), attr: attr)
        if width == 2 { lines[cursorY].cells[cursorX + 1] = TermCell(ch: 32, width: 0, attr: attr) }
        lastPrinted = value
        cursorX += width
        if cursorX >= cols {
            cursorX = cols - 1
            wrapPending = true
        }
    }

    /// Writing over half of a wide character blanks the other half.
    private func clearHalf(at x: Int) {
        guard x < cols else { return }
        let cell = lines[cursorY].cells[x]
        if cell.width == 0, x > 0 { lines[cursorY].cells[x - 1] = blank() }
        if cell.width == 2, x + 1 < cols { lines[cursorY].cells[x + 1] = blank() }
    }

    private func blank() -> TermCell { TermCell(attr: TermAttr(bg: attr.bg)) }

    /// How many columns a character takes: 0 for combining marks, 2 for East Asian wide
    /// characters and emoji, 1 for the rest.
    static func width(of v: UInt32) -> Int {
        if v < 0x300 { return 1 }
        switch v {
        case 0x300...0x36F, 0x483...0x489, 0x591...0x5BD, 0x610...0x61A, 0x64B...0x65F, 0x1AB0...0x1AFF,
             0x1DC0...0x1DFF, 0x200B...0x200F, 0x20D0...0x20FF, 0xFE00...0xFE0F, 0xFE20...0xFE2F,
             0xE0100...0xE01EF, 0x3099...0x309A:
            return 0
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0, 0x23F3,
             0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F, 0x2693, 0x26A1, 0x26AA...0x26AB,
             0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2...0x26F3, 0x26F5, 0x26FA,
             0x26FD, 0x2705, 0x270A...0x270B, 0x2728, 0x274C, 0x274E, 0x2753...0x2755, 0x2757,
             0x2795...0x2797, 0x27B0, 0x27BF, 0x2B1B...0x2B1C, 0x2B50, 0x2B55,
             0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F004, 0x1F0CF, 0x1F18E, 0x1F191...0x1F19A,
             0x1F200...0x1F2FF, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB,
             0x1F90C...0x1F9FF, 0x1FA70...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    // MARK: Moving and scrolling

    private func lineFeed() {
        wrapPending = false
        if cursorY == scrollBottom { scrollUp(1) }
        else if cursorY < rows - 1 { cursorY += 1 }
    }

    private func reverseIndex() {
        wrapPending = false
        if cursorY == scrollTop { scrollDown(1) }
        else if cursorY > 0 { cursorY -= 1 }
    }

    private func scrollUp(_ n: Int) {
        for _ in 0..<min(n, scrollBottom - scrollTop + 1) {
            let gone = lines.remove(at: scrollTop)
            // Only lines leaving the whole main screen are kept to scroll back to, not ones a
            // program scrolls within part of it (a status line below, say).
            if !isAlternate && scrollTop == 0 && scrollBottom == rows - 1 { keep(gone) }
            lines.insert(TermLine(cols, attr: attr), at: scrollBottom)
        }
    }

    private func scrollDown(_ n: Int) {
        for _ in 0..<min(n, scrollBottom - scrollTop + 1) {
            lines.remove(at: scrollBottom)
            lines.insert(TermLine(cols, attr: attr), at: scrollTop)
        }
    }

    private func keep(_ line: TermLine) {
        history.append(line)
        if history.count > Self.maxHistory + 500 {
            history.removeFirst(500)
            dropped += 500
        }
    }

    func clearHistory() {
        dropped += history.count
        history.removeAll()
    }

    private func nextTab(from x: Int) -> Int {
        var x = x + 1
        while x < cols - 1 && !tabStops[x] { x += 1 }
        return min(x, cols - 1)
    }

    private func previousTab(from x: Int) -> Int {
        var x = x - 1
        while x > 0 && !tabStops[x] { x -= 1 }
        return max(x, 0)
    }

    private func setCursor(x: Int, y: Int) {
        wrapPending = false
        cursorX = max(0, min(cols - 1, x))
        let top = originMode ? scrollTop : 0, bottom = originMode ? scrollBottom : rows - 1
        cursorY = max(top, min(bottom, y + top))
    }

    private func saveCursor() {
        saved = Saved(x: cursorX, y: cursorY, attr: attr, originMode: originMode, charsets: charsets, activeCharset: activeCharset)
    }

    private func restoreCursor() {
        cursorX = min(saved.x, cols - 1)
        cursorY = min(saved.y, rows - 1)
        attr = saved.attr
        originMode = saved.originMode
        charsets = saved.charsets
        activeCharset = saved.activeCharset
        wrapPending = false
    }

    // MARK: Erasing and editing

    private func erase(row: Int, from: Int, to: Int) {
        guard row >= 0, row < rows else { return }
        for x in max(0, from)..<min(cols, to) { lines[row].cells[x] = blank() }
        if to >= cols { lines[row].wrapped = false }
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            erase(row: cursorY, from: cursorX, to: cols)
            for y in (cursorY + 1)..<max(cursorY + 1, rows) { erase(row: y, from: 0, to: cols) }
        case 1:
            for y in 0..<cursorY { erase(row: y, from: 0, to: cols) }
            erase(row: cursorY, from: 0, to: cursorX + 1)
        case 2:
            for y in 0..<rows { erase(row: y, from: 0, to: cols) }
        case 3:
            clearHistory()
        default: break
        }
        wrapPending = false
    }

    private func eraseLine(_ mode: Int) {
        switch mode {
        case 0: erase(row: cursorY, from: cursorX, to: cols)
        case 1: erase(row: cursorY, from: 0, to: cursorX + 1)
        default: erase(row: cursorY, from: 0, to: cols)
        }
        wrapPending = false
    }

    private func insertBlanks(_ n: Int) {
        let n = min(n, cols - cursorX)
        guard n > 0 else { return }
        lines[cursorY].cells.removeLast(n)
        lines[cursorY].cells.insert(contentsOf: Array(repeating: blank(), count: n), at: cursorX)
        if let last = lines[cursorY].cells.last, last.width == 2 { lines[cursorY].cells[cols - 1] = blank() }
    }

    private func deleteChars(_ n: Int) {
        let n = min(n, cols - cursorX)
        guard n > 0 else { return }
        clearHalf(at: cursorX)
        lines[cursorY].cells.removeSubrange(cursorX..<(cursorX + n))
        lines[cursorY].cells.append(contentsOf: Array(repeating: blank(), count: n))
        if lines[cursorY].cells[cursorX].width == 0 { lines[cursorY].cells[cursorX] = blank() }
    }

    private func insertLines(_ n: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        for _ in 0..<min(n, scrollBottom - cursorY + 1) {
            lines.remove(at: scrollBottom)
            lines.insert(TermLine(cols, attr: attr), at: cursorY)
        }
        cursorX = 0
        wrapPending = false
    }

    private func deleteLines(_ n: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        for _ in 0..<min(n, scrollBottom - cursorY + 1) {
            lines.remove(at: cursorY)
            lines.insert(TermLine(cols, attr: attr), at: scrollBottom)
        }
        cursorX = 0
        wrapPending = false
    }

    private func fillWithE() {
        for y in 0..<rows {
            lines[y] = TermLine(cols)
            for x in 0..<cols { lines[y].cells[x].ch = 0x45 }
        }
    }

    private func switchScreen(alternate: Bool) {
        guard alternate != isAlternate else { return }
        if alternate {
            savedMain = lines
            lines = Array(repeating: TermLine(cols), count: rows)
        } else {
            lines = savedMain ?? lines
            savedMain = nil
        }
        wrapPending = false
    }

    func reset() {
        switchScreen(alternate: false)
        attr = TermAttr()
        lines = Array(repeating: TermLine(cols), count: rows)
        cursorX = 0
        cursorY = 0
        wrapPending = false
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = (0..<cols).map { $0 % 8 == 0 }
        appCursorKeys = false
        appKeypad = false
        bracketedPaste = false
        cursorVisible = true
        cursorShape = .block
        mouseMode = .off
        sgrMouse = false
        focusReporting = false
        autowrap = true
        originMode = false
        insertMode = false
        charsets = [false, false]
        activeCharset = 0
        saved = Saved()
    }

    // MARK: CSI sequences

    private func csi(final: UInt8) {
        var marker: UInt8 = 0
        var body = sequence[...]
        if let first = body.first, (0x3C...0x3F).contains(first) {
            marker = first
            body = body.dropFirst()
        }
        let intermediates = body.filter { $0 >= 0x20 && $0 <= 0x2F }
        let paramText = String(decoding: body.filter { $0 >= 0x30 && $0 <= 0x3B }, as: UTF8.self)
        // Each parameter, with any :-separated sub-parameters; -1 where one is left out.
        let groups: [[Int]] = paramText.isEmpty ? [] : paramText.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? -1 }
        }
        let params = groups.map { $0.first ?? -1 }
        func count(_ i: Int, _ fallback: Int = 1) -> Int {
            let v = i < params.count ? params[i] : -1
            return v <= 0 ? fallback : min(v, 10_000)
        }
        func value(_ i: Int) -> Int { max(0, i < params.count ? params[i] : 0) }

        if !intermediates.isEmpty {
            if intermediates == [UInt8(ascii: " ")], final == UInt8(ascii: "q") {
                switch value(0) {
                case 3, 4: cursorShape = .underline
                case 5, 6: cursorShape = .bar
                default: cursorShape = .block
                }
            } else if intermediates == [UInt8(ascii: "!")], final == UInt8(ascii: "p") {
                let keep = (lines, history)
                reset()
                (lines, history) = keep
            }
            return
        }

        switch final {
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            setModes(params, privateMode: marker == UInt8(ascii: "?"), on: final == UInt8(ascii: "h"))
            return
        case UInt8(ascii: "c"):
            if marker == UInt8(ascii: ">") { onResponse?("\u{1B}[>0;10;1c") }
            else if marker == 0 { onResponse?("\u{1B}[?62;22c") }
            return
        case UInt8(ascii: "n"):
            if value(0) == 5 { onResponse?("\u{1B}[0n") }
            if value(0) == 6 {
                let y = cursorY - (originMode ? scrollTop : 0)
                onResponse?("\u{1B}[" + (marker == UInt8(ascii: "?") ? "?" : "") + "\(y + 1);\(cursorX + 1)R")
            }
            return
        default: break
        }
        // The rest are only meant without a marker (CSI ? J is the same as CSI J, near enough).
        guard marker == 0 || final == UInt8(ascii: "J") || final == UInt8(ascii: "K") else { return }

        switch final {
        case UInt8(ascii: "@"): insertBlanks(count(0))
        case UInt8(ascii: "A"):
            let top = cursorY >= scrollTop ? scrollTop : 0
            cursorY = max(top, cursorY - count(0)); wrapPending = false
        case UInt8(ascii: "B"), UInt8(ascii: "e"):
            let bottom = cursorY <= scrollBottom ? scrollBottom : rows - 1
            cursorY = min(bottom, cursorY + count(0)); wrapPending = false
        case UInt8(ascii: "C"), UInt8(ascii: "a"): cursorX = min(cols - 1, cursorX + count(0)); wrapPending = false
        case UInt8(ascii: "D"): cursorX = max(0, min(cursorX, cols - 1) - count(0)); wrapPending = false
        case UInt8(ascii: "E"):
            cursorY = min(cursorY <= scrollBottom ? scrollBottom : rows - 1, cursorY + count(0)); cursorX = 0; wrapPending = false
        case UInt8(ascii: "F"):
            cursorY = max(cursorY >= scrollTop ? scrollTop : 0, cursorY - count(0)); cursorX = 0; wrapPending = false
        case UInt8(ascii: "G"), UInt8(ascii: "`"): cursorX = min(cols - 1, count(0) - 1); wrapPending = false
        case UInt8(ascii: "H"), UInt8(ascii: "f"): setCursor(x: count(1) - 1, y: count(0) - 1)
        case UInt8(ascii: "I"): for _ in 0..<count(0) { cursorX = nextTab(from: cursorX) }
        case UInt8(ascii: "Z"): for _ in 0..<count(0) { cursorX = previousTab(from: cursorX) }
        case UInt8(ascii: "J"): eraseDisplay(value(0))
        case UInt8(ascii: "K"): eraseLine(value(0))
        case UInt8(ascii: "L"): insertLines(count(0))
        case UInt8(ascii: "M"): deleteLines(count(0))
        case UInt8(ascii: "P"): deleteChars(count(0))
        case UInt8(ascii: "S"): scrollUp(count(0))
        case UInt8(ascii: "T"): if params.count <= 1 { scrollDown(count(0)) }
        case UInt8(ascii: "X"): erase(row: cursorY, from: cursorX, to: cursorX + count(0))
        case UInt8(ascii: "b"): for _ in 0..<count(0) { print(lastPrinted) }
        case UInt8(ascii: "d"): setCursor(x: cursorX, y: count(0) - 1)
        case UInt8(ascii: "g"):
            if value(0) == 0, cursorX < cols { tabStops[cursorX] = false }
            if value(0) == 3 { tabStops = Array(repeating: false, count: cols) }
        case UInt8(ascii: "m"): sgr(groups)
        case UInt8(ascii: "r"):
            let top = count(0) - 1, bottom = min(count(1, rows), rows) - 1
            if top < bottom {
                scrollTop = top
                scrollBottom = bottom
                setCursor(x: 0, y: 0)
            }
        case UInt8(ascii: "s"): saveCursor()
        case UInt8(ascii: "u"): restoreCursor()
        case UInt8(ascii: "t"):
            if value(0) == 18 { onResponse?("\u{1B}[8;\(rows);\(cols)t") }
        default: break
        }
    }

    private func setModes(_ params: [Int], privateMode: Bool, on: Bool) {
        for mode in params {
            if !privateMode {
                if mode == 4 { insertMode = on }
                continue
            }
            switch mode {
            case 1: appCursorKeys = on
            case 6: originMode = on; setCursor(x: 0, y: 0)
            case 7: autowrap = on
            case 25: cursorVisible = on
            case 47, 1047:
                if !on && mode == 1047 { for y in 0..<rows { erase(row: y, from: 0, to: cols) } }
                switchScreen(alternate: on)
            case 1049:
                if on {
                    saveCursor()
                    switchScreen(alternate: true)
                    eraseDisplay(2)
                } else {
                    switchScreen(alternate: false)
                    restoreCursor()
                }
            case 1000: mouseMode = on ? .click : .off
            case 1002: mouseMode = on ? .drag : .off
            case 1003: mouseMode = on ? .any : .off
            case 1004: focusReporting = on
            case 1006: sgrMouse = on
            case 2004: bracketedPaste = on
            default: break
            }
        }
    }

    private func sgr(_ groups: [[Int]]) {
        if groups.isEmpty { attr = TermAttr(); return }
        var i = 0
        /// 38, 48: either 38:5:n / 38:2::r:g:b in one group, or 38;5;n / 38;2;r;g;b across several.
        func extendedColor(_ group: [Int]) -> UInt32? {
            if group.count > 1 {
                if group[1] == 5, group.count >= 3 { return TermAttr.indexed | UInt32(max(0, min(255, group[2]))) }
                if group[1] == 2, group.count >= 5 {
                    let c = group.suffix(3).map { UInt32(max(0, min(255, $0))) }
                    return TermAttr.rgb | c[0] << 16 | c[1] << 8 | c[2]
                }
                return nil
            }
            guard i + 1 < groups.count else { return nil }
            let kind = groups[i + 1].first ?? -1
            if kind == 5, i + 2 < groups.count {
                i += 2
                return TermAttr.indexed | UInt32(max(0, min(255, groups[i].first ?? 0)))
            }
            if kind == 2, i + 4 < groups.count {
                let c = groups[(i + 2)...(i + 4)].map { UInt32(max(0, min(255, $0.first ?? 0))) }
                i += 4
                return TermAttr.rgb | c[0] << 16 | c[1] << 8 | c[2]
            }
            return nil
        }
        while i < groups.count {
            let group = groups[i]
            let p = max(0, group.first ?? 0)
            switch p {
            case 0: attr = TermAttr()
            case 1: attr.flags |= TermAttr.bold
            case 2: attr.flags |= TermAttr.dim
            case 3: attr.flags |= TermAttr.italic
            case 4: if group.count > 1 && group[1] == 0 { attr.flags &= ~TermAttr.underline } else { attr.flags |= TermAttr.underline }
            case 7: attr.flags |= TermAttr.inverse
            case 8: attr.flags |= TermAttr.hidden
            case 9: attr.flags |= TermAttr.strike
            case 21: attr.flags |= TermAttr.underline
            case 22: attr.flags &= ~(TermAttr.bold | TermAttr.dim)
            case 23: attr.flags &= ~TermAttr.italic
            case 24: attr.flags &= ~TermAttr.underline
            case 27: attr.flags &= ~TermAttr.inverse
            case 28: attr.flags &= ~TermAttr.hidden
            case 29: attr.flags &= ~TermAttr.strike
            case 30...37: attr.fg = TermAttr.indexed | UInt32(p - 30)
            case 38: if let c = extendedColor(group) { attr.fg = c }
            case 39: attr.fg = 0
            case 40...47: attr.bg = TermAttr.indexed | UInt32(p - 40)
            case 48: if let c = extendedColor(group) { attr.bg = c }
            case 49: attr.bg = 0
            case 58: _ = extendedColor(group)   // underline color: not drawn
            case 90...97: attr.fg = TermAttr.indexed | UInt32(p - 90 + 8)
            case 100...107: attr.bg = TermAttr.indexed | UInt32(p - 100 + 8)
            default: break
            }
            i += 1
        }
    }

    // MARK: OSC strings

    private func osc() {
        let text = String(decoding: sequence, as: UTF8.self)
        sequence = []
        guard let semicolon = text.firstIndex(of: ";") else { return }
        let code = Int(text[..<semicolon]) ?? -1
        let value = String(text[text.index(after: semicolon)...])
        switch code {
        case 0, 2: onTitle?(value)
        case 10, 11:
            if value == "?", let color = colorReport?(code == 11) { onResponse?("\u{1B}]\(code);\(color)\u{1B}\\") }
        default: break
        }
    }

    // MARK: Resizing

    func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(newCols, 2), newRows = max(newRows, 1)
        guard newCols != cols || newRows != rows else { return }
        func fitWidth(_ line: inout TermLine) {
            if line.cells.count > newCols {
                line.cells.removeLast(line.cells.count - newCols)
                if line.cells[newCols - 1].width == 2 { line.cells[newCols - 1] = TermCell() }
            } else if line.cells.count < newCols {
                line.cells += Array(repeating: TermCell(), count: newCols - line.cells.count)
            }
        }
        /// Fits a screen's lines to the new size. Rows taken off the top of the main screen go to
        /// the scrollback, and rows added come back from it, so the text stays by the cursor.
        func fit(_ screen: inout [TermLine], cursor: inout Int, main: Bool) {
            for i in screen.indices { fitWidth(&screen[i]) }
            if newRows < screen.count {
                var excess = screen.count - newRows
                while excess > 0, screen.count - 1 > cursor, screen.last?.isBlank == true {
                    screen.removeLast()
                    excess -= 1
                }
                if excess > 0 {
                    if main { for line in screen.prefix(excess) { keep(line) } }
                    screen.removeFirst(excess)
                    cursor -= excess
                }
            } else if newRows > screen.count {
                var missing = newRows - screen.count
                while main, missing > 0, var line = history.popLast() {
                    fitWidth(&line)
                    screen.insert(line, at: 0)
                    cursor += 1
                    missing -= 1
                }
                screen += Array(repeating: TermLine(newCols), count: missing)
            }
            cursor = max(0, min(newRows - 1, cursor))
        }
        cols = newCols
        rows = newRows
        if var main = savedMain {
            fit(&main, cursor: &saved.y, main: true)
            savedMain = main
            fit(&lines, cursor: &cursorY, main: false)
        } else {
            fit(&lines, cursor: &cursorY, main: true)
        }
        cursorX = min(cursorX, cols - 1)
        wrapPending = false
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = (0..<cols).map { $0 % 8 == 0 }
    }
}
