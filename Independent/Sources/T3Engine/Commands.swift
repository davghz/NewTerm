import Foundation

private struct Arguments {
    var prefix: UInt8?
    var intermediate: String
    var values: [[Int?]]

    init?(_ bytes: [UInt8]) {
        var input = bytes[...]
        if let first = input.first, (0x3c...0x3f).contains(first) { prefix = input.removeFirst() }
        let parameters = input.prefix(while: { (0x30...0x3b).contains($0) })
        let remainder = input.dropFirst(parameters.count)
        guard remainder.allSatisfy({ (0x20...0x2f).contains($0) }) else { return nil }
        intermediate = String(decoding: remainder, as: UTF8.self)
        values = [[]]
        var number: Int?
        for byte in parameters {
            if byte >= 0x30 && byte <= 0x39 { number = min(65535, (number ?? 0) * 10 + Int(byte - 0x30)) }
            else {
                values[values.count - 1].append(number)
                if byte == 0x3b { values.append([]) }
                number = nil
            }
        }
        values[values.count - 1].append(number)
    }

    func value(_ index: Int, fallback: Int = 0) -> Int {
        guard index < values.count else { return fallback }
        return values[index][0] ?? fallback
    }
}

extension TerminalEngine {
    func finishCSI(_ byte: UInt8, effects: inout [TerminalEffect]) {
        guard let args = Arguments(parameters) else { return }
        let first = args.value(0), n = max(1, first)
        let priv = args.prefix == 0x3f
        let x = screen.column, y = screen.row
        func reply(_ payload: String) { effects.append(.reply(Data(("\u{1b}[" + payload).utf8))) }
        if args.intermediate == "$", byte == 0x70 {
            let status = modeStatus(first, privateMode: priv).map { $0 ? 1 : 2 } ?? 0
            reply("\(priv ? "?" : "")\(first);\(status)$y")
            return
        }
        if args.intermediate == "!", byte == 0x70 {
            modes = TerminalModes()
            style = TerminalStyle()
            graphics = [false, false]
            g1 = false
            screen.top = 0
            screen.bottom = rows - 1
            screen.pendingWrap = false
            screen.saved = CursorState()
            mark(y)
            return
        }
        guard args.intermediate.isEmpty else { return }
        if byte == 0x63 {
            if first == 0 {
                if args.prefix == 0x3e { reply(">0;1;0c") }
                else if args.prefix == nil { reply("?1;2c") }
            }
            return
        }
        guard args.prefix == nil || priv else { return }
        if byte == 0x68 || byte == 0x6c {
            for i in args.values.indices { setMode(args.value(i), privateMode: priv, enabled: byte == 0x68) }
            return
        }
        if byte == 0x6e {
            if first == 5 && !priv { reply("0n") }
            if first == 6 { reply("\(priv ? "?" : "")\(y - (modes.origin ? screen.top : 0) + 1);\(x + 1)R") }
            return
        }
        guard !priv || byte == 0x4a || byte == 0x4b else { return }
        let top = y >= screen.top ? screen.top : 0
        let bottom = y <= screen.bottom ? screen.bottom : rows - 1
        switch byte {
        case 0x40: shiftCharacters(n, right: true)
        case 0x41: move(row: max(top, y - n), column: x)
        case 0x42, 0x65: move(row: min(bottom, y + n), column: x)
        case 0x43, 0x61: move(row: y, column: x + n)
        case 0x44: move(row: y, column: x - n)
        case 0x45: move(row: min(bottom, y + n), column: 0)
        case 0x46: move(row: max(top, y - n), column: 0)
        case 0x47, 0x60: move(row: y, column: n - 1)
        case 0x48, 0x66: locate(n - 1, max(1, args.value(1)) - 1)
        case 0x49: tab(n, backwards: false)
        case 0x4a: eraseDisplay(first)
        case 0x4b:
            if first == 0 { clear(y, from: x, through: columns - 1) }
            else if first == 1 { clear(y, from: 0, through: x) }
            else if first == 2 { clear(y, from: 0, through: columns - 1) }
            screen.pendingWrap = false
        case 0x4c, 0x4d:
            if (screen.top...screen.bottom).contains(y) {
                scroll(top: y, bottom: screen.bottom, count: n, up: byte == 0x4d, capture: false)
                move(row: y, column: 0)
            }
        case 0x50: shiftCharacters(n, right: false)
        case 0x53, 0x54: scroll(top: screen.top, bottom: screen.bottom, count: n, up: byte == 0x53, capture: true)
        case 0x58: clear(y, from: x, through: min(columns - 1, x + n - 1))
        case 0x5a: tab(n, backwards: true)
        case 0x62:
            if var glyph = lastGraphic {
                glyph.style = style
                for _ in 0..<n { printGlyph(glyph) }
            }
        case 0x64: locate(n - 1, x)
        case 0x67:
            if first == 0 { tabs.remove(x) }
            else if first == 3 { tabs.removeAll() }
        case 0x6d: applyStyle(args)
        case 0x72:
            let newTop = n - 1
            let requestedBottom = args.value(1)
            let newBottom = requestedBottom == 0 ? rows - 1 : min(requestedBottom, rows) - 1
            if newTop < newBottom || rows == 1 && newTop == 0 && newBottom == 0 {
                screen.top = newTop
                screen.bottom = newBottom
                locate(0, 0)
            }
        case 0x73: saveCursor()
        case 0x74:
            if first == 18 { reply("8;\(rows);\(columns)t") }
        case 0x75: restoreCursor()
        default: break
        }
    }

    private func eraseDisplay(_ mode: Int) {
        let x = screen.column, y = screen.row
        let blank = Array(repeating: erased, count: columns)
        switch mode {
        case 0:
            clear(y, from: x, through: columns - 1)
            for row in (y + 1)..<rows { screen.grid[row] = blank; screen.wrapped[row] = nil }
            dirty.insert(integersIn: y..<rows)
        case 1:
            clear(y, from: 0, through: x)
            for row in 0..<y { screen.grid[row] = blank; screen.wrapped[row] = nil }
            dirty.insert(integersIn: 0..<(y + 1))
        case 2:
            screen.grid = Array(repeating: blank, count: rows)
            screen.wrapped = Array(repeating: nil, count: rows)
            dirty = IndexSet(integersIn: 0..<rows)
        case 3:
            if !isAlternateScreen { history.trim(rows: 0) }
        default: break
        }
        screen.pendingWrap = false
    }

    private func setMode(_ number: Int, privateMode: Bool, enabled: Bool) {
        if !privateMode {
            if number == 4 { modes.insert = enabled }
            if number == 20 { modes.newline = enabled }
            return
        }
        switch number {
        case 1: modes.applicationCursor = enabled
        case 6: modes.origin = enabled; locate(0, 0)
        case 7: modes.autoWrap = enabled; screen.pendingWrap = false
        case 9, 1000, 1002, 1003:
            let tracking: TerminalMouseTracking
            switch number {
            case 9: tracking = .x10
            case 1000: tracking = .normal
            case 1002: tracking = .buttonMotion
            default: tracking = .anyMotion
            }
            if enabled { modes.mouseTracking = tracking }
            else if modes.mouseTracking == tracking { modes.mouseTracking = .none }
        case 25: modes.cursorVisible = enabled; mark(screen.row)
        case 47, 1047, 1049: setAlternate(enabled, mode: number)
        case 66: modes.applicationKeypad = enabled
        case 1004: modes.focusReporting = enabled
        case 1006: modes.sgrMouse = enabled
        case 1048: if enabled { saveCursor() } else { restoreCursor() }
        case 2004: modes.bracketedPaste = enabled
        case 2026: modes.synchronizedOutput = enabled
        default: break
        }
    }

    private func modeStatus(_ number: Int, privateMode: Bool) -> Bool? {
        if !privateMode {
            if number == 4 { return modes.insert }
            if number == 20 { return modes.newline }
            return nil
        }
        switch number {
        case 1: return modes.applicationCursor
        case 6: return modes.origin
        case 7: return modes.autoWrap
        case 9: return modes.mouseTracking == .x10
        case 25: return modes.cursorVisible
        case 47, 1047, 1049: return isAlternateScreen
        case 66: return modes.applicationKeypad
        case 1000: return modes.mouseTracking == .normal
        case 1002: return modes.mouseTracking == .buttonMotion
        case 1003: return modes.mouseTracking == .anyMotion
        case 1004: return modes.focusReporting
        case 1006: return modes.sgrMouse
        case 2004: return modes.bracketedPaste
        case 2026: return modes.synchronizedOutput
        default: return nil
        }
    }

    private func applyStyle(_ args: Arguments) {
        var index = 0
        while index < args.values.count {
            let value = args.value(index)
            let sub = args.values[index]
            index += 1
            switch value {
            case 0: style = TerminalStyle()
            case 1: style.bold = true
            case 2: style.faint = true
            case 3: style.italic = true
            case 4: style.underline = sub.count == 1 || sub[1] != 0
            case 5, 6: style.blink = true
            case 7: style.inverse = true
            case 8: style.invisible = true
            case 9: style.strikethrough = true
            case 21: style.underline = true
            case 22: style.bold = false; style.faint = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 25: style.blink = false
            case 27: style.inverse = false
            case 28: style.invisible = false
            case 29: style.strikethrough = false
            case 30...37: style.foreground = .indexed(value - 30)
            case 39: style.foreground = .defaultColor
            case 40...47: style.background = .indexed(value - 40)
            case 49: style.background = .defaultColor
            case 90...97: style.foreground = .indexed(value - 90 + 8)
            case 100...107: style.background = .indexed(value - 100 + 8)
            case 38, 48, 58:
                var color: TerminalColor?
                if sub.count > 1 {
                    if sub[1] == 5, sub.count == 3, let c = sub[2], c <= 255 { color = .indexed(c) }
                    if sub[1] == 2, sub.count == 5 || sub.count == 6 && (sub[2] ?? 0) == 0 {
                        color = rgb(Array(sub.suffix(3)))
                    }
                } else if index < args.values.count {
                    let type = args.value(index)
                    index += 1
                    if type == 5, index < args.values.count {
                        if let c = args.values[index][0], c <= 255 { color = .indexed(c) }
                        index += 1
                    } else if type == 2 {
                        let end = min(index + 3, args.values.count)
                        color = rgb(args.values[index..<end].map { $0[0] })
                        index = end
                    }
                }
                if let color = color {
                    if value == 38 { style.foreground = color }
                    if value == 48 { style.background = color }
                }
            default: break
            }
        }
    }

    private func rgb(_ components: [Int?]) -> TerminalColor? {
        guard components.count == 3, let r = components[0], let g = components[1], let b = components[2],
              r <= 255, g <= 255, b <= 255 else { return nil }
        return .rgb(r, g, b)
    }
}
