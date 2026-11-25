import Foundation
#if canImport(Darwin)
import Darwin
private let widthLocale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil)
#endif

private let printableASCII = (32...126).map { String(Unicode.Scalar($0)!) }
private let decGraphics = Array("◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·")

private func scalarWidth(_ scalar: Unicode.Scalar) -> Int {
    if scalar.properties.isEmojiPresentation { return 2 }
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .enclosingMark, .format, .control: return 0
    default: break
    }
    #if canImport(Darwin)
    if let locale = widthLocale {
        let width = Int(wcwidth_l(Int32(scalar.value), locale))
        return width < 0 ? 1 : min(2, width)
    }
    #endif
    switch scalar.value {
    case 0x1100...0x115f, 0x2329...0x232a, 0x2e80...0xa4cf, 0xac00...0xd7a3,
         0xf900...0xfaff, 0xfe10...0xfe19, 0xfe30...0xfe6f, 0xff01...0xff60,
         0xffe0...0xffe6, 0x20000...0x3fffd: return 2
    default: return 1
    }
}

/// A one-column viewport stores wide glyphs in its only cell. Recover their
/// natural width when the main screen grows again.
func expandedCellWidth(_ text: String) -> Int {
    var width = 1
    var emoji = false
    for scalar in text.unicodeScalars {
        if scalar.properties.isEmoji { emoji = true }
        if scalarWidth(scalar) == 2 || scalar.value == 0x20e3 || emoji && scalar.value == 0xfe0f { width = 2 }
    }
    return width
}

extension TerminalEngine {
    /// Consecutive ASCII output needs one grid mutation and one damage mark
    /// per physical row. Preserve the ordinary glyph path at Unicode boundaries.
    func printASCIIRun(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) {
        var offset = start
        if let anchor = anchor, let first = screen.grid[anchor.row][anchor.column].text.utf8.first, first >= 0x80 {
            printASCII(bytes[offset])
            offset += 1
        }
        let blank = erased
        let rendition = style
        while offset < end {
            if screen.pendingWrap {
                screen.wrapped[screen.row] = columns
                move(row: screen.row, column: 0)
                advance()
            }
            let x = screen.column, y = screen.row
            if !modes.autoWrap && x == columns - 1 { offset = end - 1 }
            let count = min(columns - x, end - offset)
            let last = x + count - 1
            screen.grid[y].withUnsafeMutableBufferPointer { cells in
                if cells[x].width == 0 { cells[x - 1] = blank }
                if cells[last].width == 2 { cells[last + 1] = blank }
                for i in 0..<count {
                    cells[x + i] = TerminalCell(text: printableASCII[Int(bytes[offset + i]) - 32], style: rendition)
                }
            }
            mark(y)
            screen.pendingWrap = modes.autoWrap && last == columns - 1
            screen.column = min(columns - 1, last + 1)
            anchor = (y, last)
            lastGraphic = screen.grid[y][last]
            offset += count
        }
    }

    func printASCII(_ byte: UInt8) {
        if graphics[g1 ? 1 : 0], byte >= 0x60, byte <= 0x7e {
            printGlyph(TerminalCell(text: String(decGraphics[Int(byte - 0x60)]), style: style))
        } else if let anchor = anchor, let first = screen.grid[anchor.row][anchor.column].text.utf8.first,
                  first >= 0x80 {
            printScalar(Unicode.Scalar(byte))
        } else {
            printGlyph(TerminalCell(text: printableASCII[Int(byte - 32)], style: style))
        }
    }

    func printScalar(_ scalar: Unicode.Scalar) {
        let suffix = String(scalar)
        if let anchor = anchor {
            let old = screen.grid[anchor.row][anchor.column]
            let joined = old.text + suffix
            if joined.count == 1 {
                // Keep hostile, indefinitely extending graphemes bounded.
                guard joined.utf8.count <= 256 else { return }
                var glyph = old
                glyph.text = joined
                if scalar.value == 0xfe0f && old.text.unicodeScalars.contains(where: { $0.properties.isEmoji })
                    || scalar.value == 0x20e3 || scalarWidth(scalar) == 2 { glyph.width = min(columns, 2) }
                if glyph.width > old.width {
                    move(row: anchor.row, column: anchor.column)
                    clear(anchor.row, from: anchor.column, through: anchor.column)
                    printGlyph(glyph, insert: false)
                } else {
                    screen.grid[anchor.row][anchor.column] = glyph
                    lastGraphic = glyph
                    mark(anchor.row)
                }
                return
            }
        }
        let width = scalarWidth(scalar)
        if width > 0 { printGlyph(TerminalCell(text: suffix, width: width, style: style)) }
    }

    func printGlyph(_ glyph: TerminalCell, insert: Bool = true) {
        var cell = glyph
        cell.width = min(cell.width, columns)
        if modes.autoWrap && (screen.pendingWrap || screen.column + cell.width > columns) {
            screen.wrapped[screen.row] = screen.pendingWrap ? columns : screen.column
            move(row: screen.row, column: 0)
            advance()
        }
        guard screen.column + cell.width <= columns else { return }
        if modes.insert && insert { shiftCharacters(cell.width, right: true) }
        let row = screen.row, x = screen.column, end = x + cell.width - 1
        if screen.grid[row][x].width == 0 { screen.grid[row][x - 1] = erased }
        if screen.grid[row][end].width == 2 { screen.grid[row][end + 1] = erased }
        screen.grid[row][x] = cell
        if cell.width == 2 { screen.grid[row][end] = TerminalCell(text: "", width: 0, style: cell.style) }
        mark(row)
        screen.pendingWrap = modes.autoWrap && end == columns - 1
        screen.column = min(columns - 1, end + 1)
        anchor = (row, x)
        lastGraphic = cell
    }
}
