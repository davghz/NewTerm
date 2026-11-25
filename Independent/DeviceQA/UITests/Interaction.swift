import UIKit
import XCTest

extension TerminalDeviceTests {
    func measureInteraction(_ app: XCUIApplication, tag: String) throws {
        let canvas = app.descendants(matching: .any)["t3rm.terminal"].firstMatch
        func command(_ mode: String, _ index: Int) {
            app.typeText("python3 /var/mobile/Library/Caches/t3rm-rewrite-qa/interaction.py " + mode + " " + tag + " " + String(index) + "\n")
        }
        func waitFor(_ text: String) -> Bool {
            let predicate = NSPredicate { _, _ in (canvas.value as? String ?? "").contains(text) }
            return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 9) == .completed
        }

        let plus = app.buttons["t3rm.newTab"].firstMatch
        for index in 1...3 {
            command("hidden", index)
            XCTAssertTrue(waitFor("HIDDEN READY " + String(index)))
            plus.tap()
        }
        var token: Int32 = 0, changed: Int32 = 0
        XCTAssertEqual(notify_register_check("com.davghz.t3rm.qa.tabs." + tag, &token), 0)
        defer { notify_cancel(token) }
        notify_check(token, &changed)
        command("visible", 4)
        let deadline = Date().addingTimeInterval(80)
        repeat {
            Thread.sleep(forTimeInterval: 0.2)
            notify_check(token, &changed)
        } while changed == 0 && Date() < deadline
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(waitFor("VISIBLE FINISHED"))
        XCTAssertFalse((canvas.value as? String ?? "").contains("HIDDEN FINISHED"))
        for index in 1...3 {
            app.buttons["t3rm.tab." + String(index)].tap()
            XCTAssertTrue(waitFor("HIDDEN FINISHED " + String(index)))
        }
        app.buttons["t3rm.tab.4"].tap()
        command("echo", 4)
        XCTAssertTrue(waitFor("ECHO READY"))
        let key = app.keyboards.keys.matching(NSPredicate(format: "label ==[c] %@", "x")).firstMatch
        XCTAssertTrue(key.exists)
        let area = canvas.frame, window = app.windows.firstMatch.frame
        let fingertip = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        var samples = [[String: UInt64]]()
        for index in 0..<7 {
            let begin = DispatchTime.now().uptimeNanoseconds
            fingertip.tap()
            let tapReturned = DispatchTime.now().uptimeNanoseconds
            var matched = false
            var observed: UInt64 = 0
            for _ in 0..<5 {
                let image = XCUIScreen.main.screenshot().image
                observed = DispatchTime.now().uptimeNanoseconds
                if try matchingPixel(image, point: CGPoint(x: area.midX, y: area.midY), window: window, red: index % 2 == 0) {
                    matched = true
                    break
                }
            }
            XCTAssertTrue(matched, "The composed screenshot did not contain the expected PTY echo color")
            samples.append(["tap_start_mono_ns": begin, "tap_returned_mono_ns": tapReturned,
                            "confirmed_screenshot_mono_ns": observed])
        }
        let records = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted])
        let attachment = XCTAttachment(data: records, uniformTypeIdentifier: "public.json")
        attachment.name = "Keyboard tap and composed screenshot timestamps"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func matchingPixel(_ image: UIImage, point: CGPoint, window: CGRect, red: Bool) throws -> Bool {
        let full = try XCTUnwrap(image.cgImage)
        let location = CGRect(x: Int((point.x - window.minX) * CGFloat(full.width) / window.width),
                              y: Int((point.y - window.minY) * CGFloat(full.height) / window.height),
                              width: 1, height: 1)
        let pixel = try XCTUnwrap(full.cropping(to: location))
        var components = [UInt8](repeating: 0, count: 4)
        try components.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                                  bitsPerComponent: 8, bytesPerRow: 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let r = Int(components[0]), g = Int(components[1])
        return red ? r > g + 60 : g > r + 60
    }
}
