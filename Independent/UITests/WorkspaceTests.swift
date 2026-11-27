import Darwin
import XCTest

final class WorkspaceTests: XCTestCase {
    #if targetEnvironment(simulator)
    private func launchShellWorkspace() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["ENV"] = "/dev/null"
        app.launch()
        XCTAssertTrue(app.buttons["t3rm.tab.1"].waitForExistence(timeout: 10))
        return app
    }

    private func closeSelectedTab(in app: XCUIApplication) {
        app.buttons["t3rm.actions"].tap()
        app.buttons["Close Tab"].tap()
    }

    func testCloseTabReapsShellAndRenumbersSurvivingTabs() throws {
        let app = launchShellWorkspace()
        let add = app.buttons["t3rm.newTab"]
        let first = app.buttons["t3rm.tab.1"]
        let second = app.buttons["t3rm.tab.2"]
        let third = app.buttons["t3rm.tab.3"]
        let terminal = app.descendants(matching: .any)["t3rm.terminal"].firstMatch

        add.tap()
        XCTAssertEqual(second.label, "Shell 2")
        terminal.tap()
        // The OSC title exposes this shell's PID without inspecting other processes.
        app.typeText(#"printf '\033]0;%s\007' "$$""# + "\n")
        let published = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES '[0-9]+'"), object: second)
        XCTAssertEqual(XCTWaiter.wait(for: [published], timeout: 8), .completed)
        let pid = try XCTUnwrap(pid_t(second.label))
        XCTAssertGreaterThan(pid, 1)
        XCTAssertEqual(kill(pid, 0), 0)

        add.tap()
        XCTAssertEqual(third.label, "Shell 3")
        terminal.tap()
        app.typeText("tab_state=third\n")
        second.tap()
        XCTAssertTrue(second.isSelected)
        closeSelectedTab(in: app)

        XCTAssertFalse(third.exists)
        XCTAssertEqual(first.label, "Shell 1")
        XCTAssertEqual(second.label, "Shell 2")
        XCTAssertTrue(second.isSelected)
        let reaped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            kill(pid, 0) == -1 && errno == ESRCH
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reaped], timeout: 8), .completed, "Closed shell still exists")
        terminal.tap()
        app.typeText(#"printf 'surviving-%s\n' "$tab_state""# + "\n")
        let alive = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'surviving-third'"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [alive], timeout: 8), .completed)

        closeSelectedTab(in: app)
        XCTAssertTrue(first.isSelected)
        XCTAssertFalse(second.exists)
        add.tap()
        XCTAssertTrue(second.isSelected)
        XCTAssertEqual(second.label, "Shell 2")
    }

    func testCloseTabPreservesShellReportedTitleAndReplacesLastShell() {
        let app = launchShellWorkspace()
        let first = app.buttons["t3rm.tab.1"]
        let second = app.buttons["t3rm.tab.2"]
        app.buttons["t3rm.newTab"].tap()
        app.descendants(matching: .any)["t3rm.terminal"].firstMatch.tap()
        app.typeText(#"printf '\033]0;Build\007'"# + "\n")
        let titled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Build'"), object: second)
        XCTAssertEqual(XCTWaiter.wait(for: [titled], timeout: 8), .completed)

        first.tap()
        closeSelectedTab(in: app)
        XCTAssertFalse(second.exists)
        XCTAssertTrue(first.isSelected)
        XCTAssertEqual(first.label, "Build")

        closeSelectedTab(in: app)
        XCTAssertFalse(second.exists)
        XCTAssertTrue(first.isSelected)
        XCTAssertEqual(first.label, "Shell 1")
    }
    #endif

    func testTabsSettingsAndOrientation() {
        let app = XCUIApplication()
        app.launch()
        let add = app.buttons["t3rm.newTab"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let second = app.descendants(matching: .any)["t3rm.tab.2"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["t3rm.settings"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }
}
