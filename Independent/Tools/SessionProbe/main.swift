import Darwin
import Foundation
import T3Engine
import T3Sessions

// This executable is built separately for QA. It starts only its own mobile shell.
let args = CommandLine.arguments
let scenario = args.count > 1 ? args[1] : "shell"
let allowed = ["shell", "claude", "opencode", "codex", "cycles"]
guard allowed.contains(scenario) else { exit(2) }

final class Probe {
    let session = TerminalSession()
    let lock = NSCondition()
    let engine = TerminalEngine(columns: 50, rows: 24)
    var bytes = 0
    var recent = Data()
    var exitCode: Int32?

    func start(directory: String) throws {
        try session.start(directory: directory, columns: 50, rows: 24, onData: { data in
            self.lock.lock()
            self.bytes += data.count
            self.recent.append(data)
            if self.recent.count > 65_536 { self.recent.removeFirst(self.recent.count - 65_536) }
            let updates = self.engine.feed(data)
            self.lock.broadcast()
            self.lock.unlock()
            for effect in updates {
                if case .reply(let reply) = effect { self.session.write(reply) }
            }
        }, onExit: { status in
            self.lock.lock()
            self.exitCode = status
            self.lock.broadcast()
            self.lock.unlock()
        })
    }

    func visible() -> String {
        (0..<engine.rows).map { row in
            engine.line(at: engine.historyCount + row).filter { $0.width != 0 }.map(\.text).joined()
        }.joined(separator: "\n")
    }

    func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        lock.lock()
        defer { lock.unlock() }
        while !condition() {
            if !lock.wait(until: deadline) { return condition() }
        }
        return true
    }

    func hasMarker(_ text: String) -> Bool {
        recent.range(of: Data(text.utf8)) != nil
    }

    func write(_ text: String) {
        session.write(Data(text.utf8))
    }
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("t3rm-probe-" + UUID().uuidString)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
setenv("ZDOTDIR", tmp.path, 1)
setenv("HISTFILE", "/dev/null", 1)
func descriptorCount() -> Int { (0..<512).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }

if scenario == "cycles" {
    let before = descriptorCount()
    for _ in 0..<100 {
        let probe = Probe()
        try probe.start(directory: tmp.path)
        probe.write("exit 0\r")
        guard probe.wait(5, { probe.exitCode == 0 }) else { exit(1) }
    }
    let after = descriptorCount()
    print("cycles=100 descriptors_before=\(before) after=\(after)")
    exit(after <= before + 1 ? 0 : 1)
}

let probe = Probe()
let started = DispatchTime.now().uptimeNanoseconds
try probe.start(directory: tmp.path)
probe.write("stty -echo; test -t 0 && test -t 1 && printf 'T3%s\\n' READY >/dev/tty\r")
guard probe.wait(8, { probe.hasMarker("T3READY\r\n") }) else {
    print("controlling_terminal=false")
    probe.session.close()
    exit(1)
}
if scenario == "shell" {
    probe.session.resize(columns: 72, rows: 31)
    probe.write("stty size; printf 'T3%s\\n' FINAL; exit 17\r")
    let complete = probe.wait(8) { probe.exitCode != nil }
    let final = probe.hasMarker("T3FINAL\r\n") && probe.hasMarker("31 72\r\n")
    print("controlling_terminal=true resize_and_final_output=\(final) exit=\(probe.exitCode ?? -1)")
    exit(complete && final && probe.exitCode == 17 ? 0 : 1)
}

var inject = "export HOME=\"$PWD\" XDG_CONFIG_HOME=\"$PWD/config\" XDG_CACHE_HOME=\"$PWD/cache\" XDG_DATA_HOME=\"$PWD/data\" CLAUDE_CONFIG_DIR=\"$PWD/.claude\" CODEX_HOME=\"$PWD/.codex\"; "
inject += "mkdir -p \"$CODEX_HOME\"; export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1; "
// A new zsh prompt proves the shell regained the foreground even if an
// interrupt discarded the rest of the input line.
let invocation = scenario == "opencode" ? "opencode --standalone" : scenario
inject += "function _t3_probe_return { printf 'T3%s\\n' RETURNED; }; precmd_functions+=(_t3_probe_return); "
probe.write(inject + invocation + "\r")

func recognized(_ value: String) -> Bool {
    let screen = value.lowercased()
    switch scenario {
    case "claude": return screen.contains("dark mode") || screen.contains("choose the text style") || screen.contains("select a theme")
    case "opencode": return screen.contains("ask anything") || screen.contains("tab agents") || screen.contains("ctrl+p commands") || (screen.contains("/models") && screen.contains("/sessions"))
    default: return screen.contains("sign in") || screen.contains("codex cli") || screen.contains("openai codex") || screen.contains("login with")
    }
}
let appeared = probe.wait(30) { recognized(probe.visible()) }
let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
probe.lock.lock()
let beforeResize = probe.bytes
probe.engine.resize(columns: 63, rows: 25)
probe.lock.unlock()
probe.session.resize(columns: 63, rows: 25)
let resized = appeared && probe.wait(5) { probe.bytes > beforeResize && recognized(probe.visible()) }
for key: UInt8 in [3, 3, 4, 3] {
    if probe.wait(0.25, { probe.hasMarker("T3RETURNED") }) { break }
    probe.session.write(Data([key]))
}
let returned = probe.wait(4) { probe.hasMarker("T3RETURNED") }
if returned {
    probe.write("stty size; exit 0\r")
    _ = probe.wait(3) { probe.exitCode != nil }
}
probe.session.close()
_ = probe.wait(4) { probe.exitCode != nil }
let actualSize = probe.hasMarker("25 63")
print("cli=\(scenario) recognizable_screen=\(appeared) first_screen_ms=\(Int(elapsed)) redraw_after_resize=\(resized) returned_to_shell=\(returned) confirmed_size=\(actualSize)")
exit(appeared && resized && returned && actualSize ? 0 : 1)
