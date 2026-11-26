import Foundation
import T3Gzip
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public enum TransferArchive {
    public static let cancel = Data("abort\r".utf8)
    public static let byteLimit = 1_048_576

    public enum Failure: LocalizedError {
        case filename, fileType, size, encoding
        public var errorDescription: String? {
            switch self {
            case .filename: return "Choose a file with a name under 101 UTF-8 bytes."
            case .fileType: return "Choose a regular file."
            case .size: return "The upload limit is 1 MiB."
            case .encoding: return "The file could not be archived."
            }
        }
    }

    public static func matchesSuggestedName(_ suggested: String?, original: String) -> Bool {
        guard let suggested = suggested, !suggested.isEmpty else { return false }
        let filename = original as NSString
        return suggested == original || (!filename.pathExtension.isEmpty && suggested == filename.deletingPathExtension)
    }

    #if canImport(UniformTypeIdentifiers)
    public static func copiedFileRepresentation(for name: String, available: [String]) -> String? {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        let offered = available.compactMap { UTType($0) }
        let content = offered.first { candidate in
            guard candidate.conforms(to: .data), !candidate.conforms(to: .url), !candidate.conforms(to: .directory) else { return false }
            return type.map { candidate.conforms(to: $0) } ?? candidate.conforms(to: .content)
        } ?? offered.first { $0 == .data }
        return content?.identifier
    }
    #endif

    public static func upload(file: URL, filename: String? = nil) throws -> Data {
        let name = filename ?? file.lastPathComponent
        guard !name.isEmpty, (name as NSString).lastPathComponent == name, name != ".", name != "..", name.utf8.count <= 100,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.filename }
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true else { throw Failure.fileType }
        guard let size = attributes.fileSize, size <= byteLimit else { throw Failure.size }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var payload = Data()
        while let bytes = try handle.read(upToCount: min(65_536, byteLimit + 1 - payload.count)), !bytes.isEmpty {
            payload.append(bytes)
            guard payload.count <= byteLimit else { throw Failure.size }
        }

        // A single regular-file ustar member, followed by two empty blocks.
        var tar = Data(repeating: 0, count: 512)
        func field(_ value: String, at offset: Int) {
            tar.replaceSubrange(offset..<offset + value.utf8.count, with: value.utf8)
        }
        field(name, at: 0)
        field("0000600", at: 100)
        field("0000000", at: 108)
        field("0000000", at: 116)
        field(String(format: "%011o", payload.count), at: 124)
        field("00000000000", at: 136)
        field("        ", at: 148)
        field("0", at: 156)
        field("ustar", at: 257)
        field("00", at: 263)
        field(String(format: "%06o", tar.reduce(0) { $0 + Int($1) }), at: 148)
        tar[154] = 0
        tar.append(payload)
        tar.append(Data(repeating: 0, count: (512 - payload.count % 512) % 512 + 1024))
        var count = 0
        guard let zipped = tar.withUnsafeBytes({ raw in
            t3_gzip(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &count)
        }) else { throw Failure.encoding }
        let gzip = Data(bytesNoCopy: zipped, count: count, deallocator: .free)
        var reply = Data("ok\r".utf8)
        reply.append(gzip.base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn]))
        reply.append(contentsOf: [13, 13])
        return reply
    }
}
