import Foundation
import T3Engine
import T3Sessions
import T3Integration

struct TerminalFrame {
    let first: Int
    let history: Int
    let start: Int
    let count: Int
    let changes: [Int: [TerminalCell]]
    let cursorColumn: Int
    let cursorLine: Int
    let modes: TerminalModes
}

struct Transcript {
    let text: String
    let anchor: Int?
}

final class TerminalModel {
    private let queue = DispatchQueue(label: "t3rm.terminal", qos: .userInitiated)
    private let engine = TerminalEngine(columns: 80, rows: 24)
    private let session = TerminalSession()
    private let notification = DispatchSource.makeUserDataAddSource(queue: .main)
    private let effectLock = NSLock()
    private var pendingTitle: String?
    private var pendingCopy: String?
    private var pendingDirectory: String?
    private var pendingBell = false
    private var pendingTransfer: TerminalEffect?
    private var previousWindow: Range<Int>?
    private var previousHistory = 0
    private var synchronizationStart: TimeInterval?
    private var historyBudget = 24 * 1024 * 1024
    private var launched = false
    private var closed = false
    private var observedEnd = false
    var onChange: (() -> Void)?
    var onEffect: ((TerminalEffect) -> Void)?
    var onWriteRejected: (() -> Void)?
    var onExit: ((String) -> Void)?

    init() {
        notification.setEventHandler { [weak self] in self?.publish() }
        notification.resume()
    }

    deinit { notification.cancel() }

    func start(directory: String?, columns: Int, rows: Int) {
        queue.async { [self] in
            guard !launched && !closed else { return }
            launched = true
            engine.resize(columns: columns, rows: rows)
            do {
                try session.start(directory: directory, columns: columns, rows: rows, onData: { [weak self] bytes in
                    self?.receive(bytes)
                }, onExit: { [weak self] code in
                    self?.queue.async { [weak self] in self?.end("Session ended (\(code))") }
                })
            } catch {
                end("Unable to start shell. \(error.localizedDescription)")
            }
            notification.add(data: 1)
        }
    }

    private func end(_ reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !observedEnd && !closed else { return }
        observedEnd = true
        DispatchQueue.main.async { [weak self] in self?.onExit?(reason) }
    }

    private func receive(_ bytes: Data) {
        // The session worker resumes reading after this returns, bounding output in flight.
        queue.sync { [self] in
            guard !closed else { return }
            let effects = engine.feed(bytes)
            if !effects.isEmpty {
                var title: String?
                var copiedText: String?
                var directory: String?
                var bell = false
                var transfer: TerminalEffect?
                var rejectedUpload = false
                for effect in effects {
                    switch effect {
                    case .reply(let response): session.write(response)
                    case .title(let value): title = value
                    case .copyText(let value): if copiedText == nil { copiedText = value }
                    case .workingDirectory(let path): directory = path
                    case .bell: bell = true
                    case .uploadRequest:
                        if transfer == nil { transfer = effect } else { rejectedUpload = true }
                    case .download: if transfer == nil { transfer = effect }
                    }
                }
                effectLock.lock()
                if let title = title { pendingTitle = title }
                if pendingCopy == nil { pendingCopy = copiedText }
                if let directory = directory { pendingDirectory = directory }
                pendingBell = pendingBell || bell
                if pendingTransfer == nil { pendingTransfer = transfer }
                else if case .uploadRequest? = transfer { rejectedUpload = true }
                effectLock.unlock()
                if rejectedUpload { session.write(TransferArchive.cancel) }
            }
            applyBudget()
            notification.add(data: 1)
        }
    }

    private func publish() {
        effectLock.lock()
        let title = pendingTitle
        let copiedText = pendingCopy
        let directory = pendingDirectory
        let bell = pendingBell
        let transfer = pendingTransfer
        pendingTitle = nil
        pendingCopy = nil
        pendingDirectory = nil
        pendingBell = false
        pendingTransfer = nil
        effectLock.unlock()
        if let directory = directory { onEffect?(.workingDirectory(directory)) }
        if let title = title { onEffect?(.title(title)) }
        if let value = copiedText { onEffect?(.copyText(value)) }
        if bell { onEffect?(.bell) }
        if let transfer = transfer { onEffect?(transfer) }
        onChange?()
    }

    private func applyBudget() {
        if engine.historyStorageBytes > historyBudget { engine.trimHistory(toBytes: historyBudget) }
    }

    func foregroundCommandIs(_ name: String) -> Bool { session.foregroundCommandIs(name) }

    var hasNonblankBeforeCursor: Bool {
        queue.sync { engine.hasNonblankBeforeCursor }
    }

    func resize(columns: Int, rows: Int) {
        queue.async { [self] in
            guard !closed, columns != engine.columns || rows != engine.rows else { return }
            engine.resize(columns: columns, rows: rows)
            applyBudget()
            session.resize(columns: columns, rows: rows)
            previousWindow = nil
            notification.add(data: 1)
        }
    }

    // Read modes on the same queue as incoming control sequences.
    func send(_ encode: @escaping (TerminalModes) -> Data) {
        queue.async { [self] in
            guard !closed && !observedEnd else { return }
            let bytes = encode(engine.modes)
            if !bytes.isEmpty, !session.tryWrite(bytes) {
                DispatchQueue.main.async { [weak self] in self?.onWriteRejected?() }
            }
        }
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            session.close()
        }
    }

    func setColors(foreground: TerminalColor, background: TerminalColor) {
        queue.async { [self] in
            engine.defaultForegroundRGB = foreground
            engine.defaultBackgroundRGB = background
        }
    }

    func trim(bytes: Int) {
        queue.async { [self] in
            historyBudget = bytes
            engine.trimHistory(toBytes: bytes)
            previousWindow = nil
            notification.add(data: 1)
        }
    }

    // A nil top follows the cursor screen. Changes are indexed from the first
    // retained line. Snapshot only the rows a view can actually display.
    func frame(top: Int?, capacity: Int, force: Bool, completion: @escaping (TerminalFrame?) -> Void) {
        queue.async { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            if engine.modes.synchronizedOutput {
                if synchronizationStart == nil { synchronizationStart = now }
                if now - (synchronizationStart ?? now) < 0.15 {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
            } else { synchronizationStart = nil }
            let history = engine.historyCount
            let first = engine.discardedHistoryLines
            let screen = first + history
            let start = max(first, min(screen, top ?? screen))
            let window = start..<min(screen + engine.rows, start + capacity)
            let dirty = engine.takeDirtyRows()
            var changes: [Int: [TerminalCell]] = [:]
            let shifted = previousHistory != screen
            for index in window {
                if force || shifted || previousWindow?.contains(index) != true || (index >= screen && dirty.contains(index - screen)) {
                    changes[index] = engine.line(at: index - first)
                }
            }
            previousWindow = window
            previousHistory = screen
            let frame = TerminalFrame(first: first, history: history, start: start, count: window.count, changes: changes,
                                      cursorColumn: engine.cursorColumn, cursorLine: screen + engine.cursorRow,
                                      modes: engine.modes)
            DispatchQueue.main.async { completion(frame) }
        }
    }

    func transcript(line target: Int?, column: Int?, _ completion: @escaping (Transcript) -> Void) {
        queue.async { [self] in
            var text = ""
            var selection: Int?
            var offset = 0
            let count = engine.historyCount + engine.rows
            let first = engine.discardedHistoryLines
            for index in 0..<count {
                let cells = engine.line(at: index)
                let wrapped = engine.wrappedLength(at: index)
                let used = min(wrapped ?? cells.count, cells.count)
                var line = ""
                var textOffset = 0
                for pos in 0..<used where cells[pos].width > 0 {
                    let cell = cells[pos]
                    if first + index == target, let column = column,
                       (pos..<(pos + cell.width)).contains(column) { selection = offset + textOffset }
                    line += cell.text
                    textOffset += cell.text.utf16.count
                }
                if wrapped == nil { while line.last == " " { line.removeLast() } }
                text.append(line)
                offset += line.utf16.count
                if wrapped == nil && index + 1 < count { text.append("\n"); offset += 1 }
            }
            let anchor = selection.map { min($0, max(0, offset - 1)) }
            let result = Transcript(text: text, anchor: anchor)
            DispatchQueue.main.async { completion(result) }
        }
    }
}
