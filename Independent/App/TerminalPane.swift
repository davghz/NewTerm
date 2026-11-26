import UIKit
import AudioToolbox
import T3Engine

private let selectionHoldDuration: TimeInterval = 1

private func crossesKeyboard(top: CGFloat, fingerY: CGFloat, dx: CGFloat, dy: CGFloat) -> Bool {
    fingerY >= top + 16 && dy >= 32 && dy > abs(dx)
}

private final class MouseGesture: UIGestureRecognizer {
    var report: ((CGPoint, Int, Bool, Bool, UIKeyModifierFlags) -> Void)?
    // Returns the distance consumed by whole wheel ticks.
    var scroll: ((CGPoint, CGFloat, UIKeyModifierFlags) -> CGFloat)?
    var selectionEnded: ((CGPoint, CGPoint) -> Void)?
    var shouldFocusOnTap: (() -> Bool)?
    var focusOnTap: (() -> Void)?
    var keyboardTopInWindow: (() -> CGFloat?)?
    var dismissKeyboard: (() -> Void)?

    private enum Mode { case pending, dragging, scrolling, pressed }
    private var mode: Mode = .pending
    private var contact: UITouch?
    private var button = 0
    private var pressOrigin = CGPoint.zero
    private var startInWindow = CGPoint.zero
    private var lastWheelY: CGFloat = 0
    private var pressFlags: UIKeyModifierFlags = []
    private var hold: DispatchWorkItem?
    private var keyboardTop: CGFloat?
    private var focusTap = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let contact = contact {
            if contact.type == .direct && mode != .pressed {
                hold?.cancel()
                state = state == .possible ? .failed : .cancelled
            } else {
                for touch in touches { ignore(touch, for: event) }
            }
            return
        }
        guard touches.count == 1, let touch = touches.first else { state = .failed; return }
        contact = touch
        pressOrigin = touch.location(in: view)
        startInWindow = touch.location(in: nil)
        pressFlags = event.modifierFlags
        button = event.buttonMask.contains(.secondary) ? 2 : event.buttonMask.contains(UIEvent.ButtonMask(rawValue: 4)) ? 1 : 0
        if touch.type == .direct {
            lastWheelY = startInWindow.y
            keyboardTop = keyboardTopInWindow?()
            focusTap = shouldFocusOnTap?() == true
            let work = DispatchWorkItem { [weak self] in self?.beginPress() }
            hold = work
            DispatchQueue.main.asyncAfter(deadline: .now() + selectionHoldDuration, execute: work)
        } else {
            beginPress()
        }
    }

    private func beginPress() {
        guard contact != nil, mode == .pending, state == .possible else { return }
        mode = .pressed
        state = .began
        report?(pressOrigin, button, false, false, pressFlags)
    }

    private func updateDrag(_ touch: UITouch, flags: UIKeyModifierFlags, ending: Bool) {
        let position = touch.location(in: nil)
        let dx = position.x - startInWindow.x
        let dy = position.y - startInWindow.y
        if mode == .pending {
            guard hypot(dx, dy) >= 10 else { return }
            hold?.cancel()
            mode = .dragging
            state = .began
        }
        if mode == .dragging {
            guard abs(dy) > abs(dx) else { return }
            if let top = keyboardTop, dy > 0 {
                // A continuous downward pull may still reach the keyboard. Wait for the lift
                // before sending any input; wheel events cannot be taken back from the PTY.
                guard ending else { return }
                if crossesKeyboard(top: top, fingerY: position.y, dx: dx, dy: dy) {
                    dismissKeyboard?()
                    return
                }
            }
            mode = .scrolling
        }
        lastWheelY += scroll?(touch.location(in: view), position.y - lastWheelY, flags) ?? 0
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = contact, touches.contains(touch) else { return }
        if mode == .pressed {
            report?(touch.location(in: view), button, false, true, event.modifierFlags)
        } else {
            updateDrag(touch, flags: event.modifierFlags, ending: false)
        }
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = contact, touches.contains(touch) else { return }
        hold?.cancel()
        if mode == .pressed {
            if button == 0 { selectionEnded?(pressOrigin, touch.location(in: view)) }
        } else {
            updateDrag(touch, flags: event.modifierFlags, ending: true)
            if mode == .pending {
                if focusTap { focusOnTap?() } else { beginPress() }
            }
        }
        if mode == .pressed { report?(touch.location(in: view), button, true, false, event.modifierFlags) }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = contact, touches.contains(touch) else { return }
        hold?.cancel()
        if mode == .pressed { report?(touch.location(in: view), button, true, false, event.modifierFlags) }
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        hold?.cancel()
        hold = nil
        contact = nil
        mode = .pending
        keyboardTop = nil
        focusTap = false
        super.reset()
    }
}

final class TerminalPane: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let model = TerminalModel()
    let canvas = TerminalCanvas()
    let input = TerminalInput()
    private let shelf = KeyShelf()
    private let scroll = UIScrollView()
    private let status = UILabel()
    private let mouse = MouseGesture()
    private let keyboardPull = UIPanGestureRecognizer()
    private var keyboardTopAtDragStart: CGFloat?
    private var trackpad: UIPanGestureRecognizer!
    private var pointerHover: UIHoverGestureRecognizer!
    private var wheel: UIPanGestureRecognizer!
    private var touchSelection: UILongPressGestureRecognizer!
    private var tap: UITapGestureRecognizer!
    private var displayLink: CADisplayLink?
    private var frameInFlight = false
    private var pending = true
    private var force = true
    private var busyWithLayout = false
    private var following = true
    private var lastFirstLine = 0
    private var lastBellTime: TimeInterval = -.infinity
    private var columns = 0
    private var rowCount = 0
    private var generation = 0
    private var ended = false
    private var started = false
    private var wheelDelta: CGFloat = 0
    private var selectionMoved = false
    private var copyDeadline: TimeInterval = -.infinity
    private var bellGeneration = 0
    private(set) var directory: String?
    var resizing = false { didSet { if !resizing { setNeedsLayout() } } }
    var active = false {
        didSet {
            canvas.active = active
            if !active {
                selectionMoved = false
                copyDeadline = -.infinity
                input.resignFirstResponder()
            }
        }
    }
    var inForeground = true { didSet { updateVisibility() } }
    var onActivate: (() -> Void)?
    var onTitle: ((String) -> Void)?
    var onTranscript: ((Transcript, Bool) -> Void)?
    var onUpload: (() -> Void)?
    var onDownload: ((String, Data) -> Void)?
    var onError: ((String) -> Void)?

    init(directory: String?) {
        self.directory = directory
        super.init(frame: .zero)
        clipsToBounds = true
        scroll.delegate = self
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = false
        scroll.bounces = false
        scroll.scrollsToTop = false
        scroll.indicatorStyle = .white
        scroll.addSubview(canvas)
        addSubview(scroll)
        addSubview(input)
        status.numberOfLines = 2
        status.font = .preferredFont(forTextStyle: .caption1)
        status.backgroundColor = .secondarySystemBackground
        status.textColor = .label
        status.textAlignment = .center
        status.isHidden = true
        addSubview(status)
        tap = UITapGestureRecognizer(target: self, action: #selector(focus))
        tap.delegate = self
        scroll.addGestureRecognizer(tap)
        touchSelection = UILongPressGestureRecognizer(target: self, action: #selector(selectAt(_:)))
        touchSelection.minimumPressDuration = selectionHoldDuration
        scroll.addGestureRecognizer(touchSelection)
        tap.require(toFail: touchSelection)
        mouse.shouldFocusOnTap = { [weak self] in
            guard let self = self, !self.input.isFirstResponder, let root = self.window?.rootViewController?.view else { return false }
            return root.keyboardLayoutGuide.layoutFrame.minY >= root.safeAreaLayoutGuide.layoutFrame.maxY - 1
        }
        mouse.focusOnTap = { [weak self] in self?.focus() }
        mouse.keyboardTopInWindow = { [weak self] in
            guard let self = self, self.input.isFirstResponder,
                  let window = self.window, let root = window.rootViewController?.view else { return nil }
            let top = root.keyboardLayoutGuide.layoutFrame.minY
            guard top < root.safeAreaLayoutGuide.layoutFrame.maxY - 1 else { return nil }
            return root.convert(CGPoint(x: 0, y: top), to: window).y
        }
        mouse.dismissKeyboard = { [weak self] in self?.input.resignFirstResponder() }
        mouse.report = { [weak self] point, button, release, motion, modifiers in
            guard let self = self else { return }
            if !self.active { self.onActivate?() }
            self.sendMouse(point: point, button: button, release: release, motion: motion, modifiers: modifiers)
        }
        mouse.scroll = { [weak self] point, distance, modifiers in
            guard let self = self else { return 0 }
            if !self.active { self.onActivate?() }
            return self.sendWheel(distance: distance, at: point, modifiers: modifiers, maxTicks: self.rowCount)
        }
        mouse.isEnabled = false
        canvas.addGestureRecognizer(mouse)
        wheel = UIPanGestureRecognizer(target: self, action: #selector(scrollWheel(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        wheel.isEnabled = false
        canvas.addGestureRecognizer(wheel)
        pointerHover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        pointerHover.isEnabled = false
        canvas.addGestureRecognizer(pointerHover)
        trackpad = UIPanGestureRecognizer(target: self, action: #selector(moveCursor(_:)))
        trackpad.minimumNumberOfTouches = 2
        trackpad.maximumNumberOfTouches = 2
        scroll.panGestureRecognizer.maximumNumberOfTouches = 1
        scroll.addGestureRecognizer(trackpad)
        keyboardPull.addTarget(self, action: #selector(pullAcrossKeyboard(_:)))
        keyboardPull.maximumNumberOfTouches = 1
        keyboardPull.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        keyboardPull.delegate = self
        scroll.addGestureRecognizer(keyboardPull)
        canvas.activate = { [weak self] in self?.focus() }
        input.onKey = { [weak self] key, flags in self?.send(key, flags) }
        input.onPaste = { [weak self] in self?.pasteContent() }
        input.onCopy = { [weak self] in self?.showTranscript(search: false) }
        input.onFocus = { [weak self] focused in
            self?.model.send { modes in modes.focusReporting ? Data((focused ? "\u{1b}[I" : "\u{1b}[O").utf8) : Data() }
        }
        shelf.send = { [weak self] key in self?.send(key, []) }
        shelf.pasteAction = { [weak self] in self?.pasteContent() }
        shelf.selectionAction = { [weak self] in self?.showTranscript(search: false) }
        shelf.dismissAction = { [weak self] in self?.input.resignFirstResponder() }
        model.onWriteRejected = { [weak self] in self?.onError?("The terminal input buffer is full or the session has ended.") }
        model.onChange = { [weak self] in self?.invalidate() }
        model.onEffect = { [weak self] effect in self?.handle(effect) }
        model.onExit = { [weak self] reason in
            guard let self = self else { return }
            self.ended = true
            self.input.resignFirstResponder()
            self.showStatus(reason)
        }
        for name in [Notification.Name.terminalSettingsChanged, UIDevice.batteryStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: name, object: nil)
        }
        settingsChanged()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { displayLink?.invalidate(); model.close() }

    @objc private func settingsChanged() {
        canvas.refreshAppearance()
        input.font = Preferences.font
        let chrome = TerminalChrome(palette: canvas.palette)
        input.keyboardAppearance = chrome.isDark ? .dark : .light
        status.textColor = chrome.text
        status.backgroundColor = chrome.raised
        trackpad.isEnabled = Preferences.defaults.integer(forKey: "keyboardTrackpadSensitivity") > 0
        input.inputAccessoryView = shelf
        shelf.rebuild()
        if input.isFirstResponder { input.reloadInputViews() }
        displayLink?.preferredFramesPerSecond = Preferences.frameRate
        model.setColors(foreground: canvas.palette.foreground.terminalRGB, background: canvas.palette.background.terminalRGB)
        backgroundColor = canvas.palette.background
        force = true
        generation += 1
        setNeedsLayout()
        invalidate()
    }

    override func didMoveToWindow() { super.didMoveToWindow(); updateVisibility() }
    private var visible: Bool { window != nil && inForeground && !isHidden }
    private func updateVisibility() {
        generation += 1
        if visible { force = true; invalidate() }
        else {
            displayLink?.invalidate(); displayLink = nil
            canvas.clearCache()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        busyWithLayout = true
        scroll.frame = bounds.inset(by: UIEdgeInsets(top: 5, left: 0, bottom: 0, right: 0))
        canvas.frame = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
        status.frame = CGRect(x: 4, y: 0, width: max(1,bounds.width-8), height: 34)
        positionInput()
        busyWithLayout = false
        guard !resizing, bounds.width > 20, bounds.height > 20 else { return }
        let newColumns = max(2, Int((bounds.width - 2 * canvas.horizontalInset)/canvas.cellSize.width))
        let newRows = max(1, Int(scroll.bounds.height / canvas.cellSize.height))
        guard columns != newColumns || rowCount != newRows else { return }
        columns = newColumns
        rowCount = newRows
        if started { model.resize(columns: columns, rows: rowCount) }
        else {
            started = true
            model.start(directory: directory, columns: columns, rows: rowCount)
        }
        generation += 1
        force = true
        invalidate()
    }

    func releaseCache() {
        canvas.clearCache()
        generation += 1
        force = true
        invalidate()
    }

    func invalidate() {
        pending = true
        guard visible else { return }
        guard !frameInFlight else { return }
        if let link = displayLink {
            link.isPaused = false
        } else {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFramesPerSecond = Preferences.frameRate
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func tick() {
        guard visible, pending, !frameInFlight, rowCount > 0 else { park(); return }
        let topOffset = max(0, scroll.contentOffset.y)
        let floatTop = topOffset / canvas.cellSize.height
        let top = following ? nil : lastFirstLine + Int(floor(floatTop))
        let fraction = following ? 0 : topOffset - floor(floatTop) * canvas.cellSize.height
        let token = generation
        let full = force
        pending = false
        force = false
        frameInFlight = true
        park()
        model.frame(top: top, capacity: rowCount + 1, force: full) { [weak self] data in
            guard let self = self else { return }
            self.frameInFlight = false
            guard self.visible else { self.force = true; return }
            if self.generation != token || data == nil {
                self.force = true
                self.invalidate()
                return
            }
            if let data = data {
                self.busyWithLayout = true
                self.lastFirstLine = data.first
                let height = self.canvas.cellSize.height
                self.scroll.contentSize = CGSize(width: self.scroll.bounds.width, height: self.scroll.bounds.height + CGFloat(data.history)*height)
                let partial = self.following || data.start != top ? 0 : fraction
                let y = CGFloat(data.start-data.first)*height + partial
                self.scroll.contentOffset = CGPoint(x: 0, y: y)
                self.canvas.frame = CGRect(origin: self.scroll.contentOffset, size: self.scroll.bounds.size)
                self.canvas.apply(data, fraction: partial)
                self.positionInput()
                self.busyWithLayout = false
                let enabled = data.modes.mouseReporting
                self.mouse.isEnabled = enabled
                self.wheel.isEnabled = enabled
                self.pointerHover.isEnabled = data.modes.mouseTracking == .anyMotion
                self.scroll.panGestureRecognizer.isEnabled = !enabled
                self.touchSelection.isEnabled = !enabled
                self.tap.isEnabled = !enabled
            }
            if self.pending { self.invalidate() }
        }
    }
    private func park() { displayLink?.isPaused = true }

    private func positionInput() {
        let cell = canvas.cellSize
        let frame = canvas.frameData
        let row = (frame?.cursorLine ?? 0) - (frame?.start ?? 0)
        let x = min(max(0, bounds.width - 40), canvas.horizontalInset + CGFloat(frame?.cursorColumn ?? 0)*cell.width)
        let y = scroll.frame.minY + min(max(0, scroll.bounds.height - cell.height), max(0, CGFloat(row)*cell.height - canvas.fraction))
        input.frame = CGRect(x: x, y: y, width: min(180, max(40, bounds.width - x)), height: cell.height)
        input.isUserInteractionEnabled = true
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !busyWithLayout else { return }
        following = scrollView.contentOffset.y >= scrollView.contentSize.height - scrollView.bounds.height - 0.5
        generation += 1
        invalidate()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === keyboardPull else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let velocity = keyboardPull.velocity(in: self)
        return velocity.y > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === tap { return true }
        guard gestureRecognizer === keyboardPull, input.isFirstResponder, !mouse.isEnabled,
              let root = window?.rootViewController?.view else { return false }
        let top = root.keyboardLayoutGuide.layoutFrame.minY
        guard top < root.safeAreaLayoutGuide.layoutFrame.maxY, touch.location(in: root).y < top else { return false }
        keyboardTopAtDragStart = top
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // After a resize the scroll view can begin its pan on a stationary touch in scrollback.
        // Let the focus tap finish its own movement check when the keyboard is hidden.
        other === scroll.panGestureRecognizer && (gestureRecognizer === keyboardPull || !input.isFirstResponder)
    }

    // The scroll view alone may never begin dragging when the terminal has no scrollback.
    @objc private func pullAcrossKeyboard(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended, let top = keyboardTopAtDragStart,
              let root = window?.rootViewController?.view else { return }
        let finger = pan.location(in: root)
        let delta = pan.translation(in: root)
        if crossesKeyboard(top: top, fingerY: finger.y, dx: delta.x, dy: delta.y) {
            input.resignFirstResponder()
        }
    }

    @objc func focus() {
        onActivate?()
        if !ended { input.becomeFirstResponder() }
    }
    private func send(_ key: TerminalKey, _ flags: UIKeyModifierFlags) {
        following = true
        let modifiers = flags.union(shelf.consume())
        if case .text(let value) = key, modifiers.intersection([.alternate, .shift, .command]).isEmpty,
           value == "\u{16}" || (modifiers.contains(.control) && value.lowercased() == "v"),
           model.foregroundCommandIs("codex"), let content = TerminalPaste.read(from: .general) {
            // The local Codex port accepts an image path as a bracketed paste. Its Ctrl+V
            // handler attempts a native clipboard read that is unavailable on iOS.
            paste(content)
            return
        }
        model.send { modes in key.bytes(modes: modes, modifiers: modifiers) }
        invalidate()
    }
    func insertCommand(_ text: String) {
        model.send { _ in Data((text + "\r").utf8) }
    }
    func pasteText(_ text: String) {
        following = true
        model.send { modes in
            if modes.bracketedPaste {
                let clean = text.replacingOccurrences(of: "\u{1b}[201~", with: "")
                return Data(("\u{1b}[200~" + clean + "\u{1b}[201~").utf8)
            }
            return Data(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r").utf8)
        }
        invalidate()
    }

    func pasteContent() {
        if let content = TerminalPaste.read(from: .general) { paste(content) }
    }

    private func paste(_ content: TerminalPaste) {
        switch content {
        case .text(let text): pasteText(text)
        case .image(let image): pasteImage(image)
        }
    }

    private func pasteImage(_ image: UIImage) {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pastes", isDirectory: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let bytes = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
                try bytes.write(to: url, options: .atomic)
                let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
                let quoted = url.path.unicodeScalars.allSatisfy(safe.contains) ? url.path : "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                DispatchQueue.main.async { self?.pasteText(quoted) }
            } catch { DispatchQueue.main.async { self?.onError?(error.localizedDescription) } }
        }
    }

    @objc private func selectAt(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, canvas.frameData != nil else { return }
        let address = canvas.address(recognizer.location(in: canvas))
        showTranscript(search: false, line: address.line, column: address.column)
    }
    func showTranscript(search: Bool, line: Int? = nil, column: Int? = nil) {
        onActivate?()
        model.transcript(line: line, column: column) { [weak self] transcript in self?.onTranscript?(transcript, search) }
    }

    private func handle(_ effect: TerminalEffect) {
        switch effect {
        case .title(let title):
            let safe = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80))
            if !safe.isEmpty { onTitle?(safe) }
        case .copyText(let value):
            guard active, visible, window?.windowScene?.activationState == .foregroundActive,
                  ProcessInfo.processInfo.systemUptime <= copyDeadline else { return }
            copyDeadline = -.infinity
            UIPasteboard.general.string = value
        case .workingDirectory(let value):
            var path = value
            if let url = URL(string: value), url.isFileURL {
                let host = (url.host ?? "").lowercased()
                let local = ProcessInfo.processInfo.hostName.lowercased()
                guard host.isEmpty || host == "localhost" || host == local else { return }
                path = url.path
            }
            var isDirectory: ObjCBool = false
            if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                directory = path
            }
        case .bell:
            let now = ProcessInfo.processInfo.systemUptime
            guard visible, now - lastBellTime >= 0.65 else { return }
            lastBellTime = now
            if Preferences.defaults.bool(forKey: "bellSound") { AudioServicesPlaySystemSound(1104) }
            if Preferences.defaults.bool(forKey: "bellVibrate") { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            if Preferences.defaults.bool(forKey: "bellHUD"), !ended {
                bellGeneration += 1
                let token = bellGeneration
                showStatus("Bell")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    if self?.bellGeneration == token && self?.ended == false { self?.status.isHidden = true }
                }
            }
        case .uploadRequest: onUpload?()
        case .download(let name, let data): onDownload?(name,data)
        default: break
        }
    }
    private func showStatus(_ value: String) {
        status.text = value
        status.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: value)
    }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        sendMouse(point: recognizer.location(in: canvas), button: 3, release: false, motion: true, modifiers: recognizer.modifierFlags)
    }
    @objc private func moveCursor(_ pan: UIPanGestureRecognizer) {
        let speed = max(0,min(3, Preferences.defaults.integer(forKey: "keyboardTrackpadSensitivity")))
        guard speed > 0 else { return }
        if pan.state == .began { onActivate?() }
        let threshold: CGFloat = [0,22,13,7][speed]
        let movement = pan.translation(in: self)
        let horizontal = abs(movement.x) >= abs(movement.y)
        let delta = horizontal ? movement.x : movement.y
        let steps = min(16,Int(abs(delta) / threshold))
        guard steps > 0 else { return }
        let key: TerminalKey = horizontal ? (delta < 0 ? .left : .right) : (delta < 0 ? .up : .down)
        for _ in 0..<steps { send(key, []) }
        let remainder = delta - CGFloat(steps)*threshold*(delta < 0 ? -1 : 1)
        pan.setTranslation(horizontal ? CGPoint(x: remainder, y: 0) : CGPoint(x: 0,y: remainder), in: self)
    }
    @objc private func scrollWheel(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { wheelDelta = 0 }
        let diff = pan.translation(in: canvas).y
        pan.setTranslation(.zero, in: canvas)
        wheelDelta += diff
        wheelDelta -= sendWheel(distance: wheelDelta, at: pan.location(in: canvas), modifiers: [], maxTicks: 16)
    }

    private func sendWheel(distance: CGFloat, at point: CGPoint, modifiers: UIKeyModifierFlags, maxTicks: Int) -> CGFloat {
        let height = max(canvas.cellSize.height, 8)
        let ticks = min(maxTicks, Int(abs(distance) / height))
        let up = distance > 0
        for _ in 0..<ticks {
            sendMouse(point: point, button: up ? 64 : 65, release: false, motion: false, modifiers: modifiers)
        }
        return CGFloat(ticks) * (up ? height : -height)
    }
    private func sendMouse(point: CGPoint, button: Int, release: Bool, motion: Bool, modifiers: UIKeyModifierFlags) {
        guard let frame = canvas.frameData else { return }
        if button == 0 {
            // Codex writes the selected text using OSC 52 immediately after the release.
            // Give one deliberate primary-button drag one opportunity to update the clipboard.
            if release {
                if selectionMoved { copyDeadline = ProcessInfo.processInfo.systemUptime + 2 }
                selectionMoved = false
            } else {
                selectionMoved = motion
                if !motion { copyDeadline = -.infinity }
            }
        }
        let addr = canvas.address(point)
        let x = min(columns, max(1, addr.column + 1))
        let y = min(rowCount, max(1, addr.line - frame.first - frame.history + 1))
        model.send { modes in
            guard modes.mouseReporting, !(release && modes.mouseTracking == .x10),
                  !motion || modes.mouseTracking == .buttonMotion || modes.mouseTracking == .anyMotion else { return Data() }
            let mask = (modifiers.contains(.shift) ? 4 : 0) + (modifiers.contains(.alternate) ? 8 : 0) +
                (modifiers.contains(.control) ? 16 : 0)
            let code = button + (motion ? 32 : 0) + mask
            if modes.sgrMouse { return Data("\u{1b}[<\(code);\(x);\(y)\(release ? "m" : "M")".utf8) }
            guard x <= 223 && y <= 223 else { return Data() }
            return Data([27, 91, 77, UInt8(32 + (release ? 3 + mask : code)), UInt8(32+x), UInt8(32+y)])
        }
    }
}
