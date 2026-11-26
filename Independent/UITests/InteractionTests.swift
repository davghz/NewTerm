import XCTest

final class InteractionTests: XCTestCase {
    private var app: XCUIApplication!
    private var terminal: XCUIElement { app.descendants(matching: .any)["t3rm.terminal"].firstMatch }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(terminal.waitForExistence(timeout: 15))
        waitForShell(in: terminal)
    }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }
    private func screenContains(_ text: String, in element: XCUIElement? = nil, timeout: TimeInterval = 25) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let wait = XCTNSPredicateExpectation(predicate: predicate, object: element ?? terminal)
        return XCTWaiter.wait(for: [wait], timeout: timeout) == .completed
    }
    private func command(_ text: String) { app.typeText(text + "\n") }
    private func waitForShell(in element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "(?s).*\\S.*"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 45), .completed, "No initial shell output. \(app.debugDescription)")
    }
    private func openSettings() {
        if app.buttons["t3rm.settings"].isHittable {
            app.buttons["t3rm.settings"].tap()
        } else {
            app.buttons["t3rm.actions"].tap()
            app.buttons["Settings"].tap()
        }
    }
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
        let menuPaste = app.buttons.matching(NSPredicate(format: "label == 'Paste' AND identifier != 't3rm.keyShelf.paste'")).firstMatch
        XCTAssertTrue(menuPaste.isHittable)
        menuPaste.tap()
        app.typeText("\n")
        XCTAssertTrue(screenContains("pasted-copy-proof"))
        XCUIDevice.shared.orientation = .landscapeLeft
        let settings = app.buttons["t3rm.settings"]
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _,_ in
            settings.exists && terminal.exists && app.frame.width > app.frame.height &&
                settings.frame.minY >= 0 && settings.frame.maxX <= app.frame.width &&
                terminal.frame.width > terminal.frame.height && settings.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 15), .completed, app.debugDescription)
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
        waitForShell(in: terminal)
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
        if app.buttons["t3rm.split"].isHittable {
            app.buttons["t3rm.split"].tap()
        } else {
            app.buttons["t3rm.actions"].tap()
            app.buttons["Split Pane"].tap()
        }
        let divider = app.descendants(matching: .any)["t3rm.divider"].firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let all = app.descendants(matching: .any).matching(identifier: "t3rm.terminal")
        XCTAssertEqual(all.count, 2)
        let first = all.element(boundBy: 0)
        let second = all.element(boundBy: 1)
        waitForShell(in: second)
        let height = first.frame.height
        let center = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 0,dy: 44)))
        XCTAssertGreaterThan(first.frame.height, height + 10)
        second.tap()
        command("printf 'cwd-%s\\n' \"${PWD##*/}\"")
        XCTAssertTrue(screenContains("cwd-tmp", in: second), "Split shell output: \(second.value as? String ?? "")")
        app.buttons["t3rm.actions"].tap()
        app.buttons["Close Pane"].tap()
        XCTAssertEqual(all.count, 1)
        XCTAssertGreaterThan(first.frame.height, height * 1.5)

    }

    func testCustomPromptAndLiteralPercent() {
        terminal.tap()
        // Use a clean interactive shell so the host's prompt hooks cannot replace this fixture.
        command("exec /usr/bin/env PROMPT='ca''se%%> ' /bin/zsh -dfi")
        let customPrompt = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH %@", "case%>"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [customPrompt], timeout: 25), .completed, "Visible terminal text: \(terminal.value as? String ?? "")")
        command("printf '%s%s\\n' 'file ' '100%'")
        XCTAssertTrue(screenContains("file 100%"), "Visible terminal text: \(terminal.value as? String ?? "")")
    }

    func testWorkspaceThemePreviewAndKeyboardShelf() throws {
        // Track the selected session while the terminal and keyboard change appearance.
        terminal.tap()
        command("printf '\\033]0;Workspace\\007'")
        app.buttons["t3rm.newTab"].tap()
        let active = app.buttons["t3rm.tab.2"]
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        XCTAssertTrue(active.isSelected)
        waitForShell(in: terminal)
        terminal.tap()
        command("uname -sm")
        XCTAssertTrue(screenContains("Darwin"))
        let escape = app.buttons["Escape"]
        XCTAssertTrue(escape.isHittable)
        let function = app.buttons["Function keys"]
        function.tap()
        XCTAssertTrue(app.buttons["F1"].isHittable)
        XCTAssertTrue(function.isSelected)
        function.tap()
        XCTAssertTrue(escape.isHittable)
        attachScreen("Session tabs and terminal keys")

        openSettings()
        let preview = app.descendants(matching: .any)["t3rm.appearancePreview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let original = try XCTUnwrap((preview.value as? String)?.components(separatedBy: ", ").first)
        let other = original == "Paper" ? "Midnight" : "Paper"
        attachScreen("Appearance settings")
        app.staticTexts["Color Theme"].tap()
        app.staticTexts[other].tap()
        XCTAssertTrue(screenContains(other, in: preview))
        let keyboard = app.keyboards.firstMatch
        XCTAssertFalse(keyboard.exists && keyboard.isHittable)
        XCTAssertFalse(escape.exists && escape.isHittable)
        app.buttons["Done"].tap()
        XCTAssertTrue(active.isSelected)
        let shelfReturned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            escape.exists && escape.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shelfReturned], timeout: 5), .completed)
        command("printf '%s%s\\n' focus- restored")
        XCTAssertTrue(screenContains("focus-restored"))
        attachScreen("Alternate terminal theme")

        openSettings()
        app.staticTexts["Color Theme"].tap()
        app.staticTexts[original].tap()
        XCTAssertTrue(screenContains(original, in: preview))
    }

    func testSwipeAccessoryKeysFromAButton() {
        terminal.tap()
        command("printf 'waiting-%s\\n' F12; IFS= read -r key; [ \"$key\" = \"$(printf '\\033[24~')\" ] && printf 'received-%s\\n' F12")
        XCTAssertTrue(screenContains("waiting-F12"))
        let shelf = app.scrollViews["t3rm.keyShelf"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        let pixel = 1 / UIScreen.main.scale
        func fullyVisible(_ button: XCUIElement) -> Bool {
            guard button.exists && button.isHittable else { return false }
            return shelf.frame.insetBy(dx: -pixel, dy: -pixel).contains(button.frame)
        }
        if UIDevice.current.userInterfaceIdiom == .phone && app.frame.width >= 375 {
            for label in ["Up arrow", "Down arrow", "Left arrow", "Right arrow"] {
                XCTAssertTrue(fullyVisible(shelf.buttons[label]), label)
            }
        }
        let left = shelf.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let right = shelf.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        func reveal(_ label: String, swipeLeft: Bool) {
            let button = shelf.buttons[label]
            for _ in 0..<7 {
                if fullyVisible(button) { return }
                let start = swipeLeft ? right : left
                start.press(forDuration: 0.1, thenDragTo: swipeLeft ? left : right)
            }
            XCTFail("Could not reveal \(label) on the keyboard shelf")
        }
        let ctrl = shelf.buttons["ctrl"]
        ctrl.tap()
        reveal("t3rm.keyShelf.hide", swipeLeft: true)
        reveal("ctrl", swipeLeft: false)
        XCTAssertTrue(ctrl.isSelected, "Dragging across keys consumed Ctrl")
        ctrl.tap()
        let function = shelf.buttons["Function keys"]
        function.tap()
        reveal("F12", swipeLeft: true)
        shelf.buttons["F12"].tap()
        app.typeText("\n")
        XCTAssertTrue(screenContains("received-F12"))
        reveal("More keys", swipeLeft: false)
        shelf.buttons["More keys"].tap()
        reveal("t3rm.keyShelf.paste", swipeLeft: true)
    }

    func testPullDownFromAccessoryAndTerminalDismissesKeyboardWithoutTyping() {
        terminal.tap()
        command("printf 'pull-%s\\n' ready; IFS= read -r line; [ \"$line\" = ok ] && printf 'pull-%s\\n' clean")
        XCTAssertTrue(screenContains("pull-ready"))

        let shelf = app.scrollViews["t3rm.keyShelf"]
        let keyboard = app.keyboards.firstMatch
        let escape = shelf.buttons["Escape"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(escape.isHittable)
        func pullDown(from start: XCUICoordinate, line: UInt = #line) {
            let initialHeight = terminal.frame.height
            let end = start.withOffset(CGVector(dx: 0, dy: keyboard.frame.maxY - 16 - start.screenPoint.y))
            start.press(forDuration: 0.05, thenDragTo: end)
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                !keyboard.exists && !shelf.exists && terminal.frame.height > initialHeight + 40
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, "Pulling down should uncover the terminal", line: line)
            terminal.tap()
            XCTAssertTrue(escape.waitForExistence(timeout: 5))
            XCTAssertTrue(keyboard.exists)
        }
        pullDown(from: escape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        let terminalBottom = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
        pullDown(from: terminalBottom.withOffset(CGVector(dx: 0, dy: -15)))
        app.typeText("ok\n")
        XCTAssertTrue(screenContains("pull-clean"), "The waiting shell must receive only the text typed after reopening the keyboard")
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
