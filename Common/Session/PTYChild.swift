//
//  PTYChild.swift
//  NewTerm
//

import Foundation

/// A spawned child with two independently owned handles to the same PTY master.
/// The read source and the write channel each take one handle and close it on teardown.
struct PTYChild {
	let pid: pid_t
	let reader: Int32
	let writer: Int32

	static func spawn(_ configuration: ShellLaunchConfiguration, windowSize: winsize) throws -> Self {
		var size = windowSize
		var master: Int32 = -1
		var slave: Int32 = -1
		guard openpty(&master, &slave, nil, nil, &size) == 0 else {
			throw SubProcessIllegalStateError.openPtyFailed(errno: errno)
		}
		defer { close(slave) }

		let writer = fcntl(master, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
		do {
			guard writer >= 0, fcntl(master, F_SETFD, FD_CLOEXEC) == 0 else {
				throw SubProcessIllegalStateError.openPtyFailed(errno: errno)
			}
			if slave > STDERR_FILENO && fcntl(slave, F_SETFD, FD_CLOEXEC) == -1 {
				throw SubProcessIllegalStateError.openPtyFailed(errno: errno)
			}
			var actions: posix_spawn_file_actions_t!
			try checkSpawn(posix_spawn_file_actions_init(&actions))
			defer { posix_spawn_file_actions_destroy(&actions) }
			for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
				try checkSpawn(posix_spawn_file_actions_adddup2(&actions, slave, fd))
			}
			if slave > STDERR_FILENO {
				try checkSpawn(posix_spawn_file_actions_addclose(&actions, slave))
			}

			let argv = configuration.arguments.cStringArray
			let envp = configuration.environment.map { "\($0.key)=\($0.value)" }.cStringArray
			defer {
				argv.freeCStrings()
				envp.freeCStrings()
			}
			var pid = pid_t()
			try checkSpawn(ie_posix_spawn(&pid, configuration.executable, &actions, nil, argv, envp))
			return Self(pid: pid, reader: master, writer: writer)
		} catch {
			if writer >= 0 { close(writer) }
			close(master)
			throw error
		}
	}

	private static func checkSpawn(_ status: Int32) throws {
		guard status == 0 else { throw SubProcessIllegalStateError.forkFailed(errno: status) }
	}
}
