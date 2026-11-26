import UIKit

enum TerminalPaste {
    case text(String)
    case image(UIImage)

    static func read(from board: UIPasteboard) -> TerminalPaste? {
        // Photos and browsers can offer an image and a text description for the same item.
        if board.hasImages, let image = board.image { return .image(image) }
        if let text = board.string { return .text(text) }
        if let url = board.url { return .text(url.absoluteString) }
        return nil
    }
}
