import XCTest
import Foundation
import T3Engine

/// Captured from a fresh macOS Vim 9.1 (patch 754) PTY with TERM=xterm-256color.
/// The test file began with "seed\n". Vim appended a line, resized, and saved.
final class VimReplayTests: XCTestCase {
    private func trace(_ sequences: [String]) -> Data {
        Data(("\u{1b}" + sequences.joined(separator: "\u{1b}")).utf8)
    }

    func testRealVimAtEveryReadBoundaryAndResize() {
        let editing = trace([
            "[?1049h", "[>4;2m", "[?1h", "=", "[?2004h", "[?1004h", "[1;10r", "[?12h", "[?12l",
            "[22;2t", "[22;1t", "[27m", "[23m", "[29m", "[m", "[H", "[2J", "[?25l",
            "[10;1H\"edit.txt\" 1L, 5B", "]10;?\u{07}", "]11;?\u{07}", "[1;1Hseed\r\n",
            "[94m~                                         ",
            "[3;1H~                                         ",
            "[4;1H~                                         ",
            "[5;1H~                                         ",
            "[6;1H~                                         ",
            "[7;1H~                                         ",
            "[8;1H~                                         ",
            "[9;1H~                                         ", "[1;1H", "[?25h", "[?4m", "[?25l",
            "[m", "[10;1H", "[1m-- INSERT --", "[m", "[10;13H", "[K", "[10;1H", "[K",
            "[2;13H\rT3Engine 界 é", "[2;14H", "[K", "[10;1H", "[1m-- INSERT --", "[2;14H", "[?25h"
        ])
        let resized = trace([
            "[27m", "[23m", "[29m", "[m", "[H", "[2J", "[?25l", "[1;1Hseed\r\nT3Engine 界 é\r\n",
            "[94m~                          ", "[4;1H~                          ",
            "[5;1H~                          ", "[6;1H~                          ",
            "[7;1H~                          ", "[m", "[8;1H", "[1m-- INSERT --", "[2;14H", "[?25h"
        ])
        let exiting = trace([
            "[?25l", "[m", "[8;1H", "[K", "[2;13H", "[?25h", "[?25l", "[8;1H:wq\r", "[27m", "[23m",
            "[29m", "[m", "[H", "[2J", "[?25h", "[?2004l", "[>4;m", "[?25l",
            "[8;1H\"edit.txt\" 2L, 22B written\r", "[23;2t", "[23;1t\r\r\n", "[?1004l", "[?2004l",
            "[?1l", ">", "[?1049l", "[?25h", "[>4;m"
        ])
        func run(_ cuts: [Int]) {
            let t = TerminalEngine(columns: 42, rows: 10)
            for (step, data) in [editing, resized, exiting].enumerated() {
                if step == 1 { t.resize(columns: 27, rows: 8) }
                let cut = cuts[step]
                if cut < 0 {
                    for byte in data { t.feed(Data([byte])) }
                } else {
                    t.feed(data.prefix(cut))
                    t.feed(data.dropFirst(cut))
                }
                if step < 2 {
                    XCTAssertTrue(t.isAlternateScreen)
                    XCTAssertTrue(t.line(at: 0).map(\.text).joined().hasPrefix("seed"))
                    XCTAssertTrue(t.line(at: 1).map(\.text).joined().hasPrefix("T3Engine 界 e\u{301}"))
                }
            }
            XCTAssertFalse(t.isAlternateScreen)
            XCTAssertTrue(t.modes.cursorVisible)
            XCTAssertFalse(t.modes.bracketedPaste)
        }
        run([-1, -1, -1])
        for (step, size) in [editing.count, resized.count, exiting.count].enumerated() {
            for cut in 0...size {
                var cuts = [0, 0, 0]
                cuts[step] = cut
                run(cuts)
            }
        }
    }
}
