import XCTest
import UIKit
import T3Engine
@testable import t3rm

@MainActor
final class KeyboardTests: XCTestCase {
    private final class Phrase: UIDictationPhrase {
        private let utterance: String
        init(_ value: String) { utterance = value; super.init() }
        override var text: String { utterance }
    }

    func testMarkedCandidatesOnlyCommitFinalGrapheme() {
        let input = TerminalInput()
        var received: [String] = []
        input.onKey = { key,_ in if case .text(let text) = key { received.append(text) } }
        input.setMarkedText("n", selectedRange: NSRange(location: 1,length: 0))
        input.setMarkedText("ni", selectedRange: NSRange(location: 2,length: 0))
        XCTAssertTrue(received.isEmpty)
        input.insertText("你")
        XCTAssertEqual(received, ["你"])
        input.setMarkedText("か", selectedRange: NSRange(location: 1,length: 0))
        input.setMarkedText("家", selectedRange: NSRange(location: 1,length: 0))
        input.unmarkText()
        XCTAssertEqual(received, ["你","家"])
    }

    func testCancelledCompositionDoesNotSendText() {
        let input = TerminalInput()
        var received: [String] = []
        input.onKey = { key,_ in if case .text(let value) = key { received.append(value) } }
        input.setMarkedText("あ", selectedRange: NSRange(location: 1,length: 0))
        input.setMarkedText("", selectedRange: NSRange(location: 0,length: 0))
        input.unmarkText()
        XCTAssertTrue(received.isEmpty)
        input.insertText("x")
        XCTAssertEqual(received, ["x"])
    }

    func testDictationSendsOneCommittedPhraseSequence() {
        let input = TerminalInput()
        var received: [String] = []
        input.onKey = { key,_ in if case .text(let value) = key { received.append(value) } }
        input.insertDictationResult([Phrase("café"),Phrase(" 世界")])
        XCTAssertEqual(received, ["café 世界"])
        XCTAssertTrue(input.text.isEmpty)
    }

    func testCursorKeypadFunctionAndControlEncodings() {
        let engine = TerminalEngine(columns: 10, rows: 2)
        func bytes(_ key: TerminalKey, _ modifiers: UIKeyModifierFlags = []) -> Data {
            key.bytes(modes: engine.modes, modifiers: modifiers)
        }
        XCTAssertEqual(bytes(.up), Data("\u{1b}[A".utf8))
        _ = engine.feed(Data("\u{1b}[?1h\u{1b}=".utf8))
        XCTAssertEqual(bytes(.left), Data("\u{1b}OD".utf8))
        XCTAssertEqual(bytes(.keypad(normal: "0", application: "p")), Data("\u{1b}Op".utf8))
        XCTAssertEqual(bytes(.down, [.shift,.control]), Data("\u{1b}[1;6B".utf8))
        XCTAssertEqual(bytes(.function(12)), Data("\u{1b}[24~".utf8))
        XCTAssertEqual(bytes(.text("c"), [.control,.alternate]), Data([27,3]))
    }

    func testXtermCubeGraysAndConfiguredDefaults() {
        let colors = Palette(name: "Midnight")
        XCTAssertEqual(colors.indexed(16).terminalRGB, .rgb(0,0,0))
        XCTAssertEqual(colors.indexed(67).terminalRGB, .rgb(95,135,175))
        XCTAssertEqual(colors.indexed(231).terminalRGB, .rgb(255,255,255))
        XCTAssertEqual(colors.indexed(232).terminalRGB, .rgb(8,8,8))
        XCTAssertEqual(colors.indexed(255).terminalRGB, .rgb(238,238,238))
        XCTAssertNotEqual(colors.foreground.terminalRGB, colors.background.terminalRGB)
    }
}
