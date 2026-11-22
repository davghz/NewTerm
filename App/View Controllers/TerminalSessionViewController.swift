//
//  TerminalSessionViewController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import os.log
import CoreServices
import SwiftUIX
import NewTermCommon

class TerminalSessionViewController: BaseTerminalSplitViewControllerChild {

	var initialCommand: String?

	override var isSplitViewResizing: Bool {
		didSet { updateIsSplitViewResizing() }
	}
	override var showsTitleView: Bool {
		didSet { updateShowsTitleView() }
	}
	override var screenSize: ScreenSize? {
		get { terminalController.screenSize }
		set { terminalController.screenSize = newValue }
	}

	private var terminalController = TerminalController()
	private var keyInput = TerminalKeyInput(frame: .zero)
	private var textView: TerminalHostingView!
	private weak var terminalScrollView: UIScrollView?
	private var textViewTapGestureRecognizer: UITapGestureRecognizer!
	private lazy var wheelPan = UIPanGestureRecognizer(target: self, action: #selector(handleWheelPan(_:)))

	private var state = TerminalState()

	private var hudState = HUDViewState()
	private var hudView: UIHostingView<AnyView>!

	private var hasAppeared = false
	private var hasStarted = false
	private var failureError: Error?

	private var lastAutomaticScrollOffset = CGPoint.zero
	private var invertScrollToTop = false
	private var hasPinnedInitialTerminalPosition = false
	private var suppressAutoBottomUntil: TimeInterval = 0
	private var preservedViewportOffsetY: CGFloat?

	private var isPickingFileForUpload = false

	override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
		super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)

		terminalController.delegate = self

		do {
			try terminalController.startSubProcess()
			hasStarted = true
		} catch {
			failureError = error
		}
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		super.loadView()

		title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")

		preferencesUpdated()
		textView = TerminalHostingView(state: state)

		textViewTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTextViewTap(_:)))
		textViewTapGestureRecognizer.delegate = self
		textView.addGestureRecognizer(textViewTapGestureRecognizer)
		wheelPan.maximumNumberOfTouches = 1
		wheelPan.delegate = self
		textView.addGestureRecognizer(wheelPan)

		keyInput.frame = view.bounds
		keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		keyInput.textView = textView
		keyInput.terminalInputDelegate = terminalController
		view.addSubview(keyInput)
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		hudView = UIHostingView(rootView: AnyView(
			HUDView()
				.environmentObject(self.hudState)
		))
		hudView.isUserInteractionEnabled = false
		hudView.translatesAutoresizingMaskIntoConstraints = false
		hudView.shouldResizeToFitContent = true
		hudView.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
		hudView.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
		view.addSubview(hudView)

		NSLayoutConstraint.activate([
			hudView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			hudView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
		])

		addKeyCommand(UIKeyCommand(title: .localize("CLEAR_TERMINAL", comment: "VoiceOver label for a button that clears the terminal."),
															 image: UIImage(systemName: "text.badge.xmark"),
															 action: #selector(self.clearTerminal),
															 input: "k",
															 modifierFlags: .command))

		#if !targetEnvironment(macCatalyst)
		addKeyCommand(UIKeyCommand(title: .localize("PASSWORD_MANAGER", comment: "VoiceOver label for the password manager button."),
															 image: UIImage(systemName: "key.fill"),
															 action: #selector(self.activatePasswordManager),
															 input: "f",
															 modifierFlags: [ .command, .alternate ]))
		#endif

		if UIApplication.shared.supportsMultipleScenes {
			NotificationCenter.default.addObserver(self, selector: #selector(self.sceneDidEnterBackground), name: UIWindowScene.didEnterBackgroundNotification, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(self.sceneWillEnterForeground), name: UIWindowScene.willEnterForegroundNotification, object: nil)
		}

		NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardFrameDidChange(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardFrameDidChange(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardFrameDidChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardToolbarLayoutDidChange(_:)), name: .terminalKeyboardToolbarLayoutDidChange, object: nil)
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		keyInput.becomeFirstResponder()
		terminalController.terminalWillAppear()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		hasAppeared = true

		if let error = failureError {
			didReceiveError(error: error)
		} else {
			if let initialCommand = initialCommand?.data(using: .utf8) {
				terminalController.write(initialCommand + EscapeSequences.return)
			}
		}

		initialCommand = nil
		scheduleScreenSizeUpdate()
		pinTerminalViewport(forceBottom: true)
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)

		keyInput.resignFirstResponder()
		terminalController.terminalWillDisappear()
	}

	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)

		hasAppeared = false
	}

	override func viewWillLayoutSubviews() {
		super.viewWillLayoutSubviews()
		updateScreenSize()
		pinTerminalViewport(forceBottom: !hasPinnedInitialTerminalPosition)
	}

	override func viewSafeAreaInsetsDidChange() {
		super.viewSafeAreaInsetsDidChange()
		updateScreenSize()
	}

	override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)
		updateScreenSize()
	}

	override func removeFromParent() {
		if hasStarted {
			do {
				try terminalController.stopSubProcess()
			} catch {
				os_log("Failed to stop subprocess: %{public}@", log: OSLog.default, type: .error, String(describing: error))
			}
		}

		super.removeFromParent()
	}

	// MARK: - Screen

	func updateScreenSize() {
		if isSplitViewResizing {
			return
		}

		// Determine the screen size based on the font size. Using the view bounds avoids iOS 13
		// safe-area-origin glitches during keyboard accessory row toggles.
		var layoutSize = textView.bounds.size
		let safeAreaInsets = textView.safeAreaInsets
		layoutSize.height -= (safeAreaInsets.top + safeAreaInsets.bottom)
		layoutSize.width -= TerminalView.horizontalSpacing * 2
		layoutSize.height -= TerminalView.verticalSpacing * 2

		if layoutSize.width < 0 || layoutSize.height < 0 {
			// Not laid out yet. We’ll be called again when we are.
			return
		}

		let glyphSize = terminalController.fontMetrics.boundingBox
		if glyphSize.width == 0 || glyphSize.height == 0 {
			fatalError("Failed to get glyph size")
		}

		// iOS 13 keyboard/inputAccessory transitions can briefly report tiny layout sizes
		// (for example ~1 row). Ignore those transient values so we don't corrupt the
		// PTY's initial terminal geometry and overlap the first prompt/login lines.
		if layoutSize.width < glyphSize.width * 20 || layoutSize.height < glyphSize.height * 5 {
			return
		}

		let newSize = ScreenSize(cols: max(1, UInt16(layoutSize.width / glyphSize.width)),
														 rows: max(1, UInt16(layoutSize.height / glyphSize.height.rounded(.up))),
														 cellSize: glyphSize)
		if screenSize != newSize {
			screenSize = newSize
			delegate?.terminal(viewController: self, screenSizeDidChange: newSize)
		}
	}

	@objc private func keyboardFrameDidChange(_ notification: Notification) {
		let shouldCaptureViewport = notification.name == UIResponder.keyboardWillHideNotification
			|| notification.name == UIResponder.keyboardWillChangeFrameNotification
		markViewportTransition(captureViewport: shouldCaptureViewport)
		scheduleScreenSizeUpdate(preserveViewport: true)
	}

	@objc private func keyboardToolbarLayoutDidChange(_ notification: Notification) {
		markViewportTransition(captureViewport: true)
		scheduleScreenSizeUpdate(preserveViewport: true)
	}

	private func markViewportTransition(captureViewport: Bool) {
		if captureViewport, let scrollView = configuredTerminalScrollView() {
			let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
			let nearBottomThreshold = max(2, terminalController.fontMetrics.boundingBox.height * 2)
			let isAtBottom = maxY <= 0 || (maxY - scrollView.contentOffset.y) <= nearBottomThreshold
			// nil = bottom sentinel: "go to maxY after resize, whatever it turns out to be"
			// non-nil = user is scrolled into scrollback; restore that relative position
			preservedViewportOffsetY = isAtBottom ? nil : min(max(0, scrollView.contentOffset.y), maxY)
		}
		suppressAutoBottomUntil = Date().timeIntervalSinceReferenceDate + 1.5
	}

	private func scheduleScreenSizeUpdate(preserveViewport: Bool = false) {
		let shouldForceBottom = !preserveViewport && !hasPinnedInitialTerminalPosition
		updateScreenSize()
		pinTerminalViewport(forceBottom: shouldForceBottom)

		// Input accessory relayout on iOS 13 can lag one runloop; recalc shortly after.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
			self?.updateScreenSize()
			self?.pinTerminalViewport(forceBottom: shouldForceBottom)
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
			self?.updateScreenSize()
			self?.pinTerminalViewport(forceBottom: shouldForceBottom)
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
			self?.updateScreenSize()
			self?.pinTerminalViewport(forceBottom: shouldForceBottom)
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
			self?.updateScreenSize()
			self?.pinTerminalViewport(forceBottom: shouldForceBottom)
		}
	}

	private func findTerminalScrollView(in view: UIView) -> UIScrollView? {
		if let scrollView = view as? UIScrollView {
			return scrollView
		}
		for child in view.subviews {
			if let scrollView = findTerminalScrollView(in: child) {
				return scrollView
			}
		}
		return nil
	}

	private func configuredTerminalScrollView() -> UIScrollView? {
		if let scrollView = terminalScrollView,
			 scrollView.isDescendant(of: textView),
			 scrollView.bounds.width > 0,
			 scrollView.bounds.height > 0 {
			scrollView.showsHorizontalScrollIndicator = false
			scrollView.alwaysBounceHorizontal = false
			scrollView.isDirectionalLockEnabled = true
			scrollView.contentInsetAdjustmentBehavior = .never
			scrollView.contentInset = .zero
			return scrollView
		}
		terminalScrollView = nil

		guard let scrollView = findTerminalScrollView(in: textView) else {
			return nil
		}

		scrollView.showsHorizontalScrollIndicator = false
		scrollView.alwaysBounceHorizontal = false
		scrollView.isDirectionalLockEnabled = true
		scrollView.contentInsetAdjustmentBehavior = .never
		scrollView.contentInset = .zero
		terminalScrollView = scrollView
		scrollView.keyboardDismissMode = .interactive
		scrollView.alwaysBounceVertical = true
		scrollView.panGestureRecognizer.require(toFail: wheelPan)
		return scrollView
	}

	private func pinTerminalViewport(forceBottom: Bool = false) {
		guard let scrollView = configuredTerminalScrollView(),
			  !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else {
			return
		}

		let glyphHeight = max(1, terminalController.fontMetrics.boundingBox.height)
		let minimumStableHeight = glyphHeight * 5
		if scrollView.bounds.height < minimumStableHeight {
			return
		}

		let minX: CGFloat = 0
		let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
		let nearBottomThreshold = max(2, terminalController.fontMetrics.boundingBox.height * 2)
		let isNearBottom = (maxY - scrollView.contentOffset.y) <= nearBottomThreshold
		let shouldSuppressAutoBottom = !forceBottom
			&& Date().timeIntervalSinceReferenceDate < suppressAutoBottomUntil
		let shouldAutoScrollBottom = forceBottom
			|| !hasPinnedInitialTerminalPosition
			|| (!shouldSuppressAutoBottom && isNearBottom)

		var offset = scrollView.contentOffset
		offset.x = minX
		if shouldAutoScrollBottom {
			offset.y = maxY
			preservedViewportOffsetY = nil
		} else if shouldSuppressAutoBottom {
			if let preservedOffsetY = preservedViewportOffsetY {
				// User was scrolled into scrollback; restore that position.
				offset.y = min(max(0, preservedOffsetY), maxY)
			} else {
				// Bottom sentinel: user was at the bottom before the transition.
				// Stay at bottom even though suppression is active — correct for
				// alternate-screen apps (Codex) where content redraws on resize.
				offset.y = maxY
			}
		} else {
			offset.y = min(max(0, offset.y), maxY)
			preservedViewportOffsetY = nil
		}
		offset.x = round(offset.x)
		offset.y = round(offset.y)

		if abs(scrollView.contentOffset.x - offset.x) > 0.5 || abs(scrollView.contentOffset.y - offset.y) > 0.5 {
			scrollView.setContentOffset(offset, animated: false)
		}
		lastAutomaticScrollOffset = offset
		hasPinnedInitialTerminalPosition = true
	}

	@objc func clearTerminal() {
		terminalController.clearTerminal()
	}

	private func updateIsSplitViewResizing() {
		state.isSplitViewResizing = isSplitViewResizing

		if !isSplitViewResizing {
			updateScreenSize()
		}
	}

	private func updateShowsTitleView() {
		updateScreenSize()
	}

	// MARK: - Gestures

	@objc private func handleTextViewTap(_ gestureRecognizer: UITapGestureRecognizer) {
		if gestureRecognizer.state == .ended && !keyInput.isFirstResponder {
			keyInput.becomeFirstResponder()
			delegate?.terminalDidBecomeActive(viewController: self)
		}
	}

	// MARK: - Lifecycle

	@objc private func sceneDidEnterBackground(_ notification: Notification) {
		if notification.object as? UIWindowScene == view.window?.windowScene {
			terminalController.windowDidEnterBackground()
		}
	}

	@objc private func sceneWillEnterForeground(_ notification: Notification) {
		if notification.object as? UIWindowScene == view.window?.windowScene {
			terminalController.windowWillEnterForeground()
		}
	}

	@objc private func preferencesUpdated() {
		state.fontMetrics = terminalController.fontMetrics
		state.colorMap = terminalController.colorMap
	}

}

extension TerminalSessionViewController: TerminalControllerDelegate {

	func refresh(lines: inout [AnyView]) {
		if let scroll = configuredTerminalScrollView() {
			state.followsOutput = !scroll.isTracking && !scroll.isDecelerating
				&& scroll.contentSize.height - scroll.bounds.height - scroll.contentOffset.y <= 2
		}
		state.lines = lines
		DispatchQueue.main.async { [weak self] in
			self?.pinTerminalViewport(forceBottom: !(self?.hasPinnedInitialTerminalPosition ?? false))
		}
	}

	func activateBell() {
		if Preferences.shared.bellHUD {
			hudState.isVisible = true
		}

		HapticController.playBell()
	}

	func titleDidChange(_ title: String?, isDirty: Bool, hasBell: Bool) {
		let newTitle = title ?? .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")
		delegate?.terminal(viewController: self,
											 titleDidChange: newTitle,
											 isDirty: isDirty,
											 hasBell: hasBell)
	}

	func currentFileDidChange(_ url: URL?, inWorkingDirectory workingDirectoryURL: URL?) {
		#if targetEnvironment(macCatalyst)
		if let windowScene = view.window?.windowScene {
			windowScene.titlebar?.representedURL = url
		}
		#endif
	}

	func saveFile(url: URL) {
		let viewController: UIDocumentPickerViewController
		if #available(iOS 14.0, *) {
			viewController = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
		} else {
			viewController = UIDocumentPickerViewController(url: url, in: .exportToService)
		}
		viewController.delegate = self
		present(viewController, animated: true, completion: nil)
	}

	func fileUploadRequested() {
		isPickingFileForUpload = true

		let viewController: UIDocumentPickerViewController
		if #available(iOS 14.0, *) {
			viewController = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .directory])
		} else {
			viewController = UIDocumentPickerViewController(documentTypes: ["public.data", "public.folder"], in: .open)
		}
		viewController.delegate = self
		present(viewController, animated: true, completion: nil)
	}

	@objc func activatePasswordManager() {
		keyInput.activatePasswordManager()
	}

	@objc func close() {
		if let splitViewController = parent as? TerminalSplitViewController {
			splitViewController.remove(viewController: self)
		}
	}

	func didReceiveError(error: Error) {
		if !hasAppeared {
			failureError = error
			return
		}
		failureError = nil

		let alertController = UIAlertController(title: .localize("TERMINAL_LAUNCH_FAILED_TITLE", comment: "Alert title displayed when a terminal could not be launched."),
																						message: .localize("TERMINAL_LAUNCH_FAILED_BODY", comment: "Alert body displayed when a terminal could not be launched."),
																						preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: .ok, style: .cancel, handler: nil))
		present(alertController, animated: true, completion: nil)
	}

}

extension TerminalSessionViewController: UIGestureRecognizerDelegate {

	func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
		guard gestureRecognizer === wheelPan else { return true }
		let velocity = wheelPan.velocity(in: textView)
		guard abs(velocity.y) > abs(velocity.x), terminalController.reportsMouse else { return false }
		if velocity.y > 0, let top = keyboardTop(in: textView) {
			let startY = wheelPan.location(in: textView).y - wheelPan.translation(in: textView).y
			// Let UIKit track a pull starting next to the keyboard interactively.
			if startY >= top - 44 { return false }
		}
		return true
	}

	private func keyboardTop(in view: UIView) -> CGFloat? {
		guard keyInput.isFirstResponder, let accessory = keyInput.inputAccessoryView,
			  accessory.window != nil, accessory.bounds.height > 0 else { return nil }
		return accessory.convert(accessory.bounds, to: view).minY
	}

	@objc private func handleWheelPan(_ pan: UIPanGestureRecognizer) {
		guard pan.state == .changed || pan.state == .ended else { return }
		if pan.velocity(in: textView).y > 0, let top = keyboardTop(in: textView),
		   pan.location(in: textView).y >= top {
			keyInput.resignFirstResponder()
			return
		}
		guard pan.state == .changed else { return }
		let cell = terminalController.fontMetrics.boundingBox
		let height = max(1, ceil(cell.height))
		let motion = pan.translation(in: textView).y
		let steps = Int(abs(motion) / height)
		guard steps > 0 else { return }
		let point = pan.location(in: textView)
		terminalController.scrollMouse(up: motion > 0, steps: steps,
			column: Int(point.x / max(1, cell.width)), row: Int(point.y / height))
		pan.setTranslation(CGPoint(x: 0, y: motion.truncatingRemainder(dividingBy: height)), in: textView)
	}

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		// This allows the tap-to-activate-keyboard gesture to work without conflicting with UIKit’s
		// internal text view/scroll view gestures… as much as we can avoid conflicting, at least.
		return gestureRecognizer == textViewTapGestureRecognizer
			&& (!(otherGestureRecognizer is UITapGestureRecognizer) || keyInput.isFirstResponder)
	}
}

extension TerminalSessionViewController: UIDocumentPickerDelegate {

	func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		guard isPickingFileForUpload,
					let url = urls.first else {
			return
		}
		terminalController.uploadFile(url: url)
		isPickingFileForUpload = false
	}

	func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
		if isPickingFileForUpload {
			isPickingFileForUpload = false
			terminalController.cancelUploadRequest()
		} else {
			// The system will clean up the temp directory for us eventually anyway, but still delete the
			// downloads temp directory now so the file doesn’t linger around till then.
			terminalController.deleteDownloadCache()
		}
	}

}
