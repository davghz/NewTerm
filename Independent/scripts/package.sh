#!/bin/bash
set -euo pipefail
umask 022
cd "$(dirname "$0")/.."
variant=${1:-review}
output=${2:-"$PWD/../packages"}
case "$variant" in
    review) identifier=com.davghz.t3rm.review; display='t3rm Review'; scheme=t3rm-review-ssh ;;
    production) identifier=com.davghz.t3rm; display=t3rm; scheme=t3rm-ssh ;;
    *) echo "Usage: package.sh {review|production} [output-directory]" >&2; exit 2 ;;
esac
mkdir -p "$output"
output=$(cd "$output" && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
derived=${DERIVED_DATA_PATH:-"$temp/build"}
xcodegen generate --spec project.yml
xcodebuild -project T3rm.xcodeproj -scheme T3rm -configuration Release \
    -destination generic/platform=iOS -derivedDataPath "$derived" ARCHS=arm64 \
    CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER="$identifier" \
    T3_DISPLAY_NAME="$display" T3_URL_SCHEME="$scheme" build
app="$temp/deb/var/jb/Applications/$identifier.app"
mkdir -p "$temp/deb/DEBIAN" "$(dirname "$app")"
if [[ "$variant" == production ]]; then app="$temp/deb/var/jb/Applications/t3rm.app"; fi
ditto "$derived/Build/Products/Release-iphoneos/t3rm.app" "$app"
ldid -S "$app/T3ShellLauncher"
ldid -S"packaging/terminal.entitlements" "$app/t3rm"
# Xcode can reuse products from a build with a restrictive umask.
chmod -R a+rX "$app"
version=0.2.0~alpha2-3
cat > "$temp/deb/DEBIAN/control" <<EOF
Package: $identifier
Name: $display
Version: $version
Architecture: iphoneos-arm64
Maintainer: davghz <davghz@users.noreply.github.com>
Section: Terminal Support
Depends: firmware (>= 15.1.1), zsh | bash | fish
Recommends: iterm2-shell-integration
Homepage: https://github.com/davghz/t3rm
Description: Native terminal with an independently developed VT engine for rootless iOS 15.
EOF
asset="${identifier}_${version//\~/.}_iphoneos-arm64.deb"
COPYFILE_DISABLE=1 dpkg-deb --root-owner-group -Zxz --build "$temp/deb" "$output/$asset"
(cd "$output" && shasum -a 256 "$asset" > "$asset.sha256")
