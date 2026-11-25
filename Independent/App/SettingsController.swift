import UIKit
import UniformTypeIdentifiers
import CoreText

final class SettingsController: UITableViewController, UIDocumentPickerDelegate {
    private enum Row {
        case font, size, theme, shelf, arrows, trackpad, bellHUD, vibrate, sound, chargingRate, batteryRate, lowPower, about
        var title: String {
            switch self {
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
            case .about: return ""
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
        ("Appearance", [.font,.size,.theme]), ("Keyboard", [.shelf,.arrows,.trackpad]),
        ("Bell", [.bellHUD,.vibrate,.sound]), ("Refresh Rate", [.chargingRate,.batteryRate,.lowPower]), ("", [.about])
    ]
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); tableView.reloadData() }
    @objc private func done() { dismiss(animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].0 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].1.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].1[indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = row.title
        cell.accessoryType = .disclosureIndicator
        let defaults = Preferences.defaults
        switch row {
        case .font: cell.detailTextLabel?.text = Preferences.font.fontName
        case .size: cell.detailTextLabel?.text = "\(Int(Preferences.font.pointSize)) pt"
        case .theme: cell.detailTextLabel?.text = defaults.string(forKey: row.key)
        case .trackpad, .arrows, .shelf: cell.detailTextLabel?.text = row.names[min(row.names.count-1,max(0, defaults.integer(forKey: row.key)))]
        case .chargingRate, .batteryRate: cell.detailTextLabel?.text = "\(defaults.integer(forKey: row.key)) Hz"
        case .bellHUD,.vibrate,.sound,.lowPower:
            cell.selectionStyle = .none
            let toggle = UISwitch()
            toggle.isOn = defaults.bool(forKey: row.key)
            toggle.accessibilityLabel = row.title
            toggle.addAction(UIAction { [weak toggle] _ in Preferences.update(toggle?.isOn ?? false, key: row.key) }, for: .valueChanged)
            cell.accessoryView = toggle
        case .about: break
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let row = sections[indexPath.section].1[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)
        if row.isSwitch { return }
        if row == .about {
            navigationController?.pushViewController(AboutController(style: .insetGrouped), animated: true); return
        }
        let defaults = Preferences.defaults
        let labels: [String]
        let values: [Any]
        let picked: String?
        switch row {
        case .font:
            var fonts = UIFont.familyNames.flatMap { UIFont.fontNames(forFamilyName: $0) }.filter { name in
                UIFont(name: name, size: 13)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
            }
            fonts.append(Preferences.font.fontName)
            labels = Array(Set(fonts)).sorted()
            values = labels
            picked = Preferences.font.fontName
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

private final class ChoiceController: UITableViewController {
    let choices: [String]
    let selected: String?
    var previewFonts = false
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
        if previewFonts { cell.textLabel?.font = UIFont(name: option, size: 16) }
        cell.accessoryType = selected == option ? .checkmark : .none
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
