import XCTest

final class TerminalDeviceTests: XCTestCase {
    func testTerminalReplay() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let id = try XCTUnwrap(env["QA_TARGET"])
        XCTAssertTrue(["com.davghz.t3rm.baseline", "com.davghz.t3rm.review"].contains(id))
        let mode = env["QA_CASE"] ?? "smoke"
        XCTAssertTrue(["interaction", "prompt", "editing", "suite", "smoke", "cold_sparse", "cold_styled", "cold_burst", "history_sparse", "history_styled", "history_burst"].contains(mode))
        let run = try XCTUnwrap(env["QA_RUN"])
        XCTAssertTrue(run.range(of: #"^[a-z0-9_]{1,50}$"#, options: .regularExpression) != nil)

        let target = XCUIApplication(bundleIdentifier: id)
        if target.state != .notRunning { target.terminate() }
        target.launch()
        XCTAssertTrue(target.wait(for: .runningForeground, timeout: 12))
        let screen = try XCTUnwrap(target.windows.firstMatch.exists ? target.windows.firstMatch : nil)
        if !target.keyboards.firstMatch.exists {
            screen.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
        }
        let screenshot = XCTAttachment(screenshot: target.screenshot())
        screenshot.name = "Isolated terminal before replay"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if mode == "interaction" {
            XCTAssertEqual(id, "com.davghz.t3rm.review")
            try measureInteraction(target, tag: run)
            return
        }
        if mode == "prompt" {
            let canvas = target.descendants(matching: .any)["t3rm.terminal"].firstMatch
            let ready = NSPredicate { _, _ in !(canvas.value as? String ?? "").isEmpty }
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5)
            let prompt = try XCTUnwrap(canvas.value as? String)
            XCTAssertFalse(prompt.isEmpty)
            XCTAssertFalse(prompt.contains("%"), prompt)
            let text = XCTAttachment(string: prompt)
            text.name = "Fresh default prompt"
            text.lifetime = .keepAlways
            add(text)
            target.typeText("printf 'literal=100\\045\\n'\n")
            let literal = NSPredicate { _, _ in (canvas.value as? String ?? "").contains("literal=100%") }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: literal, object: nil)], timeout: 5), .completed)
            let shot = XCTAttachment(screenshot: target.screenshot())
            shot.name = "Literal percent output"
            shot.lifetime = .keepAlways
            add(shot)
            return
        }
        if mode == "editing" {
            XCTAssertEqual(id, "com.davghz.t3rm.review")
            try exerciseEditors(target, run: run)
            return
        }
        var token: Int32 = 0
        let event = "com.davghz.t3rm.qa.done." + run
        XCTAssertEqual(notify_register_check(event, &token), 0)
        defer { notify_cancel(token) }
        var changed: Int32 = 0
        notify_check(token, &changed)
        target.typeText("python3 /var/mobile/Library/Caches/t3rm-rewrite-qa/replay.py " + mode + " " + run + (env["QA_PROFILE"] == "1" ? " profile" : "") + "\n")
        // The host harness collects the fixture's full JSON output from disk.
        let deadline = Date().addingTimeInterval(360)
        repeat {
            Thread.sleep(forTimeInterval: 0.2)
            XCTAssertEqual(notify_check(token, &changed), 0)
        } while changed == 0 && Date() < deadline
        XCTAssertEqual(changed, 1, "The terminal fixture did not announce completion")
        let result = XCTAttachment(screenshot: target.screenshot())
        result.name = "Isolated terminal during replay"
        result.lifetime = .keepAlways
        add(result)
    }

    private func exerciseEditors(_ app: XCUIApplication, run: String) throws {
        let canvas = app.descendants(matching: .any)["t3rm.terminal"].firstMatch
        let escape = app.buttons["Escape"].firstMatch

        func transcript() -> String { canvas.value as? String ?? "" }
        func waitFor(_ timeout: TimeInterval, _ predicate: (String) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if predicate(transcript()) { return true }
                Thread.sleep(forTimeInterval: 0.3)
            } while Date() < deadline
            return false
        }
        func evidence(_ name: String) {
            let text = XCTAttachment(string: transcript())
            text.name = name + " transcript"
            text.lifetime = .keepAlways
            add(text)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = name
            image.lifetime = .keepAlways
            add(image)
        }
        app.typeText("python3 /var/mobile/Library/Caches/t3rm-rewrite-qa/cli_probe.py " + run + "\n")
        XCTAssertTrue(waitFor(12) { $0.contains("edit.txt") || $0.contains("~") })
        app.typeText("iqa edit verified")
        XCTAssertTrue(waitFor(6) { $0.contains("qa edit verified") })
        evidence("vi insertion")
        XCTAssertTrue(escape.exists)
        escape.tap()
        app.typeText(":wq\n")
        XCTAssertTrue(waitFor(8) { $0.contains("T3 editor save verified") })
        app.typeText(". /var/mobile/Library/Caches/t3rm-rewrite-qa/editing_" + run + "/environment.sh; opencode --standalone .\n")
        let ready = waitFor(45) { text in
            let lower = text.lowercased()
            return lower.contains("what would you like to build") && lower.contains("/models")
        }
        evidence("OpenCode initial view")
        XCTAssertTrue(ready, "OpenCode UI did not become ready")
        app.typeText("qa unsent draft")
        XCTAssertTrue(waitFor(15) { $0.contains("qa unsent draft") })
        evidence("OpenCode unsent draft")
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "qa unsent draft".count))
        XCTAssertTrue(waitFor(6) { !$0.contains("qa unsent draft") })
        app.typeText("/models\n")
        let picker = waitFor(12) { text in
            let lower = text.lowercased()
            return !lower.contains("what would you like to build") &&
                (lower.contains("models") || lower.contains("select model") || lower.contains("provider"))
        }
        evidence("OpenCode model picker")
        XCTAssertTrue(picker, "Model picker did not appear")
        escape.tap()
        XCTAssertTrue(waitFor(6) { $0.lowercased().contains("what would you like to build") })
        evidence("OpenCode after picker dismissal")
    }
}
