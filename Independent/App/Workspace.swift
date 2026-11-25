import UIKit
import UniformTypeIdentifiers
import T3Integration

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let workspace = WorkspaceController()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Preferences.register()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = workspace
        self.window = window
        window.makeKeyAndVisible()
        return true
    }
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard let command = ShellLinks.command(for: url) else { return false }
        workspace.confirmSSH(command)
        return true
    }
    func applicationDidEnterBackground(_ app: UIApplication) { workspace.setForeground(false) }
    func applicationWillEnterForeground(_ app: UIApplication) { workspace.setForeground(true) }
}

private final class TerminalTab {
    let number: Int
    var panes: [TerminalPane] = []
    var activeIndex = 0
    var title: String
    init(number: Int) { self.number = number; title = "Shell \(number)" }
    var active: TerminalPane? { panes.indices.contains(activeIndex) ? panes[activeIndex] : nil }
}

final class WorkspaceController: UIViewController, UIDocumentPickerDelegate {
    private let toolbar = UIStackView()
    private let tabStrip = UIScrollView()
    private let tabButtons = UIStackView()
    private let panes = UIStackView()
    private let root = UIStackView()
    private var tabs: [TerminalTab] = []
    private var selected = 0
    private var nextNumber = 1
    private var historyBudget = 24 * 1024 * 1024
    private var foreground = true
    private var pickerPurpose: PickerPurpose?
    private enum PickerPurpose { case upload(TerminalPane), download(URL) }
    private var current: TerminalTab { tabs[selected] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        root.axis = .vertical
        root.translatesAutoresizingMaskIntoConstraints = false
        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.spacing = 2
        tabButtons.spacing = 4
        tabButtons.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.showsHorizontalScrollIndicator = false
        tabStrip.addSubview(tabButtons)
        toolbar.addArrangedSubview(tabStrip)
        tabStrip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.addSubview(root)
        root.addArrangedSubview(toolbar)
        root.addArrangedSubview(panes)
        panes.distribution = .fillEqually
        panes.spacing = 1
        panes.backgroundColor = .separator
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
            tabStrip.heightAnchor.constraint(equalTo: toolbar.heightAnchor),
            tabButtons.leadingAnchor.constraint(equalTo: tabStrip.contentLayoutGuide.leadingAnchor, constant: 4),
            tabButtons.trailingAnchor.constraint(equalTo: tabStrip.contentLayoutGuide.trailingAnchor, constant: -4),
            tabButtons.topAnchor.constraint(equalTo: tabStrip.contentLayoutGuide.topAnchor),
            tabButtons.bottomAnchor.constraint(equalTo: tabStrip.contentLayoutGuide.bottomAnchor),
            tabButtons.heightAnchor.constraint(equalTo: tabStrip.frameLayoutGuide.heightAnchor)
        ])
        control("plus", label: "New tab", id: "newTab", action: #selector(newTab))
        control("rectangle.split.2x1", label: "Split pane", id: "split", action: #selector(splitPane))
        control("magnifyingglass", label: "Search terminal", id: "search", action: #selector(search))
        control("gearshape", label: "Settings", id: "settings", action: #selector(settings))
        let more = control("ellipsis.circle", label: "Terminal actions", id: "actions", action: nil)
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [
            UIAction(title: "Show Keyboard", image: UIImage(systemName: "keyboard")) { [weak self] _ in self?.current.active?.focus() },
            UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.current.active?.pasteContent() },
            UIAction(title: "Select Text", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in self?.current.active?.showTranscript(search: false) },
            UIAction(title: "Close Pane", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in self?.closePane() },
            UIAction(title: "Close Tab", image: UIImage(systemName: "xmark.square"), attributes: .destructive) { [weak self] _ in self?.closeTab() }
        ])
        newTab()
    }

    @discardableResult
    private func control(_ icon: String, label: String, id: String, action: Selector?) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: icon), for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "t3rm." + id
        if let action = action { button.addTarget(self, action: action, for: .touchUpInside) }
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        toolbar.addArrangedSubview(button)
        return button
    }

    @objc private func newTab() {
        let cwd = tabs.isEmpty ? nil : current.active?.directory
        let tab = TerminalTab(number: nextNumber)
        nextNumber += 1
        tab.panes.append(makePane(directory: cwd, tab: tab))
        tabs.append(tab)
        selectTab(tabs.count - 1)
        balanceHistory()
    }

    private func makePane(directory: String?, tab: TerminalTab) -> TerminalPane {
        let pane = TerminalPane(directory: directory)
        pane.onActivate = { [weak self, weak pane, weak tab] in
            guard let self = self, let pane = pane, let tab = tab, self.current === tab,
                  let index = tab.panes.firstIndex(where: { $0 === pane }) else { return }
            tab.activeIndex = index
            self.markActive()
        }
        pane.onTitle = { [weak self, weak tab] title in
            guard let self = self, let tab = tab else { return }
            tab.title = title
            self.refreshTabs()
        }
        pane.onTranscript = { [weak self, weak pane] transcript, line, column, search in
            guard let self = self, self.current.active === pane, self.presentedViewController == nil else { return }
            let controller = TranscriptController(transcript, line: line, column: column, search: search)
            self.present(UINavigationController(rootViewController: controller), animated: true)
        }
        pane.onError = { [weak self] value in self?.alert("Terminal", value) }
        pane.onUpload = { [weak self, weak pane] in
            guard let self = self, let pane = pane else { return }
            guard self.current.active === pane, self.foreground, self.presentedViewController == nil else {
                pane.model.send { _ in TransferArchive.cancel }; return
            }
            self.offerUpload(pane)
        }
        pane.onDownload = { [weak self, weak pane] name, data in
            guard let self = self, self.current.active === pane, self.foreground, self.presentedViewController == nil else { return }
            self.offerDownload(name: name, data: data)
        }
        return pane
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let keyboardWasVisible = panes.arrangedSubviews.contains { ($0 as? TerminalPane)?.input.isFirstResponder == true }
        selected = index
        displayPanes()
        refreshTabs()
        if keyboardWasVisible { current.active?.focus() }
    }
    private func displayPanes() {
        for view in panes.arrangedSubviews { panes.removeArrangedSubview(view); view.removeFromSuperview() }
        for pane in current.panes { pane.inForeground = foreground; panes.addArrangedSubview(pane) }
        markActive()
        view.setNeedsLayout()
    }
    private func markActive() {
        for (index,pane) in current.panes.enumerated() {
            pane.active = index == current.activeIndex
            pane.layer.borderWidth = current.panes.count > 1 && pane.active ? 1 : 0
            pane.layer.borderColor = view.tintColor.cgColor
        }
    }

    private func refreshTabs() {
        for button in tabButtons.arrangedSubviews { tabButtons.removeArrangedSubview(button); button.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let button = UIButton(type: .system)
            var config = index == selected ? UIButton.Configuration.tinted() : UIButton.Configuration.plain()
            config.title = tab.title
            config.titleLineBreakMode = .byTruncatingTail
            config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 9, bottom: 3, trailing: 9)
            button.configuration = config
            button.accessibilityLabel = tab.title
            button.accessibilityHint = "Switch to this terminal tab"
            button.accessibilityIdentifier = "t3rm.tab.\(index + 1)"
            button.accessibilityTraits = index == selected ? [.button, .selected] : .button
            button.addAction(UIAction { [weak self] _ in self?.selectTab(index) }, for: .touchUpInside)
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 145).isActive = true
            tabButtons.addArrangedSubview(button)
        }
        tabStrip.layoutIfNeeded()
        if tabButtons.arrangedSubviews.indices.contains(selected) {
            let selectedButton = tabButtons.arrangedSubviews[selected]
            tabStrip.scrollRectToVisible(selectedButton.convert(selectedButton.bounds, to: tabStrip), animated: false)
        }
    }
    @objc private func splitPane() {
        let tab = current
        let pane = makePane(directory: tab.active?.directory, tab: tab)
        tab.panes.insert(pane, at: tab.activeIndex + 1)
        tab.activeIndex += 1
        displayPanes()
        balanceHistory()
    }
    @objc private func closePane() {
        if current.panes.count == 1 { closeTab(); return }
        current.panes.remove(at: current.activeIndex).model.close()
        current.activeIndex = min(current.activeIndex, current.panes.count - 1)
        displayPanes()
        balanceHistory()
    }
    @objc private func closeTab() {
        let removed = tabs.remove(at: selected)
        for pane in removed.panes { pane.model.close() }
        if tabs.isEmpty { newTab() } else { selectTab(min(selected,tabs.count-1)); balanceHistory() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let axis: NSLayoutConstraint.Axis = view.bounds.width >= view.bounds.height ? .horizontal : .vertical
        if panes.axis != axis { panes.axis = axis }
    }
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        historyBudget = min(historyBudget, 12 * 1024 * 1024)
        for tab in tabs { for pane in tab.panes { pane.releaseCache() } }
        balanceHistory()
    }
    private func balanceHistory() {
        let count = tabs.reduce(0) { $0 + $1.panes.count }
        let share = historyBudget / max(1,count)
        for tab in tabs { for pane in tab.panes { pane.model.trim(bytes: share) } }
    }
    func setForeground(_ value: Bool) {
        foreground = value
        for tab in tabs { for pane in tab.panes { pane.inForeground = value } }
    }

    @objc private func search() { current.active?.showTranscript(search: true) }
    @objc private func settings() {
        guard presentedViewController == nil else { return }
        present(UINavigationController(rootViewController: SettingsController(style: .insetGrouped)), animated: true)
    }

    override var keyCommands: [UIKeyCommand]? {
        func command(_ title: String, _ input: String, _ flags: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let c = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            c.discoverabilityTitle = title
            return c
        }
        return [command("New Tab", "t", .command, #selector(newTab)),
                command("Split Pane", "d", .command, #selector(splitPane)),
                command("Close Pane", "w", .command, #selector(closePane)),
                command("Search", "f", .command, #selector(search)),
                command("Settings", ",", .command, #selector(settings)),
                command("Next Tab", "]", [.command,.shift], #selector(nextTab)),
                command("Previous Tab", "[", [.command,.shift], #selector(previousTab))]
    }
    @objc private func nextTab() { selectTab((selected+1) % tabs.count) }
    @objc private func previousTab() { selectTab((selected+tabs.count-1) % tabs.count) }

    func confirmSSH(_ command: String) {
        loadViewIfNeeded()
        let alert = UIAlertController(title: "Open SSH session?", message: command, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.newTab()
            self.view.layoutIfNeeded()
            self.current.active?.layoutIfNeeded()
            self.current.active?.insertCommand(command)
        })
        guard presentedViewController == nil else { return }
        present(alert, animated: true)
    }
    private func alert(_ title: String, _ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func offerUpload(_ pane: TerminalPane) {
        let alert = UIAlertController(title: "Upload a file?", message: "This shell requested a file. Choose a file up to 1 MiB to send.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in pane.model.send { _ in TransferArchive.cancel } })
        alert.addAction(UIAlertAction(title: "Choose File", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
            self.pickerPurpose = .upload(pane)
            picker.delegate = self
            self.present(picker, animated: true)
        })
        present(alert, animated: true)
    }

    private func offerDownload(name: String, data: Data) {
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", leaf.utf8.count <= 255,
              !leaf.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return }
        let alert = UIAlertController(title: "Save a file?", message: "\(leaf)\n\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(leaf)
                try data.write(to: url, options: .atomic)
                let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                self.pickerPurpose = .download(dir)
                picker.delegate = self
                self.present(picker, animated: true)
            } catch { try? FileManager.default.removeItem(at: dir); self.alert("Download", error.localizedDescription) }
        })
        present(alert, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        defer { pickerPurpose = nil }
        switch pickerPurpose {
        case .upload(let pane): pane.model.send { _ in TransferArchive.cancel }
        case .download(let directory): try? FileManager.default.removeItem(at: directory)
        case nil: break
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        defer { pickerPurpose = nil }
        switch pickerPurpose {
        case .upload(let pane):
            guard let file = urls.first else { pane.model.send { _ in TransferArchive.cancel }; return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try TransferArchive.upload(file: file)
                    pane.model.send { _ in response }
                } catch {
                    pane.model.send { _ in TransferArchive.cancel }
                    DispatchQueue.main.async { [weak self] in self?.alert("Upload", error.localizedDescription) }
                }
            }
        case .download(let directory): try? FileManager.default.removeItem(at: directory)
        case nil: break
        }
    }
}
