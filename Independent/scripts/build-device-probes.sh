#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:?provide a build output directory}
mkdir -p "$out/T3PTY"
out=$(cd "$out" && pwd)
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
target=arm64-apple-ios15.1.1
cp Sources/T3PTY/include/*.h "$out/T3PTY"
printf 'module T3PTY { header "T3PTY.h" export * }\n' > "$out/T3PTY/module.modulemap"
xcrun clang -target "$target" -isysroot "$sdk" -O2 -I"$out/T3PTY" -c Sources/T3PTY/T3PTY.c -o "$out/pty.o"
xcrun clang -target "$target" -isysroot "$sdk" -O2 Sources/T3ShellLauncher/main.c -o "$out/T3ShellLauncher"
swift=(xcrun swiftc -target "$target" -sdk "$sdk" -O -swift-version 5 -I "$out" -I "$out/T3PTY")
for mod in T3Engine T3Sessions; do
    "${swift[@]}" -module-name "$mod" -emit-library -static -emit-module \
        -emit-module-path "$out/$mod.swiftmodule" Sources/"$mod"/*.swift -o "$out/lib$mod.a"
done
"${swift[@]}" -L "$out" -lT3Engine -lT3Sessions "$out/pty.o" Tools/SessionProbe/main.swift -o "$out/session-probe"
"${swift[@]}" -L "$out" -lT3Engine Sources/T3Replay/main.swift -o "$out/t3rm-replay"
for binary in session-probe T3ShellLauncher t3rm-replay; do ldid -S "$out/$binary"; done
