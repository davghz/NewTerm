import XCTest

final class InteractionTests: XCTestCase {
    private var app: XCUIApplication!
    private var terminal: XCUIElement { app.descendants(matching: .any)["t3rm.terminal"].firstMatch }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(terminal.waitForExistence(timeout: 8))
    }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }
    private func screenContains(_ text: String, in element: XCUIElement? = nil, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let wait = XCTNSPredicateExpectation(predicate: predicate, object: element ?? terminal)
        return XCTWaiter.wait(for: [wait], timeout: timeout) == .completed
    }
    private func command(_ text: String) { app.typeText(text + "\n") }
    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testShellSearchCopyPasteAndKeyboardRotation() {
        terminal.tap()
        command("printf '%s%s\\n' copy- proof")
        XCTAssertTrue(screenContains("copy-proof"))
        attachScreen("Portrait with keyboard")
        app.buttons["t3rm.search"].tap()
        let field = app.searchFields["t3rm.searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("copy-proof")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 4))
        app.buttons["Copy"].tap()
        app.buttons["Done"].tap()
        terminal.tap()
        app.typeText("printf '%s%s\\n' pasted- ")
        app.buttons["t3rm.actions"].tap()
        app.buttons["Paste"].tap()
        app.typeText("\n")
        XCTAssertTrue(screenContains("pasted-copy-proof"))
        XCUIDevice.shared.orientation = .landscapeLeft
        let settings = app.buttons["t3rm.settings"]
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _,_ in
            app.frame.width > app.frame.height && settings.frame.minY >= 0 && settings.frame.maxX <= app.frame.width &&
                terminal.frame.width > terminal.frame.height && settings.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        attachScreen("Landscape with keyboard")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func testHiddenTabShellOutputAndHistorySearch() {
        terminal.tap()
        command("printf '%s%s\\n' first- ready")
        XCTAssertTrue(screenContains("first-ready"))
        command("(sleep 2; awk 'BEGIN {for(i=0;i<65536;i++)printf \"%c\",7}'; printf '\\033]0;Output ready\\007'; printf '%s%s\\n' hidden- ready) &")
        app.buttons["t3rm.newTab"].tap()
        let second = app.buttons["t3rm.tab.2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        terminal.tap()
        command("printf '%s%s\\n' second- ready")
        XCTAssertTrue(screenContains("second-ready"))
        let first = app.buttons["t3rm.tab.1"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Output ready"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 6), .completed)
        first.tap()
        XCTAssertTrue(screenContains("hidden-ready"))
        command("for i in {1..100}; do echo line-$i; done")
        XCTAssertTrue(screenContains("line-100"))
        app.buttons["t3rm.search"].tap()
        let search = app.searchFields["t3rm.searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("hidden-ready")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 6))
    }
    func testSearchAcrossSoftWrapAndWideGlyph() {
        terminal.tap()
        command("printf 'long-%065d-%s\\n' 0 ok; printf '\\347\\225\\214\\n'")
        XCTAssertTrue(screenContains("界"))
        app.buttons["t3rm.search"].tap()
        let search = app.searchFields["t3rm.searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("long-" + String(repeating: "0", count: 65) + "-ok")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 6))
    }

    func testSplitResizeAndWorkingDirectory() {
        terminal.tap()
        command("cd /tmp && printf '\\033]7;file://localhost%s\\007' \"$PWD\" && printf 'cwd-%s\\n' set")
        XCTAssertTrue(screenContains("cwd-set"))
        app.buttons["t3rm.split"].tap()
        let divider = app.descendants(matching: .any)["t3rm.divider"].firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let all = app.descendants(matching: .any).matching(identifier: "t3rm.terminal")
        XCTAssertEqual(all.count, 2)
        let first = all.element(boundBy: 0)
        let second = all.element(boundBy: 1)
        let height = first.frame.height
        let center = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 0,dy: 44)))
        XCTAssertGreaterThan(first.frame.height, height + 10)
        second.tap()
        command("printf 'cwd-%s\\n' \"${PWD##*/}\"")
        XCTAssertTrue(screenContains("cwd-tmp", in: second))
        app.buttons["t3rm.actions"].tap()
        app.buttons["Close Pane"].tap()
        XCTAssertEqual(all.count, 1)
        XCTAssertGreaterThan(first.frame.height, height * 1.5)

    }

    func testCustomPromptAndLiteralPercent() {
        terminal.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "(?s).*\\S.*"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, "The login shell did not display its first output.")
        // Use a clean interactive shell so the host's prompt hooks cannot replace this fixture.
        command("exec /usr/bin/env PROMPT='ca''se%%> ' /bin/zsh -dfi")
        let customPrompt = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH %@", "case%>"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [customPrompt], timeout: 25), .completed, "Visible terminal text: \(terminal.value as? String ?? "")")
        command("printf '%s%s\\n' 'file ' '100%'")
        XCTAssertTrue(screenContains("file 100%"), "Visible terminal text: \(terminal.value as? String ?? "")")
    }

    func testShellTransferPromptsAndUploadCancellation() {
        terminal.tap()
        command("printf '\\033]1337;RequestUpload=format=tgz\\007'; IFS= read -r reply; printf 'upload-%s\\n' \"$reply\"")
        let upload = app.alerts["Upload a file?"]
        XCTAssertTrue(upload.waitForExistence(timeout: 5))
        upload.buttons["Cancel"].tap()
        XCTAssertTrue(screenContains("upload-abort"))
        terminal.tap()
        command("printf '\\033]1337;File=name=bm90ZS50eHQ=;size=3:YWJj\\007'")
        let download = app.alerts["Save a file?"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(download.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "note.txt")).firstMatch.exists)
        download.buttons["Cancel"].tap()
    }

}
