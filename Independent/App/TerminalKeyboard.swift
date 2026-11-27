import UIKit
import T3Engine

enum TerminalKey {
    case keypad(normal: String, application: String)
    case text(String), backspace, escape, tab, backtab, up, down, left, right, home, end, insert, delete, pageUp, pageDown, function(Int)

    func bytes(modes: TerminalModes, modifiers: UIKeyModifierFlags = []) -> Data {
        let esc = "\u{1b}"
        let modifier = 1 + (modifiers.contains(.shift) ? 1 : 0) + (modifiers.contains(.alternate) ? 2 : 0)
            + (modifiers.contains(.control) ? 4 : 0)
        func cursor(_ letter: String) -> String {
            modifier == 1 ? esc + (modes.applicationCursor ? "O" : "[") + letter : "\(esc)[1;\(modifier)\(letter)"
        }
        func numeric(_ n: Int) -> String { "\(esc)[\(n)" + (modifier == 1 ? "~" : ";\(modifier)~") }
        let encoded: String
        switch self {
        case .keypad(let normal, let application): encoded = modes.applicationKeypad ? esc + "O" + application : normal
        case .text(let text):
            if modifiers.contains(.shift), text == "\n" || text == "\r" {
                return Data("\(esc)[13;\(modifier)u".utf8)
            }
            let shifted = modifiers.contains(.shift) && text.count == 1 ? text.uppercased() : text
            var bytes = Data()
            for char in shifted {
                if modifiers.contains(.alternate) { bytes.append(0x1b) }
                if modifiers.contains(.control), let code = char.asciiValue {
                    switch code {
                    case 32, 50, 64: bytes.append(0)
                    case 65...95, 97...122: bytes.append(code & 31)
                    case 47, 55: bytes.append(31)
                    case 56, 63: bytes.append(127)
                    case 51...54: bytes.append(code - 24)
                    default: bytes.append(code)
                    }
                } else { bytes.append(contentsOf: String(char == "\n" ? "\r" : char).utf8) }
            }
            return bytes
        case .backspace: encoded = (modifiers.contains(.alternate) ? esc : "") + "\u{7f}"
        case .escape: encoded = esc
        case .tab: encoded = modifiers.contains(.shift) ? esc + "[Z" : "\t"
        case .backtab: encoded = esc + "[Z"
        case .up: encoded = cursor("A")
        case .down: encoded = cursor("B")
        case .right: encoded = cursor("C")
        case .left: encoded = cursor("D")
        case .home: encoded = cursor("H")
        case .end: encoded = cursor("F")
        case .insert: encoded = numeric(2)
        case .delete: encoded = numeric(3)
        case .pageUp: encoded = numeric(5)
        case .pageDown: encoded = numeric(6)
        case .function(let index):
            if (1...4).contains(index) {
                let letter = ["P", "Q", "R", "S"][index-1]
                encoded = modifier == 1 ? esc + "O" + letter : "\(esc)[1;\(modifier)" + letter
            } else if (5...12).contains(index) { encoded = numeric([15,17,18,19,20,21,23,24][index-5]) }
            else { return Data() }
        }
        return Data(encoded.utf8)
    }
}

enum DictationCursor {
    case hidden
    case visible(previous: String?)

    init(_ engine: TerminalEngine) {
        self = engine.modes.cursorVisible ? .visible(previous: engine.textBeforeCursor) : .hidden
    }
}

// UIKit owns composition and dictation. Deliver committed text exactly once,
// including replacements produced by Pinyin, Japanese and dictation.
final class TerminalInput: UITextView, UITextViewDelegate {
    var onKey: ((TerminalKey, UIKeyModifierFlags) -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onDictationListeningChanged: ((Bool) -> Void)?
    var dictationCursor: () -> DictationCursor = { .visible(previous: nil) }
    private var hasComposition = false
    private var dictationPlaceholders = Set<NSObject>()
    private enum DictationResultState { case idle, recordingEnded, placeholderRemoved }
    private var dictationResultState: DictationResultState = .idle
    private var completedPlaceholders = 0
    private var deferredInsertions: [String] = []
    private var flushScheduled = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        accessibilityIdentifier = "t3rm.input"
        accessibilityLabel = "Shell input"
        backgroundColor = .clear
        textColor = .clear
        font = Preferences.font
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        keyboardType = .default
        returnKeyType = .default
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        isScrollEnabled = false
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        NotificationCenter.default.addObserver(self, selector: #selector(inputModeChanged),
                                              name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        hasComposition = true
        super.setMarkedText(markedText, selectedRange: selectedRange)
        showPreview()
    }
    override func setAttributedMarkedText(_ markedText: NSAttributedString?, selectedRange: NSRange) {
        hasComposition = true
        super.setAttributedMarkedText(markedText, selectedRange: selectedRange)
        showPreview()
    }
    private func showPreview() {
        textColor = .label
        backgroundColor = .secondarySystemBackground
    }
    override func unmarkText() {
        let wasComposing = hasComposition || markedTextRange != nil
        super.unmarkText()
        hasComposition = false
        if wasComposing { deliver() }
    }
    override func insertText(_ value: String) {
        // Dictation edits its provisional transcript with replace(_:withText:).
        // Only an explicit insertion or IME commit belongs in the terminal.
        if !hasComposition, markedTextRange == nil, !text.isEmpty { text = "" }
        super.insertText(value)
        hasComposition = markedTextRange != nil
        deliver()
    }
    override func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        let value = dictationResult.map(\.text).joined()
        hasComposition = false
        text = ""
        backgroundColor = .clear
        textColor = .clear
        commitDictation(endingWith: value)
    }

    // iOS 15 reports "dictation" as the active keyboard language while recording.
    // This signal only controls feedback. Text delivery uses UITextInput commits.
    @objc private func inputModeChanged() {
        let listening = isFirstResponder && textInputMode?.primaryLanguage == "dictation"
        if listening { textColor = .label }
        else if !hasComposition, text.isEmpty { textColor = .clear }
        onDictationListeningChanged?(listening)
    }

    override func dictationRecordingDidEnd() {
        if dictationResultState == .idle { dictationResultState = .recordingEnded }
        onDictationListeningChanged?(false)
    }

    override func dictationRecognitionFailed() {
        discardPendingResult()
        onDictationListeningChanged?(false)
    }

    // Text view placeholders are attachments. Keep them out of storage because
    // the terminal cannot retract bytes once a shell has received them.
    override var insertDictationResultPlaceholder: Any {
        let placeholder = NSObject()
        dictationPlaceholders.insert(placeholder)
        return placeholder
    }

    override func frame(forDictationResultPlaceholder placeholder: Any) -> CGRect {
        caretRect(for: endOfDocument)
    }

    override func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {
        guard let token = placeholder as? NSObject, dictationPlaceholders.remove(token) != nil else { return }
        if willInsertResult {
            if completedPlaceholders > 0 {
                completedPlaceholders -= 1
            } else {
                dictationResultState = .placeholderRemoved
                if !deferredInsertions.isEmpty, deferredInsertions != [" "] { commitDictation() }
            }
        } else {
            completedPlaceholders = min(completedPlaceholders, dictationPlaceholders.count)
            if dictationPlaceholders.isEmpty { discardPendingResult() }
        }
    }

    private func sendCommittedText(_ value: String) {
        if dictationResultState != .idle {
            if value == " ", deferredInsertions.isEmpty {
                deferredInsertions.append(value)
            } else {
                commitDictation(endingWith: value)
            }
        } else if dictationPlaceholders.count > completedPlaceholders {
            // iOS 15 can confirm the result just after insertText. Hold this turn
            // only; ordinary typing during a longer recognition wait must still echo.
            deferredInsertions.append(value)
            if !flushScheduled {
                flushScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.flushScheduled = false
                    if self.dictationResultState == .idle { self.flushOrdinaryInput() }
                }
            }
        } else {
            onKey?(.text(value), [])
        }
    }

    private func commitDictation(endingWith value: String? = nil) {
        if dictationResultState != .placeholderRemoved, completedPlaceholders < dictationPlaceholders.count {
            completedPlaceholders += 1
        }
        if value == "" {
            discardPendingResult()
            return
        }
        if let value = value { deferredInsertions.append(value) }
        let suppliedSpace = deferredInsertions.count > 1 && deferredInsertions.first == " "
        let phrase = deferredInsertions.dropFirst(suppliedSpace ? 1 : 0).joined()
        deferredInsertions.removeAll()
        dictationResultState = .idle
        guard let first = phrase.first else { return }
        let separate: Bool
        switch dictationCursor() {
        case .hidden:
            // Full-screen programs may leave the rendering cursor on a status line.
            separate = suppliedSpace && !first.isWhitespace && !first.isPunctuation
        case .visible(let previous):
            if suppliedSpace {
                separate = previous?.last.map { !$0.isWhitespace } == true && !first.isWhitespace && !first.isPunctuation
            } else {
                separate = Self.needsWordSpace(after: previous?.last, before: first)
            }
        }
        onKey?(.text(separate ? " " + phrase : phrase), [])
    }

    private static func needsWordSpace(after previous: Character?, before first: Character) -> Bool {
        guard let previous = previous else { return false }
        // Unicode word-break classes distinguish alphabetic words from scripts
        // that conventionally run together, such as Chinese and Japanese.
        func isWordCharacter(_ character: Character) -> Bool {
            String(character).range(of: #"^[\p{wb=ALetter}\p{wb=Hebrew_Letter}\p{wb=Numeric}]"#,
                                    options: .regularExpression) != nil
        }
        return isWordCharacter(first) && (isWordCharacter(previous) || ".,;:!?…)]}".contains(previous))
    }

    private func flushOrdinaryInput() {
        let pending = deferredInsertions
        deferredInsertions.removeAll()
        dictationResultState = .idle
        for value in pending { onKey?(.text(value), []) }
    }

    private func discardPendingResult() {
        if dictationResultState != .idle && deferredInsertions == [" "] {
            deferredInsertions.removeAll()
        }
        flushOrdinaryInput()
        if !hasComposition { text = ""; textColor = .clear; backgroundColor = .clear }
    }

    private func deliver() {
        guard markedTextRange == nil && !hasComposition else { return }
        backgroundColor = .clear
        textColor = .clear
        guard let value = text, !value.isEmpty else { return }
        text = ""
        sendCommittedText(value)
    }

    override func deleteBackward() {
        flushOrdinaryInput()
        if hasComposition || markedTextRange != nil || !text.isEmpty { super.deleteBackward() }
        else { onKey?(.backspace, []) }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let board = UIPasteboard.general
            return board.hasStrings || board.hasImages || board.hasURLs
        }
        return super.canPerformAction(action, withSender: sender)
    }
    override func paste(_ sender: Any?) { flushOrdinaryInput(); onPaste?() }
    override func copy(_ sender: Any?) { onCopy?() }
    func textViewDidBeginEditing(_ textView: UITextView) {
        // UIKit can still deliver the old view's result after it loses focus.
        // Retire any abandoned recognition when a fresh editing session starts.
        discardPendingResult()
        dictationPlaceholders.removeAll()
        completedPlaceholders = 0
        inputModeChanged()
        onFocus?(true)
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        onDictationListeningChanged?(false)
        onFocus?(false)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        flushOrdinaryInput()
        var unused = Set<UIPress>()
        for press in presses {
            guard let key = press.key, !key.modifierFlags.contains(.command), markedTextRange == nil else {
                unused.insert(press); continue
            }
            let terminalKey: TerminalKey?
            switch key.keyCode {
            case .keypad0: terminalKey = .keypad(normal: "0", application: "p")
            case .keypad1: terminalKey = .keypad(normal: "1", application: "q")
            case .keypad2: terminalKey = .keypad(normal: "2", application: "r")
            case .keypad3: terminalKey = .keypad(normal: "3", application: "s")
            case .keypad4: terminalKey = .keypad(normal: "4", application: "t")
            case .keypad5: terminalKey = .keypad(normal: "5", application: "u")
            case .keypad6: terminalKey = .keypad(normal: "6", application: "v")
            case .keypad7: terminalKey = .keypad(normal: "7", application: "w")
            case .keypad8: terminalKey = .keypad(normal: "8", application: "x")
            case .keypad9: terminalKey = .keypad(normal: "9", application: "y")
            case .keypadPeriod: terminalKey = .keypad(normal: ".", application: "n")
            case .keypadComma: terminalKey = .keypad(normal: ",", application: "l")
            case .keypadEnter: terminalKey = .keypad(normal: "\r", application: "M")
            case .keypadPlus: terminalKey = .keypad(normal: "+", application: "k")
            case .keypadHyphen: terminalKey = .keypad(normal: "-", application: "m")
            case .keypadAsterisk: terminalKey = .keypad(normal: "*", application: "j")
            case .keypadSlash: terminalKey = .keypad(normal: "/", application: "o")
            case .keypadEqualSign: terminalKey = .keypad(normal: "=", application: "X")
            case .keyboardUpArrow: terminalKey = .up
            case .keyboardDownArrow: terminalKey = .down
            case .keyboardLeftArrow: terminalKey = .left
            case .keyboardRightArrow: terminalKey = .right
            case .keyboardHome: terminalKey = .home
            case .keyboardEnd: terminalKey = .end
            case .keyboardPageUp: terminalKey = .pageUp
            case .keyboardPageDown: terminalKey = .pageDown
            case .keyboardInsert: terminalKey = .insert
            case .keyboardDeleteForward: terminalKey = .delete
            case .keyboardEscape: terminalKey = .escape
            case .keyboardTab: terminalKey = key.modifierFlags.contains(.shift) ? .backtab : .tab
            case .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
                 .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12:
                terminalKey = .function(Int(key.keyCode.rawValue - UIKeyboardHIDUsage.keyboardF1.rawValue) + 1)
            default:
                if (key.modifierFlags.contains(.control) || key.modifierFlags.contains(.alternate)), !key.charactersIgnoringModifiers.isEmpty {
                    terminalKey = .text(key.charactersIgnoringModifiers)
                } else { terminalKey = nil }
            }
            if let keyToSend = terminalKey { onKey?(keyToSend, key.modifierFlags) }
            else { unused.insert(press) }
        }
        if !unused.isEmpty { super.pressesBegan(unused, with: event) }
    }
}

private final class KeyShelfScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        // Allow a drag that starts on a key to scroll before the key fires on release.
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

final class KeyShelf: UIInputView, UIGestureRecognizerDelegate {
    var send: ((TerminalKey) -> Void)?
    var pasteAction: (() -> Void)?
    var selectionAction: (() -> Void)?
    var dismissAction: (() -> Void)?
    var heightDidChange: (() -> Void)?

    private enum Page { case closed, more, function }
    private var page = Page.closed
    private var modifiers: UIKeyModifierFlags = []
    private var modifierButtons: [(UIKeyModifierFlags, UIButton)] = []
    private let base = KeyShelfScrollView()
    private let extra = KeyShelfScrollView()
    private let controls = UIStackView()
    private let keys = UIStackView()
    private let dismissPan = UIPanGestureRecognizer()
    private let edge = UIView()
    private var moreButton: UIButton!
    private var primaryWidths: [NSLayoutConstraint] = []
    private var chrome = TerminalChrome.current
    private var usesIcons = false
    private let rowHeight: CGFloat = 46

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 375, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        base.accessibilityIdentifier = "t3rm.keyShelf"
        extra.accessibilityIdentifier = "t3rm.keyShelf.extra"
        let rows = UIStackView(arrangedSubviews: [extra, base])
        rows.axis = .vertical
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        for (scroll, stack) in [(base, controls), (extra, keys)] {
            scroll.delaysContentTouches = false
            scroll.isDirectionalLockEnabled = true
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.showsVerticalScrollIndicator = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(stack)
            let height = scroll.heightAnchor.constraint(equalToConstant: rowHeight)
            height.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                height,
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
                stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor)
            ])
        }
        let fitBase = controls.widthAnchor.constraint(equalTo: base.frameLayoutGuide.widthAnchor)
        fitBase.priority = UILayoutPriority(999)
        fitBase.isActive = true
        edge.translatesAutoresizingMaskIntoConstraints = false
        edge.isUserInteractionEnabled = false
        addSubview(edge)
        dismissPan.addTarget(self, action: #selector(pullDown(_:)))
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        dismissPan.delegate = self
        addGestureRecognizer(dismissPan)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            rows.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: page == .closed ? rowHeight : 2 * rowHeight)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: super.systemLayoutSizeFitting(targetSize).width, height: intrinsicContentSize.height)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let velocity = dismissPan.velocity(in: self)
        return velocity.y > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === base.panGestureRecognizer || other === extra.panGestureRecognizer
    }

    @objc private func pullDown(_ pan: UIPanGestureRecognizer) {
        let movement = pan.translation(in: self)
        if pan.state == .ended, movement.y >= 32, movement.y > abs(movement.x) { dismissAction?() }
    }

    func consume() -> UIKeyModifierFlags {
        let value = modifiers
        if !value.isEmpty {
            modifiers = []
            updateSelection()
        }
        return value
    }

    func rebuild() {
        chrome = .current
        usesIcons = Preferences.defaults.integer(forKey: "keyboardAccessoryStyle") == 1
        backgroundColor = chrome.surface
        edge.backgroundColor = chrome.stroke
        extra.indicatorStyle = chrome.isDark ? .white : .black
        base.indicatorStyle = extra.indicatorStyle
        NSLayoutConstraint.deactivate(primaryWidths)
        primaryWidths.removeAll()
        for button in controls.arrangedSubviews { button.removeFromSuperview() }
        modifierButtons.removeAll()
        controls.addArrangedSubview(modifier("ctrl", symbol: "control", flag: .control, primary: true))
        controls.addArrangedSubview(character("esc", .escape, label: "Escape", symbol: "escape", primary: true))
        controls.addArrangedSubview(modifier("shift", symbol: "shift", flag: .shift, primary: true))
        moreButton = makeButton("more", label: "More keys", symbol: "ellipsis", primary: true) { [weak self] in
            guard let self = self else { return }
            self.setPage(self.page == .closed ? .more : .closed)
        }
        controls.addArrangedSubview(moreButton)
        controls.addArrangedSubview(UIView())
        addArrows()
        NSLayoutConstraint.activate(primaryWidths)
        showPage()
    }

    private func modifier(_ title: String, symbol: String, flag: UIKeyModifierFlags, primary: Bool = false) -> UIButton {
        let button = makeButton(title, symbol: symbol, primary: primary, identifier: "t3rm.keyShelf." + title) { [weak self] in
            guard let self = self else { return }
            self.modifiers.formSymmetricDifference(flag)
            self.updateSelection()
        }
        modifierButtons.append((flag, button))
        return button
    }

    private func updateSelection() {
        for (flag, button) in modifierButtons { button.isSelected = modifiers.contains(flag) }
        moreButton.isSelected = page != .closed
    }

    private func makeButton(_ title: String, label: String? = nil, symbol: String? = nil,
                            primary: Bool = false, compact: Bool = false, identifier: String? = nil,
                            action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .custom)
        let font = UIFont.monospacedSystemFont(ofSize: compact ? 11 : 13, weight: .semibold)
        var config = UIButton.Configuration.plain()
        if usesIcons, let symbol = symbol, let image = UIImage(systemName: symbol) {
            config.image = image
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: compact ? 10 : 14, weight: .semibold)
        } else {
            var legend = AttributedString(title)
            legend.font = font
            config.attributedTitle = legend
        }
        config.contentInsets = .zero
        config.cornerStyle = .fixed
        config.background.cornerRadius = compact ? 4 : 7
        let inset: CGFloat = compact ? 0 : 6
        config.background.backgroundInsets = NSDirectionalEdgeInsets(top: inset, leading: 2, bottom: inset, trailing: 2)
        button.configuration = config
        button.configurationUpdateHandler = { [chrome] key in
            guard var style = key.configuration else { return }
            let active = key.isSelected || key.isHighlighted
            style.baseForegroundColor = active ? chrome.accent : chrome.text
            style.background.backgroundColor = active ? chrome.accentFill : chrome.raised
            style.background.strokeColor = key.isSelected ? chrome.accent : chrome.stroke
            style.background.strokeWidth = key.isSelected ? 1 : 0.5
            key.configuration = style
        }
        button.accessibilityLabel = label ?? title
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        let legendWidth = config.image == nil ? (title as NSString).size(withAttributes: [.font: font]).width : 0
        let minimum = max(primary ? 32 : 44, ceil(legendWidth) + 10)
        if primary {
            // Keep the arrow cluster on screen in portrait and give it room to breathe on iPad.
            let preferred = button.widthAnchor.constraint(equalTo: base.frameLayoutGuide.widthAnchor, multiplier: 0.12)
            preferred.priority = .defaultHigh
            primaryWidths.append(preferred)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum),
                button.widthAnchor.constraint(lessThanOrEqualToConstant: max(minimum, Preferences.isPad ? 60 : 52))
            ])
        } else {
            button.widthAnchor.constraint(equalToConstant: minimum).isActive = true
        }
        return button
    }

    private func character(_ title: String, _ key: TerminalKey, label: String? = nil,
                           symbol: String? = nil, primary: Bool = false, compact: Bool = false) -> UIButton {
        makeButton(title, label: label, symbol: symbol, primary: primary, compact: compact) { [weak self] in self?.send?(key) }
    }

    private func setPage(_ next: Page) {
        let wasClosed = page == .closed
        page = next
        showPage()
        if wasClosed != (next == .closed) {
            frame.size.height = intrinsicContentSize.height
            invalidateIntrinsicContentSize()
            heightDidChange?()
        }
        UIAccessibility.post(notification: .layoutChanged, argument: moreButton)
    }

    private func showPage() {
        modifierButtons.removeAll { $0.0 == .alternate }
        for item in keys.arrangedSubviews { item.removeFromSuperview() }
        extra.isHidden = page == .closed
        if page != .closed {
            let function = makeButton("fn", label: "Function keys", symbol: "function") { [weak self] in
                guard let self = self else { return }
                self.setPage(self.page == .function ? .more : .function)
            }
            function.isSelected = page == .function
            if page == .function {
                keys.addArrangedSubview(function)
                for n in 1...12 { keys.addArrangedSubview(character("F\(n)", .function(n))) }
            } else {
                keys.addArrangedSubview(character("tab", .tab, label: "Tab", symbol: "arrow.right.to.line"))
                keys.addArrangedSubview(makeButton("Paste", symbol: "doc.on.clipboard", identifier: "t3rm.keyShelf.paste") { [weak self] in self?.pasteAction?() })
                for (title, key) in [("Home", TerminalKey.home), ("End", .end), ("PgUp", .pageUp), ("PgDn", .pageDown)] {
                    keys.addArrangedSubview(character(title, key))
                }
                keys.addArrangedSubview(modifier("alt", symbol: "option", flag: .alternate))
                keys.addArrangedSubview(function)
                keys.addArrangedSubview(character("Ins", .insert))
                keys.addArrangedSubview(character("Del", .delete))
                for symbol in ["/", "|", "~", "-", "_", "\\", "`"] { keys.addArrangedSubview(character(symbol, .text(symbol))) }
                keys.addArrangedSubview(makeButton("Select", identifier: "t3rm.keyShelf.select") { [weak self] in self?.selectionAction?() })
                keys.addArrangedSubview(makeButton("Hide", identifier: "t3rm.keyShelf.hide") { [weak self] in self?.dismissAction?() })
            }
            keys.addArrangedSubview(UIView())
        }
        updateSelection()
        extra.setContentOffset(.zero, animated: false)
    }

    private func addArrows() {
        let style = Preferences.defaults.integer(forKey: "keyboardArrowsStyle")
        let vim = style == 3 || style == 4
        let left = character(vim ? "h" : "←", .left, label: "Left arrow", symbol: vim ? nil : "arrow.left", primary: true)
        let right = character(vim ? "l" : "→", .right, label: "Right arrow", symbol: vim ? nil : "arrow.right", primary: true)
        let paired = style == 0 || style == 1
        let up = character(vim ? "k" : "↑", .up, label: "Up arrow", symbol: vim ? nil : "arrow.up", primary: true, compact: paired)
        let down = character(vim ? "j" : "↓", .down, label: "Down arrow", symbol: vim ? nil : "arrow.down", primary: true, compact: paired)
        controls.addArrangedSubview(left)
        if paired {
            let middle = UIStackView(arrangedSubviews: [up, down])
            middle.axis = .vertical
            middle.distribution = .fillEqually
            middle.isLayoutMarginsRelativeArrangement = true
            middle.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
            middle.spacing = style == 1 ? 3 : 1
            controls.addArrangedSubview(middle)
        } else {
            controls.addArrangedSubview(style == 4 ? up : down)
            controls.addArrangedSubview(style == 4 ? down : up)
        }
        controls.addArrangedSubview(right)
    }
}
