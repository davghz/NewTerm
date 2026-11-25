#!/bin/bash
set -euo pipefail
output="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/T3ShellLauncher"
case "$PLATFORM_NAME" in
    iphoneos) suffix="" ;;
    iphonesimulator) suffix="-simulator" ;;
    *) exit 1 ;;
esac
mkdir -p "$(dirname "$output")" "$TARGET_TEMP_DIR/t3-helper"
objects=()
for arch in $ARCHS; do
    part="$TARGET_TEMP_DIR/t3-helper/$arch"
    xcrun clang -isysroot "$SDKROOT" -target "${arch}-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}${suffix}" \
        -O2 -Wall -Wextra "$SRCROOT/Sources/T3ShellLauncher/main.c" -o "$part"
    objects+=("$part")
done
xcrun lipo -create "${objects[@]}" -output "$output"
if [[ "$PLATFORM_NAME" == iphonesimulator ]]; then
    codesign --force --sign - "$output"
fi
