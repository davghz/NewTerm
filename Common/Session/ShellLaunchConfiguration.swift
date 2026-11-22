//
//  ShellLaunchConfiguration.swift
//  NewTerm
//

import Foundation

struct ShellLaunchConfiguration {
	let executable: String
	let arguments: [String]
	let environment: [String: String]

	static func login(initialDirectory: String?, preferredLocale: String) throws -> Self {
		let account = currentAccount()
		let directory = initialDirectory ?? account.home
		let executable: String
		let arguments: [String]

		#if targetEnvironment(simulator)
		// Simulator installs strip execute permission from auxiliary bundle files.
		// The host's env sets the child's directory before starting its login shell.
		executable = "/usr/bin/env"
		arguments = ["env", "-C", directory, "/bin/zsh", "--login", "-i"]
		#else
		guard let helper = Bundle.main.path(forAuxiliaryExecutable: "NewTermLoginHelper") else {
			throw SubProcessIllegalStateError.forkFailed(errno: ENOENT)
		}
		if FileManager.default.fileExists(atPath: "/var/Liy/xina") {
			// Xina uses a direct login shell without /usr/bin/login.
			executable = helper
			arguments = ["-NewTermLoginHelper", directory, "/var/jb/bin/zsh", "--login", "-i"]
		} else {
			executable = loginExecutable
			let hushFile = URL(fileURLWithPath: account.home).appendingPathComponent(".hushlogin")
			let hush = FileManager.default.fileExists(atPath: hushFile.path)
			arguments = ["login", hush ? "-fpq" : "-fp", NSUserName(), helper, directory, account.shell]
		}
		#endif

		var environment = ProcessInfo.processInfo.environment
		environment["TERM"] = "xterm-256color"
		environment["COLORTERM"] = "truecolor"
		environment["TERM_PROGRAM"] = "t3rm"
		environment["LC_TERMINAL"] = "t3rm"
		environment["LANG"] = localeCode(preferredLocale)
		return Self(executable: executable, arguments: arguments, environment: environment)
	}

	private static var loginExecutable: String {
		#if targetEnvironment(macCatalyst)
		return "/usr/bin/login"
		#else
		let rootlessLogin = "/var/jb/usr/bin/login"
		return FileManager.default.fileExists(atPath: rootlessLogin) ? rootlessLogin : "/usr/bin/login"
		#endif
	}

	private static func currentAccount() -> (home: String, shell: String) {
		let fallback = (home: NSHomeDirectory(), shell: "/bin/bash")
		let suggestedSize = sysconf(_SC_GETPW_R_SIZE_MAX)
		var size = suggestedSize > 0 ? suggestedSize : 16384
		while true {
			let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
			defer { buffer.deallocate() }
			var account = passwd()
			var result: UnsafeMutablePointer<passwd>?
			let status = ie_getpwuid_r(getuid(), &account, buffer, size, &result)
			if status == 0, result != nil {
				// Both fields point into buffer. Copy them before leaving this scope.
				let home = account.pw_dir.map { String(cString: $0) } ?? fallback.home
				let shell = account.pw_shell.map { String(cString: $0) } ?? fallback.shell
				return (home, shell)
			}
			guard status == ERANGE else { return fallback }
			size *= 2
		}
	}

	private static func localeCode(_ preferredLocale: String) -> String {
		var languages = Locale.preferredLanguages
		if !preferredLocale.isEmpty, Locale(identifier: preferredLocale).languageCode != nil {
			languages.insert(preferredLocale, at: 0)
		}
		for language in languages {
			let locale = Locale(identifier: language)
			if let language = locale.languageCode, let region = locale.regionCode {
				let identifier = "\(language)_\(region).UTF-8"
				if FileManager.default.fileExists(atPath: "/usr/share/locale/" + identifier) {
					return identifier
				}
			}
		}
		return "en_US.UTF-8"
	}
}
