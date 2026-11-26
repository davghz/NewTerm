import Foundation
import UniformTypeIdentifiers
import UIKit
import T3Integration

enum CopiedFileUpload {
    enum Failure: LocalizedError {
        case differentFile, noFileRepresentation

        var errorDescription: String? {
            switch self {
            case .differentFile: return "The clipboard does not contain the selected file."
            case .noFileRepresentation: return "Files did not provide a readable copy of this document."
            }
        }
    }

    // The caller has a filename from the picker and an explicit Paste action from the user.
    static func read(named name: String, completion: @escaping (Result<Data, Error>) -> Void) {
        let items = UIPasteboard.general.itemProviders
        guard items.count == 1, let provider = items.first else {
            completion(.failure(Failure.differentFile))
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let source = item as? URL, source.isFileURL else {
                    readRepresentation(provider, name: name, suggested: provider.suggestedName, completion: completion)
                    return
                }
                guard TransferArchive.matchesSuggestedName(source.lastPathComponent, original: name) else {
                    completion(.failure(Failure.differentFile))
                    return
                }
                guard source.startAccessingSecurityScopedResource() else {
                    readRepresentation(provider, name: name, suggested: source.lastPathComponent, completion: completion)
                    return
                }
                defer { source.stopAccessingSecurityScopedResource() }
                do {
                    completion(.success(try TransferArchive.upload(file: source, filename: name)))
                } catch let error as TransferArchive.Failure {
                    completion(.failure(error))
                } catch {
                    readRepresentation(provider, name: name, suggested: source.lastPathComponent, completion: completion)
                }
            }
        } else {
            readRepresentation(provider, name: name, suggested: provider.suggestedName, completion: completion)
        }
    }

    private static func readRepresentation(_ provider: NSItemProvider, name: String, suggested: String?,
                                           completion: @escaping (Result<Data, Error>) -> Void) {
        // Files can omit the extension from its suggested name. The picker supplies the original.
        guard TransferArchive.matchesSuggestedName(suggested, original: name) else {
            completion(.failure(Failure.differentFile))
            return
        }
        guard let content = TransferArchive.copiedFileRepresentation(for: name, available: provider.registeredTypeIdentifiers) else {
            completion(.failure(Failure.noFileRepresentation))
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: content) { local, error in
            guard let local = local else {
                completion(.failure(error ?? Failure.noFileRepresentation))
                return
            }
            // iOS removes the brokered temporary copy when this callback returns.
            completion(Result { try TransferArchive.upload(file: local, filename: name) })
        }
    }
}
