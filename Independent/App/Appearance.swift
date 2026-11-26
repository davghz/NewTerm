import UIKit
import CoreText
import T3Engine

extension Notification.Name { static let terminalSettingsChanged = Notification.Name("TerminalSettingsChanged") }

enum Preferences {
    static let defaults = UserDefaults.standard
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static var sizeKey: String { isPad ? "fontSizePad" : "fontSizePhone" }
    static func register() {
        defaults.register(defaults: ["fontName": "Menlo-Regular", "fontSizePhone": 13, "fontSizePad": 15,
            "themeName": "Midnight", "keyboardAccessoryStyle": 0, "keyboardArrowsStyle": 0,
            "keyboardTrackpadSensitivity": 2, "bellHUD": true, "bellVibrate": false, "bellSound": false,
            "refreshRateOnAC": 60, "refreshRateOnBattery": 60, "reduceRefreshRateInLPM": true])
        var urls = (try? FileManager.default.contentsOfDirectory(at: fontsDirectory, includingPropertiesForKeys: nil)) ?? []
        for ext in ["ttf","otf","ttc"] {
            urls += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }
        for url in urls where ["ttf","otf","ttc"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
    static var fontsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fonts", isDirectory: true)
    }
    static var font: UIFont {
        let size = CGFloat(max(8, min(36, defaults.double(forKey: sizeKey))))
        let requested = defaults.string(forKey: "fontName") ?? ""
        let normalized = requested.lowercased().filter { $0.isLetter || $0.isNumber }
        if ["sfmono","sfmonoregular","system","systemmonospace"].contains(normalized) {
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if let face = UIFont(name: requested, size: size) { return face }
        for family in UIFont.familyNames {
            let faces = UIFont.fontNames(forFamilyName: family)
            let clean: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            if clean(family) == normalized {
                let face = faces.first(where: { $0.lowercased().hasSuffix("regular") }) ?? faces.first
                if let face = face, let font = UIFont(name: face, size: size) { return font }
            }
            if let match = faces.first(where: { clean($0) == normalized }), let font = UIFont(name: match, size: size) { return font }
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
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
    let isDark: Bool
    let background: UIColor
    let foreground: UIColor
    let ansi: [UIColor]
    static let names = ThemeSwatch.choices.map(\.name)
    init(name: String) {
        let swatch = ThemeSwatch.choices.first { $0.name == name } ?? ThemeSwatch.choices[0]
        let light = swatch.light
        isDark = !light
        background = UIColor(hex: swatch.background)
        foreground = UIColor(hex: swatch.foreground)
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

extension UIColor {
    var terminalRGB: TerminalColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return .rgb(Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

/// The terminal theme also supplies the surrounding controls' contrast and surfaces.
struct TerminalChrome {
    let isDark: Bool
    let surface: UIColor
    let raised: UIColor
    let stroke: UIColor
    let text: UIColor
    let secondary: UIColor
    let accent: UIColor
    let accentFill: UIColor

    static var current: Self { Self(palette: Palette(name: Preferences.defaults.string(forKey: "themeName") ?? "Midnight")) }

    init(palette: Palette) {
        isDark = palette.isDark
        let base = palette.background
        let ink = palette.foreground
        surface = base.mixed(with: ink, amount: isDark ? 0.035 : 0.025)
        raised = base.mixed(with: ink, amount: isDark ? 0.10 : 0.065)
        stroke = base.mixed(with: ink, amount: isDark ? 0.20 : 0.19)
        text = ink
        secondary = base.mixed(with: ink, amount: isDark ? 0.73 : 0.78)
        accent = UIColor(hex: isDark ? 0x63dfb4 : 0x00644d)
        accentFill = base.mixed(with: accent, amount: isDark ? 0.15 : 0.11)
    }
}

private extension UIColor {
    func mixed(with color: UIColor, amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        color.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
        return UIColor(red: r + (rr-r)*amount, green: g + (gg-g)*amount, blue: b + (bb-b)*amount, alpha: 1)
    }
}
