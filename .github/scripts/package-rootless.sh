#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
build=${DERIVED_DATA_PATH:-$stage/DerivedData}
output=${1:-packages}
mkdir -p "$output" "$stage/pkg/DEBIAN" "$stage/pkg/var/jb/Applications"

xcodebuild -project NewTerm.xcodeproj -scheme 'NewTerm (iOS)' \
    -configuration Release -destination generic/platform=iOS \
    -derivedDataPath "$build" -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO INSTALL_PREFIX=/var/jb ARCHS=arm64 build

app="$stage/pkg/var/jb/Applications/t3rm.app"
ditto "$build/Build/Products/Release-iphoneos/t3rm.app" "$app"
ldid -S "$app/NewTermLoginHelper"
ldid -SApp/entitlements.plist "$app/t3rm"
sed 's/^Architecture: .*/Architecture: iphoneos-arm64/' control > "$stage/pkg/DEBIAN/control"
name=$(sed -n 's/^Package: //p' control)
version=$(sed -n 's/^Version: //p' control)
# GitHub Releases converts tildes to periods in asset names.
asset="${name}_${version//\~/.}_iphoneos-arm64.deb"
COPYFILE_DISABLE=1 dpkg-deb -Zxz --root-owner-group --build "$stage/pkg" "$output/$asset"
(cd "$output" && shasum -a 256 "$asset" > "$asset.sha256")
