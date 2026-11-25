import Foundation

public enum TerminalColor: Equatable {
    case defaultColor
    case indexed(Int)
    case rgb(Int, Int, Int)
}

public struct TerminalStyle: Equatable {
    public var foreground: TerminalColor = .defaultColor
    public var background: TerminalColor = .defaultColor
    public var bold = false
    public var faint = false
    public var italic = false
    public var underline = false
    public var blink = false
    public var inverse = false
    public var invisible = false
    public var strikethrough = false

    public init() {}

    /// Traditional ANSI themes use a bright color for bold base-palette foregrounds.
    public var brightBoldForeground: TerminalColor {
        if bold, case let .indexed(index) = foreground, (0..<8).contains(index) {
            return .indexed(index + 8)
        }
        return foreground
    }
}

public struct TerminalCell: Equatable {
    public var text: String
    /// A wide glyph occupies its leading cell and a width-zero continuation cell.
    public var width: Int
    public var style: TerminalStyle

    public init(text: String = " ", width: Int = 1, style: TerminalStyle = TerminalStyle()) {
        self.text = text
        self.width = width
        self.style = style
    }
}

public enum TerminalMouseTracking: Equatable {
    case none, x10, normal, buttonMotion, anyMotion
}

public struct TerminalModes: Equatable {
    public internal(set) var applicationCursor = false
    public internal(set) var applicationKeypad = false
    public internal(set) var bracketedPaste = false
    public internal(set) var cursorVisible = true
    public internal(set) var focusReporting = false
    public internal(set) var sgrMouse = false
    public internal(set) var mouseTracking: TerminalMouseTracking = .none
    public var mouseReporting: Bool { mouseTracking != .none }
    public internal(set) var synchronizedOutput = false
    public internal(set) var autoWrap = true
    public internal(set) var origin = false
    public internal(set) var insert = false
    public internal(set) var newline = false
}

public enum TerminalEffect: Equatable {
    case reply(Data)
    case title(String)
    case bell
    case workingDirectory(String)
    case uploadRequest
    case download(name: String, data: Data)
}

struct CursorState {
    var row = 0
    var column = 0
    var style = TerminalStyle()
    var origin = false
    var autoWrap = true
    var pendingWrap = false
    var graphics = [false, false]
    var g1 = false
}

final class Screen {
    var grid: [[TerminalCell]]
    // For soft-wrapped rows, record how many source columns belong to this paragraph.
    var wrapped: [Int?]
    var row = 0
    var column = 0
    var top = 0
    var bottom: Int
    var pendingWrap = false
    var saved = CursorState()

    init(columns: Int, rows: Int) {
        let blank = Array(repeating: TerminalCell(), count: columns)
        grid = Array(repeating: blank, count: rows)
        wrapped = Array(repeating: nil, count: rows)
        bottom = rows - 1
    }
}
