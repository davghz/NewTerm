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

    private func recordBytes(from input: TerminalInput) -> () -> Data {
        let modes = TerminalEngine(columns: 12, rows: 2).modes
        var bytes = Data()
        input.onKey = { key, modifiers in bytes.append(key.bytes(modes: modes, modifiers: modifiers)) }
        return { bytes }
    }

    private func waitForKeyboardCallbacks() {
        let nextTurn = expectation(description: "Deferred keyboard input delivered")
        DispatchQueue.main.async { nextTurn.fulfill() }
        wait(for: [nextTurn], timeout: 2)
    }

    private func keyboardBytes(_ perform: (TerminalInput) -> Void) -> Data {
        let input = TerminalInput()
        let received = recordBytes(from: input)
        perform(input)
        waitForKeyboardCallbacks()
        XCTAssertTrue(input.text.isEmpty)
        return received()
    }

    private func replaceHypothesis(in input: TerminalInput, with hypothesis: String) {
        guard let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) else {
            return XCTFail("Expected a valid dictation replacement range")
        }
        input.replace(range, withText: hypothesis)
        input.delegate?.textViewDidChange?(input)
    }

    func testLiveDictationRevisionsStayEditableUntilTheFinalResult() {
        for usePhraseResult in [false, true] {
            let input = TerminalInput()
            let received = recordBytes(from: input)
            for hypothesis in ["H", "Hello there", "Hello"] {
                replaceHypothesis(in: input, with: hypothesis)
                waitForKeyboardCallbacks()
                XCTAssertEqual(input.text, hypothesis)
                XCTAssertTrue(received().isEmpty, "A partial result reached the terminal")
            }
            input.dictationRecordingDidEnd()
            XCTAssertEqual(input.text, "Hello")
            input.unmarkText()
            XCTAssertTrue(received().isEmpty, "Dictation replacements have no marked range to commit")
            let final = "hello how are you"
            if usePhraseResult {
                input.insertDictationResult([Phrase("hello"), Phrase(" how are you")])
            } else {
                input.insertText(final)
            }
            waitForKeyboardCallbacks()
            XCTAssertEqual(received(), Data(final.utf8))
            XCTAssertTrue(input.text.isEmpty)
        }
    }

    func testFailedDictationDropsTheHypothesisBeforeOrdinaryTypingResumes() {
        let bytes = keyboardBytes { input in
            replaceHypothesis(in: input, with: "H")
            waitForKeyboardCallbacks()
            input.dictationRecognitionFailed()
            XCTAssertTrue(input.text.isEmpty)
            input.insertText("x")
        }
        XCTAssertEqual(bytes, Data("x".utf8))
    }

    func testListeningIndicatorFollowsRecordingAndFocus() throws {
        let window = UIWindow(frame: .zero)
        let pane = TerminalPane(directory: nil)
        window.addSubview(pane)
        pane.active = true
        let indicator = try XCTUnwrap(pane.subviews.first { $0.accessibilityIdentifier == "t3rm.dictation.listening" })
        XCTAssertTrue(indicator.isHidden)
        pane.input.onDictationListeningChanged?(true)
        XCTAssertFalse(indicator.isHidden)
        pane.input.dictationRecordingDidEnd()
        XCTAssertTrue(indicator.isHidden)
        pane.input.onDictationListeningChanged?(true)
        pane.input.textViewDidEndEditing(pane.input)
        XCTAssertTrue(indicator.isHidden)
    }

    func testTypedPrefixBeforeDictationIsPreserved() {
        let bytes = keyboardBytes { input in
            input.insertText("H")
            input.dictationCursor = { .visible(previous: "H") }
            replaceHypothesis(in: input, with: "H")
            waitForKeyboardCallbacks()
            input.insertDictationResult([Phrase("Hello")])
        }
        XCTAssertEqual(bytes, Data("H Hello".utf8))
    }

    func testAttributedMarkedTextCommitsOnlyWhenUnmarked() {
        let input = TerminalInput()
        let received = recordBytes(from: input)
        for candidate in ["に", "日"] {
            let marked = NSAttributedString(string: candidate, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
            input.setAttributedMarkedText(marked, selectedRange: NSRange(location: marked.length, length: 0))
            waitForKeyboardCallbacks()
            XCTAssertTrue(received().isEmpty)
        }
        input.unmarkText()
        input.unmarkText()
        XCTAssertEqual(received(), Data("日".utf8))
        XCTAssertTrue(input.text.isEmpty)
    }

    func testDictationAtBlankCursorWithEitherPlaceholderCallbackOrder() {
        let transcript = "  café 世界"
        for removeFirst in [false, true] {
            let bytes = keyboardBytes { input in
                let placeholder = input.insertDictationResultPlaceholder
                if removeFirst { input.removeDictationResultPlaceholder(placeholder, willInsertResult: true) }
                input.insertText(" ")
                input.insertText(transcript)
                if !removeFirst { input.removeDictationResultPlaceholder(placeholder, willInsertResult: true) }
            }
            XCTAssertEqual(bytes, Data(transcript.utf8), "Removed placeholder before text: \(removeFirst)")
        }
    }

    func testDictationSeparatesWordsAndPreservesPunctuationAndWhitespace() {
        let cases: [(previous: String?, phrase: String, expected: String)] = [
            ("d", "Example", " Example"),
            ("d", ", for example", ", for example"),
            ("d", "  Example", "  Example"),
            (" ", "Example", "Example"),
            (".", "Example", " Example"),
            ("/", "bin", "bin"),
            ("世", "界", "界"),
            (nil, "Example", "Example")
        ]
        for (previous, phrase, expected) in cases {
            let bytes = keyboardBytes { input in
                input.dictationCursor = { .visible(previous: previous) }
                input.insertDictationResult([Phrase(phrase)])
            }
            XCTAssertEqual(bytes, Data(expected.utf8), "After \(previous.debugDescription), dictated \(phrase.debugDescription)")
        }
    }

    func testWordAfterRecordingGetsOneSeparatorWithEitherPlaceholderCallbackOrder() {
        for removeFirst in [false, true] {
            for systemSendsSpace in [false, true] {
                let bytes = keyboardBytes { input in
                    input.dictationCursor = { .visible(previous: "d") }
                    let placeholder = input.insertDictationResultPlaceholder
                    if removeFirst { input.removeDictationResultPlaceholder(placeholder, willInsertResult: true) }
                    else { input.dictationRecordingDidEnd() }
                    if systemSendsSpace { input.insertText(" ") }
                    input.insertText("Example")
                    if !removeFirst { input.removeDictationResultPlaceholder(placeholder, willInsertResult: true) }
                    input.insertText("s")
                }
                XCTAssertEqual(bytes, Data(" Examples".utf8), "removeFirst=\(removeFirst), systemSendsSpace=\(systemSendsSpace)")
            }
        }
    }

    func testOnlyTheConfirmedUtteranceGetsWordSpacing() {
        let bytes = keyboardBytes { input in
            input.dictationCursor = { .visible(previous: "d") }
            input.insertText("a")
            input.dictationRecordingDidEnd()
            waitForKeyboardCallbacks()
            input.insertText("Example")
            input.insertText("s")
            input.dictationRecordingDidEnd()
            input.dictationRecognitionFailed()
            input.insertText("x")
        }
        XCTAssertEqual(bytes, Data("a Examplesx".utf8))
    }

    func testEmptyResultAndRefocusingDoNotAddSpacesToOrdinaryTyping() {
        let bytes = keyboardBytes { input in
            input.dictationCursor = { .visible(previous: "d") }
            let finished = input.insertDictationResultPlaceholder
            input.dictationRecordingDidEnd()
            input.insertText(" ")
            input.insertDictationResult([])
            input.removeDictationResultPlaceholder(finished, willInsertResult: true)
            input.insertText("s")

            let cancelled = input.insertDictationResultPlaceholder
            input.dictationRecordingDidEnd()
            input.insertText(" ")
            input.removeDictationResultPlaceholder(cancelled, willInsertResult: false)

            let abandoned = input.insertDictationResultPlaceholder
            input.dictationRecordingDidEnd()
            input.textViewDidEndEditing(input)
            input.textViewDidBeginEditing(input)
            input.removeDictationResultPlaceholder(abandoned, willInsertResult: true)
            input.insertText("x")
        }
        XCTAssertEqual(bytes, Data("sx".utf8))
    }

    func testResultCanStillBeDeliveredToTheViewThatLostFocus() {
        let bytes = keyboardBytes { input in
            input.dictationCursor = { .visible(previous: "d") }
            input.dictationRecordingDidEnd()
            input.textViewDidEndEditing(input)
            input.insertText("Example")
            input.textViewDidBeginEditing(input)
            input.insertText("s")
        }
        XCTAssertEqual(bytes, Data(" Examples".utf8))
    }

    func testHiddenTerminalCursorDoesNotUsePaintedTextForWordSpacing() {
        let engine = TerminalEngine(columns: 30, rows: 8)
        engine.feed(Data("\u{1b}[?1049h\u{1b}[?25lStatus".utf8))
        XCTAssertEqual(engine.textBeforeCursor, "s")
        let bytes = keyboardBytes { input in
            input.dictationCursor = { DictationCursor(engine) }
            input.insertDictationResult([Phrase("First")])
            input.dictationRecordingDidEnd()
            input.insertText(" ")
            input.insertText("second")
            engine.feed(Data("\u{1b}[?25h".utf8))
            input.insertDictationResult([Phrase("visible")])
        }
        XCTAssertEqual(bytes, Data("First second visible".utf8))
    }

    func testPhraseResultWithPendingSpacePreservesDictatedWhitespace() {
        let bytes = keyboardBytes { input in
            let placeholder = input.insertDictationResultPlaceholder
            input.insertText(" ")
            input.insertDictationResult([Phrase("  café"), Phrase(" 世界")])
            input.removeDictationResultPlaceholder(placeholder, willInsertResult: true)
        }
        XCTAssertEqual(bytes, Data("  café 世界".utf8))
    }

    func testCancellationKeepsOrdinaryTypingAndBackspaceInOrder() {
        let bytes = keyboardBytes { input in
            let placeholder = input.insertDictationResultPlaceholder
            input.insertText(" ")
            input.insertText("x")
            input.deleteBackward()
            input.removeDictationResultPlaceholder(placeholder, willInsertResult: false)
            input.insertText("y")
        }
        XCTAssertEqual(bytes, Data(" x\u{7f}y".utf8))
    }

    func testRemovingCompletedPhrasePlaceholderPreservesFollowingTyping() {
        let bytes = keyboardBytes { input in
            let placeholder = input.insertDictationResultPlaceholder
            input.insertDictationResult([Phrase("hello")])
            input.removeDictationResultPlaceholder(placeholder, willInsertResult: true)
            input.insertText(" ")
            input.insertText("next")
        }
        XCTAssertEqual(bytes, Data("hello next".utf8))
    }

    func testOrdinarySpaceIsDeliveredWhileRecognitionIsPending() {
        let bytes = keyboardBytes { input in
            _ = input.insertDictationResultPlaceholder
            input.insertText(" ")
        }
        XCTAssertEqual(bytes, Data(" ".utf8))
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
        XCTAssertEqual(bytes(.tab, [.shift]), Data("\u{1b}[Z".utf8))
        XCTAssertEqual(bytes(.tab), Data([9]))
        XCTAssertEqual(bytes(.text("a"), [.shift]), Data("A".utf8))
        XCTAssertEqual(bytes(.text("x"), [.shift, .control]), Data([24]))
        XCTAssertEqual(bytes(.text("\n"), [.shift]), Data("\u{1b}[13;2u".utf8))
        XCTAssertEqual(bytes(.text("\n")), Data([13]))
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
