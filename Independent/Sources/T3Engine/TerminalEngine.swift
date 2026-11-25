import Foundation

/// Each session owns one engine. Serialize feeds, resizing and reads on the
/// session's queue. Feeding a hidden session updates exactly the same model.
public final class TerminalEngine {
    public internal(set) var columns: Int
    public internal(set) var rows: Int
    public internal(set) var modes = TerminalModes()
    public var defaultForegroundRGB: TerminalColor = .rgb(224, 224, 224)
    public var defaultBackgroundRGB: TerminalColor = .rgb(16, 16, 16)
    var history: History
    var primary: Screen
    var alternate: Screen?
    var screen: Screen
    public internal(set) var isAlternateScreen = false
    var style = TerminalStyle()
    var graphics = [false, false]
    var g1 = false
    var tabs: IndexSet
    var dirty: IndexSet
    var anchor: (row: Int, column: Int)?
    var lastGraphic: TerminalCell?
    var parser = ParserState.ground
    var parameters: [UInt8] = []
    var stringBytes: [UInt8] = []
    var stringEscaped = false
    var stringOverflow = false
    var stringUTF8Remaining = 0
    var stringLimit = 8192
    var reportedDirectoryHost: String?
    var utf8Value: UInt32 = 0
    var utf8Remaining = 0
    var utf8Min: UInt8 = 0x80
    var utf8Max: UInt8 = 0xbf

    public init(columns: Int, rows: Int, historyLimit: Int = 10_000, historyByteLimit: Int = 16 * 1024 * 1024) {
        self.columns = min(1024, max(1, columns))
        self.rows = min(512, max(1, rows))
        history = History(limit: min(100_000, historyLimit), byteLimit: historyByteLimit)
        primary = Screen(columns: self.columns, rows: self.rows)
        screen = primary
        dirty = IndexSet(integersIn: 0..<self.rows)
        tabs = IndexSet(stride(from: 8, to: self.columns, by: 8))
    }

    public var historyCount: Int { isAlternateScreen ? 0 : history.count }
    public var retainedHistoryCount: Int { history.count }
    public var discardedHistoryLines: Int { history.discarded }
    public var historyStorageBytes: Int { history.byteCount }
    public var cursorColumn: Int { screen.column }
    public var cursorRow: Int { screen.row }

    /// Number of columns joined to the following row by autowrap; nil for hard breaks.
    public func wrappedLength(at index: Int) -> Int? {
        let count = historyCount
        guard index >= 0, index < count + rows else { return nil }
        return index < count ? history.wrappedLength(at: index) : screen.wrapped[index - count]
    }

    public func line(at index: Int) -> [TerminalCell] {
        let count = historyCount
        guard index >= 0, index < count + rows else { return [] }
        if index < count { return history.line(at: index, columns: columns) }
        return screen.grid[index - count]
    }

    /// Screen-relative damage, including both the old and new cursor location.
    public func takeDirtyRows() -> IndexSet {
        let result = dirty
        dirty.removeAll()
        return result
    }

    public func trimHistory(to count: Int) { history.trim(rows: count) }
    public func trimHistory(toBytes bytes: Int) { history.trim(bytes: bytes) }

    public func resize(columns requestedColumns: Int, rows requestedRows: Int) {
        let width = min(1024, max(1, requestedColumns))
        let height = min(512, max(1, requestedRows))
        guard width != columns || height != rows else { return }
        if width > columns {
            tabs.formUnion(IndexSet(stride(from: ((columns + 7) / 8) * 8, to: width, by: 8)))
        } else {
            tabs.remove(integersIn: width..<columns)
        }
        if width != columns {
            reflowPrimary(width: width, height: height)
        } else {
            resize(primary, width: width, height: height, saveHistory: true)
        }
        if let alternate = alternate { resize(alternate, width: width, height: height, saveHistory: false) }
        rows = height
        columns = width
        dirty = IndexSet(integersIn: 0..<height)
        anchor = nil
    }

    private func resize(_ page: Screen, width: Int, height: Int, saveHistory: Bool) {
        let blank = Array(repeating: TerminalCell(), count: width)
        let heightDelta = height - rows
        if heightDelta < 0 {
            // Cut unused bottom rows first. Move the top into history only
            // when necessary to keep the cursor visible.
            let shift = max(0, page.row - height + 1)
            if saveHistory {
                for i in 0..<shift { history.append(page.grid[i], wrapped: page.wrapped[i]) }
            }
            page.wrapped.removeFirst(shift)
            page.wrapped.removeLast(-heightDelta - shift)
            page.grid.removeFirst(shift)
            page.grid.removeLast(-heightDelta - shift)
            page.row -= shift
            page.saved.row -= shift
        }
        if width != columns {
            page.wrapped = Array(repeating: nil, count: page.grid.count)
            for row in page.grid.indices {
                if width > columns {
                    page.grid[row].append(contentsOf: repeatElement(TerminalCell(), count: width - columns))
                } else {
                    page.grid[row].removeLast(columns - width)
                    if page.grid[row][width - 1].width == 2 { page.grid[row][width - 1] = TerminalCell() }
                }
            }
        }
        if heightDelta > 0 {
            var restored = [[TerminalCell]]()
            var wrapped = [Int?]()
            if saveHistory {
                while restored.count < heightDelta, let line = history.takeLast(columns: width) {
                    restored.append(line.cells)
                    wrapped.append(line.wrapped)
                }
            }
            page.wrapped.insert(contentsOf: wrapped.reversed(), at: 0)
            page.wrapped.append(contentsOf: repeatElement(nil, count: heightDelta - restored.count))
            page.grid.insert(contentsOf: restored.reversed(), at: 0)
            page.row += restored.count
            page.saved.row += restored.count
            page.grid.append(contentsOf: repeatElement(blank, count: heightDelta - restored.count))
        }
        page.column = min(page.column, width - 1)
        page.saved.column = min(page.saved.column, width - 1)
        page.saved.row = min(height - 1, max(0, page.saved.row))
        page.top = 0
        page.bottom = height - 1
        page.pendingWrap = false
        page.saved.pendingWrap = false
    }

    func mark(_ row: Int) {
        if !dirty.contains(row) { dirty.insert(row) }
    }

    func move(row: Int, column: Int) {
        mark(screen.row)
        screen.row = min(rows - 1, max(0, row))
        screen.column = min(columns - 1, max(0, column))
        screen.pendingWrap = false
        anchor = nil
        mark(screen.row)
    }

    func locate(_ row: Int, _ column: Int) {
        move(row: modes.origin ? min(screen.bottom, screen.top + row) : row, column: column)
    }

    var erased: TerminalCell {
        // BCE clears with the current background; foreground and decorations
        // belong to the erased glyph.
        var eraseStyle = TerminalStyle()
        eraseStyle.background = style.inverse ? style.foreground : style.background
        return TerminalCell(style: eraseStyle)
    }

    func clear(_ row: Int, from start: Int, through last: Int) {
        guard last >= start else { return }
        var lo = start, hi = last
        if screen.grid[row][lo].width == 0 { lo -= 1 }
        if screen.grid[row][hi].width == 2 { hi += 1 }
        if last == columns - 1 { screen.wrapped[row] = nil }
        screen.grid[row].replaceSubrange(lo...hi, with: repeatElement(erased, count: hi - lo + 1))
        mark(row)
    }

    func repairWideCells(row: Int) {
        let blank = erased
        for c in 0..<columns {
            switch screen.grid[row][c].width {
            case 0 where c == 0 || screen.grid[row][c - 1].width != 2: screen.grid[row][c] = blank
            case 2 where c + 1 == columns || screen.grid[row][c + 1].width != 0: screen.grid[row][c] = blank
            default: break
            }
        }
    }

    func shiftCharacters(_ count: Int, right: Bool) {
        let x = screen.column, y = screen.row, n = min(count, columns - x)
        guard n > 0 else { return }
        if screen.grid[y][x].width == 0 { screen.grid[y][x - 1] = erased }
        if right {
            screen.grid[y].removeLast(n)
            screen.grid[y].insert(contentsOf: repeatElement(erased, count: n), at: x)
        } else {
            if screen.grid[y][x + n - 1].width == 2 { screen.grid[y][x + n] = erased }
            screen.grid[y].removeSubrange(x..<(x + n))
            screen.grid[y].append(contentsOf: repeatElement(erased, count: n))
        }
        repairWideCells(row: y)
        mark(y)
    }

    func scroll(top: Int, bottom: Int, count: Int, up: Bool, capture: Bool) {
        guard top <= bottom else { return }
        let n = min(count, bottom - top + 1)
        let blank = Array(repeating: erased, count: columns)
        if up {
            if capture && !isAlternateScreen && top == 0 && bottom == rows - 1 {
                for i in 0..<n { history.append(screen.grid[i], wrapped: screen.wrapped[i]) }
            }
            screen.wrapped.removeSubrange(top..<(top + n))
            screen.wrapped.insert(contentsOf: repeatElement(nil, count: n), at: bottom + 1 - n)
            screen.grid.removeSubrange(top..<(top + n))
            screen.grid.insert(contentsOf: repeatElement(blank, count: n), at: bottom + 1 - n)
        } else {
            screen.wrapped.removeSubrange((bottom + 1 - n)...bottom)
            screen.wrapped.insert(contentsOf: repeatElement(nil, count: n), at: top)
            screen.grid.removeSubrange((bottom + 1 - n)...bottom)
            screen.grid.insert(contentsOf: repeatElement(blank, count: n), at: top)
        }
        dirty.insert(integersIn: top..<(bottom + 1))
        anchor = nil
    }

    func advance(reverse: Bool = false) {
        if !reverse && screen.row == screen.bottom || reverse && screen.row == screen.top {
            scroll(top: screen.top, bottom: screen.bottom, count: 1, up: !reverse, capture: true)
            screen.pendingWrap = false
        } else {
            move(row: screen.row + (reverse ? -1 : 1), column: screen.column)
        }
    }

    func saveCursor() {
        screen.saved = CursorState(row: screen.row, column: screen.column, style: style,
                                  origin: modes.origin, autoWrap: modes.autoWrap,
                                  pendingWrap: screen.pendingWrap, graphics: graphics, g1: g1)
    }

    func restoreCursor() {
        let saved = screen.saved
        modes.origin = saved.origin
        modes.autoWrap = saved.autoWrap
        style = saved.style
        graphics = saved.graphics
        g1 = saved.g1
        move(row: saved.row, column: saved.column)
        screen.pendingWrap = saved.pendingWrap
    }

    func setAlternate(_ enabled: Bool, mode: Int) {
        guard enabled != isAlternateScreen else { return }
        if enabled {
            if mode == 1049 { saveCursor() }
            if alternate == nil || mode == 1049 { alternate = Screen(columns: columns, rows: rows) }
            screen = alternate!
        } else {
            if mode == 1047 { alternate = nil }
            screen = primary
            if mode == 1049 { restoreCursor() }
        }
        isAlternateScreen = enabled
        anchor = nil
        dirty = IndexSet(integersIn: 0..<rows)
    }

    func reset() {
        history.trim(rows: 0)
        primary = Screen(columns: columns, rows: rows)
        screen = primary
        alternate = nil
        isAlternateScreen = false
        modes = TerminalModes()
        style = TerminalStyle()
        graphics = [false, false]
        g1 = false
        anchor = nil
        lastGraphic = nil
        reportedDirectoryHost = nil
        tabs = IndexSet(stride(from: 8, to: columns, by: 8))
        dirty = IndexSet(integersIn: 0..<rows)
    }
}
