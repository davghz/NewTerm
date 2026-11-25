import Darwin
import Foundation
import T3PTY

/// A shell and its controlling terminal. Callbacks are ordered on a session
/// worker thread. Returning from onData allows the next block of output to be read.
public final class TerminalSession {
    private let lock = NSLock()
    private var current: SessionWorker?

    public init() {}

    deinit { close() }

    public func start(directory: String?, columns: Int, rows: Int,
                      onData: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws {
        guard let executable = Bundle.main.executableURL else {
            throw POSIXError(.ENOENT)
        }
        let launcher = executable.deletingLastPathComponent().appendingPathComponent("T3ShellLauncher").path
        try start(launcher: launcher, shell: Self.defaultShell, directory: directory,
                  columns: columns, rows: rows, onData: onData, onExit: onExit)
    }

    internal func start(launcher: String, shell: String, directory: String?, columns: Int, rows: Int,
                        onData: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard current?.isFinished != false else { throw POSIXError(.EBUSY) }
        guard [launcher, shell, directory ?? ""].allSatisfy({ !$0.utf8.contains(0) }) else {
            throw POSIXError(.EINVAL)
        }

        var terminal = t3_pty()
        var failure = t3_failure()
        let size = TerminalSize(columns: columns, rows: rows)
        guard t3_start(launcher, shell, directory ?? "", size.columns, size.rows, &terminal, &failure) == 0 else {
            let operation = String(cString: t3_operation(failure))
            let reason = String(cString: strerror(failure.number))
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure.number),
                          userInfo: [NSLocalizedDescriptionKey: "\(operation): \(reason)"])
        }
        let worker = SessionWorker(terminal, onData: onData, onExit: onExit)
        current = worker
        worker.start()
    }

    private static var defaultShell: String {
        #if os(iOS) && !targetEnvironment(simulator)
        let candidates = ["/var/jb/bin/zsh", "/var/jb/usr/bin/zsh", "/var/jb/bin/bash",
                          "/var/jb/usr/bin/bash", "/var/jb/bin/sh", "/var/jb/usr/bin/sh", "/bin/sh"]
        #else
        let candidates = [ProcessInfo.processInfo.environment["SHELL"] ?? "", "/bin/zsh", "/bin/sh"]
        #endif
        return candidates.first { $0.hasPrefix("/") && access($0, X_OK) == 0 } ?? "/bin/sh"
    }

    private var worker: SessionWorker? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func write(_ data: Data) { _ = tryWrite(data) }

    /// Accepts the entire input or returns false if the session is closing or
    /// its 2 MiB pending-input budget is exhausted. Suitable for paste admission.
    @discardableResult
    public func tryWrite(_ data: Data) -> Bool { worker?.enqueue(data) ?? false }

    public func resize(columns: Int, rows: Int) {
        worker?.resize(TerminalSize(columns: columns, rows: rows))
    }

    public func close() { worker?.requestClose() }
}

private struct TerminalSize {
    let columns: UInt16
    let rows: UInt16

    init(columns: Int, rows: Int) {
        self.columns = max(1, UInt16(clamping: columns))
        self.rows = max(1, UInt16(clamping: rows))
    }
}

private final class SessionWorker {
    private let terminal: t3_pty
    private var onData: ((Data) -> Void)?
    private var onExit: ((Int32) -> Void)?

    // The worker owns the PTY and child. Producers hold the lock only to
    // change bounded pending state and wake the worker. No callbacks hold it.
    private let lock = NSLock()
    private var finished = false
    private var closing = false
    private var pendingSize: TerminalSize?
    private var input = Data()
    private var sent = 0
    private static let inputLimit = 2 * 1024 * 1024

    init(_ terminal: t3_pty, onData: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) {
        self.terminal = terminal
        self.onData = onData
        self.onExit = onExit
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func start() {
        Thread.detachNewThread {
            Thread.current.name = "T3RM terminal"
            self.run()
        }
    }

    func enqueue(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished && !closing && data.count <= Self.inputLimit - (input.count - sent) else {
            return false
        }
        guard !data.isEmpty else { return true }
        if data.count > Self.inputLimit - input.count {
            input.removeFirst(sent)
            sent = 0
        }
        input.append(data)
        t3_wake(terminal.events)
        return true
    }

    func resize(_ size: TerminalSize) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished && !closing else { return }
        pendingSize = size
        t3_wake(terminal.events)
    }

    func requestClose() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished && !closing else { return }
        closing = true
        t3_wake(terminal.events)
    }

    private func applyPending() -> (closing: Bool, hasInput: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let size = pendingSize {
            if t3_resize(terminal.slave, size.columns, size.rows) < 0 { closing = true }
            pendingSize = nil
        }
        if !closing && sent < input.count {
            let written = input.withUnsafeBytes { bytes in
                Darwin.write(terminal.master, bytes.baseAddress!.advanced(by: sent),
                             min(bytes.count - sent, 16 * 1024))
            }
            if written > 0 {
                sent += written
                if sent == input.count {
                    input.removeAll(keepingCapacity: true)
                    sent = 0
                }
            } else if written < 0 && errno != EAGAIN && errno != EINTR {
                closing = true
            }
        }
        return (closing, !closing && sent < input.count)
    }

    /// One bounded turn keeps input, window updates, and shutdown responsive
    /// during continuous output. The parent keeps the slave open until final
    /// output has been delivered: Darwin may discard it on the last slave close.
    private func readOutput(limit: Int) {
        var remaining = limit
        var buffer = [UInt8](repeating: 0, count: min(remaining, 16 * 1024))
        while remaining > 0 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(terminal.master, bytes.baseAddress!, min(bytes.count, remaining))
            }
            if count > 0 {
                remaining -= count
                onData?(Data(buffer.prefix(count)))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                if count == 0 || errno != EAGAIN { requestClose() }
                return
            }
        }
    }

    private func hangup(_ group: pid_t) {
        t3_signal_group(group, terminal.child, SIGHUP)
        t3_signal_group(group, terminal.child, SIGCONT)
    }

    private func run() {
        var watchingWrite = false
        var foreground: pid_t = -1
        var killDeadline: DispatchTime?
        var exitCode: Int32 = 1
        while true {
            let pending = applyPending()
            if pending.closing && killDeadline == nil {
                foreground = t3_foreground(terminal.master)
                if foreground != terminal.child { hangup(foreground) }
                hangup(terminal.child)
                killDeadline = .now() + .milliseconds(350)
            }
            if let deadline = killDeadline, DispatchTime.now() >= deadline {
                t3_signal_group(foreground, terminal.child, SIGKILL)
                t3_signal_group(terminal.child, terminal.child, SIGKILL)
                // A shell can change its session. We still own this unreaped PID.
                Darwin.kill(terminal.child, SIGKILL)
            }

            if t3_reap(terminal.child, &exitCode) != 0 { break }
            if pending.hasInput != watchingWrite {
                if t3_writable(terminal.events, terminal.master, pending.hasInput ? 1 : 0) < 0 {
                    requestClose()
                }
                watchingWrite = pending.hasInput
            }
            autoreleasepool { readOutput(limit: 64 * 1024) }
            var timeout: Int32 = -1
            if let deadline = killDeadline {
                let now = DispatchTime.now().uptimeNanoseconds
                timeout = deadline.uptimeNanoseconds > now
                    ? Int32((deadline.uptimeNanoseconds - now) / 1_000_000 + 1) : 10
            }
            if t3_wait_event(terminal.events, timeout) < 0 { requestClose() }
        }

        if killDeadline != nil && foreground != terminal.child {
            t3_signal_group(foreground, terminal.child, SIGKILL)
        }
        // A background descendant may keep writing. Deliver exactly what is
        // readable at shell exit instead of waiting indefinitely for its EOF.
        let available = t3_available(terminal.master)
        readOutput(limit: available >= 0 ? Int(available) : 64 * 1024)
        lock.lock()
        finished = true
        input.removeAll()
        Darwin.close(terminal.events)
        Darwin.close(terminal.master)
        Darwin.close(terminal.slave)
        lock.unlock()
        onData = nil
        let callback = onExit
        onExit = nil
        callback?(exitCode)
    }
}
