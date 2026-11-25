import Darwin
import Foundation
import XCTest
@testable import T3Sessions

private final class Output {
    private let condition = NSCondition()
    private var bytes = Data()
    private(set) var status: Int32?

    func append(_ data: Data) {
        condition.lock()
        bytes.append(data)
        condition.broadcast()
        condition.unlock()
    }

    func exit(_ code: Int32) {
        condition.lock()
        status = code
        condition.broadcast()
        condition.unlock()
    }

    func waitFor(_ marker: String, timeout: TimeInterval = 5) -> Bool {
        let needle = Data(marker.utf8)
        return wait(timeout) { bytes.range(of: needle) != nil }
    }

    func waitForExit(timeout: TimeInterval = 5) -> Bool {
        wait(timeout) { status != nil }
    }

    private func wait(_ timeout: TimeInterval, until test: () -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !test() && condition.wait(until: deadline) {}
        return test()
    }

    var data: Data {
        condition.lock()
        defer { condition.unlock() }
        return bytes
    }

    var text: String { String(decoding: data, as: UTF8.self) }
}

final class TerminalSessionTests: XCTestCase {
    /// SwiftPM puts the launcher beside the test bundle on macOS. App-hosted
    /// tests can use the same executable as the phone app.
    private var launcher: String {
        let candidates = [
            Bundle(for: Self.self).bundleURL.deletingLastPathComponent(),
            Bundle.main.executableURL!.deletingLastPathComponent()
        ]
        return candidates.map { $0.appendingPathComponent("T3ShellLauncher").path }
            .first(where: { access($0, X_OK) == 0 }) ?? "missing-T3ShellLauncher"
    }

    @discardableResult
    private func start(_ session: TerminalSession, shell: String = "/bin/sh",
                       directory: String? = "/tmp") throws -> Output {
        let output = Output()
        try session.start(launcher: launcher, shell: shell, directory: directory, columns: 78, rows: 23,
                          onData: output.append, onExit: output.exit)
        return output
    }

    private func command(_ command: String, _ session: TerminalSession) {
        XCTAssertTrue(session.tryWrite(Data((command + "\n").utf8)))
    }

    func testControllingTTYDirectoryEnvironmentAndResize() throws {
        let session = TerminalSession()
        defer { session.close() }
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("T3 shell " + UUID().uuidString)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let output = try start(session, directory: cwd.path)
        command("stty -echo; test -t 0 && test -t 1 && test -t 2 && printf 'TTY%s\\n' OK >/dev/tty; stty size", session)
        XCTAssertTrue(output.waitFor("TTYOK\r\n"), output.text)
        XCTAssertTrue(output.waitFor("23 78\r\n"), output.text)
        session.resize(columns: 132, rows: 41)
        command("stty size; pwd -P; printf '%s|%s|%s\\n' \"$TERM\" \"$TERM_PROGRAM\" \"$LC_TERMINAL\"; exit 17", session)
        XCTAssertTrue(output.waitForExit(), output.text)
        XCTAssertEqual(output.status, 17)
        XCTAssertTrue(output.text.contains("41 132\r\n"), output.text)
        XCTAssertTrue(output.text.contains(cwd.lastPathComponent), output.text)
        XCTAssertTrue(output.text.contains("xterm-256color|t3rm|t3rm"), output.text)
    }

    func testForegroundJobsReceiveTerminalInterrupt() throws {
        let session = TerminalSession()
        defer { session.close() }
        let output = try start(session)
        // printf runs inside the foreground job, after the shell transfers the tty.
        command("stty -echo; sh -c 'printf \"JOB%s\\n\" READY; exec sleep 30'", session)
        XCTAssertTrue(output.waitFor("JOBREADY\r\n"), output.text)
        session.write(Data([3]))
        command("printf 'RESULT=%s\\n' \"$?\"; exit", session)
        XCTAssertTrue(output.waitForExit(), output.text)
        XCTAssertTrue(output.text.contains("RESULT=130"), output.text)
    }

    func testFinalOutputDeliveredBeforeExit() throws {
        let session = TerminalSession()
        defer { session.close() }
        let output = try start(session)
        command("stty -echo; exec sh -c 'head -c 180000 /dev/zero; printf \"TAIL%s\\n\" END; exit 42'", session)
        XCTAssertTrue(output.waitForExit(), "No exit event")
        XCTAssertEqual(output.status, 42)
        XCTAssertEqual(output.data.filter { $0 == 0 }.count, 180000)
        XCTAssertTrue(output.text.hasSuffix("TAILEND\r\n"), String(reflecting: output.text.suffix(48)))
    }

    func testSetupErrorsAndRetryOnSameObject() throws {
        let session = TerminalSession()
        defer { session.close() }
        let missing = "/tmp/" + UUID().uuidString
        XCTAssertThrowsError(try session.start(launcher: missing, shell: "/bin/sh", directory: "/",
                                              columns: 3, rows: 3, onData: { _ in }, onExit: { _ in })) {
            XCTAssertEqual(($0 as NSError).code, Int(ENOENT))
        }
        XCTAssertThrowsError(try start(session, directory: missing)) {
            XCTAssertEqual(($0 as NSError).code, Int(ENOENT))
            XCTAssertTrue($0.localizedDescription.contains("directory"))
        }
        XCTAssertThrowsError(try start(session, shell: missing)) {
            XCTAssertEqual(($0 as NSError).code, Int(ENOENT))
            XCTAssertTrue($0.localizedDescription.contains("Execute shell"))
        }
        let valid = try start(session)
        XCTAssertThrowsError(try start(session)) {
            XCTAssertEqual(($0 as NSError).code, Int(EBUSY))
        }
        command("exit 0", session)
        XCTAssertTrue(valid.waitForExit())
        let next = try start(session)
        command("exit 23", session)
        XCTAssertTrue(next.waitForExit())
        XCTAssertEqual(next.status, 23)
    }

    func testCloseReapsShellAndForegroundJob() throws {
        let session = TerminalSession()
        let output = try start(session)
        command("stty -echo; trap '' HUP; sh -c 'trap \"\" HUP; printf \"PIDS %s %s!\\n\" \"$PPID\" \"$$\"; exec sleep 30'", session)
        XCTAssertTrue(output.waitFor("!\r\n"), output.text)
        let pattern = try NSRegularExpression(pattern: "PIDS ([0-9]+) ([0-9]+)!")
        let transcript = output.text as NSString
        let match = try XCTUnwrap(pattern.firstMatch(in: output.text, range: NSRange(location: 0, length: transcript.length)))
        let shell = try XCTUnwrap(Int32(transcript.substring(with: match.range(at: 1))))
        let child = try XCTUnwrap(Int32(transcript.substring(with: match.range(at: 2))))
        session.close()
        session.close()
        XCTAssertTrue(output.waitForExit(), output.text)
        XCTAssertEqual(kill(shell, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let deadline = Date().addingTimeInterval(2)
        while kill(child, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(kill(child, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(session.tryWrite(Data([1])))
    }

    func testLargeInputSurvivesPartialWrites() throws {
        let session = TerminalSession()
        defer { session.close() }
        let output = try start(session)
        command("stty raw -echo; printf 'RAW%s' READY; head -c 1500000 | LC_ALL=C tr -d Q | wc -c; printf 'END%s' RAW; exit", session)
        XCTAssertTrue(output.waitFor("RAWREADY"), output.text)
        XCTAssertTrue(session.tryWrite(Data(repeating: 81, count: 1_500_000)))
        XCTAssertTrue(output.waitForExit(timeout: 15), output.text)
        XCTAssertTrue(output.text.range(of: #"RAWREADY\s*0\s*ENDRAW"#, options: .regularExpression) != nil, output.text)
    }

    func testInputBudgetAndIndependentSessions() throws {
        let first = TerminalSession(), second = TerminalSession()
        defer { first.close(); second.close() }
        let a = try start(first), b = try start(second)
        XCTAssertFalse(first.tryWrite(Data(repeating: 65, count: 2 * 1024 * 1024 + 1)))
        command("printf 'SESSION%s\\n' ONE; exit 11", first)
        command("printf 'SESSION%s\\n' TWO; exit 22", second)
        XCTAssertTrue(a.waitForExit())
        XCTAssertTrue(b.waitForExit())
        XCTAssertEqual(a.status, 11)
        XCTAssertEqual(b.status, 22)
        XCTAssertTrue(a.text.contains("SESSIONONE"))
        XCTAssertTrue(b.text.contains("SESSIONTWO"))
        XCTAssertFalse(a.text.contains("SESSIONTWO"))
        XCTAssertFalse(b.text.contains("SESSIONONE"))
    }
}
