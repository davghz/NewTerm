//
//  KeyboardToolbarInputView.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import SwiftUI
import Combine

final class KeyboardToolbarController: UIInputViewController {
	private let accessory: KeyboardToolbarInputView
	private let host: UIHostingController<AnyView>
	private var rowObservation: AnyCancellable?

	init(delegate: KeyboardToolbarViewDelegate?, toolbars: [Toolbar], state: KeyboardToolbarViewState) {
		accessory = KeyboardToolbarInputView(frame: CGRect(x: 0, y: 0, width: 0, height: KeyboardToolbarView.rowHeight), inputViewStyle: .default)
		host = UIHostingController(rootView: AnyView(
			KeyboardToolbarView(delegate: delegate, toolbars: toolbars)
				.environmentObject(state)
		))
		super.init(nibName: nil, bundle: nil)
		rowObservation = state.$toggledKeys.sink { [weak self] toggles in
			let rows = toolbars.filter { toolbar in
				switch toolbar {
				case .secondary: return toggles.contains(.more)
				case .fnKeys: return toggles.contains(.fnKeys)
				default: return true
				}
			}
			guard let self = self else { return }
			let height = CGFloat(rows.count) * KeyboardToolbarView.rowHeight
			self.accessory.rowHeight = height
			self.preferredContentSize = CGSize(width: 0, height: height)
		}
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		view = accessory
		accessory.autoresizingMask = .flexibleWidth
		accessory.heightConstraint.isActive = true
		accessory.backgroundColor = .keyboardToolbarBackground
		accessory.allowsSelfSizing = true
		// Containment gives SwiftUI the accessory's safe area in the keyboard window.
		addChild(host)
		let content = host.view!
		content.backgroundColor = .clear
		content.translatesAutoresizingMaskIntoConstraints = false
		accessory.addSubview(content)
		NSLayoutConstraint.activate([
			content.leadingAnchor.constraint(equalTo: accessory.safeAreaLayoutGuide.leadingAnchor),
			content.trailingAnchor.constraint(equalTo: accessory.safeAreaLayoutGuide.trailingAnchor),
			content.topAnchor.constraint(equalTo: accessory.topAnchor),
			content.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
		])
		host.didMove(toParent: self)
	}
}

final class KeyboardToolbarInputView: UIInputView, UIInputViewAudioFeedback {
	lazy var heightConstraint = heightAnchor.constraint(equalToConstant: rowHeight)
	var rowHeight = KeyboardToolbarView.rowHeight {
		didSet {
			if rowHeight != oldValue {
				heightConstraint.constant = rowHeight
				frame.size.height = rowHeight
				invalidateIntrinsicContentSize()
			}
		}
	}

	override var intrinsicContentSize: CGSize {
		CGSize(width: UIView.noIntrinsicMetric, height: rowHeight)
	}

	var enableInputClicksWhenVisible: Bool { true }
}
