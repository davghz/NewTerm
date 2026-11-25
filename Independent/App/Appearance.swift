import UIKit
import CoreText

extension Notification.Name { static let terminalSettingsChanged = Notification.Name("TerminalSettingsChanged") }

enum Preferences {
    static let defaults = UserDefaults.standard
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static var sizeKey: String { isPad ? "fontSizePad" : "fontSizePhone" }
    static func register() {
        defaults.register(defaults: ["fontName": "Menlo-Regular", "fontSizePhone": 13, "fontSizePad": 15,
            "themeName": "Midnight", "keyboardAccessoryStyle": "standard", "keyboardArrowsStyle": "horizontal",
            "keyboardTrackpadSensitivity": 1.0, "bellHUD": true, "bellVibrate": false, "bellSound": false,
            "refreshRateOnAC": 60, "refreshRateOnBattery": 60, "reduceRefreshRateInLPM": true])
        if let urls = try? FileManager.default.contentsOfDirectory(at: fontsDirectory, includingPropertiesForKeys: nil) {
            for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }
    static var fontsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fonts", isDirectory: true)
    }
    static var font: UIFont {
        let size = CGFloat(max(8, min(36, defaults.double(forKey: sizeKey))))
        return UIFont(name: defaults.string(forKey: "fontName") ?? "", size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    static func update(_ value: Any, key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .terminalSettingsChanged, object: nil)
    }
    static var frameRate: Int {
        let charging = [.charging, .full].contains(UIDevice.current.batteryState)
        var rate = defaults.integer(forKey: charging ? "refreshRateOnAC" : "refreshRateOnBattery")
        if rate <= 0 { rate = 60 }
        if defaults.bool(forKey: "reduceRefreshRateInLPM") && ProcessInfo.processInfo.isLowPowerModeEnabled {
            rate = min(rate, 30)
        }
        return max(1, min(rate, UIScreen.main.maximumFramesPerSecond))
    }
}

private extension UIColor {
    convenience init(hex: Int) {
        self.init(red: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255,
                  blue: CGFloat(hex & 255)/255, alpha: 1)
    }
}

struct Palette {
    let background: UIColor
    let foreground: UIColor
    let ansi: [UIColor]
    static let names = ["Midnight", "Paper", "Black"]
    init(name: String) {
        let light = name == "Paper"
        background = UIColor(hex: light ? 0xf7f5ef : name == "Black" ? 0x000000 : 0x111722)
        foreground = UIColor(hex: light ? 0x202632 : 0xe3e8f0)
        ansi = (light ? [
            0x24282e, 0xa92c3e, 0x276736, 0x805d00, 0x234c9f, 0x773e8d, 0x006c71, 0xc4c8cc,
            0x555d64, 0xc33850, 0x377d45, 0x966b00, 0x3766b2, 0x914ea7, 0x107e84, 0xf6f6f6
        ] : [
            0x202730, 0xe87583, 0x80c393, 0xe4bd75, 0x79a7e3, 0xbb96da, 0x75c4ca, 0xd1d7df,
            0x687787, 0xff96a0, 0xa4e5ad, 0xffdc96, 0x9dc6ff, 0xdcb6f7, 0x98e3e7, 0xf5f7fa
        ]).map(UIColor.init(hex:))
    }
    func indexed(_ number: Int) -> UIColor {
        let n = max(0, min(255, number))
        if n < 16 { return ansi[n] }
        if n < 232 {
            let value = n - 16
            let cube = [0, 95, 135, 175, 215, 255]
            return UIColor(hex: (cube[value / 36] << 16) | (cube[(value / 6) % 6] << 8) | cube[value % 6])
        }
        let gray = CGFloat(8 + 10 * (n - 232)) / 255
        return UIColor(white: gray, alpha: 1)
    }
}
