# What ships in t3rm

The independent app, terminal engine, UIKit interface, ordinary-user session launcher, archive encoder, and icon source are developed in this directory. The build has no dependency on SwiftTerm, SwiftUIX, or the NewTerm Xcode project. The icon is generated from artwork/Icon.swift. The release package includes the rights notice from Resources/RIGHTS.txt.

The engine's behavior is tested against [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/), the [xterm protocol](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html), and [iTerm2's shell integration](https://iterm2.com/documentation-escape-codes.html). The Apple SDK supplies UIKit, Foundation, Darwin, system fonts and zlib. The package uses the user's installed shell and terminal utilities. Optional fonts supplied outside the app retain their own licenses.

The NewTerm-derived alpha3 and earlier versions keep their existing notices and licenses. Their Git history documents the original contributors and changes. See [the alpha3 notices](https://github.com/davghz/t3rm/blob/a479ba732f45f2d6d304ce42f76d99fa083b96ba/LICENSE.md).
