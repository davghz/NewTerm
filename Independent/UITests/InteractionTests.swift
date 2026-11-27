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
    private func splitPane() {
        if app.buttons["t3rm.split"].isHittable {
            app.buttons["t3rm.split"].tap()
        } else {
            app.buttons["t3rm.actions"].tap()
            app.buttons["Split Pane"].tap()
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
    func testCompactSessionBarScrollsLongTitlesAndKeepsActionsReachable() throws {
        try XCTSkipIf(app.frame.width >= 560, "The compact toolbar uses the overflow menu below 560 points")
        let add = app.buttons["t3rm.newTab"]
        let search = app.buttons["t3rm.search"]
        let more = app.buttons["t3rm.actions"]
        let first = app.buttons["t3rm.tab.1"]
        let last = app.buttons["t3rm.tab.6"]
        func setTitle(_ title: String, of tab: XCUIElement, output: String) {
            // Hold the shell after printing so its next prompt cannot overwrite the OSC title.
            command("printf '\\033]0;\(title)\\007\\033[2J\\033[H'; " + output + "; IFS= read -r reply")
            let titled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: tab)
            XCTAssertEqual(XCTWaiter.wait(for: [titled], timeout: 8), .completed)
        }
        terminal.tap()
        setTitle("Workspace diagnostics", of: first, output: "uname -sm")
        for _ in 0..<5 { add.tap() }
        waitForShell(in: terminal)
        setTitle("Terminal environment", of: last, output: #"printf 'TERM=%s\n' "$TERM""#)

        let keyboard = app.keyboards.firstMatch
        let shelf = app.scrollViews["t3rm.keyShelf"]
        let key = shelf.buttons["Escape"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        key.press(forDuration: 0.05, thenDragTo: key.withOffset(CGVector(dx: 0, dy: 150)))
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !keyboard.exists && !shelf.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)

        let strip = app.scrollViews.containing(.button, identifier: "t3rm.tab.6").firstMatch
        XCTAssertTrue(strip.exists)
        let viewport = strip.frame
        XCTAssertTrue(last.isSelected && last.isHittable)
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(last.frame))
        XCTAssertFalse(first.isHittable)
        let actions = [add, search, more]
        let originalFrames = actions.map(\.frame)
        XCTAssertLessThanOrEqual(viewport.maxX, add.frame.minX)
        attachScreen("Glass toolbar with last session selected")

        // Anchor to the window so both directions start inside the strip even after a tab scrolls offscreen.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let y = viewport.midY - app.frame.minY
        let leading = origin.withOffset(CGVector(dx: viewport.minX - app.frame.minX + 12, dy: y))
        let trailing = origin.withOffset(CGVector(dx: viewport.maxX - app.frame.minX - 12, dy: y))
        func reveal(_ tab: XCUIElement, from start: XCUICoordinate, to end: XCUICoordinate) {
            for _ in 0..<4 {
                if tab.isHittable { break }
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTAssertTrue(tab.isHittable)
            tab.tap()
            XCTAssertTrue(tab.isSelected)
            XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(tab.frame))
        }
        reveal(first, from: leading, to: trailing)
        attachScreen("Glass toolbar with first session selected")
        reveal(last, from: trailing, to: leading)
        for (button, frame) in zip(actions, originalFrames) {
            XCTAssertEqual(button.frame, frame)
            XCTAssertGreaterThanOrEqual(frame.width, 44)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            XCTAssertTrue(button.isHittable)
        }
        XCTAssertFalse(keyboard.exists)
        search.tap()
        XCTAssertTrue(app.searchFields["t3rm.searchField"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        more.tap()
        XCTAssertTrue(app.buttons["Split Pane"].isHittable)
        XCTAssertTrue(app.buttons["Settings"].isHittable)
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
        splitPane()
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

    func testFirstTapSelectsInactivePaneAndSecondTapOpensKeyboard() {
        XCUIDevice.shared.orientation = .landscapeLeft
        splitPane()
        let panes = app.descendants(matching: .any).matching(identifier: "t3rm.terminal")
        XCTAssertEqual(panes.count, 2)
        let ordered = panes.allElementsBoundByIndex.sorted { $0.frame.midX < $1.frame.midX }
        let left = ordered[0]
        let right = ordered[1]
        XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX)
        waitForShell(in: right)
        XCTAssertTrue(right.isSelected)
        let keyboard = app.keyboards.firstMatch
        let shelf = app.scrollViews["t3rm.keyShelf"]
        XCTAssertFalse(keyboard.exists)
        XCTAssertFalse(shelf.exists)

        let center = CGVector(dx: 0.5, dy: 0.5)
        left.coordinate(withNormalizedOffset: center).tap()
        XCTAssertTrue(left.isSelected)
        XCTAssertFalse(keyboard.exists, "Switching from the new pane to the original pane opened the keyboard")
        XCTAssertFalse(shelf.exists)
        right.coordinate(withNormalizedOffset: center).tap()
        XCTAssertTrue(right.isSelected)
        XCTAssertFalse(keyboard.exists, "Switching back should only select the new pane")
        XCTAssertFalse(shelf.exists)

        right.coordinate(withNormalizedOffset: center).tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(shelf.exists)
        command("printf 'selected-%s\\n' second")
        XCTAssertTrue(screenContains("selected-second", in: right))
        XCTAssertFalse((left.value as? String ?? "").contains("selected-second"))
    }

    func testPullFromInactiveLowerPaneDismissesUpperKeyboardAndPreservesDraft() {
        splitPane()
        let panes = app.descendants(matching: .any).matching(identifier: "t3rm.terminal")
        XCTAssertEqual(panes.count, 2)
        let ordered = panes.allElementsBoundByIndex.sorted { $0.frame.midY < $1.frame.midY }
        let upper = ordered[0]
        let lower = ordered[1]
        XCTAssertLessThanOrEqual(upper.frame.maxY, lower.frame.minY)
        waitForShell(in: lower)
        XCTAssertTrue(lower.isSelected)

        upper.tap()
        XCTAssertTrue(upper.isSelected)
        upper.tap()
        let keyboard = app.keyboards.firstMatch
        let shelf = app.scrollViews["t3rm.keyShelf"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(shelf.exists)
        command(#"printf 'upper-%s\n' ready; IFS= read -r line; [ "$line" = draftok ] && printf 'draft-%s\n' preserved"#)
        XCTAssertTrue(screenContains("upper-ready", in: upper))
        app.typeText("draft")

        let start = lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let lowerHeight = lower.frame.height
        start.press(forDuration: 0.05, thenDragTo: end)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !keyboard.exists && !shelf.exists && lower.frame.height > lowerHeight + 20
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(upper.isSelected)
        XCTAssertFalse(lower.isSelected)

        upper.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        app.typeText("ok\n")
        XCTAssertTrue(screenContains("draft-preserved", in: upper))
        XCTAssertFalse((lower.value as? String ?? "").contains("draft-preserved"))
    }

    func testTabSwitchWithHiddenKeyboardThenSingleTapOpensKeyboard() {
        app.buttons["t3rm.newTab"].tap()
        let second = app.buttons["t3rm.tab.2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(second.isSelected)
        let first = app.buttons["t3rm.tab.1"]
        first.tap()
        XCTAssertTrue(first.isSelected)
        let keyboard = app.keyboards.firstMatch
        XCTAssertFalse(keyboard.exists)
        XCTAssertFalse(app.scrollViews["t3rm.keyShelf"].exists)

        terminal.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        command("printf 'selected-%s\\n' tab")
        XCTAssertTrue(screenContains("selected-tab"))
    }

    func testSwitchToMouseReportingPaneDismissesKeyboardAndConsumesTap() throws {
        terminal.tap()
        command([
            #"stty -echo; printf '\033[?1000h\033[?1006hpane-%s\n' ready; IFS= read -r wire"#,
            #"printf '\033[?1000l\033[?1006l'; stty echo; printf 'wire-%s\n' begin"#,
            #"printf %s "$wire" | tr '\033' '\n'; printf '\nwire-%s\n' end"#
        ].joined(separator: "; "))
        XCTAssertTrue(screenContains("pane-ready"))
        splitPane()
        let panes = app.descendants(matching: .any).matching(identifier: "t3rm.terminal")
        XCTAssertEqual(panes.count, 2)
        let first = panes.element(boundBy: 0)
        waitForShell(in: panes.element(boundBy: 1))
        let keyboard = app.keyboards.firstMatch
        let shelf = app.scrollViews["t3rm.keyShelf"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(shelf.exists)

        func tapFirstPane() {
            first.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        }
        tapFirstPane()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !keyboard.exists && !shelf.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        tapFirstPane()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        app.typeText("x")
        tapFirstPane()
        app.typeText("\n")

        XCTAssertTrue(screenContains("wire-end", in: first))
        let output = try XCTUnwrap(first.value as? String)
        let packets = #"wire-begin\s+x\s+\[<0;(\d+);(\d+)M\s+\[<0;\1;\2m\s+wire-end"#
        XCTAssertNotNil(output.range(of: packets, options: .regularExpression), "Unexpected terminal input: \(output)")
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
        let more = app.buttons["More keys"]
        more.tap()
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
        let extra = app.scrollViews["t3rm.keyShelf.extra"]
        let more = shelf.buttons["More keys"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        let pixel = 1 / UIScreen.main.scale
        func fullyVisible(_ button: XCUIElement, in row: XCUIElement) -> Bool {
            guard button.exists && button.isHittable else { return false }
            return row.frame.insetBy(dx: -pixel, dy: -pixel).contains(button.frame)
        }
        if UIDevice.current.userInterfaceIdiom == .phone && app.frame.width >= 375 {
            for label in ["ctrl", "Escape", "t3rm.keyShelf.shift", "More keys", "Up arrow", "Down arrow", "Left arrow", "Right arrow"] {
                XCTAssertTrue(fullyVisible(shelf.buttons[label], in: shelf), "\(label) at \(shelf.buttons[label].frame) in \(shelf.frame)")
            }
        }
        attachScreen("Terminal keys")
        let baseline = shelf.frame
        more.tap()
        XCTAssertTrue(extra.waitForExistence(timeout: 5))
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(shelf.frame.minY - baseline.minY) <= 2 && abs(extra.frame.height - baseline.height) <= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed,
                       "Collapsed base \(baseline), expanded base \(shelf.frame), extra \(extra.frame)")
        XCTAssertLessThanOrEqual(extra.frame.maxY, shelf.frame.minY + pixel)
        XCTAssertTrue(fullyVisible(extra.buttons["t3rm.keyShelf.paste"], in: extra))
        attachScreen("Expanded terminal keys")
        let left = extra.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        let right = extra.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))
        func reveal(_ label: String, swipeLeft: Bool) {
            let button = extra.buttons[label]
            for _ in 0..<8 {
                if fullyVisible(button, in: extra) { return }
                let start = swipeLeft ? right : left
                start.press(forDuration: 0.1, thenDragTo: swipeLeft ? left : right)
            }
            XCTFail("Could not reveal \(label) on the keyboard shelf")
        }
        let ctrl = shelf.buttons["ctrl"]
        ctrl.tap()
        reveal("t3rm.keyShelf.hide", swipeLeft: true)
        reveal("Tab", swipeLeft: false)
        XCTAssertTrue(ctrl.isSelected, "Dragging across keys consumed Ctrl")
        ctrl.tap()
        reveal("Function keys", swipeLeft: true)
        extra.buttons["Function keys"].tap()
        reveal("F12", swipeLeft: true)
        extra.buttons["F12"].tap()
        app.typeText("\n")
        XCTAssertTrue(screenContains("received-F12"))
        more.tap()
        XCTAssertFalse(extra.exists)
        XCTAssertTrue(shelf.buttons["Right arrow"].isHittable)
    }

    func testShiftShortcutsReachTheTerminalOnce() {
        terminal.tap()
        command(#"stty -echo; printf 'shift-%s\n' ready; IFS= read -r keys; stty echo; [ "$keys" = "$(printf '\033[Z\033[1;2AYy\033[13;2u')" ] && printf 'shift-%s\n' passed"#)
        XCTAssertTrue(screenContains("shift-ready"))
        let base = app.scrollViews["t3rm.keyShelf"]
        let extra = app.scrollViews["t3rm.keyShelf.extra"]
        let shift = base.buttons["t3rm.keyShelf.shift"]
        shift.tap()
        base.buttons["More keys"].tap()
        XCTAssertTrue(shift.isSelected)
        extra.buttons["Tab"].tap()
        XCTAssertFalse(shift.isSelected)
        shift.tap()
        base.buttons["Up arrow"].tap()
        shift.tap()
        app.typeText("yy")
        shift.tap()
        app.typeText("\n")
        XCTAssertFalse(shift.isSelected)
        app.typeText("\n")
        XCTAssertTrue(screenContains("shift-passed"))
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
            let distance = min(150, keyboard.frame.maxY - 8 - start.screenPoint.y)
            let end = start.withOffset(CGVector(dx: 0, dy: distance))
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

    func testShellRequiresAHoldToSelectText() {
        terminal.tap()
        command("printf 'hold-%s\\n' selection")
        XCTAssertTrue(screenContains("hold-selection"))
        let selection = app.navigationBars["Select Text"]
        let point = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.1))
        point.press(forDuration: 0.6)
        XCTAssertFalse(selection.exists)
        point.press(forDuration: 1.2)
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["Terminal transcript"].exists)
    }

    func testSingleTapReopensKeyboardAfterScrollingHistory() throws {
        terminal.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        command("for i in {1..160}; do echo row-$i; done; printf 'scroll-%s\\n' ready; IFS= read -r line; [ \"$line\" = ok ] && printf 'scroll-%s\\n' clean")
        XCTAssertTrue(screenContains("scroll-ready"))

        func firstVisibleRow() -> Int? {
            let text = terminal.value as? String ?? ""
            return text.split(separator: "\n").first(where: { $0.hasPrefix("row-") }).flatMap { Int($0.dropFirst(4)) }
        }
        let originalRow = try XCTUnwrap(firstVisibleRow())
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24))
        let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        start.press(forDuration: 0.08, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            firstVisibleRow().map { $0 < originalRow } ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 5), .completed)
        XCTAssertTrue(keyboard.exists)

        let initialHeight = terminal.frame.height
        let shelf = app.scrollViews["t3rm.keyShelf"]
        let key = shelf.buttons["Escape"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        key.press(forDuration: 0.05, thenDragTo: key.withOffset(CGVector(dx: 0, dy: 150)))
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            !keyboard.exists && !shelf.exists && terminal.frame.height > initialHeight + 40
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.25)).tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "One tap on scrollback should reopen the keyboard")
        app.typeText("ok\n")
        XCTAssertTrue(screenContains("scroll-clean"))
    }

    func testTapRestoresKeyboardWithoutClickingMouseReportingTerminal() throws {
        terminal.tap()
        let keyboard = app.keyboards.firstMatch
        let shelf = app.scrollViews["t3rm.keyShelf"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        // Keep the tap coordinates for comparison, but collapse consecutive wheel ticks.
        command([
            #"stty -echo; printf '\033[?1000h\033[?1006hmouse-%s\n' ready; IFS= read -r wire"#,
            #"printf '\033[?1000l\033[?1006l'; stty echo; printf 'wire-%s\n' begin"#,
            #"printf %s "$wire" | tr '\033' '\n' | sed -E 's/^\[<64;[0-9]+;[0-9]+M/wheel/' | uniq"#,
            #"printf '\nwire-%s\n' end"#
        ].joined(separator: "; "))
        XCTAssertTrue(screenContains("mouse-ready"))

        let initialHeight = terminal.frame.height
        let start = shelf.buttons["Escape"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 150)))
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            !keyboard.exists && !shelf.exists && terminal.frame.height > initialHeight + 40
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)

        let dragStart = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3))
        let dragEnd = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.55))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        XCTAssertFalse(keyboard.exists, "Dragging in the terminal should still reach the program")

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.64, dy: 0.4)).tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            keyboard.exists && shelf.exists && abs(terminal.frame.height - initialHeight) < 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed, "One tap should restore the keyboard")
        app.typeText("x")
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        app.typeText("\n")
        XCTAssertTrue(screenContains("wire-end"))

        // Only upward wheel ticks precede the typed x. The visible tap sends a matching click pair.
        let output = try XCTUnwrap(terminal.value as? String)
        let packets = #"wire-begin\s+(?:wheel\s+)?wheelx\s+\[<0;(\d+);(\d+)M\s+\[<0;\1;\2m\s+wire-end"#
        XCTAssertNotNil(output.range(of: packets, options: .regularExpression), "Unexpected terminal input: \(output)")
    }

    func testPullFromMouseReportingTerminalAcrossKeyboardPreservesDraft() {
        terminal.tap()
        let keyboard = app.keyboards.firstMatch
        let shelf = app.scrollViews["t3rm.keyShelf"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))

        // Button-motion mode reports selection drags as well as their press and release.
        command([
            #"stty -echo; printf '\033[?1002h\033[?1006hpull-%s\n' ready"#,
            #"IFS= read -r draft; [ "$draft" = draftok ] && printf 'draft-%s\n' intact"#,
            #"IFS= read -r wire; printf '\033[?1002l\033[?1006l'; stty echo"#,
            #"printf %s "$wire" | tr '\033' '\n' | awk -F';' 'NF == 3 {print $1 substr($3,length($3))}' | uniq"#,
            #"printf 'drag-%s\n' done"#
        ].joined(separator: "; "))
        XCTAssertTrue(screenContains("pull-ready"))
        app.typeText("draft")

        let initialHeight = terminal.frame.height
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let end = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            !keyboard.exists && !shelf.exists && terminal.frame.height > initialHeight + 40
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, "The pull should uncover the transcript")

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(shelf.exists)
        app.typeText("ok\n")
        XCTAssertTrue(screenContains("draft-intact"), "Only deliberately typed text should reach the program")

        let selectionStart = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.2))
        let selectionEnd = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        selectionStart.press(forDuration: 0.05, thenDragTo: selectionEnd)
        selectionEnd.press(forDuration: 0.6, thenDragTo: selectionStart)
        let right = selectionStart.withOffset(CGVector(dx: 80, dy: 0))
        selectionStart.press(forDuration: 0.05, thenDragTo: right)
        selectionStart.press(forDuration: 1.2, thenDragTo: selectionEnd)
        XCTAssertTrue(keyboard.exists, "Scrolling and selecting inside the transcript should keep the keyboard open")
        app.typeText("\n")
        XCTAssertTrue(screenContains("drag-done"))
        let output = terminal.value as? String ?? ""
        XCTAssertNotNil(output.range(of: #"draft-intact\s+\[<64M\s+\[<65M\s+\[<0M\s+\[<32M\s+\[<0m\s+drag-done"#, options: .regularExpression),
                        "Expected wheel ticks in each direction, followed by a held selection drag. Received \(output)")
    }

    func testMouseSelectionCopiesTerminalTextForPaste() {
        terminal.tap()
        // A terminal application waits for the SGR mouse release, then uses OSC 52 to copy.
        let sample = "copied-界-selection"
        let payload = Data(sample.utf8).base64EncodedString()
        command([
            #"stty -echo -icanon; printf '\033[?1002h\033[?1006hselect-%s\n' ready"#,
            #"IFS= read -r -d m events"#,
            #"printf '\033[?1002l\033[?1006l\033]52;c;%s\007' '"# + payload + "'",
            #"stty icanon; printf 'paste-%s\n' ready; IFS= read -r pasted; stty echo"#,
            #"printf 'received-%s\n' "$pasted""#
        ].joined(separator: "; "))
        XCTAssertTrue(screenContains("select-ready"))
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
        let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4))
        start.press(forDuration: 1.15, thenDragTo: end)
        XCTAssertTrue(screenContains("paste-ready"))
        app.buttons["t3rm.actions"].tap()
        let paste = app.buttons.matching(NSPredicate(format: "label == 'Paste' AND identifier != 't3rm.keyShelf.paste'")).firstMatch
        paste.tap()
        app.typeText("\n")
        XCTAssertTrue(screenContains("received-" + sample))
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

    func testInactiveMousePaneSeparatesKeyboardPullFromWheelScroll() {
        terminal.tap()
        command(#"printf 'upper-%s\n' ready; IFS= read -r line; [ "$line" = draftok ] && printf 'draft-%s\n' preserved"#)
        XCTAssertTrue(screenContains("upper-ready"))
        app.typeText("draft")
        splitPane()
        let panes = app.descendants(matching: .any).matching(identifier: "t3rm.terminal")
        XCTAssertEqual(panes.count, 2)
        let ordered = panes.allElementsBoundByIndex.sorted { $0.frame.midY < $1.frame.midY }
        let upper = ordered[0]
        let lower = ordered[1]
        waitForShell(in: lower)
        XCTAssertTrue(lower.isSelected)
        let keyboard = app.keyboards.firstMatch
        let shelf = app.scrollViews["t3rm.keyShelf"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))

        // Each Return ends a capture. Check the raw PTY input before printing the verdict.
        command([
            #"stty -echo; printf '\033[?1002h\033[?1006hprobe-%s\n' ready"#,
            #"IFS= read -r crossed; [ -z "$crossed" ] && result=empty || result=leaked; printf 'cross-%s\n' "$result""#,
            #"IFS= read -r wheel; printf '\033[?1002l\033[?1006l'; stty echo"#,
            #"printf '%s\n' "$wheel" | grep -Eq "^($(printf '\033')\[<64;[0-9]+;[0-9]+M)+$" && result=up || result=unexpected"#,
            #"printf 'wheel-result-%s\n' "$result""#
        ].joined(separator: "; "))
        XCTAssertTrue(screenContains("probe-ready", in: lower))

        func waitForDismissal(line: UInt = #line) {
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !keyboard.exists && !shelf.exists
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, line: line)
        }
        func selectAndOpen(_ pane: XCUIElement) {
            pane.tap()
            waitForDismissal()
            XCTAssertTrue(pane.isSelected)
            pane.tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        }
        selectAndOpen(upper)
        let start = lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let across = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: across)
        waitForDismissal()
        XCTAssertTrue(upper.isSelected)
        upper.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        app.typeText("ok\n")
        XCTAssertTrue(screenContains("draft-preserved", in: upper))
        selectAndOpen(lower)
        app.typeText("\n")
        XCTAssertTrue(screenContains("cross-empty", in: lower), "A dismissal leaked input to the mouse-reporting pane")

        selectAndOpen(upper)
        let inside = lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.05, thenDragTo: inside)
        waitForDismissal()
        XCTAssertTrue(lower.isSelected)
        lower.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        app.typeText("\n")
        XCTAssertTrue(screenContains("wheel-result-up", in: lower), "An in-pane downward drag should send only wheel-up packets")
    }

}
