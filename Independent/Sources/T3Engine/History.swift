import Foundation

/// Printable ASCII costs one byte per cell. Style changes and other glyphs use
/// tagged records. Blank padding is reconstructed at the reader's current width.
private struct HistoryLine {
    var wrapped: Int?
    var bytes: [UInt8] = []
    var styles: [TerminalStyle] = []
    var cost: Int {
        64 + bytes.capacity + styles.capacity * MemoryLayout<TerminalStyle>.stride
    }

    init(_ cells: [TerminalCell], wrapped: Int?) {
        self.wrapped = wrapped
        guard let last = cells.lastIndex(where: { $0 != TerminalCell() }) else { return }
        var style = TerminalStyle()
        for cell in cells[...last] where cell.width > 0 {
            if cell.style != style {
                bytes.append(0)
                styles.append(cell.style)
                style = cell.style
            }
            if cell.width == 1, cell.text.utf8.count == 1, let byte = cell.text.utf8.first,
               (0x20...0x7e).contains(byte) {
                bytes.append(byte)
            } else {
                let size = cell.text.utf8.count
                bytes.append(UInt8(cell.width))
                bytes.append(UInt8(size & 255))
                bytes.append(UInt8(size >> 8))
                bytes.append(contentsOf: cell.text.utf8)
            }
        }
    }

    func unpack(columns: Int) -> [TerminalCell] {
        var result = Array(repeating: TerminalCell(), count: columns)
        var offset = 0, column = 0, nextStyle = 0
        var style = TerminalStyle()
        while offset < bytes.count && column < columns {
            let tag = bytes[offset]
            offset += 1
            switch tag {
            case 0:
                style = styles[nextStyle]
                nextStyle += 1
            case 1, 2:
                let count = Int(bytes[offset]) + 256 * Int(bytes[offset + 1])
                offset += 2
                let end = offset + count
                guard column + Int(tag) <= columns else { return result }
                result[column] = TerminalCell(text: String(decoding: bytes[offset..<end], as: UTF8.self),
                                              width: Int(tag), style: style)
                if tag == 2 { result[column + 1] = TerminalCell(text: "", width: 0, style: style) }
                column += Int(tag)
                offset = end
            default:
                result[column] = TerminalCell(text: String(Unicode.Scalar(tag)), style: style)
                column += 1
            }
        }
        return result
    }
}

final class History {
    private var slots: [HistoryLine?] = []
    private var first = 0
    private(set) var count = 0
    private(set) var discarded = 0
    private(set) var byteCount = 0
    private let limit: Int
    private let byteLimit: Int

    init(limit: Int, byteLimit: Int) {
        self.limit = max(0, limit)
        self.byteLimit = max(0, byteLimit)
    }

    func append(_ row: [TerminalCell], wrapped: Int?) {
        guard limit > 0, byteLimit > 0 else { discarded += 1; return }
        let line = HistoryLine(row, wrapped: wrapped)
        guard line.cost <= byteLimit else {
            trim(rows: 0)
            discarded += 1
            return
        }
        while count > 0 && (count >= limit || line.cost > byteLimit - byteCount) { dropFirst() }
        if count == slots.count {
            let size = min(limit, max(16, 2 * count))
            var newSlots = Array<HistoryLine?>(repeating: nil, count: size)
            for i in 0..<count { newSlots[i] = slots[(first + i) % slots.count] }
            slots = newSlots
            first = 0
        }
        slots[(first + count) % slots.count] = line
        count += 1
        byteCount += line.cost
    }

    func wrappedLength(at index: Int) -> Int? {
        guard index >= 0, index < count else { return nil }
        return slots[(first + index) % slots.count]?.wrapped
    }

    func line(at index: Int, columns: Int) -> [TerminalCell] {
        guard index >= 0, index < count,
              let line = slots[(first + index) % slots.count] else { return [] }
        return line.unpack(columns: columns)
    }

    func replacement() -> History {
        let result = History(limit: limit, byteLimit: byteLimit)
        result.discarded = discarded
        return result
    }

    func drainFirst(columns: Int) -> (cells: [TerminalCell], wrapped: Int?)? {
        guard count > 0, let line = slots[first] else { return nil }
        slots[first] = nil
        first = (first + 1) % slots.count
        count -= 1
        byteCount -= line.cost
        return (line.unpack(columns: columns), line.wrapped)
    }

    func takeLast(columns: Int) -> (cells: [TerminalCell], wrapped: Int?)? {
        guard count > 0 else { return nil }
        let index = (first + count - 1) % slots.count
        guard let line = slots[index] else { return nil }
        slots[index] = nil
        byteCount -= line.cost
        count -= 1
        return (line.unpack(columns: columns), line.wrapped)
    }

    func trim(rows: Int) {
        while count > max(0, rows) { dropFirst() }
        releaseEmptySlots()
    }

    func trim(bytes: Int) {
        while byteCount > max(0, bytes) { dropFirst() }
        releaseEmptySlots()
    }

    private func releaseEmptySlots() {
        if count == 0 {
            slots.removeAll()
            first = 0
        } else if slots.count > max(32, count * 4) {
            slots = (0..<count).map { slots[(first + $0) % slots.count] }
            first = 0
        }
    }

    private func dropFirst() {
        guard let line = slots[first] else { return }
        byteCount -= line.cost
        discarded += 1
        slots[first] = nil
        first = (first + 1) % slots.count
        count -= 1
    }
}
