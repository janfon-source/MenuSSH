import AppKit

/// Draws a TerminalEmulator's screen and scrollback, and turns keys, pastes and the mouse into
/// what a terminal sends. Input methods (Zhuyin, Pinyin, and the rest) compose in place at the
/// cursor, through NSTextInputClient.
final class TerminalView: NSView, NSTextInputClient, NSUserInterfaceValidations {
    let emulator: TerminalEmulator
    /// Bytes for the program: keys typed, text pasted, mouse reports.
    var onInput: (([UInt8]) -> Void)?
    /// The grid changed size to fit the view.
    var onResize: ((_ cols: Int, _ rows: Int) -> Void)?

    static let padding: CGFloat = 6
    private static let fontSizeKey = "menussh.terminalFontSize"
    private static let optionAsMetaKey = "menussh.optionAsMeta"

    static var fontSize: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: fontSizeKey) as? Double ?? 13) }
        set { UserDefaults.standard.set(Double(min(max(newValue, 8), 32)), forKey: fontSizeKey) }
    }

    /// ⌥ sends Esc and the key, as Meta, so ⌥B and ⌥F move by words in the shell.
    static var optionAsMeta: Bool {
        get { UserDefaults.standard.object(forKey: optionAsMetaKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: optionAsMetaKey) }
    }

    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16
    private var textOffset: CGFloat = 0

    /// How many lines up into the scrollback the view is; 0 shows the screen.
    private var scrollOffset = 0
    /// Where the scrollback stood when last drawn, to keep a scrolled-up view still as lines arrive.
    private var lastTotal = 0
    private var scrollRemainder: CGFloat = 0

    /// A selection, from where the mouse went down to where it is, by line counted from the very
    /// first line ever kept (so it stays put as old ones are dropped) and column.
    private struct Point: Comparable {
        var line: Int, col: Int
        static func < (a: Point, b: Point) -> Bool { a.line != b.line ? a.line < b.line : a.col < b.col }
    }
    private var selectionStart: Point?
    private var selectionEnd: Point?
    private var reportingButton: Int?

    /// Being typed with an input method, not sent yet.
    private var marked = ""

    init(emulator: TerminalEmulator) {
        self.emulator = emulator
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        // Since macOS 14 views draw past their edges unless told not to, and the background
        // would paint over the toolbar above.
        clipsToBounds = true
        updateFont()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Size

    func updateFont() {
        let size = Self.fontSize
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        boldFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        cellWidth = ("W" as NSString).size(withAttributes: [.font: font]).width
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        cellHeight = ceil(lineHeight * 1.08)
        textOffset = floor((cellHeight - lineHeight) / 2)
        fitGrid()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitGrid()
    }

    private func fitGrid() {
        let cols = max(Int((bounds.width - 2 * Self.padding) / cellWidth), 10)
        let rows = max(Int((bounds.height - 2 * Self.padding) / cellHeight), 3)
        guard cols != emulator.cols || rows != emulator.rows else { return }
        emulator.resize(cols: cols, rows: rows)
        scrollOffset = min(scrollOffset, emulator.history.count)
        onResize?(cols, rows)
        needsDisplay = true
    }

    /// New output: keeps a view scrolled into the past looking at the same lines.
    func outputArrived() {
        let total = emulator.dropped + emulator.history.count
        if scrollOffset > 0 { scrollOffset = min(scrollOffset + total - lastTotal, emulator.history.count) }
        lastTotal = total
        needsDisplay = true
    }

    // MARK: Colors

    private struct Palette {
        var foreground: NSColor
        var background: NSColor
        var cursor: NSColor
        var selection: NSColor
        var ansi: [NSColor]
    }

    /// The 16 ANSI colors (iTerm2's defaults), then the 6×6×6 cube and the grays.
    private static let ansi256: [NSColor] = {
        let base: [UInt32] = [0x000000, 0xC91B00, 0x00C200, 0xC7C400, 0x2A6FE8, 0xCA30C7, 0x00C5C7, 0xC7C7C7,
                              0x686868, 0xFF6E67, 0x5FFA68, 0xFFFC67, 0x6B9EFF, 0xFF77FF, 0x60FDFF, 0xFFFFFF]
        var colors = base.map(color)
        let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
        for r in steps { for g in steps { for b in steps { colors.append(color(r << 16 | g << 8 | b)) } } }
        for i in 0..<24 {
            let v = UInt32(8 + i * 10)
            colors.append(color(v << 16 | v << 8 | v))
        }
        return colors
    }()

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private var palette: Palette {
        isDark
            ? Palette(foreground: Self.color(0xE6E6E6), background: Self.color(0x1C1C1E), cursor: Self.color(0xE6E6E6),
                      selection: NSColor.selectedTextBackgroundColor, ansi: Self.ansi256)
            : Palette(foreground: Self.color(0x1D1D1F), background: Self.color(0xFFFFFF), cursor: Self.color(0x1D1D1F),
                      selection: NSColor.selectedTextBackgroundColor, ansi: Self.ansi256)
    }

    /// For OSC 10 and 11: programs such as vim ask whether the background is dark.
    func colorReport(background: Bool) -> String {
        let c = (background ? palette.background : palette.foreground).usingColorSpace(.sRGB) ?? .black
        func hex(_ v: CGFloat) -> String { String(format: "%04x", Int(v * 65535)) }
        return "rgb:\(hex(c.redComponent))/\(hex(c.greenComponent))/\(hex(c.blueComponent))"
    }

    private func resolve(_ attr: TermAttr, _ palette: Palette, selected: Bool) -> (fg: NSColor, bg: NSColor?) {
        func lookup(_ c: UInt32, foreground: Bool) -> NSColor? {
            if c == 0 { return nil }
            if c & TermAttr.rgb != 0 { return Self.color(c & 0xFFFFFF) }
            var index = Int(c & 0xFF)
            // Bold text in one of the first eight colors shows in its bright version, as in xterm.
            if foreground, attr.has(TermAttr.bold), index < 8 { index += 8 }
            return palette.ansi[index]
        }
        var fg = lookup(attr.fg, foreground: true) ?? palette.foreground
        var bg = lookup(attr.bg, foreground: false)
        if attr.has(TermAttr.inverse) {
            let oldFg = fg
            fg = bg ?? palette.background
            bg = oldFg
        }
        if attr.has(TermAttr.dim) { fg = fg.withAlphaComponent(0.6) }
        if selected { bg = palette.selection; if isDark == false { fg = palette.foreground } }
        return (fg, bg)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let palette = self.palette
        palette.background.setFill()
        dirtyRect.intersection(bounds).fill()
        let top = emulator.history.count - scrollOffset
        let selection = orderedSelection
        for row in 0..<emulator.rows {
            let y = Self.padding + CGFloat(row) * cellHeight
            guard NSRect(x: 0, y: y, width: bounds.width, height: cellHeight).intersects(dirtyRect),
                  let line = emulator.line(top + row) else { continue }
            drawLine(line, at: y, absolute: emulator.dropped + top + row, selection: selection, palette: palette)
        }
        drawCursor(palette)
    }

    private func drawLine(_ line: TermLine, at y: CGFloat, absolute: Int, selection: (Point, Point)?, palette: Palette) {
        let count = min(line.cells.count, emulator.cols)
        func isSelected(_ x: Int) -> Bool {
            guard let (start, end) = selection else { return false }
            let p = Point(line: absolute, col: x)
            return p >= start && p < end
        }
        // Backgrounds, a run at a time.
        var x = 0
        while x < count {
            let (_, bg) = resolve(line.cells[x].attr, palette, selected: isSelected(x))
            var end = x + 1
            while end < count {
                let next = resolve(line.cells[end].attr, palette, selected: isSelected(end)).bg
                if next != bg { break }
                end += 1
            }
            if let bg {
                bg.setFill()
                NSRect(x: Self.padding + CGFloat(x) * cellWidth, y: y, width: CGFloat(end - x) * cellWidth, height: cellHeight).fill()
            }
            x = end
        }
        // Text: plain ASCII in runs of the same look, everything else a character at a time at its
        // own cell, since a fallback font's characters needn't be the grid's width.
        x = 0
        while x < count {
            let cell = line.cells[x]
            if cell.width == 0 { x += 1; continue }
            let (fg, _) = resolve(cell.attr, palette, selected: isSelected(x))
            var text = cell.text
            var end = x + Int(cell.width)
            if cell.ch < 0x80, cell.combining == nil {
                while end < count {
                    let next = line.cells[end]
                    guard next.ch < 0x80, next.width == 1, next.combining == nil, next.attr == cell.attr,
                          isSelected(end) == isSelected(x) else { break }
                    text.unicodeScalars.append(Unicode.Scalar(UInt8(next.ch)))
                    end += 1
                }
            }
            let left = Self.padding + CGFloat(x) * cellWidth
            if !cell.attr.has(TermAttr.hidden), text.contains(where: { $0 != " " }) {
                (text as NSString).draw(at: NSPoint(x: left, y: y + textOffset), withAttributes: textAttributes(cell.attr, fg))
            }
            if cell.attr.has(TermAttr.underline) || cell.attr.has(TermAttr.strike) {
                fg.setFill()
                let width = CGFloat(end - x) * cellWidth
                if cell.attr.has(TermAttr.underline) { NSRect(x: left, y: y + cellHeight - 2, width: width, height: 1).fill() }
                if cell.attr.has(TermAttr.strike) { NSRect(x: left, y: y + cellHeight / 2, width: width, height: 1).fill() }
            }
            x = end
        }
    }

    private func textAttributes(_ attr: TermAttr, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: attr.has(TermAttr.bold) ? boldFont : font, .foregroundColor: color]
        if attr.has(TermAttr.italic) { attributes[.obliqueness] = 0.18 }
        return attributes
    }

    private var cursorRect: NSRect {
        let row = emulator.cursorY + scrollOffset
        let x = Self.padding + CGFloat(min(emulator.cursorX, emulator.cols - 1)) * cellWidth
        return NSRect(x: x, y: Self.padding + CGFloat(row) * cellHeight, width: cellWidth, height: cellHeight)
    }

    private var isFocused: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    private func drawCursor(_ palette: Palette) {
        guard emulator.cursorY + scrollOffset < emulator.rows else { return }
        var rect = cursorRect
        if !marked.isEmpty {
            // What the input method is composing, over the cursor and to its right.
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.foreground,
                                                             .underlineStyle: NSUnderlineStyle.single.rawValue]
            let size = (marked as NSString).size(withAttributes: attributes)
            palette.background.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: size.width, height: cellHeight).fill()
            (marked as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + textOffset), withAttributes: attributes)
            return
        }
        guard emulator.cursorVisible else { return }
        let cell = emulator.lines[emulator.cursorY].cells[min(emulator.cursorX, emulator.cols - 1)]
        if cell.width == 2 { rect.size.width *= 2 }
        palette.cursor.setFill()
        palette.cursor.setStroke()
        guard isFocused else {
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return
        }
        switch emulator.cursorShape {
        case .block:
            rect.fill()
            if cell.ch != 32 {
                (cell.text as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + textOffset),
                                             withAttributes: textAttributes(cell.attr, palette.background))
            }
        case .underline: NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2).fill()
        case .bar: NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
        }
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        if emulator.focusReporting { onInput?(Array("\u{1B}[I".utf8)) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        if emulator.focusReporting { onInput?(Array("\u{1B}[O".utf8)) }
        return true
    }

    // MARK: Keys

    private func send(_ text: String) {
        send(Array(text.utf8))
    }

    private func send(_ bytes: [UInt8]) {
        if scrollOffset != 0 { scrollOffset = 0; needsDisplay = true }
        onInput?(bytes)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return super.keyDown(with: event) }
        if !marked.isEmpty { return interpretKeyEvents([event]) }
        if let bytes = specialKey(event, flags) {
            if !bytes.isEmpty { send(bytes) }   // empty: it scrolled the view, and nothing goes to the program
            return
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        interpretKeyEvents([event])
    }

    /// Keys that send escape sequences or control characters rather than text.
    private func specialKey(_ event: NSEvent, _ flags: NSEvent.ModifierFlags) -> [UInt8]? {
        let shift = flags.contains(.shift), option = flags.contains(.option), control = flags.contains(.control)
        let modifier = 1 + (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0)
        let esc = "\u{1B}"
        func cursorKey(_ letter: String) -> [UInt8] {
            if modifier > 1 { return Array("\(esc)[1;\(modifier)\(letter)".utf8) }
            return Array((emulator.appCursorKeys ? "\(esc)O" : "\(esc)[").utf8) + Array(letter.utf8)
        }
        func tilde(_ n: Int) -> [UInt8] { Array((modifier > 1 ? "\(esc)[\(n);\(modifier)~" : "\(esc)[\(n)~").utf8) }

        switch event.keyCode {
        case 36, 76: return option && Self.optionAsMeta ? [0x1B, 0x0D] : [0x0D]
        case 48: return shift ? Array("\(esc)[Z".utf8) : [0x09]
        case 51: return option && Self.optionAsMeta ? [0x1B, 0x7F] : control ? [0x08] : [0x7F]
        case 53: return [0x1B]
        case 117: return tilde(3)
        case 123:
            if option && !shift && !control && Self.optionAsMeta { return Array("\(esc)b".utf8) }
            return cursorKey("D")
        case 124:
            if option && !shift && !control && Self.optionAsMeta { return Array("\(esc)f".utf8) }
            return cursorKey("C")
        case 125: return cursorKey("B")
        case 126: return cursorKey("A")
        case 115:
            if shift { scrollTo(emulator.history.count); return [] }
            return cursorKey("H")
        case 119:
            if shift { scrollTo(0); return [] }
            return cursorKey("F")
        case 116:
            if shift && !emulator.isAlternate { scrollTo(scrollOffset + emulator.rows - 1); return [] }
            return tilde(5)
        case 121:
            if shift && !emulator.isAlternate { scrollTo(scrollOffset - emulator.rows + 1); return [] }
            return tilde(6)
        case 122: return modifier > 1 ? Array("\(esc)[1;\(modifier)P".utf8) : Array("\(esc)OP".utf8)
        case 120: return modifier > 1 ? Array("\(esc)[1;\(modifier)Q".utf8) : Array("\(esc)OQ".utf8)
        case 99: return modifier > 1 ? Array("\(esc)[1;\(modifier)R".utf8) : Array("\(esc)OR".utf8)
        case 118: return modifier > 1 ? Array("\(esc)[1;\(modifier)S".utf8) : Array("\(esc)OS".utf8)
        case 96: return tilde(15)
        case 97: return tilde(17)
        case 98: return tilde(18)
        case 100: return tilde(19)
        case 101: return tilde(20)
        case 109: return tilde(21)
        case 103: return tilde(23)
        case 111: return tilde(24)
        default: break
        }

        guard let base = event.charactersIgnoringModifiers, let scalar = base.unicodeScalars.first else { return nil }
        if control {
            var byte: UInt8?
            switch scalar {
            case "a"..."z": byte = UInt8(scalar.value - 96)
            case "A"..."Z": byte = UInt8(scalar.value - 64)
            case "@", " ", "2": byte = 0
            case "[", "3": byte = 0x1B
            case "\\", "4": byte = 0x1C
            case "]", "5": byte = 0x1D
            case "^", "6", "~": byte = 0x1E
            case "_", "-", "/", "7": byte = 0x1F
            case "?", "8": byte = 0x7F
            default: break
            }
            if let byte { return (option && Self.optionAsMeta ? [0x1B] : []) + [byte] }
        }
        if option && Self.optionAsMeta && !control { return [0x1B] + Array(base.utf8) }
        return nil
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        marked = ""
        needsDisplay = true
        send(text)
    }

    override func doCommand(by selector: Selector) {}   // the keys that matter are handled above

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        marked = ""
        needsDisplay = true
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count)
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the input method's candidate window goes: just under the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(cursorRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: Copy and paste

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText, !text.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard var text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if emulator.bracketedPaste { text = "\u{1B}[200~" + text.replacingOccurrences(of: "\u{1B}", with: "") + "\u{1B}[201~" }
        send(text)
    }

    @objc override func selectAll(_ sender: Any?) {
        selectionStart = Point(line: emulator.dropped, col: 0)
        selectionEnd = Point(line: emulator.dropped + emulator.history.count + emulator.rows - 1, col: emulator.cols)
        needsDisplay = true
    }

    /// Clears the scrollback (⌘K), keeping what's on the screen.
    @objc func clearScrollback(_ sender: Any?) {
        emulator.clearHistory()
        scrollOffset = 0
        selectionStart = nil
        lastTotal = emulator.dropped
        needsDisplay = true
    }

    private var orderedSelection: (Point, Point)? {
        guard let a = selectionStart, let b = selectionEnd, a != b else { return nil }
        return a < b ? (a, b) : (b, a)
    }

    private var selectedText: String? {
        guard let (start, end) = orderedSelection else { return nil }
        var result = ""
        for absolute in start.line...end.line {
            guard let line = emulator.line(absolute - emulator.dropped) else { continue }
            let from = absolute == start.line ? start.col : 0
            let to = absolute == end.line ? min(end.col, line.cells.count) : line.cells.count
            var text = ""
            if from < to { for cell in line.cells[from..<to] where cell.width != 0 { text += cell.text } }
            if absolute != end.line && line.wrapped {
                result += text
            } else {
                while text.hasSuffix(" ") { text.removeLast() }
                result += text + (absolute == end.line ? "" : "\n")
            }
        }
        return result
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return orderedSelection != nil }
        if item.action == #selector(paste(_:)) { return NSPasteboard.general.string(forType: .string) != nil }
        return true
    }

    // MARK: Mouse

    private func gridPoint(_ event: NSEvent) -> (col: Int, row: Int) {
        let p = convert(event.locationInWindow, from: nil)
        let col = Int(((p.x - Self.padding) / cellWidth).rounded(.down))
        let row = Int(((p.y - Self.padding) / cellHeight).rounded(.down))
        return (max(0, min(emulator.cols - 1, col)), max(0, min(emulator.rows - 1, row)))
    }

    private func selectionPoint(_ event: NSEvent) -> Point {
        let p = convert(event.locationInWindow, from: nil)
        let col = Int(((p.x - Self.padding) / cellWidth).rounded())
        let row = max(0, min(emulator.rows - 1, Int(((p.y - Self.padding) / cellHeight).rounded(.down))))
        return Point(line: emulator.dropped + emulator.history.count - scrollOffset + row, col: max(0, min(emulator.cols, col)))
    }

    /// Whether the program wants the mouse; holding ⌥ selects text anyway.
    private func reportsMouse(_ event: NSEvent) -> Bool {
        emulator.mouseMode != .off && !event.modifierFlags.contains(.option)
    }

    private func report(_ button: Int, _ event: NSEvent, press: Bool, motion: Bool = false) {
        let (col, row) = gridPoint(event)
        let flags = event.modifierFlags
        var code = button + (motion ? 32 : 0) + (flags.contains(.shift) ? 4 : 0) + (flags.contains(.control) ? 16 : 0)
        if emulator.sgrMouse {
            send("\u{1B}[<\(code);\(col + 1);\(row + 1)\(press ? "M" : "m")")
        } else {
            if !press { code = 3 + (code & ~3 & ~64) }
            send([0x1B, 0x5B, 0x4D, UInt8(min(code + 32, 255)), UInt8(min(col + 33, 255)), UInt8(min(row + 33, 255))])
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if reportsMouse(event) {
            reportingButton = 0
            return report(0, event, press: true)
        }
        let point = selectionPoint(event)
        switch event.clickCount {
        case 2: selectWord(at: point)
        case 3...:
            selectionStart = Point(line: point.line, col: 0)
            selectionEnd = Point(line: point.line, col: emulator.cols)
        default:
            selectionStart = point
            selectionEnd = point
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if reportingButton != nil {
            if emulator.mouseMode == .drag || emulator.mouseMode == .any { report(0, event, press: true, motion: true) }
            return
        }
        guard selectionStart != nil else { return }
        // Dragging past the top or bottom scrolls.
        let y = convert(event.locationInWindow, from: nil).y
        if y < 0 { scrollTo(scrollOffset + 1) } else if y > bounds.height { scrollTo(scrollOffset - 1) }
        selectionEnd = selectionPoint(event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if reportingButton != nil {
            reportingButton = nil
            report(0, event, press: false)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if reportsMouse(event) { return report(2, event, press: true) }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if reportsMouse(event) { report(2, event, press: false) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if reportsMouse(event) { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: tr("拷貝", "Copy"), action: #selector(copy(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("貼上", "Paste"), action: #selector(paste(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("全選", "Select All"), action: #selector(selectAll(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("清除回捲紀錄", "Clear Scrollback"), action: #selector(clearScrollback(_:)), keyEquivalent: "").target = self
        return menu
    }

    private func selectWord(at point: Point) {
        guard let line = emulator.line(point.line - emulator.dropped) else { return }
        let cells = line.cells
        let col = min(point.col, cells.count - 1)
        guard col >= 0 else { return }
        func isWord(_ i: Int) -> Bool {
            let c = cells[i]
            if c.width == 0 { return true }
            guard let s = Unicode.Scalar(c.ch) else { return false }
            return c.ch != 32 && !" \t\"'`()[]{}<>|,;".unicodeScalars.contains(s)
        }
        guard isWord(col) else {
            selectionStart = Point(line: point.line, col: col)
            selectionEnd = Point(line: point.line, col: col + 1)
            return
        }
        var start = col, end = col
        while start > 0 && isWord(start - 1) { start -= 1 }
        while end < cells.count - 1 && isWord(end + 1) { end += 1 }
        selectionStart = Point(line: point.line, col: start)
        selectionEnd = Point(line: point.line, col: end + 1)
    }

    override func scrollWheel(with event: NSEvent) {
        var delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += delta / cellHeight
            delta = scrollRemainder.rounded(.towardZero)
            scrollRemainder -= delta
        } else {
            delta *= 3
        }
        let lines = Int(delta)
        guard lines != 0 else { return }
        if reportsMouse(event) {
            for _ in 0..<min(abs(lines), 10) { report(lines > 0 ? 64 : 65, event, press: true) }
        } else if emulator.isAlternate {
            // less, man and vim without the mouse: the wheel moves as the arrow keys do.
            let key = emulator.appCursorKeys ? (lines > 0 ? "\u{1B}OA" : "\u{1B}OB") : (lines > 0 ? "\u{1B}[A" : "\u{1B}[B")
            for _ in 0..<min(abs(lines), 10) { onInput?(Array(key.utf8)) }
        } else {
            scrollTo(scrollOffset + lines)
        }
    }

    private func scrollTo(_ offset: Int) {
        let offset = max(0, min(emulator.history.count, offset))
        guard offset != scrollOffset else { return }
        scrollOffset = offset
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}
