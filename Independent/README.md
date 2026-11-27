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

Tap the selected terminal to type. In a split view, tap another pane once to select it, then tap it again to open its keyboard. To dismiss the keyboard, drag from either pane onto the keys. The pane you were typing in stays selected and keeps its draft.

Use **+** for another shell and the magnifying glass to find text. Open **…** for **Split Pane** or **Settings** on a narrow screen. Wider windows show these controls directly. Settings previews the selected theme and font and supports importing fonts.

Swipe up or down in Codex to scroll the conversation. To select text, hold one finger still for about a second, then drag and lift to copy. In a regular shell, the same hold opens transcript selection.

Tap the microphone on the iOS keyboard to dictate at the terminal cursor. If the cursor follows a word, t3rm separates it from the next dictated word with a space. Dictating after an existing space preserves that spacing.

The keyboard toolbar keeps Ctrl, Esc, Shift, More and the four arrows within reach. Tap **More** for Tab, Paste and navigation keys. Swipe the upper row sideways to reach Alt, Fn and additional keys. Shift applies to the next keystroke. For example, tap **Shift**, then **Tab** in the upper row to send Shift+Tab. To hide the keyboard, swipe down from the toolbar or drag from the transcript onto the keyboard. Tap the transcript or message box once to bring it back.

In the local Codex CLI, use **More → Paste** or **Ctrl+V** to paste text into the draft or attach a copied image. With the keyboard hidden, use **… → Paste**.

The app starts the current account's local shell. OpenCode, Codex and Claude Code use their own installed CLI packages. Session history belongs to the terminal process and can be lost when iOS terminates the app. The app processes hidden tabs while iOS allows it to run.

See the [rights notice](Resources/RIGHTS.txt) and [component and asset provenance](PROVENANCE.md).
