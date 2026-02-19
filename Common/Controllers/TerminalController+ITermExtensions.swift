//
//  ITermExtensionsParser.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 11/4/21.
//

import Foundation
import SwiftTerm
import QuickLook
import os.log

extension TerminalController {
	private static let iTermLog = OSLog(subsystem: "ws.hbang.Terminal", category: "TerminalController")

	public func iTermContent(source: Terminal, _ content: String) {
		let scanner = Scanner(string: content)

		let command = scanner.scanUpToString("=")
		switch command {
		case "ShellIntegrationVersion":
			_ = scanner.scanString("=")
			iTermIntegrationVersion = scanner.scanUpToString(";")
			_ = scanner.scanString(";")
			while !scanner.isAtEnd {
				let command = scanner.scanUpToString("=")
				_ = scanner.scanString("=")
				switch command {
				case "shell": shell = scanner.scanUpToString(";")
				default: break
				}
				_ = scanner.scanString(";")
			}
				os_log("Shell reports iTerm integration ver %{public}@ under %{public}@",
				       log: Self.iTermLog,
				       type: .debug,
				       self.iTermIntegrationVersion ?? "?",
				       self.shell ?? "?")

		case "RemoteHost":
			_ = scanner.scanString("=")
			userAndHostname = scanner.scanUpToString(";")
			if let atIndex = userAndHostname?.firstIndex(of: "@") {
				let afterAtIndex = userAndHostname!.index(after: atIndex)
				user = String(userAndHostname![userAndHostname!.startIndex..<atIndex])
				hostname = String(userAndHostname![afterAtIndex..<userAndHostname!.endIndex])
			} else {
				user = nil
				hostname = nil
			}
				os_log("Shell reports host %{public}@%{public}@",
				       log: Self.iTermLog,
				       type: .debug,
				       self.user ?? "?",
				       self.hostname ?? "?")

		case "CurrentDir":
			if isProcessTrusted(source: source) {
				_ = scanner.scanString("=")
				if let currentDir = scanner.scanUpToString(";"),
					 !currentDir.isEmpty {
					currentWorkingDirectory = URL(fileURLWithPath: currentDir)
					DispatchQueue.main.async {
						self.delegate?.currentFileDidChange(self.currentFile ?? self.currentWorkingDirectory,
																								inWorkingDirectory: self.currentWorkingDirectory)
					}
				}
			}
				os_log("Shell reports current file %{public}@, cwd %{public}@",
				       log: Self.iTermLog,
				       type: .debug,
				       self.currentFile?.path ?? "?",
				       self.currentWorkingDirectory?.path ?? "?")

		case "File":
			// TODO: We could support displaying file download progress, but SwiftTerm just gives us the
			// entire escape at once as a ginormous string.
			_ = scanner.scanString("=name=")
			let encodedFileName = scanner.scanUpToString(";")
			_ = scanner.scanString(";size=")
			let fileSize = scanner.scanInt()
//			_ = scanner.scanString(";")
//			let isInline = scanner.scanString("inline=1") != nil
			_ = scanner.scanString(":")
			let encodedFile = scanner.scanUpToString(";")

			if let filename = String(data: Data(base64Encoded: encodedFileName ?? "") ?? Data(), encoding: .utf8),
				 let file = Data(base64Encoded: encodedFile ?? ""),
				 file.count == fileSize {
				// TODO: Support inline images!
				let basename = URL(fileURLWithPath: filename).lastPathComponent
				let tempURL = FileManager.default.temporaryDirectory/"downloads"/UUID().uuidString
				try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: [:])
				let url = tempURL/basename

				DispatchQueue.main.async {
					self.delegate?.fileDownloadDidStart(filename: basename)
				}
				DispatchQueue.global(qos: .userInitiated).async {
					try? file.write(to: url, options: .completeFileProtection)
					DispatchQueue.main.async {
						self.delegate?.fileDownloadDidFinish()
						self.delegate?.saveFile(url: url)
					}
				}
			}

		case "RequestUpload":
			// The only supported format is currently tgz.
			if scanner.scanString("=format=tgz") != nil {
				DispatchQueue.main.async {
					self.delegate?.fileUploadRequested()
				}
				return
			}

		default:
				os_log("Unrecognised iTerm2 command %{public}@",
				       log: Self.iTermLog,
				       type: .error,
				       content)
			}
		}

	// MARK: - File download/upload

	private static let preFileUploadMarker   = "ok\r".data(using: .utf8)!
	private static let postFileUploadMarker  = "\r\r".data(using: .utf8)!
	private static let abortFileUploadMarker = "abort\r".data(using: .utf8)!

	public func deleteDownloadCache() {
		let tempURL = FileManager.default.temporaryDirectory/"downloads"
		try? FileManager.default.removeItem(at: tempURL)
	}

	public func uploadFile(url: URL) {
		terminalQueue.async {
			var isDir: ObjCBool = false
			FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

			let data: Data
			if isDir.boolValue {
				// Directory: compress to tar+gzip using /usr/bin/tar (available on jailbroken iOS).
				guard let tgzData = Self.createTarGz(from: url) else {
					self.cancelUploadRequest()
					return
				}
				data = tgzData
			} else {
				guard let fileData = try? Data(contentsOf: url) else {
					self.cancelUploadRequest()
					return
				}
				data = fileData
			}

			// Respond with ok to confirm we’re about to send a payload.
			self.write(Self.preFileUploadMarker)
			// Base64-encode and send.
			let encodedData = data.base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn])
			self.write(encodedData)
			// Two ending returns indicate end of file.
			self.write(Self.postFileUploadMarker)
		}
	}

	private static func createTarGz(from url: URL) -> Data? {
		let tempDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("newterm-upload-\(UUID().uuidString)")
		let outputURL = tempDir.appendingPathComponent("upload.tar.gz")
		do {
			try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
		} catch {
			return nil
		}
		defer { try? FileManager.default.removeItem(at: tempDir) }

		let tarPath = "/usr/bin/tar"
		guard FileManager.default.fileExists(atPath: tarPath) else {
			os_log("tar not found at /usr/bin/tar", log: iTermLog, type: .error)
			return nil
		}

		// Use posix_spawn (available on iOS) to invoke tar.
		// argv: tar -czf <output> -C <parentDir> <dirName>
		let parentPath = url.deletingLastPathComponent().path
		let argv = ["tar", "-czf", outputURL.path, "-C", parentPath, url.lastPathComponent].cStringArray
		defer { argv.deallocate() }

		var pid = pid_t()
		let spawnResult = posix_spawn(&pid, tarPath, nil, nil, argv, nil)
		guard spawnResult == 0 else {
			os_log("posix_spawn tar failed: %{public}d", log: iTermLog, type: .error, spawnResult)
			return nil
		}

		var status = Int32()
		waitpid(pid, &status, 0)
		guard WEXITSTATUS(status) == 0 else {
			os_log("tar exited with status %d", log: iTermLog, type: .error, WEXITSTATUS(status))
			return nil
		}
		return try? Data(contentsOf: outputURL)
	}

	public func cancelUploadRequest() {
		terminalQueue.async {
			self.write(Self.abortFileUploadMarker)
		}
	}

}
