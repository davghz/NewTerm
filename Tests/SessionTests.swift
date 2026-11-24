import XCTest
import SwiftTerm
@testable import NewTermCommon

final class SessionTests: XCTestCase {
	func testFailedSpawnsReleaseTerminalDescriptors() {
		let invalid = ShellLaunchConfiguration(executable: "/no-such-newterm-shell", arguments: ["sh"], environment: [:])
		func terminalDescriptorCount() -> Int {
			(0..<getdtablesize()).filter { isatty($0) == 1 }.count
		}
		let before = terminalDescriptorCount()
		for _ in 0..<8 {
			XCTAssertThrowsError(try PTYChild.spawn(invalid, windowSize: winsize())) { error in
				guard case SubProcessIllegalStateError.forkFailed(let code) = error else {
					return XCTFail("Unexpected launch error: \(error)")
				}
				XCTAssertEqual(code, ENOENT)
			}
		}
		XCTAssertEqual(terminalDescriptorCount(), before)
	}

	func testLoginStartsInRequestedDirectoryWithoutChangingParent() throws {
		let parentDirectory = FileManager.default.currentDirectoryPath
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NewTerm \(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
		defer { try? FileManager.default.removeItem(at: directory) }

		let login = try ShellLaunchConfiguration.login(initialDirectory: directory.path, preferredLocale: "en_US")
		XCTAssertEqual(login.environment["TERM"], "xterm-256color")
		XCTAssertEqual(login.environment["TERM_PROGRAM"], "t3rm")

		let command = "test -t 0 && test -t 1 && test -t 2 && stty size > result"
		let probe = ShellLaunchConfiguration(executable: login.executable, arguments: login.arguments + ["-c", command], environment: login.environment)
		let child = try PTYChild.spawn(probe, windowSize: winsize(ws_row: 31, ws_col: 89, ws_xpixel: 0, ws_ypixel: 0))
		defer {
			kill(child.pid, SIGKILL)
			waitpid(child.pid, nil, 0)
			close(child.writer)
			close(child.reader)
		}

		// The shell creates this file relative to its own working directory.
		let marker = directory.appendingPathComponent("result")
		let ready = NSPredicate { _, _ in
			(try? String(contentsOf: marker).split(whereSeparator: { $0.isWhitespace })) == ["31", "89"]
		}
		let captured = XCTNSPredicateExpectation(predicate: ready, object: nil)
		XCTAssertEqual(XCTWaiter.wait(for: [captured], timeout: 10), .completed)
		XCTAssertEqual(FileManager.default.currentDirectoryPath, parentDirectory)
	}
}

private final class RenderTerminal: TerminalDelegate {
	private var cache = TerminalLineCache<String>()
	private var lastFrame = [String]()
	lazy var terminal = Terminal(delegate: self, options: TerminalOptions(cols: 16, rows: 4, scrollback: 3))

	func send(source: Terminal, data: ArraySlice<UInt8>) {}
	func bufferActivated(source: Terminal) { cache.bufferActivated() }
	func scrolled(source: Terminal, yDisp: Int) { cache.scrolled(source, top: yDisp) }

	func frame(after output: String) -> [String] {
		terminal.feed(byteArray: Array(output.utf8))
		if let frame = cache.refresh(terminal, render: { _, line in
			line?.translateToString().replacingOccurrences(of: "\0", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
		}) { lastFrame = frame }
		return lastFrame
	}
}

final class TerminalLineCacheTests: XCTestCase {
	func testSparseChangesKeepFirstAndLastRowsAndPublishedFrame() {
		let display = RenderTerminal()
		let home = "\u{1b}[1;1H"
		let initial = display.frame(after: "\u{1b}[?1049hfirst\r\nsecond\r\nthird\r\nlast" + home)
		XCTAssertEqual(initial, ["first", "second", "third", "last"])

		let updated = display.frame(after: home + "\u{1b}[2Ktop" + home)
		XCTAssertEqual(updated, ["top", "second", "third", "last"])
		let partial = display.frame(after: "\u{1b}[3;1H\u{1b}[2Kmiddle" + home)
		XCTAssertEqual(partial, ["top", "second", "middle", "last"])
		XCTAssertEqual(initial, ["first", "second", "third", "last"])
	}

	func testTrimmedScrollbackSurvivesAlternateBufferAndResize() {
		let display = RenderTerminal()
		for i in 0..<8 { _ = display.frame(after: "line\(i)\r\n") }
		let normal = display.frame(after: "line8")
		XCTAssertEqual(normal, (2...8).map { "line\($0)" })

		let alternate = display.frame(after: "\u{1b}[?1049h\u{1b}[Halpha\r\nbeta\r\ngamma\r\ndelta")
		XCTAssertEqual(alternate, ["alpha", "beta", "gamma", "delta"])
		XCTAssertEqual(display.frame(after: "\u{1b}[?1049l"), normal)

		display.terminal.resize(cols: 16, rows: 5)
		let resized = display.frame(after: "")
		XCTAssertEqual(resized.count, display.terminal.getTopVisibleRow() + 5)
		XCTAssertTrue(resized.contains("line8"))
	}
}
