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

final class KeyShelf: UIInputView {
    var send: ((TerminalKey) -> Void)?
    var pasteAction: (() -> Void)?
    var selectionAction: (() -> Void)?
    var dismissAction: (() -> Void)?
    private var modifiers: UIKeyModifierFlags = []
    private var page = 0
    private let stack = UIStackView()
    private let scroll = UIScrollView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 360, height: 44), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .fill
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -3),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -6)
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    func consume() -> UIKeyModifierFlags {
        let value = modifiers
        if !value.isEmpty { modifiers = []; rebuild() }
        return value
    }
    func rebuild() {
        for item in stack.arrangedSubviews { stack.removeArrangedSubview(item); item.removeFromSuperview() }
        let icons = Preferences.defaults.integer(forKey: "keyboardAccessoryStyle") == 1
        let symbols = ["esc": "escape", "ctrl": "control", "alt": "option", "fn": "function",
                       "•••": "ellipsis", "⇥": "arrow.right.to.line", "←": "arrow.left",
                       "↓": "arrow.down", "↑": "arrow.up", "→": "arrow.right"]
        func makeButton(_ title: String, name: String? = nil, selected: Bool = false,
                        compact: Bool = false, action: @escaping () -> Void) -> UIButton {
            let key = UIButton(type: .system)
            var config = UIButton.Configuration.tinted()
            if icons, let symbol = symbols[title], let image = UIImage(systemName: symbol) {
                config.image = image
                config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: compact ? 11 : 14, weight: .medium)
            } else { config.title = title }
            config.baseForegroundColor = selected ? .white : .label
            config.baseBackgroundColor = selected ? .systemBlue : .secondarySystemFill
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: compact ? 2 : 7, bottom: 0, trailing: compact ? 2 : 7)
            key.configuration = config
            key.accessibilityLabel = name ?? title
            key.accessibilityTraits = selected ? [.button, .selected] : .button
            key.addAction(UIAction { _ in action() }, for: .touchUpInside)
            key.widthAnchor.constraint(greaterThanOrEqualToConstant: compact ? 29 : 34).isActive = true
            return key
        }
        func button(_ title: String, name: String? = nil, selected: Bool = false, action: @escaping () -> Void) {
            stack.addArrangedSubview(makeButton(title, name: name, selected: selected, action: action))
        }
        func character(_ title: String, _ key: TerminalKey, _ label: String? = nil) {
            button(title, name: label) { [weak self] in self?.send?(key) }
        }
        func toggle(_ title: String, _ flag: UIKeyModifierFlags) {
            button(title, selected: modifiers.contains(flag)) { [weak self] in
                guard let self = self else { return }
                if self.modifiers.contains(flag) { self.modifiers.remove(flag) } else { self.modifiers.insert(flag) }
                self.rebuild()
            }
        }
        character("esc", .escape, "Escape")
        toggle("ctrl", .control); toggle("alt", .alternate)
        button("fn", name: "Function keys", selected: page == 1) { [weak self] in self?.switchPage(1) }
        button("•••", name: "More keys", selected: page == 2) { [weak self] in self?.switchPage(2) }
        switch page {
        case 1: for n in 1...12 { character("F\(n)", .function(n)) }
        case 2:
            for (title,key) in [("Home",TerminalKey.home), ("End",.end), ("PgUp",.pageUp), ("PgDn",.pageDown),
                                ("Ins",.insert), ("Del",.delete)] { character(title,key) }
            for symbol in ["/","|","~","-","_","\\","`"] { character(symbol, .text(symbol)) }
            button("Paste") { [weak self] in self?.pasteAction?() }
            button("Select") { [weak self] in self?.selectionAction?() }
            button("Hide") { [weak self] in self?.dismissAction?() }
        default:
            character("⇥", .tab, "Tab")
            let style = Preferences.defaults.integer(forKey: "keyboardArrowsStyle")
            let keys: [(String,TerminalKey,String)] = [("←",.left,"Left arrow"), ("↓",.down,"Down arrow"),
                                                        ("↑",.up,"Up arrow"), ("→",.right,"Right arrow")]
            func arrow(_ index: Int, _ title: String? = nil, compact: Bool = false) -> UIButton {
                let item = keys[index]
                return makeButton(title ?? item.0, name: item.2, compact: compact) { [weak self] in self?.send?(item.1) }
            }
            switch style {
            case 0, 1:
                stack.addArrangedSubview(arrow(0))
                let middle = UIStackView(arrangedSubviews: [arrow(2, compact: true), arrow(1, compact: true)])
                middle.axis = .vertical
                middle.distribution = .fillEqually
                if style == 1 { middle.spacing = 2 }
                stack.addArrangedSubview(middle)
                stack.addArrangedSubview(arrow(3))
            case 3,4:
                let captions = style == 3 ? ["h","j","k","l"] : ["h","k","j","l"]
                let order = style == 3 ? [0,1,2,3] : [0,2,1,3]
                for index in order.indices {
                    stack.addArrangedSubview(arrow(order[index], captions[index]))
                }
            default: for index in keys.indices { stack.addArrangedSubview(arrow(index)) }
            }
        }
    }
    private func switchPage(_ next: Int) {
        page = page == next ? 0 : next
        rebuild()
        scroll.setContentOffset(.zero, animated: false)
    }
}
