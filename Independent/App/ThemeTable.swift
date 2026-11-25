import Foundation

/// Fresh t3rm swatches, keyed by persistent preference values from earlier releases.
struct ThemeSwatch {
    let name: String
    let background: Int
    let foreground: Int
    let light: Bool

    private init(_ name: String, _ background: Int, _ foreground: Int, light: Bool = false) {
        self.name = name
        self.background = background
        self.foreground = foreground
        self.light = light
    }

    static let choices: [Self] = [
        Self("Midnight", 0x111722, 0xe3e8f0),
        Self("Paper", 0xf7f5ef, 0x202632, light: true),
        Self("Black", 0x000000, 0xe3e8f0),
        Self("Basic", 0xfcfcfc, 0x252525, light: true),
        Self("Basic (Dark)", 0x161616, 0xe2e3e1),
        Self("Grass", 0x17361f, 0xe2f5cf),
        Self("Homebrew", 0x0c150e, 0x9de19b),
        Self("kirb", 0x251d31, 0xf5e8ff),
        Self("Man Page", 0xfff4d2, 0x242017, light: true),
        Self("Novel", 0xf4e6cd, 0x392b1c, light: true),
        Self("Ocean", 0x122f4a, 0xd9eefb),
        Self("Pro", 0x202125, 0xebebeb),
        Self("Red Sands", 0x432722, 0xffe8c9),
        Self("Silver Aerogel", 0xe4e8eb, 0x29323a, light: true),
        Self("VSCode", 0x1d2025, 0xd6dce2)
    ]
}
