import XCTest
@testable import t3rm

final class SessionStartupTests: XCTestCase {
    func testLaunchErrorSurvivesInputQueuedDuringStartup() {
        let model = TerminalModel()
        defer { model.close() }
        let failed = expectation(description: "Shell directory failure")
        let drained = expectation(description: "Queued input processed")
        model.onExit = { message in
            XCTAssertTrue(message.contains("Open shell directory"), message)
            failed.fulfill()
        }
        model.onWriteRejected = { XCTFail("A second input error obscured the launch error") }
        let missingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        model.start(directory: missingDirectory.path, columns: 40, rows: 24)
        model.send { _ in Data("pwd\r".utf8) }
        model.transcript(line: nil, column: nil) { _ in drained.fulfill() }
        wait(for: [failed, drained], timeout: 45)
    }
}
