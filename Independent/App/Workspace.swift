import UIKit
import UniformTypeIdentifiers
import T3Integration
import T3Sessions

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    static func main() {
        #if targetEnvironment(simulator)
        if let status = TerminalSession.runSimulatorLauncherIfRequested() { exit(status) }
        #endif
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
    }

    private var workspaces: [String: WorkspaceController] = [:]
    private var connected: [String: ObjectIdentifier] = [:]

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Preferences.register()
        UIDevice.current.isBatteryMonitoringEnabled = true
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Terminal", sessionRole: session.role)
        config.delegateClass = TerminalSceneDelegate.self
        return config
    }
    func workspace(for session: UISceneSession, scene: UIScene) -> WorkspaceController {
        connected[session.persistentIdentifier] = ObjectIdentifier(scene)
        if let existing = workspaces[session.persistentIdentifier] { return existing }
        let workspace = WorkspaceController()
        workspaces[session.persistentIdentifier] = workspace
        return workspace
    }
    func disconnect(_ scene: UIScene) {
        let id = scene.session.persistentIdentifier
        if connected[id] == ObjectIdentifier(scene) { connected.removeValue(forKey: id) }
    }
    func application(_ application: UIApplication, didDiscardSceneSessions sessions: Set<UISceneSession>) {
        for session in sessions where connected[session.persistentIdentifier] == nil {
            workspaces.removeValue(forKey: session.persistentIdentifier)?.closeSessions()
        }
    }
}

final class TerminalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var workspace: WorkspaceController? { window?.rootViewController as? WorkspaceController }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene, let app = UIApplication.shared.delegate as? AppDelegate else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = app.workspace(for: session, scene: scene)
        self.window = window
        window.makeKeyAndVisible()
        scene.title = "t3rm"
        if let url = connectionOptions.urlContexts.first?.url { showURL(url) }
    }
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { showURL(url) }
    }
    private func showURL(_ url: URL) {
        if let command = ShellLinks.command(for: url) {
            DispatchQueue.main.async { [weak self] in self?.workspace?.confirmSSH(command) }
        }
    }
    func sceneDidEnterBackground(_ scene: UIScene) { workspace?.setForeground(false) }
    func sceneWillEnterForeground(_ scene: UIScene) { workspace?.setForeground(true) }
    func sceneDidDisconnect(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?.disconnect(scene)
        workspace?.setForeground(false)
        window?.rootViewController = nil
        window = nil
    }
}

private final class TerminalTab {
    let number: Int
    var panes: [TerminalPane] = []
    var weights: [CGFloat] = []
    var activeIndex = 0
    var title: String
    init(number: Int) { self.number = number; title = "Shell \(number)" }
    var active: TerminalPane? { panes.indices.contains(activeIndex) ? panes[activeIndex] : nil }
}

final class WorkspaceController: UIViewController, UIDocumentPickerDelegate {
    private let toolbar = WorkspaceBar()
    private let headerBackground = UIView()
    private var chrome = TerminalChrome.current
    private let panes = PaneDeck()
    private let root = UIStackView()
    private var tabs: [TerminalTab] = []
    private var selected = 0
    private var nextNumber = 1
    private var foreground = true
    private var pickerPurpose: PickerPurpose?
    private enum PickerPurpose { case upload(TerminalPane), download(URL) }
    private var current: TerminalTab { tabs[selected] }

    override func viewDidLoad() {
        super.viewDidLoad()
        root.axis = .vertical
        root.translatesAutoresizingMaskIntoConstraints = false
        headerBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBackground)
        view.addSubview(root)
        root.addArrangedSubview(toolbar)
        root.addArrangedSubview(panes)
        panes.changed = { [weak self] weights in self?.current.weights = weights }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 46),
            headerBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBackground.topAnchor.constraint(equalTo: view.topAnchor),
            headerBackground.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)
        ])
        toolbar.connect(to: self, add: #selector(newTab), splitPane: #selector(splitPane),
                        find: #selector(search), preferences: #selector(settings))
        toolbar.selectTab = { [weak self] index in self?.selectTab(index) }
        toolbar.makeMenu = { [weak self] compact in self?.actionMenu(compact: compact) ?? UIMenu(children: []) }
        NotificationCenter.default.addObserver(self, selector: #selector(applyAppearance),
                                               name: .terminalSettingsChanged, object: nil)
        applyAppearance()
        newTab()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { chrome.isDark ? .lightContent : .darkContent }

    @objc private func applyAppearance() {
        let palette = Palette(name: Preferences.defaults.string(forKey: "themeName") ?? "Midnight")
        chrome = TerminalChrome(palette: palette)
        view.backgroundColor = palette.background
        view.tintColor = chrome.accent
        headerBackground.backgroundColor = chrome.surface
        toolbar.apply(chrome)
        toolbar.overrideUserInterfaceStyle = chrome.isDark ? .dark : .light
        panes.apply(chrome)
        if let panel = presentedViewController as? UINavigationController { stylePanel(panel) }
        if !tabs.isEmpty { markActive() }
        setNeedsStatusBarAppearanceUpdate()
    }

    private func actionMenu(compact: Bool) -> UIMenu {
        var actions = [
            UIAction(title: "Show Keyboard", image: UIImage(systemName: "keyboard")) { [weak self] _ in self?.current.active?.focus() },
            UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.current.active?.pasteContent() },
            UIAction(title: "Select Text", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in self?.current.active?.showTranscript(search: false) }
        ]
        let close = [
            UIAction(title: "Close Pane", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in self?.closePane() },
            UIAction(title: "Close Tab", image: UIImage(systemName: "xmark.square"), attributes: .destructive) { [weak self] _ in self?.closeTab() }
        ]
        if UIApplication.shared.supportsMultipleScenes {
            actions.insert(UIAction(title: "New Window", image: UIImage(systemName: "plus.rectangle.on.rectangle")) { _ in
                UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
            }, at: 0)
        }
        var sections: [UIMenuElement] = []
        if compact {
            let split = UIAction(title: "Split Pane", image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in self?.splitPane() }
            let settings = UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in self?.settings() }
            sections.append(UIMenu(options: .displayInline, children: [split, settings]))
        }
        sections.append(UIMenu(options: .displayInline, children: actions))
        sections.append(UIMenu(options: .displayInline, children: close))
        return UIMenu(children: sections)
    }

    @objc private func newTab() {
        let cwd = tabs.isEmpty ? nil : current.active?.directory
        let tab = TerminalTab(number: nextNumber)
        nextNumber += 1
        tab.panes.append(makePane(directory: cwd, tab: tab))
        tab.weights = [1]
        tabs.append(tab)
        selectTab(tabs.count - 1)
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
            guard let self = self, let tab = tab, tab.title != title else { return }
            tab.title = title
            self.refreshTabs()
        }
        pane.onTranscript = { [weak self, weak pane] transcript, search in
            guard let self = self, self.current.active === pane, self.presentedViewController == nil else { return }
            let controller = TranscriptController(transcript, search: search)
            self.presentPanel(controller)
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
        HistoryBudget.shared.add(pane)
        return pane
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let keyboardWasVisible = panes.paneViews.contains { $0.input.isFirstResponder }
        selected = index
        displayPanes()
        refreshTabs()
        if keyboardWasVisible { current.active?.focus() }
    }
    private func displayPanes() {
        for pane in current.panes { pane.inForeground = foreground }
        panes.display(current.panes, weights: current.weights)
        markActive()
        view.setNeedsLayout()
    }
    private func markActive() {
        for (index,pane) in current.panes.enumerated() {
            pane.active = index == current.activeIndex
            pane.layer.borderWidth = current.panes.count > 1 && pane.active ? 1 : 0
            pane.layer.borderColor = chrome.accent.cgColor
        }
    }

    private func refreshTabs() {
        toolbar.show(titles: tabs.map(\.title), selected: selected)
    }
    @objc private func splitPane() {
        let tab = current
        let wasTyping = tab.active?.input.isFirstResponder == true
        let pane = makePane(directory: tab.active?.directory, tab: tab)
        let half = tab.weights[tab.activeIndex] / 2
        tab.weights[tab.activeIndex] = half
        tab.weights.insert(half, at: tab.activeIndex + 1)
        tab.panes.insert(pane, at: tab.activeIndex + 1)
        tab.activeIndex += 1
        displayPanes()
        if wasTyping { pane.focus() }
    }
    @objc private func closePane() {
        if current.panes.count == 1 { closeTab(); return }
        let wasTyping = current.active?.input.isFirstResponder == true
        let pane = current.panes.remove(at: current.activeIndex)
        current.weights.remove(at: current.activeIndex)
        pane.model.close()
        HistoryBudget.shared.remove(pane)
        current.activeIndex = min(current.activeIndex, current.panes.count - 1)
        displayPanes()
        if wasTyping { current.active?.focus() }
    }
    @objc private func closeTab() {
        let removed = tabs.remove(at: selected)
        for pane in removed.panes { pane.model.close(); HistoryBudget.shared.remove(pane) }
        if tabs.isEmpty { newTab() } else { selectTab(min(selected,tabs.count-1)) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let axis: NSLayoutConstraint.Axis = view.bounds.width >= view.bounds.height ? .horizontal : .vertical
        if panes.axis != axis { panes.axis = axis }
    }
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        HistoryBudget.shared.underPressure()
    }
    func closeSessions() {
        for tab in tabs { for pane in tab.panes { pane.model.close(); HistoryBudget.shared.remove(pane) } }
    }
    func setForeground(_ value: Bool) {
        foreground = value
        for tab in tabs { for pane in tab.panes { pane.inForeground = value } }
    }

    @objc private func search() { current.active?.showTranscript(search: true) }
    @objc private func settings() {
        guard presentedViewController == nil else { return }
        presentPanel(SettingsController(style: .insetGrouped))
    }

    private func presentPanel(_ controller: UIViewController) {
        let navigation = UINavigationController(rootViewController: controller)
        stylePanel(navigation)
        present(navigation, animated: true)
    }

    private func stylePanel(_ panel: UINavigationController) {
        panel.overrideUserInterfaceStyle = chrome.isDark ? .dark : .light
        panel.view.tintColor = chrome.accent
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
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
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
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                do {
                    var error: NSError?
                    var result: Result<Data, Error>?
                    NSFileCoordinator().coordinate(readingItemAt: file, options: .withoutChanges, error: &error) { url in
                        result = Result { try TransferArchive.upload(file: url) }
                    }
                    if let error = error { throw error }
                    guard let result = result else { throw CocoaError(.fileReadUnknown) }
                    let response = try result.get()
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
