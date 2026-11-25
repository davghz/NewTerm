import Foundation
import XCTest
import T3Engine

final class TerminalEngineTests: XCTestCase {
    private let esc = "\u{1b}"

    private func text(_ engine: TerminalEngine, _ line: Int) -> String {
        engine.line(at: line).map(\.text).joined()
    }

    private func replay(_ bytes: Data, cols: Int = 12, rows: Int = 4,
                        verify: (TerminalEngine, [TerminalEffect]) -> Void) {
        var cuts = (0...bytes.count).map { [0, $0, bytes.count] }
        cuts.append(Array(0...bytes.count))
        for boundaries in cuts {
            let engine = TerminalEngine(columns: cols, rows: rows)
            var events = [TerminalEffect]()
            for (a, b) in zip(boundaries, boundaries.dropFirst()) {
                events += engine.feed(bytes.subdata(in: a..<b))
            }
            verify(engine, events)
        }
    }

    func testEveryPTYReadBoundaryAndOrderedEffects() {
        let transcript = "p> " + esc + "[31;1m界e\u{301}👩‍💻" + esc + "[m" + esc + "[6n"
            + "\r\n" + esc + "]2;Überblick" + esc + "\\" + esc + "]7;file:///tmp/a\u{07}\u{07}"
            + esc + "[?1;25;1002;1006;2004;2026h" + esc + "[?2026$p" + esc + "[c" + esc + "[>c"
        replay(Data(transcript.utf8)) { t, effects in
            let line = t.line(at: 0)
            XCTAssertEqual(Array(line[3...7].map(\.text)), ["界", "", "e\u{301}", "👩‍💻", ""])
            XCTAssertEqual(Array(line[3...7].map(\.width)), [2, 0, 1, 2, 0])
            XCTAssertEqual(line[3].style.foreground, .indexed(1))
            XCTAssertEqual(line[3].style.brightBoldForeground, .indexed(9))
            XCTAssertEqual(t.cursorRow, 1)
            XCTAssertEqual(t.cursorColumn, 0)
            XCTAssertTrue(t.modes.applicationCursor && t.modes.cursorVisible && t.modes.bracketedPaste)
            XCTAssertTrue(t.modes.sgrMouse && t.modes.synchronizedOutput)
            XCTAssertEqual(t.modes.mouseTracking, .buttonMotion)
            let expected: [TerminalEffect] = [
                .reply(Data((esc + "[1;9R").utf8)), .title("Überblick"), .workingDirectory("file:///tmp/a"), .bell,
                .reply(Data((esc + "[?2026;1$y").utf8)), .reply(Data((esc + "[?1;2c").utf8)),
                .reply(Data((esc + "[>0;1;0c").utf8))
            ]
            XCTAssertEqual(effects, expected)
        }
    }

    func testAlternateBufferSaveRestoreAndResize() {
        let t = TerminalEngine(columns: 6, rows: 3)
        t.feed(Data(("A\r\nB\r\nC\r\n" + esc + "[34mD" + esc + "[?1049h").utf8))
        XCTAssertEqual(t.historyCount, 0)
        XCTAssertEqual(t.retainedHistoryCount, 1)
        XCTAssertEqual(text(t, 0), "      ")
        t.feed(Data(("alt\r\n" + esc + "[31mX\r\nY\r\nZ" + esc + "[?1049l!").utf8))
        XCTAssertEqual(t.historyCount, 1)
        XCTAssertEqual(text(t, 0), "A     ")
        XCTAssertEqual(text(t, 3), "D!    ")
        XCTAssertEqual(t.line(at: 3)[1].style.foreground, .indexed(4))
        t.resize(columns: 5, rows: 2)
        XCTAssertEqual(t.historyCount, 2)
        XCTAssertEqual(text(t, 3), "D!   ")
        t.resize(columns: 7, rows: 4)
        XCTAssertEqual(t.historyCount, 0)
        XCTAssertEqual(text(t, 0), "A      ")
        XCTAssertEqual(t.cursorRow, 3)
        XCTAssertEqual(t.takeDirtyRows(), IndexSet(integersIn: 0..<4))
        XCTAssertTrue(t.takeDirtyRows().isEmpty)
    }

    func testMarginOriginReverseIndexInsertDeleteLines() {
        let t = TerminalEngine(columns: 5, rows: 5)
        t.feed(Data(("111\r\n222\r\n333\r\n444\r\n555" + esc + "[2;4r" + esc + "[?6h").utf8))
        XCTAssertEqual(t.cursorRow, 1)
        t.feed(Data((esc + "M").utf8))
        XCTAssertEqual((0..<5).map { text(t, $0) }, ["111  ", "     ", "222  ", "333  ", "555  "])
        t.feed(Data(("A" + esc + "[3;1H\nB").utf8))
        XCTAssertEqual((0..<5).map { text(t, $0) }, ["111  ", "222  ", "333  ", "B    ", "555  "])
        XCTAssertEqual(t.feed(Data((esc + "[?6n").utf8)), [.reply(Data((esc + "[?3;2R").utf8))])
        t.feed(Data((esc + "[2;1H" + esc + "[L" + "Q" + esc + "[M").utf8))
        XCTAssertEqual((0..<5).map { text(t, $0) }, ["111  ", "222  ", "333  ", "     ", "555  "])
        XCTAssertEqual(t.historyCount, 0)
    }

    func testWideOverwritesInsertDeleteEraseAndTruncatedEdges() {
        let t = TerminalEngine(columns: 8, rows: 2)
        t.feed(Data(("a界b界z" + esc + "[3GX").utf8))
        XCTAssertEqual(text(t, 0), "a Xb界z ")
        t.feed(Data((esc + "[4G" + esc + "[2@").utf8))
        XCTAssertEqual(text(t, 0), "a X  b界")
        t.feed(Data((esc + "[7G" + esc + "[P").utf8))
        XCTAssertEqual(text(t, 0), "a X  b  ")
        t.feed(Data((esc + "[5G界" + esc + "[6G" + esc + "[X").utf8))
        XCTAssertEqual(text(t, 0), "a X     ")
        t.feed(Data((esc + "[7G界").utf8))
        t.resize(columns: 7, rows: 2)
        XCTAssertEqual(t.line(at: 0).last?.width, 1)
        XCTAssertEqual(t.line(at: 0).last?.text, " ")
    }

    func testStylesAndErasedBackground() {
        let t = TerminalEngine(columns: 9, rows: 2)
        t.feed(Data((esc + "[1;31;44mA" + esc + "[22mB" + esc + "[91mC" + esc + "[38;5;201mD"
                     + esc + "[38:2::1:2:3;48;2;4;5;6;3;4;7mE").utf8))
        let line = t.line(at: 0)
        XCTAssertEqual(line[0].style.brightBoldForeground, .indexed(9))
        XCTAssertEqual(line[1].style.brightBoldForeground, .indexed(1))
        XCTAssertEqual(line[2].style.foreground, .indexed(9))
        XCTAssertEqual(line[3].style.foreground, .indexed(201))
        XCTAssertEqual(line[4].style.foreground, .rgb(1, 2, 3))
        XCTAssertEqual(line[4].style.background, .rgb(4, 5, 6))
        XCTAssertTrue(line[4].style.italic && line[4].style.underline && line[4].style.inverse)
        t.feed(Data((esc + "[27m" + esc + "[K").utf8))
        XCTAssertEqual(t.line(at: 0)[8].style.background, .rgb(4, 5, 6))
    }

    func testBoundedRingStylesGlyphsAndHistoryDamage() {
        let t = TerminalEngine(columns: 8, rows: 2, historyLimit: 3)
        for number in 0..<40 {
            t.feed(Data(("\(number)" + esc + "[4;91m界" + esc + "[me\u{301}\r\n").utf8))
        }
        XCTAssertEqual(t.historyCount, 3)
        XCTAssertEqual(t.discardedHistoryLines, 36)
        XCTAssertTrue(text(t, 0).hasPrefix("36界e\u{301}"))
        XCTAssertEqual(t.line(at: 0)[2].style.foreground, .indexed(9))
        XCTAssertTrue(t.line(at: 0)[3].style.underline)
        XCTAssertEqual(t.line(at: 0)[3].width, 0)
        XCTAssertTrue((1..<4096).contains(t.historyStorageBytes))
        t.trimHistory(to: 1)
        XCTAssertTrue(text(t, 0).hasPrefix("38界"))
        t.trimHistory(toBytes: 0)
        XCTAssertEqual(t.historyStorageBytes, 0)
        XCTAssertEqual(t.discardedHistoryLines, 39)
        XCTAssertEqual(t.line(at: -1), [])
        XCTAssertEqual(t.line(at: .max), [])
    }

    func testControlStringsTransferBoundsAndUnicodeSTByte() {
        let input = esc + "]2;Ü\u{07}" + esc + "Pstuff" + esc + "\\"
            + esc + "]1337;RequestUpload=format=tgz\u{07}"
            + esc + "]1337;File=name=Li4vdGVzdA==;size=3:YWJj" + esc + "\\"
            + esc + "]1337;File=size=4:YWJj\u{07}" + esc + "]1337;File=inline=1:YWJj\u{07}X"
        replay(Data(input.utf8)) { t, effects in
            XCTAssertEqual(effects, [.title("Ü"), .uploadRequest, .download(name: "test", data: Data("abc".utf8))])
            XCTAssertTrue(text(t, 0).hasPrefix("X "))
        }
        let t = TerminalEngine(columns: 8, rows: 1)
        let huge = esc + "]2;" + String(repeating: "x", count: 9000) + "\u{07}OK"
        XCTAssertTrue(t.feed(Data(huge.utf8)).isEmpty)
        XCTAssertTrue(text(t, 0).hasPrefix("OK "))
        t.feed(Data((esc + "[" + String(repeating: "1", count: 257) + "HL").utf8))
        XCTAssertTrue(text(t, 0).hasPrefix("OKL "))
    }

    func testMalformedUTF8InterruptAndWrapCombining() {
        var bytes = Data([0xe2, 0x82, 0x41, 0xed, 0xa0, 0x80])
        bytes.append(Data((esc + "[2;4H❤️X").utf8))
        replay(bytes, cols: 4, rows: 3) { t, _ in
            XCTAssertEqual(text(t, 0), "\u{fffd}A\u{fffd}\u{fffd}")
            XCTAssertEqual(t.line(at: 2)[0].text, "❤️")
            XCTAssertEqual(t.line(at: 2)[0].width, 2)
            XCTAssertEqual(t.line(at: 2)[2].text, "X")
        }
    }

    func testSoftWrapRotationPreservesWideGlyphsHardBreaksAndCursor() {
        let t = TerminalEngine(columns: 5, rows: 4)
        t.feed(Data(("abcd界e\r\n" + "xy").utf8))
        XCTAssertEqual(text(t, 0), "abcd ")
        XCTAssertEqual(text(t, 1), "界e  ")
        t.resize(columns: 8, rows: 4)
        XCTAssertEqual(text(t, 0), "abcd界e ")
        XCTAssertEqual(text(t, 1), "xy      ")
        XCTAssertEqual(t.cursorRow, 1)
        XCTAssertEqual(t.cursorColumn, 2)
        t.resize(columns: 3, rows: 4)
        XCTAssertEqual((0..<3).map { text(t, $0) }, ["abc", "d界", "e  "])
        XCTAssertEqual(text(t, 3), "xy ")
        XCTAssertEqual(t.historyCount + t.cursorRow, 3)
        t.feed(Data("!".utf8))
        XCTAssertEqual(text(t, 3), "xy!")
        t.resize(columns: 7, rows: 4)
        XCTAssertEqual(text(t, 0), "abcd界e")
        XCTAssertEqual(text(t, 1), "xy!    ")
    }

    func testReflowAcrossHistoryBoundaryAndSavedCursor() {
        let t = TerminalEngine(columns: 4, rows: 2)
        t.feed(Data(("abcdefghijk\r\nZ" + esc + "[1;3H" + esc + "7" + esc + "[2;2H").utf8))
        XCTAssertEqual(t.historyCount, 2)
        t.resize(columns: 7, rows: 3)
        XCTAssertEqual((0..<3).map { text(t, $0) }, ["abcdefg", "hijk   ", "Z      "])
        XCTAssertEqual(t.historyCount, 0)
        t.feed(Data((esc + "8!").utf8))
        XCTAssertEqual(text(t, 1), "hij!   ")
        t.feed(Data((esc + "[?1049h1234567").utf8))
        t.resize(columns: 4, rows: 3)
        XCTAssertEqual(text(t, 0), "1234")
        XCTAssertEqual(text(t, 1), "    ")
        t.feed(Data((esc + "[?1049l").utf8))
        XCTAssertEqual((0..<3).map { text(t, $0) }, ["abcd", "efgh", "ij! "])
    }

    func testTerminalColorQueriesUseConfiguredTheme() {
        let t = TerminalEngine(columns: 8, rows: 2)
        t.defaultBackgroundRGB = .rgb(1, 42, 255)
        let effects = t.feed(Data((esc + "]11;?\u{07}").utf8))
        XCTAssertEqual(effects, [.reply(Data((esc + "]11;rgb:0101/2a2a/ffff" + esc + "\\").utf8))])
    }

    func testVersionedUploadAndLocalRemoteWorkingDirectory() {
        let first = esc + "]1337;RequestUpload=format=tgz;version=My42LjE=\u{07}"
        let second = esc + "]1337;RequestUpload=version=My42LjE=;format=tgz" + esc + "\\"
        let invalid = esc + "]1337;RequestUpload=format=tgz;format=zip\u{07}"
        let local = esc + "]7;file://localhost/var/mobile/My%20Files\u{07}"
        let remote = esc + "]1337;RemoteHost=user@remote.example\u{07}" + esc + "]1337;CurrentDir=/tmp/a b\u{07}"
        let other = esc + "]7;file://remote.example/tmp/x\u{07}" + esc + "]7;file:///tmp/%00etc\u{07}"
        replay(Data((first + second + invalid + local + remote + other).utf8)) { _, effects in
            XCTAssertEqual(effects, [.uploadRequest, .uploadRequest, .workingDirectory("file://localhost/var/mobile/My%20Files"),
                                      .workingDirectory("file://remote.example/tmp/a%20b"), .workingDirectory("file://remote.example/tmp/x")])
        }
    }

    func testOneColumnReflowRestoresIntrinsicWidths() {
        let t = TerminalEngine(columns: 4, rows: 5)
        t.feed(Data("界❤️A".utf8))
        t.resize(columns: 1, rows: 5)
        XCTAssertEqual((0..<3).map { text(t, $0) }, ["界", "❤️", "A"])
        t.resize(columns: 7, rows: 5)
        XCTAssertEqual(t.line(at: 0).map(\.width), [2, 0, 2, 0, 1, 1, 1])
        XCTAssertEqual(t.cursorColumn, 5)
    }

    func testGridInvariantsUnderMixedEditingAndRotation() {
        let t = TerminalEngine(columns: 8, rows: 4, historyLimit: 7)
        var seed: UInt64 = 741
        func draw(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(upper))
        }
        let commands = ["界", " ", "a", "👩‍💻", "\r", "\n", "\t", "\u{08}", esc + "[1@", esc + "[2P", esc + "[2K",
                        esc + "[1S", esc + "[2T", esc + "[?1049l", esc + "[?1049h", esc + "7", esc + "8", esc + "[4h", esc + "[4l"]
        for _ in 0..<2000 {
            switch draw(12) {
            case 0: t.resize(columns: draw(13) + 1, rows: draw(7) + 1)
            case 1: t.feed(Data((esc + "[\(draw(t.rows) + 1);\(draw(t.columns) + 1)H").utf8))
            default: t.feed(Data(commands[draw(commands.count)].utf8))
            }
            XCTAssertTrue((0..<t.rows).contains(t.cursorRow))
            XCTAssertTrue((0..<t.columns).contains(t.cursorColumn))
            for i in 0..<(t.historyCount + t.rows) {
                let row = t.line(at: i)
                XCTAssertEqual(row.count, t.columns)
                if let length = t.wrappedLength(at: i) { XCTAssertTrue((0...t.columns).contains(length)) }
                for (column, cell) in row.enumerated() {
                    if cell.width == 0 { XCTAssertTrue(column > 0 && row[column - 1].width == 2) }
                    if cell.width == 2 { XCTAssertTrue(column + 1 < row.count && row[column + 1].width == 0) }
                }
            }
        }
    }

    func testASCIIRunsWrappingAndReplacingWideCells() {
        let t = TerminalEngine(columns: 5, rows: 2)
        t.feed(Data(("a界界" + esc + "[3GXYZ" + esc + "[?7l123456" + esc + "[?7h" + esc + "[H").utf8))
        XCTAssertEqual(text(t, 0), "a XY6")
        t.feed(Data("1234567890abcdefghi".utf8))
        XCTAssertEqual((0..<4).map { text(t, $0) }, ["12345", "67890", "abcde", "fghi "])
        XCTAssertEqual(t.historyCount, 2)
        XCTAssertEqual(t.cursorColumn, 4)
        XCTAssertEqual((0..<4).map { t.wrappedLength(at: $0) }, [5, 5, 5, nil])
    }

    func testRepeatedDirtyReadsAndModelWhileHidden() {
        let engines = (0..<3).map { _ in TerminalEngine(columns: 16, rows: 4) }
        for (session, t) in engines.enumerated() {
            _ = t.takeDirtyRows()
            t.feed(Data("tab\(session)".utf8))
            if session == 0 { XCTAssertEqual(t.takeDirtyRows(), IndexSet(integer: 0)) }
        }
        for i in 0..<100 {
            for (session, t) in engines.enumerated() { t.feed(Data("\r\n\(session):\(i)".utf8)) }
        }
        for (session, t) in engines.enumerated() {
            XCTAssertEqual(t.historyCount, 97)
            XCTAssertTrue(text(t, t.historyCount + 3).hasPrefix("\(session):99 "))
            XCTAssertEqual(t.takeDirtyRows(), IndexSet(integersIn: 0..<4))
        }
    }
}
