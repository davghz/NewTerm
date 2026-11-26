import Darwin
import Foundation
import T3PTY

/// A shell and its controlling terminal. Callbacks are ordered on a session
/// worker thread. Returning from onData allows the next block of output to be read.
public final class TerminalSession {
    private let lock = NSLock()
    private var current: SessionWorker?

    public init() {}

    #if targetEnvironment(simulator)
    /// CoreSimulator installs only the main executable with execute permission.
    /// The PTY child dispatches to the same launcher body before UIKit starts.
    public static func runSimulatorLauncherIfRequested() -> Int32? {
        guard CommandLine.arguments.first == "t3rm-pty-helper" else { return nil }
        return t3_run_launcher(CommandLine.argc, CommandLine.unsafeArgv)
    }
    #endif

    deinit { close() }

    public func start(directory: String?, columns: Int, rows: Int,
                      onData: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws {
        guard let executable = Bundle.main.executableURL else {
            throw POSIXError(.ENOENT)
        }
        #if targetEnvironment(simulator)
        let launcher = executable.path
        #else
        let launcher = executable.deletingLastPathComponent().appendingPathComponent("T3ShellLauncher").path
        #endif
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
        guard t3_start(launcher, shell, directory ?? "", Self.loginLocale, size.columns, size.rows, &terminal, &failure) == 0 else {
            let operation = String(cString: t3_operation(failure))
            let reason = String(cString: strerror(failure.number))
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure.number),
                          userInfo: [NSLocalizedDescriptionKey: "\(operation): \(reason)"])
        }
        let worker = SessionWorker(terminal, onData: onData, onExit: onExit)
        current = worker
        worker.start()
    }

    private static var loginLocale: String {
        let requested = UserDefaults.standard.string(forKey: "preferredLocale") ?? ""
        let locale = Locale(identifier: requested.isEmpty ? Locale.current.identifier : requested)
        guard let language = locale.languageCode, language.utf8.count <= 8 else { return "en_US.UTF-8" }
        return [language, locale.regionCode].compactMap { $0 }.joined(separator: "_") + ".UTF-8"
    }

    private static var defaultShell: String {
        #if os(iOS) && !targetEnvironment(simulator)
        // The rootless bootstrap has a separate login-shell database for mobile.
        var candidates = [String]()
        if let accounts = try? String(contentsOfFile: "/var/jb/etc/passwd", encoding: .utf8) {
            for line in accounts.split(separator: "\n") {
                let fields = line.split(separator: ":", omittingEmptySubsequences: false)
                if fields.count == 7, UInt32(fields[2]) == getuid(), fields[6].hasPrefix("/") {
                    let configured = String(fields[6])
                    if !configured.hasPrefix("/var/jb/") { candidates.append("/var/jb" + configured) }
                    candidates.append(configured)
                    break
                }
            }
        }
        candidates += ["/var/jb/usr/bin/zsh", "/var/jb/usr/bin/bash", "/var/jb/usr/bin/fish", "/var/jb/bin/sh"]
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

    public func foregroundCommandIs(_ name: String) -> Bool {
        worker?.foregroundCommandIs(name) ?? false
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

    func foregroundCommandIs(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished && !closing && t3_foreground_command_is(terminal.master, name) != 0
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

    private func run() {
        var watchingWrite = false
        var shellSignaled = false
        var killDeadline: DispatchTime?
        var exitCode: Int32 = 1
        while true {
            let pending = applyPending()
            if pending.closing && killDeadline == nil {
                let foreground = t3_foreground(terminal.master)
                let signaled = t3_signal_foreground(terminal.master, terminal.child, SIGHUP) == 0
                t3_signal_foreground(terminal.master, terminal.child, SIGCONT)
                shellSignaled = foreground == terminal.child && signaled
                killDeadline = .now() + .milliseconds(350)
            }
            if let deadline = killDeadline {
                let foreground = t3_foreground(terminal.master)
                if DispatchTime.now() >= deadline {
                    // Signal the foreground before terminating its session leader.
                    t3_signal_foreground(terminal.master, terminal.child, SIGKILL)
                    Darwin.kill(terminal.child, SIGKILL)
                } else if !shellSignaled && (foreground <= 1 || foreground == terminal.child) {
                    // Keep the controlling session attached while a job handles HUP.
                    // The worker owns this direct child's PID until waitpid reaps it.
                    Darwin.kill(terminal.child, SIGHUP)
                    Darwin.kill(terminal.child, SIGCONT)
                    shellSignaled = true
                }
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
