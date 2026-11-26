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
            var bytes = Data()
            for char in text {
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
        case .tab: encoded = "\t"
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

// UIKit owns composition and dictation. Deliver committed text exactly once,
// including replacements produced by Pinyin, Japanese and dictation.
final class TerminalInput: UITextView, UITextViewDelegate {
    var onKey: ((TerminalKey, UIKeyModifierFlags) -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    private var hasComposition = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        accessibilityIdentifier = "t3rm.input"
        accessibilityLabel = "Shell input"
        backgroundColor = .clear
        tintColor = .clear
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
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        hasComposition = true
        super.setMarkedText(markedText, selectedRange: selectedRange)
        textColor = .label
        backgroundColor = .secondarySystemBackground
    }
    override func unmarkText() {
        super.unmarkText()
        hasComposition = false
        deliver()
    }
    override func insertText(_ text: String) {
        if hasComposition {
            super.insertText(text)
            hasComposition = markedTextRange != nil
            deliver()
        } else {
            super.insertText(text)
        }
    }
    override func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        let value = dictationResult.map(\.text).joined()
        hasComposition = false
        text = ""
        backgroundColor = .clear
        textColor = .clear
        if !value.isEmpty { onKey?(.text(value), []) }
    }
    func textViewDidChange(_ textView: UITextView) { deliver() }
    private func deliver() {
        guard markedTextRange == nil && !hasComposition else { return }
        backgroundColor = .clear
        textColor = .clear
        guard let value = text, !value.isEmpty else { return }
        text = ""
        onKey?(.text(value), [])
    }

    override func deleteBackward() {
        if hasComposition || markedTextRange != nil || !text.isEmpty { super.deleteBackward() }
        else { onKey?(.backspace, []) }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    override func paste(_ sender: Any?) { onPaste?() }
    override func copy(_ sender: Any?) { onCopy?() }
    func textViewDidBeginEditing(_ textView: UITextView) { onFocus?(true) }
    func textViewDidEndEditing(_ textView: UITextView) { onFocus?(false) }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
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

final class KeyShelf: UIInputView {
    var send: ((TerminalKey) -> Void)?
    var pasteAction: (() -> Void)?
    var selectionAction: (() -> Void)?
    var dismissAction: (() -> Void)?

    private enum Page { case navigation, function, more }
    private var page = Page.navigation
    private var modifiers: UIKeyModifierFlags = []
    private var modifierButtons: [(UIKeyModifierFlags, UIButton)] = []
    private var pageButtons: [(Page, UIButton)] = []
    private let controls = UIStackView()
    private let keys = UIStackView()
    private let scroll = KeyShelfScrollView()
    private let dismissPan = UIPanGestureRecognizer()
    private let separator = UIView()
    private let edge = UIView()
    private var chrome = TerminalChrome.current
    private var usesIcons = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 375, height: 46), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        for item in [controls, separator, keys] {
            item.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(item)
        }
        edge.translatesAutoresizingMaskIntoConstraints = false
        edge.isUserInteractionEnabled = false
        addSubview(edge)
        scroll.accessibilityIdentifier = "t3rm.keyShelf"
        scroll.delaysContentTouches = false
        scroll.isDirectionalLockEnabled = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false
        dismissPan.addTarget(self, action: #selector(pullDown(_:)))
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(dismissPan)
        scroll.panGestureRecognizer.require(toFail: dismissPan)
        let pixel = 1 / UIScreen.main.scale
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
            controls.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            controls.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            controls.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: 5),
            separator.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: pixel),
            separator.heightAnchor.constraint(equalToConstant: 20),
            keys.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 5),
            keys.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            keys.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            keys.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.heightAnchor.constraint(equalToConstant: pixel)
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let movement = dismissPan.translation(in: self)
        return movement.y > abs(movement.x)
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
        separator.backgroundColor = chrome.stroke
        edge.backgroundColor = chrome.stroke
        scroll.indicatorStyle = chrome.isDark ? .white : .black
        for button in controls.arrangedSubviews { button.removeFromSuperview() }
        modifierButtons.removeAll()
        pageButtons.removeAll()
        controls.addArrangedSubview(character("esc", .escape, label: "Escape", symbol: "escape", primary: true))
        for (title, symbol, flag) in [("ctrl", "control", UIKeyModifierFlags.control), ("alt", "option", .alternate)] {
            let button = makeButton(title, symbol: symbol, primary: true) { [weak self] in
                guard let self = self else { return }
                self.modifiers.formSymmetricDifference(flag)
                self.updateSelection()
            }
            controls.addArrangedSubview(button)
            modifierButtons.append((flag, button))
        }
        for (title, label, symbol, next) in [("fn", "Function keys", "function", Page.function),
                                             ("…", "More keys", "ellipsis", .more)] {
            let button = makeButton(title, label: label, symbol: symbol, primary: true) { [weak self] in
                guard let self = self else { return }
                self.page = self.page == next ? .navigation : next
                self.showPage()
                UIAccessibility.post(notification: .layoutChanged, argument: self.pageButtons.first { $0.0 == next }?.1)
            }
            controls.addArrangedSubview(button)
            pageButtons.append((next, button))
        }
        showPage()
    }

    private func updateSelection() {
        for (flag, button) in modifierButtons { button.isSelected = modifiers.contains(flag) }
        for (item, button) in pageButtons { button.isSelected = page == item }
    }

    private func makeButton(_ title: String, label: String? = nil, symbol: String? = nil,
                            primary: Bool = false, compact: Bool = false, identifier: String? = nil,
                            action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .custom)
        let font = UIFont.monospacedSystemFont(ofSize: compact ? 11 : 13, weight: .semibold)
        var config = UIButton.Configuration.plain()
        let useSymbol = usesIcons || title == "…"
        if useSymbol, let symbol = symbol, let image = UIImage(systemName: symbol) {
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
        let phoneMinimum: CGFloat = primary ? 34 : 44
        let minimum: CGFloat = Preferences.isPad ? 46 : phoneMinimum
        let legendWidth = config.image == nil ? (title as NSString).size(withAttributes: [.font: font]).width : 0
        button.widthAnchor.constraint(equalToConstant: max(minimum, ceil(legendWidth) + 10)).isActive = true
        return button
    }

    private func character(_ title: String, _ key: TerminalKey, label: String? = nil,
                           symbol: String? = nil, primary: Bool = false, compact: Bool = false) -> UIButton {
        makeButton(title, label: label, symbol: symbol, primary: primary, compact: compact) { [weak self] in self?.send?(key) }
    }

    private func showPage() {
        for item in keys.arrangedSubviews { item.removeFromSuperview() }
        let spacer = UIView()
        let preferredWidth = spacer.widthAnchor.constraint(equalToConstant: 0)
        preferredWidth.priority = .defaultLow
        preferredWidth.isActive = true
        switch page {
        case .navigation:
            keys.addArrangedSubview(character("⇥", .tab, label: "Tab", symbol: "arrow.right.to.line", primary: true))
            addArrows()
            fallthrough
        case .more:
            for (title, key) in [("Home", TerminalKey.home), ("End", .end), ("PgUp", .pageUp),
                                 ("PgDn", .pageDown), ("Ins", .insert), ("Del", .delete)] {
                keys.addArrangedSubview(character(title, key))
            }
            for symbol in ["/", "|", "~", "-", "_", "\\", "`"] { keys.addArrangedSubview(character(symbol, .text(symbol))) }
            keys.addArrangedSubview(makeButton("Paste", identifier: "t3rm.keyShelf.paste") { [weak self] in self?.pasteAction?() })
            keys.addArrangedSubview(makeButton("Select", identifier: "t3rm.keyShelf.select") { [weak self] in self?.selectionAction?() })
            keys.addArrangedSubview(makeButton("Hide", identifier: "t3rm.keyShelf.hide") { [weak self] in self?.dismissAction?() })
        case .function:
            for n in 1...12 { keys.addArrangedSubview(character("F\(n)", .function(n))) }
        }
        keys.addArrangedSubview(spacer)
        updateSelection()
        scroll.setContentOffset(.zero, animated: false)
    }

    private func addArrows() {
        let style = Preferences.defaults.integer(forKey: "keyboardArrowsStyle")
        let vim = style == 3 || style == 4
        let left = character(vim ? "h" : "←", .left, label: "Left arrow", symbol: vim ? nil : "arrow.left", primary: true)
        let right = character(vim ? "l" : "→", .right, label: "Right arrow", symbol: vim ? nil : "arrow.right", primary: true)
        let paired = style == 0 || style == 1
        let up = character(vim ? "k" : "↑", .up, label: "Up arrow", symbol: vim ? nil : "arrow.up", primary: true, compact: paired)
        let down = character(vim ? "j" : "↓", .down, label: "Down arrow", symbol: vim ? nil : "arrow.down", primary: true, compact: paired)
        keys.addArrangedSubview(left)
        if paired {
            let middle = UIStackView(arrangedSubviews: [up, down])
            middle.axis = .vertical
            middle.distribution = .fillEqually
            middle.isLayoutMarginsRelativeArrangement = true
            middle.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
            middle.spacing = style == 1 ? 3 : 1
            keys.addArrangedSubview(middle)
        } else {
            keys.addArrangedSubview(style == 4 ? up : down)
            keys.addArrangedSubview(style == 4 ? down : up)
        }
        keys.addArrangedSubview(right)
    }
}
