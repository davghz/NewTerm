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

    func testCopiedFileMatchesOnlyOriginalNameOrItsDisplayStem() {
        XCTAssertTrue(TransferArchive.matchesSuggestedName("résumé", original: "résumé.txt"))
        XCTAssertTrue(TransferArchive.matchesSuggestedName("résumé.txt", original: "résumé.txt"))
        XCTAssertTrue(TransferArchive.matchesSuggestedName("archive.tar", original: "archive.tar.gz"))
        XCTAssertFalse(TransferArchive.matchesSuggestedName("archive", original: "archive.tar.gz"))
        XCTAssertTrue(TransferArchive.matchesSuggestedName(".env", original: ".env"))
        XCTAssertFalse(TransferArchive.matchesSuggestedName("env", original: ".env"))
        XCTAssertFalse(TransferArchive.matchesSuggestedName("other.txt", original: "résumé.txt"))
        XCTAssertFalse(TransferArchive.matchesSuggestedName(nil, original: "résumé.txt"))
        XCTAssertFalse(TransferArchive.matchesSuggestedName("", original: ".env"))
    }

    #if canImport(UniformTypeIdentifiers)
    func testCopiedFileRepresentationAcceptsRawDataAndRejectsReferences() {
        XCTAssertEqual(TransferArchive.copiedFileRepresentation(for: "file.txt", available: ["public.data"]), "public.data")
        XCTAssertEqual(TransferArchive.copiedFileRepresentation(for: ".env", available: ["public.data"]), "public.data")
        XCTAssertEqual(TransferArchive.copiedFileRepresentation(for: "unknown.abcxyz", available: ["public.data"]), "public.data")
        XCTAssertEqual(TransferArchive.copiedFileRepresentation(for: "file.txt", available: ["public.file-url", "public.utf8-plain-text"]), "public.utf8-plain-text")
        XCTAssertNil(TransferArchive.copiedFileRepresentation(for: "file.jpeg", available: ["public.file-url", "public.url", "public.directory"]))
        XCTAssertNil(TransferArchive.copiedFileRepresentation(for: "file.jpeg", available: ["public.item"]))
    }
    #endif

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
        let displayName = "original ü.txt"
        let copied = try TransferArchive.upload(file: member, filename: displayName)
        let renamed = try XCTUnwrap(Data(base64Encoded: copied.dropFirst(3).dropLast(2), options: .ignoreUnknownCharacters))
        try renamed.write(to: file)
        let checkName = Process(), names = Pipe()
        checkName.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        checkName.arguments = ["-tzf", file.path]
        checkName.standardOutput = names
        try checkName.run()
        let listing = names.fileHandleForReading.readDataToEndOfFile()
        checkName.waitUntilExit()
        XCTAssertEqual(checkName.terminationStatus, 0)
        XCTAssertEqual(String(decoding: listing, as: UTF8.self), displayName + "\n")
        for invalid in ["", ".", "..", "../escape", "dir/file", "a/b.txt", "a\nb.txt"] {
            XCTAssertThrowsError(try TransferArchive.upload(file: member, filename: invalid))
        }
        try Data(count: TransferArchive.byteLimit).write(to: member)
        XCTAssertNoThrow(try TransferArchive.upload(file: member, filename: displayName))
        try Data(count: TransferArchive.byteLimit + 1).write(to: member)
        XCTAssertThrowsError(try TransferArchive.upload(file: member))
        XCTAssertThrowsError(try TransferArchive.upload(file: member, filename: displayName))
    }
    #endif
}
