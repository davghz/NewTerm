//
//  SubProcess.swift
//  NewTerm
//
//  Created by Adam Demasi on 9/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import Foundation
import os.log

enum SubProcessIllegalStateError: Error, LocalizedError {
	case alreadyStarted, notStarted
	case openPtyFailed(errno: errno_t)
	case loginTtyFailed(errno: errno_t)
	case forkFailed(errno: errno_t)
	case deallocatedWhileRunning

	private func errorString(errno: errno_t) -> String {
		if let string = strerror(errno) {
			return String(cString: string)
		}
		return String(format: .localize("Unknown (%i)"), errno)
	}

	var errorDescription: String? {
		switch self {
		case .alreadyStarted, .notStarted, .deallocatedWhileRunning:
			return .localize("Internal state error")

		case .openPtyFailed(let errno):
			return String(format: .localize("Couldn’t initialize a terminal. %@"), errorString(errno: errno))

		case .loginTtyFailed(let errno):
			return String(format: .localize("Couldn’t prepare terminal for logging in. %@"), errorString(errno: errno))

		case .forkFailed(let errno):
			return String(format: .localize("Couldn’t start a terminal process. %@"), errorString(errno: errno))
		}
	}
}

enum SubProcessIOError: Error {
	case readFailed(errno: errno_t?)
	case writeFailed(errno: errno_t?)
}

protocol SubProcessDelegate: AnyObject {
	func subProcessDidConnect()
	func subProcess(didReceiveData data: [UTF8Char])
	func subProcess(didDisconnectWithError error: Error?)
	func subProcess(didReceiveError error: Error)
}

final class SubProcess {

	weak var delegate: SubProcessDelegate?

	private var childPID: pid_t?
	private var fileDescriptor: Int32?
	private var writeChannel: DispatchIO?

	var foregroundIsCodex: Bool {
		queue.sync { fileDescriptor.map { nt_foreground_is_codex($0) } ?? false }
	}

	private let queue = DispatchQueue(label: "com.davghz.t3rm.io-queue")
	private var readSource: DispatchSourceRead?
	private var signalSource: DispatchSourceProcess?

	private let log = OSLog(subsystem: "com.davghz.t3rm", category: "SubProcess")

	private var currentSize = ScreenSize.default
	var screenSize: ScreenSize {
		get { queue.sync { currentSize } }
		set {
			queue.sync {
				currentSize = newValue
				updateWindowSize()
			}
		}
	}

	func start(initialDirectory: String? = nil) throws {
		let configuration = try ShellLaunchConfiguration.login(
			initialDirectory: initialDirectory, preferredLocale: Preferences.shared.preferredLocale
		)
		try queue.sync {
			guard childPID == nil else { throw SubProcessIllegalStateError.alreadyStarted }
			let child = try PTYChild.spawn(configuration, windowSize: currentSize.windowSize)
			observe(child)
		}
		delegate?.subProcessDidConnect()
	}

	private func observe(_ child: PTYChild) {
		childPID = child.pid
		fileDescriptor = child.reader
		let writer = child.writer
		writeChannel = DispatchIO(type: .stream, fileDescriptor: writer, queue: queue) { _ in
			close(writer)
		}

		// Go ahead and plug a file handle into the child tty.
		readSource = DispatchSource.makeReadSource(fileDescriptor: child.reader, queue: queue)
		let reader = child.reader
		readSource?.setCancelHandler { close(reader) }
		readSource?.setEventHandler { [weak self] in
			self?.handleRead()
		}
		signalSource = DispatchSource.makeProcessSource(identifier: child.pid, eventMask: .exit, queue: queue)
		signalSource?.setEventHandler { [weak self] in
			try? self?.stop()
		}

		readSource?.activate()
		signalSource?.activate()
	}

	func closeTerminal() {
		queue.sync {
			try? stop(notifyDelegate: false)
		}
	}

	private func stop(notifyDelegate: Bool = true) throws {
		guard let childPID = childPID else {
			throw SubProcessIllegalStateError.notStarted
		}

		// If process is still running, send it SIGKILL and wait for termination
		if kill(childPID, 0) == 0 {
			kill(childPID, SIGKILL)

			var status = Int32()
			waitpid(childPID, &status, WUNTRACED)

			os_log("Process stopped with exit code: %{public}d", log: log, type: .debug, WEXITSTATUS(status))
		}

		self.childPID = nil
		writeChannel?.close(flags: .stop)
		writeChannel = nil
		fileDescriptor = nil
		readSource?.cancel()
		readSource = nil
		signalSource?.cancel()
		signalSource = nil

		if notifyDelegate {
			// nil error means disconnected due to user request
			DispatchQueue.main.async {
				self.delegate?.subProcess(didDisconnectWithError: nil)
			}
		}
	}

	private func handleRead() {
		guard let fileDescriptor = fileDescriptor else {
			return
		}

		let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(BUFSIZ), alignment: MemoryLayout<CChar>.alignment)
		let bytesRead = read(fileDescriptor, buffer, Int(BUFSIZ))
		switch bytesRead {
		case -1:
			let code = errno
			switch code {
			case EAGAIN, EINTR:
				// Ignore, we’ll be called again when the source is ready.
				break

			default:
				// Something is wrong.
				DispatchQueue.main.async {
					self.delegate?.subProcess(didDisconnectWithError: SubProcessIOError.readFailed(errno: code))
				}
			}

		case 0:
			// Zero-length data is an indicator of EOF. This can happen if the user exits the terminal by
			// typing `exit` or ^D, or if there’s a catastrophic failure (e.g. /bin/login is broken).
			try? stop()

		default:
			// Read from output and notify delegate.
			let bytes = buffer.bindMemory(to: UTF8Char.self, capacity: bytesRead)
			let data = Array(UnsafeBufferPointer(start: bytes, count: bytesRead))
			delegate?.subProcess(didReceiveData: data)
		}
		buffer.deallocate()
	}

	func write(data: [UTF8Char]) {
		guard !data.isEmpty else { return }
		let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
		queue.async {
			self.writeChannel?.write(offset: 0, data: bytes, queue: self.queue) { [weak self] done, _, error in
				if done && error != 0 && error != ECANCELED {
					DispatchQueue.main.async {
						self?.delegate?.subProcess(didReceiveError: SubProcessIOError.writeFailed(errno: error))
					}
				}
			}
		}
	}

	private func updateWindowSize() {
		guard let fileDescriptor = fileDescriptor else {
			return
		}

		var windowSize = currentSize.windowSize
		if ioctl(fileDescriptor, TIOCSWINSZ, &windowSize) == -1 {
			let error = errno
			os_log("Setting screen size failed: %{public}d", log: log, type: .error, error)
		}
	}

	deinit {
		if childPID != nil {
			os_log("Illegal state - SubProcess deallocated while still running", log: log, type: .error)
		}

		try? stop(notifyDelegate: false)
	}

}
