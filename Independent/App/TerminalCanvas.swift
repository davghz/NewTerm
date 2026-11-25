import UIKit
import CoreText
import T3Engine
import os.signpost

private struct GlyphRun {
    let column: Int
    let width: Int
    let background: UIColor
    let line: CTLine?
    let text: String
}

final class TerminalCanvas: UIView {
    private static let performance = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "t3rm", category: "TerminalRenderer")
    private(set) var font = Preferences.font
    private(set) var palette = Palette(name: Preferences.defaults.string(forKey: "themeName") ?? "")
    private(set) var cellSize = CGSize(width: 8, height: 16)
    private var rows: [Int: [GlyphRun]] = [:]
    private var fonts: [Int: UIFont] = [:]
    private var fixedPitch = true
    private(set) var frameData: TerminalFrame?
    var fraction: CGFloat = 0
    var horizontalInset: CGFloat = 4
    var active = false { didSet { if oldValue != active { setNeedsDisplay() } } }
    var activate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isAccessibilityElement = true
        accessibilityIdentifier = "t3rm.terminal"
        accessibilityLabel = "Terminal"
        accessibilityTraits = [.allowsDirectInteraction]
        refreshAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityActivate() -> Bool { activate?(); return true }
    override var accessibilityValue: String? {
        get {
            guard let data = frameData else { return nil }
            return (data.start..<(data.start + data.count)).compactMap { index in
                rows[index]?.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        set {}
    }

    func refreshAppearance() {
        font = Preferences.font
        fixedPitch = font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        palette = Palette(name: Preferences.defaults.string(forKey: "themeName") ?? "Midnight")
        cellSize = CGSize(width: max(1, ("M" as NSString).size(withAttributes: [.font: font]).width),
                          height: ceil(font.lineHeight))
        fonts.removeAll()
        backgroundColor = palette.background
        clearCache()
    }

    func clearCache() {
        frameData = nil
        rows.removeAll(keepingCapacity: false)
        setNeedsDisplay()
    }

    func apply(_ data: TerminalFrame, fraction: CGFloat) {
        let trace = OSSignpostID(log: Self.performance)
        os_signpost(.begin, log: Self.performance, name: "LayoutRows", signpostID: trace)
        defer { os_signpost(.end, log: Self.performance, name: "LayoutRows", signpostID: trace) }
        let old = frameData
        let moved = old?.start != data.start || old?.count != data.count || self.fraction != fraction
        self.fraction = fraction
        let window = data.start..<(data.start + data.count)
        for index in rows.keys where !window.contains(index) { rows.removeValue(forKey: index) }
        for (index, cells) in data.changes { rows[index] = layoutRow(cells) }
        frameData = data
        if moved { setNeedsDisplay(); return }
        for index in data.changes.keys { invalidate(line: index) }
        if old?.cursorLine != data.cursorLine || old?.cursorColumn != data.cursorColumn ||
            old?.modes.cursorVisible != data.modes.cursorVisible {
            if let line = old?.cursorLine { invalidate(line: line) }
            invalidate(line: data.cursorLine)
        }
    }

    private func invalidate(line: Int) {
        guard let data = frameData, line >= data.start, line < data.start + data.count else { return }
        setNeedsDisplay(CGRect(x: 0, y: CGFloat(line - data.start) * cellSize.height - fraction,
                               width: bounds.width, height: cellSize.height).integral)
    }

    func address(_ point: CGPoint) -> (column: Int, line: Int) {
        let column = max(0, Int(floor((point.x-horizontalInset) / cellSize.width)))
        let line = (frameData?.start ?? 0) + max(0, Int(floor((point.y + fraction) / cellSize.height)))
        return (column, line)
    }

    private func color(_ color: TerminalColor, fallback: UIColor) -> UIColor {
        switch color {
        case .defaultColor: return fallback
        case .indexed(let number): return palette.indexed(number)
        case .rgb(let r, let g, let b):
            return UIColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
        }
    }

    private func face(_ style: TerminalStyle) -> UIFont {
        let key = (style.bold ? 1 : 0) | (style.italic ? 2 : 0)
        if let cached = fonts[key] { return cached }
        var traits = font.fontDescriptor.symbolicTraits
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        let result = font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        fonts[key] = result
        return result
    }

    private func layoutRow(_ cells: [TerminalCell]) -> [GlyphRun] {
        var output: [GlyphRun] = []
        var index = 0
        while index < cells.count {
            let cell = cells[index]
            guard cell.width > 0 else { index += 1; continue }
            let start = index
            var string = cell.text
            index += max(1, cell.width)
            // Draw simple monospace runs together. A grapheme needing fallback gets
            // its own origin so a proportional fallback cannot displace later cells.
            if fixedPitch && cell.width == 1 && cell.text.utf8.count == 1 {
                while index < cells.count && cells[index].width == 1 && cells[index].text.utf8.count == 1 &&
                        cells[index].style == cell.style {
                    string += cells[index].text
                    index += 1
                }
            }
            let style = cell.style
            var ink = color(style.brightBoldForeground, fallback: palette.foreground)
            var paper = color(style.background, fallback: palette.background)
            if style.inverse { swap(&ink, &paper) }
            if style.faint { ink = ink.withAlphaComponent(0.55) }
            if style.invisible { ink = paper }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: face(style), .foregroundColor: ink, .ligature: 0, .kern: 0,
                .strikethroughStyle: style.strikethrough ? NSUnderlineStyle.single.rawValue : 0,
                .underlineStyle: style.underline ? NSUnderlineStyle.single.rawValue : 0
            ]
            let glyphs = (style.underline || string.contains(where: { $0 != " " })) ?
                CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs)) : nil
            output.append(GlyphRun(column: start, width: index-start, background: paper, line: glyphs, text: string))
        }
        return output
    }

    override func draw(_ rect: CGRect) {
        let trace = OSSignpostID(log: Self.performance)
        os_signpost(.begin, log: Self.performance, name: "DrawRows", signpostID: trace)
        defer { os_signpost(.end, log: Self.performance, name: "DrawRows", signpostID: trace) }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        palette.background.setFill()
        ctx.fill(rect)
        guard let data = frameData else { return }
        let first = max(0, Int(floor((rect.minY + fraction) / cellSize.height)))
        let end = min(data.count, Int(ceil((rect.maxY + fraction) / cellSize.height)))
        guard first < end else { return }
        for row in first..<end {
            let index = data.start + row
            let y = CGFloat(row) * cellSize.height - fraction
            for run in rows[index] ?? [] {
                let x = horizontalInset + CGFloat(run.column) * cellSize.width
                let box = CGRect(x: x, y: y, width: CGFloat(run.width) * cellSize.width, height: cellSize.height)
                if !run.background.isEqual(palette.background) { ctx.setFillColor(run.background.cgColor); ctx.fill(box) }
                guard let line = run.line else { continue }
                ctx.saveGState()
                ctx.clip(to: box)
                ctx.translateBy(x: x, y: y + font.ascender + (cellSize.height - font.lineHeight)/2)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textMatrix = .identity
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            if data.modes.cursorVisible && index == data.cursorLine {
                let x = horizontalInset + CGFloat(data.cursorColumn) * cellSize.width
                let box = CGRect(x: x, y: y, width: cellSize.width, height: cellSize.height)
                ctx.setStrokeColor(palette.foreground.cgColor)
                if active {
                    ctx.setFillColor(palette.foreground.cgColor)
                    ctx.fill(CGRect(x: x, y: box.maxY - 2, width: box.width, height: 2))
                } else { ctx.stroke(box.insetBy(dx: 0.5, dy: 0.5), width: 1) }
            }
        }
    }
}
