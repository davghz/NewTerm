import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import t3rm

@MainActor
final class PasteTests: XCTestCase {
    func testImageWithTextFallbackStillPastesThePicture() throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 2)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        }
        board.items = [[UTType.png.identifier: try XCTUnwrap(image.pngData()),
                        UTType.utf8PlainText.identifier: "Image caption"]]
        guard case .image(let pasted)? = TerminalPaste.read(from: board) else {
            return XCTFail("Expected the image representation")
        }
        XCTAssertEqual(pasted.cgImage?.width, image.cgImage?.width)
        XCTAssertEqual(pasted.cgImage?.height, image.cgImage?.height)
    }

    func testTextAndURLRepresentations() throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let draft = "a  b\n界 — é"
        board.string = draft
        guard case .text(let text)? = TerminalPaste.read(from: board) else { return XCTFail("Expected text") }
        XCTAssertEqual(text, draft)
        let url = try XCTUnwrap(URL(string: "https://example.com/paste?x=1"))
        board.url = url
        guard case .text(let address)? = TerminalPaste.read(from: board) else { return XCTFail("Expected a URL") }
        XCTAssertEqual(address, url.absoluteString)
    }
}
