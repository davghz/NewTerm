import XCTest
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
