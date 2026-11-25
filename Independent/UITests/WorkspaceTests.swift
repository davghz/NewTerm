import XCTest

final class WorkspaceTests: XCTestCase {
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
