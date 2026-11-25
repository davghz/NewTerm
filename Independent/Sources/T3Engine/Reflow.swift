import Foundation

private struct Position {
    var row: Int
    var column: Int
    var pending: Bool
}

private struct PhysicalLine {
    var cells: [TerminalCell]
    var wrapped: Int?
}

/// Stream one paragraph at a time through a single output line. Keep at most
/// one destination screen unpacked; completed rows spill into compressed history.
private final class Reflow {
    let width: Int
    let height: Int
    let blank: [TerminalCell]
    let history: History
    let oldCursor: Position
    let oldSaved: Position
    var cursor: Position?
    var saved: Position?
    var firstVisible = 0
    var visible: [PhysicalLine?]
    var head = 0
    var count = 0
    var current: [TerminalCell]
    var x = 0
    var outputRow = 0
    var unfinished = false

    init(width: Int, height: Int, history: History, page: Screen) {
        self.width = width
        self.height = height
        self.history = history
        blank = Array(repeating: TerminalCell(), count: width)
        current = blank
        visible = Array(repeating: nil, count: height)
        oldCursor = Position(row: page.row, column: page.column, pending: page.pendingWrap)
        oldSaved = Position(row: page.saved.row, column: page.saved.column, pending: page.saved.pendingWrap)
    }

    func emit(wrapped: Int?) {
        // A reduction in height may cut bottom rows to keep the cursor visible.
        if cursor == nil || outputRow < cursor!.row + height {
            if count == height {
                if let first = visible[head] { history.append(first.cells, wrapped: first.wrapped) }
                head = (head + 1) % height
                count -= 1
                firstVisible += 1
            }
            visible[(head + count) % height] = PhysicalLine(cells: current, wrapped: wrapped)
            count += 1
        }
        outputRow += 1
        current = blank
        x = 0
    }

    func consume(_ cells: [TerminalCell], wrapped: Int?, screenRow: Int?) {
        let hasCursor = screenRow == oldCursor.row
        let hasSaved = screenRow == oldSaved.row
        let cursorOffset = oldCursor.column + (oldCursor.pending ? 1 : 0)
        let savedOffset = oldSaved.column + (oldSaved.pending ? 1 : 0)
        var end = wrapped ?? cells.lastIndex(where: { $0 != TerminalCell() }).map { $0 + 1 } ?? 0
        if hasCursor { end = max(end, cursorOffset) }
        if hasSaved { end = max(end, savedOffset) }
        end = min(cells.count, end)

        func mapped(_ column: Int) -> Position {
            Position(row: outputRow, column: min(width - 1, column), pending: column == width)
        }

        var source = 0
        while source < end {
            var cell = cells[source]
            let originalWidth = max(1, cell.width)
            cell.width = min(width, originalWidth)
            if x + cell.width > width { emit(wrapped: x) }
            if hasCursor, !oldCursor.pending, oldCursor.column >= source, oldCursor.column < source + originalWidth {
                cursor = mapped(x + min(cell.width - 1, oldCursor.column - source))
            }
            if hasSaved, !oldSaved.pending, oldSaved.column >= source, oldSaved.column < source + originalWidth {
                saved = mapped(x + min(cell.width - 1, oldSaved.column - source))
            }
            current[x] = cell
            if cell.width == 2 { current[x + 1] = TerminalCell(text: "", width: 0, style: cell.style) }
            x += cell.width
            source += originalWidth
            if hasCursor, oldCursor.pending, cursorOffset == source { cursor = mapped(x) }
            if hasSaved, oldSaved.pending, savedOffset == source { saved = mapped(x) }
        }
        let cursorAtEnd = hasCursor && !oldCursor.pending && cursorOffset == end
        let savedAtEnd = hasSaved && !oldSaved.pending && savedOffset == end
        if cursorAtEnd || savedAtEnd {
            // A non-pending insertion point immediately after the last cell
            // occupies column zero of the next physical row at this width.
            if x == width { emit(wrapped: x) }
            if cursorAtEnd { cursor = mapped(x) }
            if savedAtEnd { saved = mapped(x) }
        }
        unfinished = wrapped != nil
        if wrapped == nil { emit(wrapped: nil) }
    }

    func install(on page: Screen) {
        if unfinished { emit(wrapped: nil) }
        page.grid.removeAll(keepingCapacity: true)
        page.wrapped.removeAll(keepingCapacity: true)
        for i in 0..<count {
            if let line = visible[(head + i) % height] {
                page.grid.append(line.cells)
                page.wrapped.append(line.wrapped)
            }
        }
        page.grid.append(contentsOf: repeatElement(blank, count: height - count))
        page.wrapped.append(contentsOf: repeatElement(nil, count: height - count))
        if let pos = cursor {
            page.row = max(0, min(height - 1, pos.row - firstVisible))
            page.column = pos.column
            page.pendingWrap = pos.pending
        }
        if let pos = saved {
            page.saved.row = max(0, min(height - 1, pos.row - firstVisible))
            page.saved.column = pos.column
            page.saved.pendingWrap = pos.pending
        }
        page.top = 0
        page.bottom = height - 1
    }
}

extension TerminalEngine {
    func reflowPrimary(width: Int, height: Int) {
        let result = Reflow(width: width, height: height, history: history.replacement(), page: primary)
        while let line = history.drainFirst(columns: columns) {
            result.consume(line.cells, wrapped: line.wrapped, screenRow: nil)
        }
        for row in primary.grid.indices {
            result.consume(primary.grid[row], wrapped: primary.wrapped[row], screenRow: row)
        }
        result.install(on: primary)
        history = result.history
    }
}
