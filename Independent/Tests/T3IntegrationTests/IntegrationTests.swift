import Foundation
import XCTest
import T3Integration

final class IntegrationTests: XCTestCase {
    func testLinksAcceptDestinationsAndRejectCommandText() throws {
        func command(_ input: String) -> String? { URL(string: input).flatMap(ShellLinks.command) }
        XCTAssertEqual(command("t3rm-ssh://mobile@device.local:2222"), "ssh -p 2222 -l mobile -- device.local")
        XCTAssertEqual(command("t3rm-review-ssh://[::1]"), "ssh -- ::1")
        for value in ["ssh://localhost", "t3rm-ssh://-foo", "t3rm-ssh://x/y", "t3rm-ssh://x?p=1",
                      "t3rm-ssh://x:0", "t3rm-ssh://a%20b@x", "t3rm-ssh://a:pass@x", "t3rm-ssh://x#c"] {
            XCTAssertNil(command(value), value)
        }
    }

    #if os(macOS)
    func testWireReplyIsReadableBySystemTar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let member = dir.appendingPathComponent("example ü.txt")
        let content = Data((0..<251).map { UInt8($0) })
        try content.write(to: member)
        let wire = try TransferArchive.upload(file: member)
        XCTAssertTrue(wire.starts(with: Data("ok\r".utf8)))
        XCTAssertTrue(wire.suffix(2).elementsEqual([13, 13]))
        let gz = try XCTUnwrap(Data(base64Encoded: wire.dropFirst(3).dropLast(2), options: .ignoreUnknownCharacters))
        let file = dir.appendingPathComponent("upload.tgz")
        try gz.write(to: file)
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xzOf", file.path, member.lastPathComponent]
        task.standardOutput = output
        try task.run()
        let decoded = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        XCTAssertEqual(decoded, content)
        try Data(count: TransferArchive.byteLimit + 1).write(to: member)
        XCTAssertThrowsError(try TransferArchive.upload(file: member))
    }
    #endif
}
