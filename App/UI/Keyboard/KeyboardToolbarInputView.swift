//
//  KeyboardToolbarInputView.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import SwiftUI
import SwiftUIX

final class KeyboardToolbarInputView: UIInputView, UIInputViewAudioFeedback {
	private let toolbarHeight: CGFloat

	init(delegate: KeyboardToolbarViewDelegate, toolbars: [Toolbar], state: KeyboardToolbarViewState) {
		let rows = toolbars.filter { $0.isVisible(with: state.toggledKeys) }
		toolbarHeight = CGFloat(rows.count) * KeyboardToolbarView.rowHeight
		super.init(frame: CGRect(x: 0, y: 0, width: 0, height: toolbarHeight), inputViewStyle: .default)
		autoresizingMask = .flexibleWidth
		backgroundColor = .keyboardToolbarBackground
		allowsSelfSizing = true

		// UIKit owns the keyboard safe area. Lay out the rows from the top of
		// the accessory, including when the hosting view inherits a bottom inset.
		let content = UIHostingView(rootView: GeometryReader { _ in
			KeyboardToolbarView(delegate: delegate, toolbars: rows)
				.environmentObject(state)
		}.ignoresSafeArea())
		content.translatesAutoresizingMaskIntoConstraints = false
		addSubview(content)
		NSLayoutConstraint.activate([
			heightAnchor.constraint(equalToConstant: toolbarHeight),
			content.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
			content.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
			content.topAnchor.constraint(equalTo: topAnchor),
			content.bottomAnchor.constraint(equalTo: bottomAnchor)
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var intrinsicContentSize: CGSize {
		CGSize(width: UIView.noIntrinsicMetric, height: toolbarHeight)
	}

	override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
		CGSize(width: targetSize.width, height: toolbarHeight)
	}

	var enableInputClicksWhenVisible: Bool { true }
}
