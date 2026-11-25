# t3rm

An independently developed native terminal for rootless iOS 15.1.1 and later in the iOS 15 series, maintained by davghz. The app and parser are built from the sources in this directory.

## Build and test

Use Xcode 16.4 and install the command-line dependencies with `brew install xcodegen ldid dpkg`. From the repository root, run:

```sh
swift test --package-path Independent -c release
xcodegen generate --spec Independent/project.yml
open Independent/T3rm.xcodeproj
Independent/scripts/package.sh review
Independent/scripts/package.sh production
```

The review package has its own app identifier, preferences, and SSH URL scheme. The production package upgrades `com.davghz.t3rm` in place. Verify either package with its checksum and `Independent/scripts/check-package.py`. Use the T3rm scheme to run UI tests on an iPhone or iPad simulator.

## Use

Tap the terminal to type. Use **+** for another shell, the split button for another pane, and the magnifying glass to find text. Long-press terminal text for selection and copying. The keyboard toolbar provides modifiers, arrow keys, paste, and function keys. Terminal applications receive mouse input when they request it. Optional fonts can be imported in Settings.

The app starts the current account's local shell. OpenCode, Codex and Claude Code use their own installed CLI packages. Session history belongs to the terminal process and can be lost when iOS terminates the app. The app processes hidden tabs while iOS allows it to run.

See the [rights notice](Resources/RIGHTS.txt) and [component and asset provenance](PROVENANCE.md).
