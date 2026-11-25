import Foundation

enum ParserState: Equatable {
    case ground, escape, escapeIntermediate, csi, ignoreCSI, osc, ignoredString
}

extension TerminalEngine {
    /// Replies and notifications are returned in wire order. Partial sequences
    /// and the last grapheme remain available across arbitrary PTY read sizes.
    @discardableResult
    public func feed(_ data: Data) -> [TerminalEffect] {
        var effects = [TerminalEffect]()
        data.withUnsafeBytes { raw in
            consume(raw.bindMemory(to: UInt8.self), effects: &effects)
        }
        return effects
    }

    private func consume(_ bytes: UnsafeBufferPointer<UInt8>, effects: inout [TerminalEffect]) {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if parser == .ground, utf8Remaining == 0, (0x20...0x7e).contains(byte),
               !modes.insert, !graphics[g1 ? 1 : 0] {
                let start = index - 1
                while index < bytes.count && (0x20...0x7e).contains(bytes[index]) { index += 1 }
                printASCIIRun(bytes, from: start, to: index)
                continue
            }
            if parser == .ground && utf8Remaining > 0 {
                if byte >= utf8Min && byte <= utf8Max {
                    utf8Value = (utf8Value << 6) | UInt32(byte & 0x3f)
                    utf8Min = 0x80
                    utf8Max = 0xbf
                    utf8Remaining -= 1
                    if utf8Remaining == 0, let scalar = Unicode.Scalar(utf8Value) { printScalar(scalar) }
                    continue
                }
                printScalar("\u{fffd}")
                utf8Remaining = 0
            }
            if byte == 0x18 || byte == 0x1a {
                parser = .ground
                releaseString()
                anchor = nil
                continue
            }
            if parser == .osc || parser == .ignoredString {
                consumeString(byte, effects: &effects)
                continue
            }
            if byte == 0x1b {
                parser = .escape
                parameters.removeAll(keepingCapacity: true)
                anchor = nil
                continue
            }
            if byte < 0x20 || byte == 0x7f {
                control(byte, effects: &effects)
                continue
            }
            switch parser {
            case .ground:
                switch byte {
                case 0x20...0x7e: printASCII(byte)
                case 0xc2...0xdf: startUTF8(byte & 0x1f, remaining: 1)
                case 0xe0...0xef:
                    startUTF8(byte & 0xf, remaining: 2, min: byte == 0xe0 ? 0xa0 : 0x80,
                              max: byte == 0xed ? 0x9f : 0xbf)
                case 0xf0...0xf4:
                    startUTF8(byte & 7, remaining: 3, min: byte == 0xf0 ? 0x90 : 0x80,
                              max: byte == 0xf4 ? 0x8f : 0xbf)
                case 0x84: advance()
                case 0x85: move(row: screen.row, column: 0); advance()
                case 0x8d: advance(reverse: true)
                case 0x90, 0x98, 0x9e, 0x9f: startString(.ignoredString)
                case 0x9b: startCSI()
                case 0x9d: startString(.osc)
                case 0x9c: break
                default: printScalar("\u{fffd}")
                }
            case .escape, .escapeIntermediate:
                if (0x20...0x2f).contains(byte) {
                    parser = .escapeIntermediate
                    if parameters.count < 8 { parameters.append(byte) }
                } else {
                    let intermediate = parameters
                    parser = .ground
                    finishEscape(byte, intermediate: intermediate, effects: &effects)
                }
            case .csi, .ignoreCSI:
                if (0x40...0x7e).contains(byte) {
                    let accepted = parser == .csi
                    parser = .ground
                    if accepted { finishCSI(byte, effects: &effects) }
                    parameters.removeAll(keepingCapacity: true)
                } else if !(0x20...0x3f).contains(byte) || parameters.count >= 256 {
                    parser = .ignoreCSI
                } else if parser == .csi {
                    parameters.append(byte)
                }
            case .osc, .ignoredString: break
            }
        }
    }

    private func startUTF8(_ value: UInt8, remaining: Int, min: UInt8 = 0x80, max: UInt8 = 0xbf) {
        utf8Value = UInt32(value)
        utf8Remaining = remaining
        utf8Min = min
        utf8Max = max
    }

    private func control(_ byte: UInt8, effects: inout [TerminalEffect]) {
        switch byte {
        case 7: effects.append(.bell)
        case 8: move(row: screen.row, column: screen.column - 1)
        case 9: tab(1, backwards: false)
        case 10...12:
            if modes.newline { move(row: screen.row, column: 0) }
            advance()
        case 13: move(row: screen.row, column: 0)
        case 14: g1 = true
        case 15: g1 = false
        default: break
        }
    }

    func tab(_ count: Int, backwards: Bool) {
        var column = screen.column
        for _ in 0..<min(count, columns) {
            if backwards {
                column = tabs.integerLessThan(column) ?? 0
            } else {
                column = tabs.integerGreaterThan(column) ?? columns - 1
            }
        }
        move(row: screen.row, column: column)
    }

    private func startCSI() {
        parser = .csi
        parameters.removeAll(keepingCapacity: true)
        anchor = nil
    }

    private func startString(_ type: ParserState) {
        parser = type
        stringBytes.removeAll(keepingCapacity: true)
        stringLimit = 8192
        stringEscaped = false
        stringOverflow = false
        stringUTF8Remaining = 0
        anchor = nil
    }

    private func releaseString() {
        if !stringBytes.isEmpty || stringBytes.capacity > 8192 {
            stringBytes.removeAll(keepingCapacity: stringBytes.capacity <= 8192)
        }
        stringEscaped = false
        stringUTF8Remaining = 0
    }

    private func consumeString(_ byte: UInt8, effects: inout [TerminalEffect]) {
        if stringEscaped {
            stringEscaped = false
            if byte == 0x5c {
                if parser == .osc && !stringOverflow { finishOSC(effects: &effects) }
                releaseString()
                parser = .ground
            } else if parser == .ignoredString {
                // DCS/APC/PM payload is opaque, including embedded escapes.
                return
            } else {
                // An ESC inside a string can also start a new control sequence.
                releaseString()
                parameters.removeAll(keepingCapacity: true)
                parser = .escape
                if byte != 0x1b {
                    parser = .ground
                    finishEscape(byte, intermediate: [], effects: &effects)
                }
            }
            return
        }
        if byte == 0x1b { stringEscaped = true; return }
        if byte == 0x9c && stringUTF8Remaining == 0 || byte == 7 && parser == .osc {
            if parser == .osc && !stringOverflow { finishOSC(effects: &effects) }
            releaseString()
            parser = .ground
            return
        }
        if (0x80...0xbf).contains(byte), stringUTF8Remaining > 0 { stringUTF8Remaining -= 1 }
        else {
            switch byte {
            case 0xc2...0xdf: stringUTF8Remaining = 1
            case 0xe0...0xef: stringUTF8Remaining = 2
            case 0xf0...0xf4: stringUTF8Remaining = 3
            default: stringUTF8Remaining = 0
            }
        }
        guard parser == .osc, !stringOverflow, byte >= 0x20, byte != 0x7f else { return }
        if stringBytes.count >= stringLimit {
            stringOverflow = true
            releaseString()
            return
        }
        stringBytes.append(byte)
        if stringBytes.count == 10, stringBytes.elementsEqual("1337;File=".utf8) {
            stringLimit = Self.downloadEncodedLimit + 8192
        }
    }

    private func finishEscape(_ byte: UInt8, intermediate: [UInt8], effects: inout [TerminalEffect]) {
        if !intermediate.isEmpty {
            if intermediate == [0x28] || intermediate == [0x29] {
                graphics[intermediate[0] == 0x28 ? 0 : 1] = byte == 0x30
            } else if intermediate == [0x23], byte == 0x38 {
                let line = Array(repeating: TerminalCell(text: "E"), count: columns)
                screen.grid = Array(repeating: line, count: rows)
                screen.wrapped = Array(repeating: nil, count: rows)
                dirty = IndexSet(integersIn: 0..<rows)
            }
            return
        }
        switch byte {
        case 0x37: saveCursor()
        case 0x38: restoreCursor()
        case 0x3d: modes.applicationKeypad = true
        case 0x3e: modes.applicationKeypad = false
        case 0x44: advance()
        case 0x45: move(row: screen.row, column: 0); advance()
        case 0x48: tabs.insert(screen.column)
        case 0x4d: advance(reverse: true)
        case 0x50, 0x58, 0x5e, 0x5f: startString(.ignoredString)
        case 0x5a: effects.append(.reply(Data("\u{1b}[?1;2c".utf8)))
        case 0x5b: startCSI()
        case 0x5d: startString(.osc)
        case 0x63: reset()
        default: break
        }
    }

    private static let downloadLimit = 1024 * 1024
    private static let downloadEncodedLimit = ((downloadLimit + 2) / 3) * 4

    private func finishOSC(effects: inout [TerminalEffect]) {
        if stringBytes.starts(with: "1337;File=".utf8) {
            guard let colon = stringBytes.firstIndex(of: 0x3a), colon <= 8192 else { return }
            let payload = stringBytes[(colon + 1)...]
            guard payload.count <= Self.downloadEncodedLimit else { return }
            let header = String(decoding: stringBytes[10..<colon], as: UTF8.self)
            var name = "Download"
            var size: Int?
            for option in header.split(separator: ";") {
                let pair = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "inline" where pair[1] != "0": return
                case "size":
                    guard let count = Int(pair[1]), (0...Self.downloadLimit).contains(count) else { return }
                    size = count
                case "name":
                    guard pair[1].utf8.count <= 1024, let raw = Data(base64Encoded: String(pair[1])),
                          let value = String(data: raw, encoding: .utf8) else { return }
                    let base = (value as NSString).lastPathComponent
                    if !base.isEmpty, base != ".", base != "..", base != "/",
                       !base.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                        name = base
                    }
                default: break
                }
            }
            guard let data = Data(base64Encoded: Data(payload)), data.count <= Self.downloadLimit,
                  size.map({ $0 == data.count }) ?? true else { return }
            effects.append(.download(name: name, data: data))
            return
        }
        let string = String(decoding: stringBytes, as: UTF8.self)
        guard let semicolon = string.firstIndex(of: ";") else { return }
        let body = String(string[string.index(after: semicolon)...])
        switch string[..<semicolon] {
        case "0", "2": effects.append(.title(body))
        case "7":
            guard let url = URLComponents(string: body), url.scheme?.lowercased() == "file",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  validDirectory(url.path) else { return }
            reportedDirectoryHost = url.host.flatMap { $0.isEmpty ? nil : $0 }
            effects.append(.workingDirectory(body))
        case "10", "11":
            let opcode = String(string[..<semicolon])
            let color = opcode == "10" ? defaultForegroundRGB : defaultBackgroundRGB
            if body == "?", case let .rgb(r, g, b) = color {
                let components = [r, g, b].map { String(format: "%04x", min(255, max(0, $0)) * 257) }
                let response = "\u{1b}]" + opcode + ";rgb:" + components.joined(separator: "/") + "\u{1b}\\"
                effects.append(.reply(Data(response.utf8)))
            }
        case "1337":
            if body.hasPrefix("RequestUpload=") {
                let options = body.dropFirst("RequestUpload=".count).split(separator: ";")
                let formats = options.filter { $0.hasPrefix("format=") }
                if formats == ["format=tgz"] { effects.append(.uploadRequest) }
            } else if body.hasPrefix("RemoteHost=") {
                let identity = body.dropFirst("RemoteHost=".count)
                // Keep a remote hint even for malformed host reports; a following
                // CurrentDir must not silently turn into a local filesystem path.
                reportedDirectoryHost = identity.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            } else if body.hasPrefix("CurrentDir=") {
                let path = String(body.dropFirst("CurrentDir=".count))
                guard validDirectory(path) else { return }
                if let host = reportedDirectoryHost {
                    guard !host.isEmpty else { return }
                    var url = URLComponents()
                    url.scheme = "file"
                    url.host = host
                    url.path = path
                    if let location = url.string { effects.append(.workingDirectory(location)) }
                } else { effects.append(.workingDirectory(path)) }
            }
        default: break
        }
    }

    private func validDirectory(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
