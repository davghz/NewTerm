//
//  RootViewController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import SwiftUI
import NewTermCommon

class RootViewController: UIViewController {

	static let settingsViewDoneNotification = Notification.Name(rawValue: "RootViewControllerSettingsViewDoneNotification")

	var initialCommand: String?

	private var terminals: [BaseTerminalSplitViewControllerChild] = []
	private var selectedTabIndex = 0

	private var tabToolbar: TabToolbarViewController?

	override func viewDidLoad() {
		super.viewDidLoad()

		#if !targetEnvironment(macCatalyst)
		tabToolbar = TabToolbarViewController()
		tabToolbar!.view.autoresizingMask = [.flexibleWidth]
		tabToolbar!.delegate = self
		tabToolbar!.dataSource = self
		addChild(tabToolbar!)
		view.addSubview(tabToolbar!.view)
		tabToolbar!.didMove(toParent: self)
		#endif

		addTerminal()

		addKeyCommand(UIKeyCommand(title: .localize("SETTINGS", comment: "Title of Settings page."),
															 image: UIImage(systemName: "gear"),
															 action: #selector(self.openSettings),
															 input: ",",
															 modifierFlags: .command))

		addKeyCommand(UIKeyCommand(title: .localize("NEW_TAB", comment: "VoiceOver label for the new tab button."),
															 action: #selector(self.newTab),
															 input: "t",
															 modifierFlags: .command))
		addKeyCommand(UIKeyCommand(title: .localize("CLOSE_TAB", comment: "VoiceOver label for the close tab button."),
															 action: #selector(self.removeCurrentTerminal),
															 input: "w",
															 modifierFlags: .command))

		#if !targetEnvironment(macCatalyst)
		addKeyCommand(UIKeyCommand(title: .localize("SHOW_PREVIOUS_TAB"),
															 action: #selector(self.selectPreviousTab),
															 input: "{",
															 modifierFlags: .command))
		addKeyCommand(UIKeyCommand(title: .localize("SHOW_NEXT_TAB"),
															 action: #selector(self.selectNextTab),
															 input: "}",
															 modifierFlags: .command))
		#endif

		let digits = (Array(1...9) + [0]).map { "\($0)" }
		for digit in digits {
			addKeyCommand(UIKeyCommand(action: #selector(self.selectTabFromKeyCommand),
																 input: digit,
																 modifierFlags: .command))
		}

		if UIApplication.shared.supportsMultipleScenes {
			addKeyCommand(UIKeyCommand(title: .localize("NEW_WINDOW", comment: "VoiceOver label for the new window button."),
																 action: #selector(self.addWindow),
																 input: "n",
																 modifierFlags: .command))
			addKeyCommand(UIKeyCommand(title: .localize("CLOSE_WINDOW", comment: "VoiceOver label for the close window button."),
																 action: #selector(self.closeCurrentWindow),
																 input: "w",
																 modifierFlags: [.command, .shift]))
		}

		addKeyCommand(UIKeyCommand(title: .localize("SPLIT_HORIZONTALLY"),
															 action: #selector(self.splitHorizontally),
															 input: "d",
															 modifierFlags: [.command, .shift]))
		addKeyCommand(UIKeyCommand(title: .localize("SPLIT_VERTICALLY"),
															 action: #selector(self.splitVertically),
															 input: "d",
															 modifierFlags: .command))


		NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.dismissSettings), name: Self.settingsViewDoneNotification, object: nil)

		preferencesUpdated()
	}

	override func viewWillLayoutSubviews() {
		super.viewWillLayoutSubviews()

		// TODO: Cleanup
		#if !targetEnvironment(macCatalyst)
		let width = view.safeAreaLayoutGuide.layoutFrame.width
		let topBarHeight: CGFloat = TabToolbarView.usesSingleRow(width: width) ? 33 : 66
		tabToolbar?.view.frame = CGRect(x: 0, y: 0, width: view.frame.size.width, height: view.safeAreaInsets.top + topBarHeight)

		for viewController in terminals {
			viewController.additionalSafeAreaInsets.top = topBarHeight
		}
		#endif
	}

	// MARK: - Preferences

	@objc private func preferencesUpdated() {
		let preferences = Preferences.shared
		view.backgroundColor = preferences.colorMap.background
	}

	// MARK: - Tab management

	@objc func newTab() {
		#if targetEnvironment(macCatalyst)
		if let sceneDelegate = view.window?.windowScene?.delegate as? TerminalSceneDelegate {
			sceneDelegate.createWindow(asTab: true)
		}
		#else
		addTerminal()
		#endif
	}

	func addTerminal() {
		let index = min(selectedTabIndex + 1, terminals.count)
		addTerminal(at: index, initialCommand: initialCommand)
		selectTerminal(at: index)
		initialCommand = nil
	}

	private func addTerminal(at index: Int, axis: NSLayoutConstraint.Axis? = nil, initialCommand: String? = nil) {
		let splitViewController = TerminalSplitViewController()
		splitViewController.view.autoresizingMask = [ .flexibleWidth, .flexibleHeight ]
		splitViewController.view.frame = view.bounds
		splitViewController.delegate = self

		let newTerminal = TerminalSessionViewController()
		newTerminal.initialCommand = initialCommand

		addChild(splitViewController)
		if let tabToolbar = tabToolbar {
			view.insertSubview(splitViewController.view, belowSubview: tabToolbar.view)
		} else {
			view.addSubview(splitViewController.view)
		}
		splitViewController.didMove(toParent: self)

		if let axis = axis {
			splitViewController.axis = axis
			splitViewController.viewControllers = [terminals[index], newTerminal]
			terminals[index] = splitViewController
			tabToolbar?.tabDidUpdate(at: index)
		} else {
			splitViewController.viewControllers = [newTerminal]
			terminals.insert(splitViewController, at: index)
			tabToolbar?.didAddTab(at: index)
		}
	}

	func removeTerminal(viewController: BaseTerminalSplitViewControllerChild) {
		guard let index = terminals.firstIndex(of: viewController) else {
			NSLog("asked to remove terminal that doesn’t exist? %@", viewController)
			return
		}

		let wasSelected = selectedTabIndex == index
		if wasSelected {
			viewController.beginAppearanceTransition(false, animated: false)
			viewController.endAppearanceTransition()
		}
		viewController.closeTerminal()
		terminals.remove(at: index)
		tabToolbar?.didRemoveTab(at: index)

		if terminals.isEmpty {
			selectedTabIndex = 0
			if UIApplication.shared.supportsMultipleScenes {
				closeCurrentWindow()
			} else {
				addTerminal()
			}
		} else if wasSelected {
			showTerminal(at: min(index, terminals.count - 1), replacing: nil)
		} else {
			if index < selectedTabIndex { selectedTabIndex -= 1 }
			tabToolbar?.didSelectTab(at: selectedTabIndex)
		}
	}

	func removeTerminal(at index: Int) {
		removeTerminal(viewController: terminals[index])
	}

	@IBAction func removeCurrentTerminal() {
		removeTerminal(at: selectedTabIndex)
	}

	@IBAction func removeAllTerminals() {
		for (index, terminal) in terminals.enumerated().reversed() {
			terminal.closeTerminal()
			tabToolbar?.didRemoveTab(at: index)
		}
		terminals.removeAll()
		selectedTabIndex = 0
		addTerminal()
	}

	func selectTerminal(at index: Int) {
		guard terminals.indices.contains(index) else { return }
		let previous = terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex] : nil
		showTerminal(at: index, replacing: previous)
	}

	private func showTerminal(at index: Int, replacing previousViewController: BaseTerminalSplitViewControllerChild?) {
		let newViewController = terminals[index]

		selectedTabIndex = index
		tabToolbar?.didSelectTab(at: index)
		handleTitleChange(at: index)

		// Call the appropriate view controller lifecycle methods on the previous and new view controllers
		previousViewController?.beginAppearanceTransition(false, animated: false)
		previousViewController?.view.isHidden = true
		previousViewController?.endAppearanceTransition()

		newViewController.beginAppearanceTransition(true, animated: false)
		newViewController.view.isHidden = false
		newViewController.endAppearanceTransition()
	}

	private func handleTitleChange(at index: Int) {
		if selectedTabIndex == index {
			view.window?.windowScene?.title = terminalName(at: index)

			if #available(iOS 15, *),
				 let size = terminals[index].screenSize {
				view.window?.windowScene?.subtitle = "\(size.cols)×\(size.rows)"
			}
		}
	}

	@objc private func selectPreviousTab() {
		if selectedTabIndex == 0 {
			selectTerminal(at: terminals.count - 1)
		} else {
			selectTerminal(at: selectedTabIndex - 1)
		}
	}

	@objc private func selectNextTab() {
		if selectedTabIndex == terminals.count - 1 {
			selectTerminal(at: 0)
		} else {
			selectTerminal(at: selectedTabIndex + 1)
		}
	}

	@objc private func selectTabFromKeyCommand(_ keyCommand: UIKeyCommand) {
		guard var digit = Int(keyCommand.input ?? ""),
					digit >= 0 && digit <= 9 else {
			return
		}

		if digit == 0 {
			digit = 10
		}
		digit -= 1

		if terminals.count > digit {
			selectTerminal(at: digit)
		}
	}

	// MARK: - Window management

	@objc func addWindow() {
		if let sceneDelegate = view.window?.windowScene?.delegate as? TerminalSceneDelegate {
			sceneDelegate.createWindow(asTab: false)
		}
	}

	@objc func closeCurrentWindow() {
		if terminals.count == 0 {
			destructScene()
			return
		}

		let title: String?
		let action: String
		if isBigDevice {
			title = String.localizedStringWithFormat(.localize("CLOSE_WINDOW_TITLE"), terminals.count)
			action = .close
		} else {
			title = nil
			action = String.localizedStringWithFormat(.localize("CLOSE_WINDOW_ACTION"), terminals.count)
		}

		let alertController = UIAlertController(title: title, message: nil, preferredStyle: isBigDevice ? .alert : .actionSheet)
		alertController.addAction(UIAlertAction(title: action, style: isBigDevice ? .default : .destructive, handler: { _ in
			self.destructScene()
		}))
		alertController.addAction(UIAlertAction(title: .cancel, style: .cancel, handler: nil))
		present(alertController, animated: true, completion: nil)
	}

	private func destructScene() {
		if UIApplication.shared.supportsMultipleScenes {
			// TODO: Probably need to directly use NSWindow APIs for this on Catalyst.
			// https://developer.apple.com/forums/thread/127382
			UIApplication.shared.requestSceneSessionDestruction(view.window!.windowScene!.session, options: nil, errorHandler: nil)
		} else {
			removeAllTerminals()
		}
	}

	// MARK: - Split views

	@objc func splitHorizontally() {
		addTerminal(at: selectedTabIndex, axis: .vertical)
	}

	@objc func splitVertically() {
		addTerminal(at: selectedTabIndex, axis: .horizontal)
	}

}

extension RootViewController: TerminalSplitViewControllerDelegate {

	func terminal(viewController: BaseTerminalSplitViewControllerChild, titleDidChange title: String, isDirty: Bool, hasBell: Bool) {
		guard let index = terminals.firstIndex(of: viewController) else {
			return
		}

		handleTitleChange(at: index)
		tabToolbar?.tabDidUpdate(at: index)
	}

	func terminal(viewController: BaseTerminalSplitViewControllerChild, screenSizeDidChange screenSize: ScreenSize) {
		guard let index = terminals.firstIndex(of: viewController) else {
			return
		}

		handleTitleChange(at: index)
		tabToolbar?.tabDidUpdate(at: index)
	}

	func terminalDidBecomeActive(viewController: BaseTerminalSplitViewControllerChild) {
		guard let index = terminals.firstIndex(of: viewController) else {
			return
		}

		handleTitleChange(at: index)
		tabToolbar?.tabDidUpdate(at: index)
	}

}

extension RootViewController: TabToolbarDataSource {

	func numberOfTerminals() -> Int {
		return terminals.count
	}

	func selectedTerminalIndex() -> Int {
		return selectedTabIndex
	}

	func terminalName(at index: Int) -> String {
		let title = terminals[index].title
		return title == nil || title!.isEmpty
			? .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")
			: title!
	}

}

extension RootViewController: TabToolbarDelegate {

	@objc func openSettings() {
		if UIApplication.shared.supportsMultipleScenes {
			UIApplication.shared.activateScene(userActivity: .settingsScene,
																				 requestedByScene: view.window?.windowScene,
																				 withProminentPresentation: true)
		} else {
			if presentedViewController == nil {
				let viewController = UIHostingController(rootView: SettingsView())
				viewController.modalPresentationStyle = .formSheet
				present(viewController, animated: true, completion: nil)
			}
		}
	}

	@objc private func dismissSettings() {
		presentedViewController?.dismiss(animated: true, completion: nil)
	}

	func openPasswordManager() {
		UIApplication.shared.sendAction(#selector(TerminalSessionViewController.activatePasswordManager), to: nil, from: self, for: nil)
	}

}
