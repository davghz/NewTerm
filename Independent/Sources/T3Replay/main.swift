import Foundation
import T3Engine

// This executable creates deterministic byte streams and records preparation costs.
// Feed and grid inspection are measured separately from UIKit layout and display.
let args = CommandLine.arguments
let bytesPerBurst = 63_312
let lines = 24, columns = 50
let row = Data((String(repeating: "x", count: 48) + "\r\n").utf8)
let styled = Data((0..<lines).map { i in
    "\u{1b}[\(i + 1);1H\u{1b}[38;5;196m\(String(repeating: "x", count: 48))\u{1b}[0m"
}.joined().utf8)
let cell = Data("\u{1b}[12;24H*".utf8)
let burst = Data((0..<bytesPerBurst).map { row[$0 % row.count] })
let workloads = [("cell",cell),("styled",styled),("burst",burst)]
if args.count == 3, args[1] == "--emit", let job = workloads.first(where: { $0.0 == args[2] }) {
    FileHandle.standardOutput.write(job.1)
    exit(0)
}
let samples = 100
func percentile(_ durations: [Double], _ p: Double) -> Double {
    durations.sorted()[min(durations.count - 1, Int(ceil(Double(durations.count) * p)) - 1)]
}
print("workload,history_lines,cols,rows,input_bytes,samples,median_prepare_ms,p95_prepare_ms")
for (name, bytes) in workloads {
    for history in (name == "cell" ? [0,10_000] : [0]) {
        var durations = [Double]()
        let model = TerminalEngine(columns: columns, rows: lines)
        if history > 0 {
            for _ in 0..<(history + lines - 1) { _ = model.feed(row) }
        }
        _ = model.takeDirtyRows()
        for _ in 0..<samples {
            // Alternate-screen bursts have the same retained dimensions every time.
            if name == "burst" { _ = model.feed(Data("\u{1b}[?1049h\u{1b}[2J\u{1b}[H".utf8)) }
            let t = DispatchTime.now().uptimeNanoseconds
            _ = model.feed(bytes)
            for index in model.takeDirtyRows() {
                _ = model.line(at: model.historyCount + index)
            }
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000)
            if name == "burst" { _ = model.feed(Data("\u{1b}[?1049l".utf8)) }
        }
        print("\(name),\(history),\(columns),\(lines),\(bytes.count),\(samples),\(String(format: "%.3f", percentile(durations, 0.5))),\(String(format: "%.3f", percentile(durations, 0.95)))")
    }
}
