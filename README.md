# t3rm

t3rm is a native terminal for rootless iOS 15.1.1 and later in the iOS 15 series, maintained by davghz. The current implementation includes an independently developed terminal engine, a UIKit renderer and local shell sessions. It supports iPhone tabs, resizable iPad panes, scrollback search, selection, and shell integration.

## Build and install

Use Xcode 16.4 on macOS. Install the build tools, run the tests, and build the isolated review package:

```sh
brew install xcodegen ldid dpkg
make test
make review
```

Review packages install beside the existing app. To build an in-place upgrade for `com.davghz.t3rm`, run `make package`. The packages and SHA-256 checksums are written to `packages/`. Alpha3 and earlier binaries use the original NewTerm-derived codebase. [Published releases](https://github.com/davghz/t3rm/releases)

## Use t3rm

Tap the terminal to type. Use **+** for a shell tab and the magnifying glass to search. On a narrow screen, the **…** menu contains **Split Pane** and **Settings**. Wider windows show both controls in the tab bar. The keyboard shelf keeps **Esc**, **Ctrl**, **Alt**, and **Fn** within reach. Locally installed Claude Code, Codex, OpenCode, and terminal editors run in ordinary shell sessions.

[Build instructions and simulator tests](Independent/README.md) · [Physical-device checks](Independent/DeviceQA) · [Report an issue](https://github.com/davghz/t3rm/issues)

## Credits

Earlier versions of t3rm were based on NewTerm by HASHBANG Productions. The Git history preserves that work. The independent build and its included components are described in the [provenance record](Independent/PROVENANCE.md) and [rights notice](LICENSE.md).
