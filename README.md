# t3rm for rootless iOS 15

t3rm is an experimental terminal app based on NewTerm 3. It installs alongside NewTerm on rootless iOS 15.1.1 and later in the iOS 15 series. The app and Debian package use the identifier `com.davghz.t3rm`.

## Install

Download the `iphoneos-arm64.deb` for t3rm, open it in your package manager, and launch **t3rm** from the Home Screen. [Latest t3rm release](https://github.com/davghz/t3rm/releases/latest)

## Use the keyboard and tabs

- Tap the iOS keyboard microphone to dictate at the terminal cursor.
- Tap **Shift** to modify the next key. **Ctrl**, **Esc**, and the arrow keys are also on the main toolbar.
- Tap **More** to reach **Tab**, **Paste**, and the navigation keys. In OpenCode, **Paste** inserts text or attaches a clipboard image to your prompt. Tap **Fn** in the expanded row to show the function keys.
- Swipe down on the toolbar with one finger to dismiss the keyboard. Tap the terminal to bring it back.
- Tap **+** to open a tab. With iTerm2 shell integration enabled, a new tab can start in the current working directory. [iTerm2 shell integration](https://chariz.com/get/iterm2-shell-integration)

Terminal apps that enable mouse reporting receive taps on the corresponding text cell. In OpenCode, tap the **+** beside the session title to start a conversation. t3rm’s **+** in the app toolbar opens a separate shell. Tap a shell tab’s title to select it or its close icon to end it.

## Run Codex or OpenCode

Install the corresponding CLI package, then type `codex` or `opencode` at the t3rm prompt. [Codex for iOS](https://github.com/davghz/ios-codex) · [OpenCode for iOS](https://github.com/davghz/opencode-ios)

## Build the package

The release workflow uses Xcode 16.4 on macOS. With Xcode selected, run these commands from the repository root.

```sh
brew install ldid dpkg
.github/scripts/package-rootless.sh
```

The script writes the arm64 Debian package and its SHA-256 checksum to `packages/`. [Build workflow](.github/workflows/build.yml)

## Session architecture

The app forwards keyboard and paste events through `TerminalController`. Within `Common/Session`, `ShellLaunchConfiguration` selects the login program, working directory and environment. `PTYChild` connects the process to a pseudoterminal. `SubProcess` owns the live session and serializes terminal reads, writes, resizes and closure. SwiftTerm interprets the output for the display.

Run the session regression tests with the **NewTerm (iOS)** scheme on an iPhone simulator.

## Credits and license

NewTerm was developed by HASHBANG Productions. The project license and notices for earlier code, bundled fonts, and other assets are in the license file. [Upstream NewTerm](https://github.com/hbang/NewTerm) · [License and notices](LICENSE.md)
