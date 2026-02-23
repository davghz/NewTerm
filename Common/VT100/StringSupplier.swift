//
//  StringSupplier.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 2/4/21.
//

import Foundation
import SwiftTerm
import SwiftUI

fileprivate extension View {
	static func + (lhs: Self, rhs: some View) -> AnyView {
		AnyView(ViewBuilder.buildBlock(lhs, AnyView(rhs)))
	}
}

open class StringSupplier {

	open var terminal: Terminal!
	open var colorMap: ColorMap!
	open var fontMetrics: FontMetrics!
	open var cursorVisible = true

	public init() {}

	public func attributedString(forScrollInvariantRow row: Int) -> AnyView {
		guard let terminal = terminal else {
			fatalError()
		}

		guard let line = terminal.getScrollInvariantLine(row: row) else {
			return AnyView(EmptyView())
		}

		let cursorPosition = terminal.getCursorLocation()
		let scrollbackRows = terminal.getTopVisibleRow()

		var lastAttribute = Attribute.empty
		var views = [AnyView]()
		var buffer = ""
		for j in 0..<terminal.cols {
			let data = line[j]
			let isCursor = cursorVisible && row - scrollbackRows == cursorPosition.y && j == cursorPosition.x

			if isCursor || lastAttribute != data.attribute {
				// Finish up the last run by appending it to the attributed string, then reset for the
				// next run.
				views.append(text(buffer, attribute: lastAttribute))
				lastAttribute = data.attribute
				buffer.removeAll()
			}

			let character = data.getCharacter()
			buffer.append(character == "\0" ? " " : character)

			if isCursor {
				// We may need to insert a space for the cursor to show up.
				if buffer.isEmpty {
					buffer.append(" ")
				}

				views.append(text(buffer, attribute: lastAttribute, isCursor: true))
				buffer.removeAll()
			}
		}

		// Append the final run
		views.append(text(buffer, attribute: lastAttribute))

		let lineHeight = max(1, ceil(fontMetrics?.boundingBox.height ?? UIFont.monospacedSystemFont(ofSize: 12, weight: .regular).lineHeight))

		return AnyView(HStack(alignment: .center, spacing: 0) {
			views.reduce(AnyView(EmptyView()), { $0 + $1 })
		}
			.frame(minHeight: lineHeight, maxHeight: lineHeight, alignment: .leading)
			.frame(maxWidth: .infinity, alignment: .leading))
	}

	private func text(_ run: String, attribute: Attribute, isCursor: Bool = false) -> AnyView {
		var fgColor = attribute.fg
		var bgColor = attribute.bg

		if attribute.style.contains(.inverse) {
			swap(&bgColor, &fgColor)
			if fgColor == .defaultColor {
				fgColor = .defaultInvertedColor
			}
			if bgColor == .defaultColor {
				bgColor = .defaultInvertedColor
			}
		}

		let foreground = colorMap?.color(for: fgColor,
																		 isForeground: true,
																		 isBold: attribute.style.contains(.bold),
																		 isCursor: isCursor)
		let background = colorMap?.color(for: bgColor,
																		 isForeground: false,
																		 isCursor: isCursor)

		let font: UIFont?
		if attribute.style.contains(.bold) || attribute.style.contains(.blink) {
			font = attribute.style.contains(.italic) ? fontMetrics?.boldItalicFont : fontMetrics?.boldFont
		} else if attribute.style.contains(.dim) {
			font = attribute.style.contains(.italic) ? fontMetrics?.lightItalicFont : fontMetrics?.lightFont
		} else {
			font = attribute.style.contains(.italic) ? fontMetrics?.italicFont : fontMetrics?.regularFont
		}

		let width = ceil(CGFloat(run.unicodeScalars.reduce(0, { $0 + UnicodeUtil.columnWidth(rune: $1) })) * (fontMetrics?.width ?? 0))
		let lineHeight = max(1, ceil(fontMetrics?.boundingBox.height ?? UIFont.monospacedSystemFont(ofSize: 12, weight: .regular).lineHeight))

		return AnyView(
			Text(run)
				// Text attributes
				.foregroundColor(Color(foreground ?? .white))
				.font(Font(font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)))
				.underline(attribute.style.contains(.underline))
				.strikethrough(attribute.style.contains(.crossedOut))
				.tracking(0)
				// View attributes
				.allowsTightening(false)
				.lineLimit(1)
				.truncationMode(.clip)
				.fixedSize(horizontal: true, vertical: false)
				.background(Color(background ?? .black))
				.frame(width: width, height: lineHeight, alignment: .leading)
		)
	}

}
