import XCTest

final class PadTests: XCTestCase {
    func testSplitResizesWithoutLosingTabs() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Requires an iPad") }
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        let split = app.buttons["t3rm.split"]
        XCTAssertTrue(split.waitForExistence(timeout: 8))
        split.tap()
        let divider = app.descendants(matching: .any)["t3rm.divider"].firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let initial = divider.value as? String
        let center = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.15, thenDragTo: center.withOffset(CGVector(dx: 110, dy: 0)))
        XCTAssertNotEqual(divider.value as? String, initial)
        let resized = divider.value as? String
        app.buttons["t3rm.newTab"].tap()
        XCTAssertFalse(divider.exists)
        app.buttons["t3rm.tab.1"].tap()
        XCTAssertEqual(divider.value as? String, resized)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "t3rm.terminal").count, 2)
    }
}
