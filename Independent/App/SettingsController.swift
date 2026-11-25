import UIKit
import UniformTypeIdentifiers
import CoreText
import T3Engine

final class SettingsController: UITableViewController, UIDocumentPickerDelegate {
    private enum Row {
        case preview, font, size, theme, locale, shelf, arrows, trackpad, bellHUD, vibrate, sound, chargingRate, batteryRate, lowPower, about
        var title: String {
            switch self {
            case .preview: return "Terminal preview"
            case .locale: return "Shell Locale"
            case .font: return "Font"
            case .size: return "Font Size"
            case .theme: return "Color Theme"
            case .shelf: return "Accessory Keys"
            case .arrows: return "Arrow Keys"
            case .trackpad: return "Trackpad Sensitivity"
            case .bellHUD: return "Show Bell"
            case .vibrate: return "Haptic Bell"
            case .sound: return "Sound Bell"
            case .chargingRate: return "While Charging"
            case .batteryRate: return "On Battery"
            case .lowPower: return "Reduce in Low Power Mode"
            case .about: return "About t3rm"
            }
        }
        var key: String {
            switch self {
            case .locale: return "preferredLocale"
            case .font: return "fontName"
            case .size: return Preferences.sizeKey
            case .theme: return "themeName"
            case .shelf: return "keyboardAccessoryStyle"
            case .arrows: return "keyboardArrowsStyle"
            case .trackpad: return "keyboardTrackpadSensitivity"
            case .bellHUD: return "bellHUD"
            case .vibrate: return "bellVibrate"
            case .sound: return "bellSound"
            case .chargingRate: return "refreshRateOnAC"
            case .batteryRate: return "refreshRateOnBattery"
            case .lowPower: return "reduceRefreshRateInLPM"
            case .preview, .about: return ""
            }
        }
        var names: [String] {
            switch self {
            case .theme: return Palette.names
            case .shelf: return ["Text", "Icons"]
            case .arrows: return ["Butterfly", "Scissor", "Classic", "Vim", "Vim inverted"]
            case .trackpad: return ["Off", "Low", "Medium", "High"]
            default: return []
            }
        }
        var isSwitch: Bool { [.bellHUD,.vibrate,.sound,.lowPower].contains(self) }
    }
    private let sections: [(String,[Row])] = [
        ("Appearance", [.preview,.theme,.font,.size]), ("Keyboard", [.shelf,.arrows,.trackpad]),
        ("Session", [.locale]), ("Bell", [.bellHUD,.vibrate,.sound]), ("Refresh Rate", [.chargingRate,.batteryRate,.lowPower]), ("", [.about])
    ]
    private var selectedFontName: String {
        let font = Preferences.font
        let systemMono = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        return font.fontName == systemMono.fontName ? "SF Mono" : font.fontName
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 50
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); tableView.reloadData() }
    @objc private func done() { dismiss(animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].0 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].1.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].1[indexPath.row]
        if row == .preview { return TerminalPreviewCell() }
        let largeText = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let cell = UITableViewCell(style: largeText ? .subtitle : .value1, reuseIdentifier: nil)
        cell.textLabel?.text = row.title
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = largeText ? 0 : 1
        cell.accessoryType = .disclosureIndicator
        let defaults = Preferences.defaults
        switch row {
        case .locale: cell.detailTextLabel?.text = defaults.string(forKey: row.key).flatMap { $0.isEmpty ? nil : $0 } ?? "System"
        case .font: cell.detailTextLabel?.text = selectedFontName
        case .size:
            let size = Int(Preferences.font.pointSize)
            cell.detailTextLabel?.text = "\(size) pt"
            if !largeText {
                let stepper = UIStepper()
                stepper.minimumValue = 8
                stepper.maximumValue = 36
                stepper.value = Double(size)
                stepper.accessibilityLabel = row.title
                stepper.accessibilityValue = "\(size) points"
                stepper.addAction(UIAction { [weak self, weak stepper, weak cell] _ in
                    guard let self = self, let stepper = stepper else { return }
                    let points = Int(stepper.value)
                    Preferences.update(points, key: row.key)
                    cell?.detailTextLabel?.text = "\(points) pt"
                    stepper.accessibilityValue = "\(points) points"
                    self.tableView.beginUpdates()
                    for case let preview as TerminalPreviewCell in self.tableView.visibleCells { preview.update() }
                    self.tableView.endUpdates()
                }, for: .valueChanged)
                cell.accessoryView = stepper
            }
        case .theme:
            let name = defaults.string(forKey: row.key) ?? Palette.names[0]
            cell.detailTextLabel?.text = name
            cell.imageView?.image = themeBadge(name)
        case .trackpad, .arrows, .shelf: cell.detailTextLabel?.text = row.names[min(row.names.count-1,max(0, defaults.integer(forKey: row.key)))]
        case .chargingRate, .batteryRate: cell.detailTextLabel?.text = "\(defaults.integer(forKey: row.key)) Hz"
        case .bellHUD,.vibrate,.sound,.lowPower:
            cell.selectionStyle = .none
            let toggle = UISwitch()
            toggle.isOn = defaults.bool(forKey: row.key)
            toggle.accessibilityLabel = row.title
            toggle.addAction(UIAction { [weak toggle] _ in Preferences.update(toggle?.isOn ?? false, key: row.key) }, for: .valueChanged)
            cell.accessoryView = toggle
        case .preview, .about: break
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let row = sections[indexPath.section].1[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)
        if row.isSwitch || row == .preview { return }
        if row == .about {
            navigationController?.pushViewController(AboutController(style: .insetGrouped), animated: true); return
        }
        let defaults = Preferences.defaults
        let labels: [String]
        let values: [Any]
        let picked: String?
        switch row {
        case .locale:
            let current = defaults.string(forKey: row.key) ?? ""
            var available = Set(Locale.availableIdentifiers.map { $0 + ".UTF-8" })
            available.formUnion(["C", "C.UTF-8", "en_US.UTF-8"])
            if !current.isEmpty { available.insert(current) }
            let identifiers = available.sorted()
            labels = ["System"] + identifiers
            values = [""] + identifiers
            picked = current.isEmpty ? "System" : current
        case .font:
            var fonts = UIFont.familyNames.flatMap { UIFont.fontNames(forFamilyName: $0) }.filter { name in
                UIFont(name: name, size: 13)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
            }
            fonts += ["SF Mono", selectedFontName]
            labels = Array(Set(fonts)).sorted()
            values = labels
            picked = selectedFontName
        case .size:
            let sizes = Array(8...36)
            labels = sizes.map { "\($0) pt" }; values = sizes; picked = "\(Int(Preferences.font.pointSize)) pt"
        case .theme:
            labels = row.names; values = labels; picked = defaults.string(forKey: row.key)
        case .chargingRate,.batteryRate:
            let rates = [15,24,30,48,60,80,90,120]
            labels = rates.map { "\($0) Hz" }; values = rates; picked = "\(defaults.integer(forKey: row.key)) Hz"
        default:
            labels = row.names; values = Array(labels.indices)
            let index = defaults.integer(forKey: row.key)
            picked = labels.indices.contains(index) ? labels[index] : nil
        }
        let picker = ChoiceController(title: row.title, choices: labels, selected: picked) { index in
            Preferences.update(values[index], key: row.key)
        }
        picker.previewThemes = row == .theme
        if row == .font {
            picker.previewFonts = true
            picker.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Import", style: .plain, target: self, action: #selector(importFont))
        }
        navigationController?.pushViewController(picker, animated: true)
    }
    @objc private func importFont() {
        let types = [UTType(filenameExtension: "ttf"), UTType(filenameExtension: "otf")].compactMap { $0 }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let source = urls.first else { return }
        let destination = Preferences.fontsDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        do {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(source as CFURL) as? [CTFontDescriptor],
                  let name = descriptors.compactMap({ CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }).first else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try FileManager.default.createDirectory(at: Preferences.fontsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            var failure: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(destination as CFURL, .process, &failure) else {
                if let failure = failure { throw failure.takeRetainedValue() as Error }
                throw CocoaError(.fileReadCorruptFile)
            }
            Preferences.update(name, key: "fontName")
            navigationController?.popToViewController(self, animated: true)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            let alert = UIAlertController(title: "Font Import", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

private final class TerminalPreviewCell: UITableViewCell {
    private let canvas = TerminalCanvas()
    private let heading = UILabel()
    private let swatches = UIStackView()
    private var canvasHeight: NSLayoutConstraint!

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        isAccessibilityElement = true
        accessibilityLabel = "Terminal preview"
        accessibilityIdentifier = "t3rm.appearancePreview"
        accessibilityTraits = .staticText
        heading.text = "Preview"
        heading.font = .preferredFont(forTextStyle: .caption1)
        heading.adjustsFontForContentSizeCategory = true
        swatches.spacing = 3
        let header = UIStackView(arrangedSubviews: [heading, swatches])
        header.alignment = .center
        header.spacing = 8
        for _ in 0..<6 {
            let chip = UIView()
            chip.layer.cornerRadius = 2
            swatches.addArrangedSubview(chip)
            NSLayoutConstraint.activate([chip.widthAnchor.constraint(equalToConstant: 10), chip.heightAnchor.constraint(equalToConstant: 6)])
        }
        canvas.horizontalInset = 0
        canvas.active = true
        canvas.isAccessibilityElement = false
        canvas.accessibilityIdentifier = nil
        let stack = UIStackView(arrangedSubviews: [header, canvas])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        canvasHeight = canvas.heightAnchor.constraint(equalToConstant: 48)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            canvasHeight
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        canvas.refreshAppearance()
        let palette = canvas.palette
        contentView.backgroundColor = palette.background
        heading.textColor = palette.foreground
        for (index, chip) in swatches.arrangedSubviews.enumerated() { chip.backgroundColor = palette.ansi[index + 1] }
        // Use the shell renderer for the sample so font metrics, ANSI colors and cursor match a real pane.
        let engine = TerminalEngine(columns: 12, rows: 3)
        _ = engine.feed(Data("~ > ls -F\r\n\u{1b}[34mLibrary/\u{1b}[0m\r\n~ > ".utf8))
        let changes = Dictionary(uniqueKeysWithValues: (0..<engine.rows).map { ($0, engine.line(at: $0)) })
        let frame = TerminalFrame(first: 0, history: 0, start: 0, count: engine.rows, changes: changes,
                                  cursorColumn: engine.cursorColumn, cursorLine: engine.cursorRow, modes: engine.modes)
        canvas.apply(frame, fraction: 0)
        canvasHeight.constant = CGFloat(engine.rows) * canvas.cellSize.height
        let name = Preferences.defaults.string(forKey: "themeName") ?? Palette.names[0]
        accessibilityValue = "\(name), \(canvas.font.familyName), \(Int(canvas.font.pointSize)) points"
    }
}

private func themeBadge(_ name: String) -> UIImage {
    let palette = Palette(name: name)
    let size = CGSize(width: 34, height: 28)
    return UIGraphicsImageRenderer(size: size).image { _ in
        let shape = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
        palette.background.setFill()
        shape.fill()
        palette.foreground.withAlphaComponent(0.35).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let type = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: type, .foregroundColor: palette.foreground]
        let sample = "Aa" as NSString
        let textSize = sample.size(withAttributes: attributes)
        sample.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
    }.withRenderingMode(.alwaysOriginal)
}

private final class ChoiceController: UITableViewController {
    let choices: [String]
    let selected: String?
    var previewFonts = false
    var previewThemes = false
    let choose: (Int) -> Void
    init(title: String, choices: [String], selected: String?, choose: @escaping (Int) -> Void) {
        self.choices = choices; self.selected = selected; self.choose = choose
        super.init(style: .insetGrouped)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { choices.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "choice") ?? UITableViewCell(style: .default, reuseIdentifier: "choice")
        let option = choices[indexPath.row]
        cell.textLabel?.text = option
        if previewFonts {
            let face = UIFont(name: option, size: 16) ?? .monospacedSystemFont(ofSize: 16, weight: .regular)
            cell.textLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: face)
        }
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        if previewThemes { cell.imageView?.image = themeBadge(option) }
        cell.accessoryType = selected == option ? .checkmark : .none
        if selected == option { cell.accessibilityTraits.insert(.selected) } else { cell.accessibilityTraits.remove(.selected) }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        choose(indexPath.row); navigationController?.popViewController(animated: true)
    }
}

private final class AboutController: UITableViewController {
    private let links = [("Project", "https://github.com/davghz/t3rm"), ("Report an Issue", "https://github.com/davghz/t3rm/issues")]
    override func viewDidLoad() { super.viewDidLoad(); title = "About" }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : links.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            cell.textLabel?.text = "t3rm \(version)"
            cell.detailTextLabel?.text = "by davghz"
            cell.selectionStyle = .none
        } else {
            cell.textLabel?.text = links[indexPath.row].0
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1, let url = URL(string: links[indexPath.row].1) { UIApplication.shared.open(url) }
    }
}
