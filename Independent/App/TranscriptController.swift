import UIKit

final class TranscriptController: UIViewController, UISearchBarDelegate {
    private let source: Transcript
    private let startsInSearch: Bool
    private let field = UISearchBar()
    private let body = UITextView()
    private let count = UILabel()
    private lazy var previousResult = UIBarButtonItem(image: UIImage(systemName: "chevron.up"), style: .plain, target: self, action: #selector(prev))
    private lazy var nextResult = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), style: .plain, target: self, action: #selector(advance))
    private var matches: [NSRange] = []
    private var selectedMatch = 0
    private var searchToken = 0
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "t3rm.search"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var highlight: NSRange?

    init(_ source: Transcript, search: Bool) {
        self.source = source
        startsInSearch = search
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = startsInSearch ? "Search" : "Select Text"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        field.placeholder = "Find in terminal"
        field.searchBarStyle = .minimal
        field.delegate = self
        field.searchTextField.accessibilityIdentifier = "t3rm.searchField"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        let themeName = Preferences.defaults.string(forKey: "themeName")
        let theme = ThemeSwatch.choices.first { $0.name == themeName } ?? ThemeSwatch.choices[0]
        let palette = Palette(name: theme.name)
        body.backgroundColor = palette.background
        body.textColor = palette.foreground
        body.tintColor = palette.ansi[6]
        body.indicatorStyle = theme.light ? .black : .white
        body.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        body.font = Preferences.font
        body.text = source.text
        body.isEditable = false
        body.isSelectable = true
        body.alwaysBounceVertical = true
        body.accessibilityLabel = "Terminal transcript"
        let navigation = UIToolbar()
        previousResult.accessibilityLabel = "Previous result"
        nextResult.accessibilityLabel = "Next result"
        previousResult.isEnabled = false
        nextResult.isEnabled = false
        count.font = .preferredFont(forTextStyle: .caption1)
        count.adjustsFontForContentSizeCategory = true
        count.textColor = .secondaryLabel
        navigation.items = [UIBarButtonItem(customView: count), UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                            previousResult, nextResult, UIBarButtonItem(title: "Copy", style: .plain, target: self, action: #selector(copySelection))]
        let stack = UIStackView(arrangedSubviews: [field, body, navigation])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if startsInSearch { field.becomeFirstResponder() }
        else if let position = source.anchor, source.text.utf16.count > position {
            var range = (source.text as NSString).rangeOfComposedCharacterSequence(at: position)
            if let cursor = body.position(from: body.beginningOfDocument, offset: position),
               let word = body.tokenizer.rangeEnclosingPosition(cursor, with: .word, inDirection: UITextDirection(rawValue: 0)) {
                let offset = body.offset(from: body.beginningOfDocument, to: word.start)
                range = NSRange(location: offset, length: body.offset(from: word.start, to: word.end))
            }
            body.becomeFirstResponder()
            body.selectedRange = range
            body.scrollRangeToVisible(range)
        } else {
            body.scrollRangeToVisible(NSRange(location: source.text.utf16.count, length: 0))
        }
    }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        queue.cancelAllOperations()
        searchToken += 1
        let token = searchToken
        selectedMatch = 0
        matches = []
        if searchText.isEmpty { displayResult(); return }
        let original = source.text as NSString
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation = operation, !operation.isCancelled else { return }
            var found: [NSRange] = []
            var start = 0
            while start < original.length && found.count < 10_000 && !operation.isCancelled {
                let remaining = NSRange(location: start, length: original.length-start)
                let range = original.range(of: searchText, options: [.caseInsensitive], range: remaining)
                guard range.location != NSNotFound && range.length > 0 else { break }
                found.append(range)
                start = NSMaxRange(range)
            }
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self = self, self.searchToken == token else { return }
                self.matches = found
                self.displayResult()
            }
        }
        queue.addOperation(operation)
    }
    private func displayResult() {
        previousResult.isEnabled = matches.count > 1
        nextResult.isEnabled = matches.count > 1
        if let previous = highlight { body.textStorage.removeAttribute(.backgroundColor, range: previous) }
        highlight = nil
        if matches.isEmpty {
            count.text = field.text?.isEmpty == false ? "No results" : ""
            body.selectedRange = NSRange(location: 0, length: 0)
        } else {
            count.text = "\(selectedMatch + 1) of \(matches.count)"
            let match = matches[selectedMatch]
            body.textStorage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.45), range: match)
            highlight = match
            body.selectedRange = match
            body.scrollRangeToVisible(matches[selectedMatch])
        }
        count.sizeToFit()
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { field.resignFirstResponder(); displayResult() }
    override var keyCommands: [UIKeyCommand]? {
        let find = UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(focusSearch))
        find.discoverabilityTitle = "Find in Terminal"
        let forward = UIKeyCommand(input: "g", modifierFlags: .command, action: #selector(advance))
        forward.discoverabilityTitle = "Next Result"
        let backward = UIKeyCommand(input: "g", modifierFlags: [.command, .shift], action: #selector(prev))
        backward.discoverabilityTitle = "Previous Result"
        let close = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(done))
        return [find, forward, backward, close]
    }
    @objc private func focusSearch() { field.searchTextField.becomeFirstResponder() }
    @objc private func advance() { if !matches.isEmpty { selectedMatch = (selectedMatch+1) % matches.count; displayResult() } }
    @objc private func prev() { if !matches.isEmpty { selectedMatch = (selectedMatch+matches.count-1) % matches.count; displayResult() } }
    @objc private func copySelection() {
        let range = body.selectedRange
        if range.length > 0 { UIPasteboard.general.string = (source.text as NSString).substring(with: range) }
    }
    @objc private func done() { dismiss(animated: true) }
}
