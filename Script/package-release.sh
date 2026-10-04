#!/bin/bash
# Reproducible complete download: app, bundled CLI/helper, DMG, ZIP and checksums.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/LidCodeKit/Model/LidCodeVersion.swift)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { echo "Invalid version" >&2; exit 1; }
export VERSION
bash Script/build-app.sh release
APP="dist/LidCode.app"
for binary in Contents/MacOS/LidCode Contents/Helpers/lidcode Contents/Helpers/lidcode-helper; do
    test -x "$APP/$binary"
    lipo -archs "$APP/$binary" | grep -qw arm64
 done
for resource in LidCode.icns install-helper.sh ProviderIcons/claude.svg ProviderIcons/codex.svg OpenUsage-LICENSE.txt; do
    test -f "$APP/Contents/Resources/$resource"
done
codesign --verify --deep --strict "$APP"
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
CLI_VERSION=$("$APP/Contents/Helpers/lidcode" --version)
[[ "$PLIST_VERSION" == "$VERSION" && "$CLI_VERSION" == "$VERSION" ]]

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/lidcode-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/LidCode.app"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.md "$STAGE/Read Me.txt"
DMG="dist/Lidcode-$VERSION.dmg"
ZIP="dist/Lidcode-$VERSION.zip"
rm -f "$DMG" "$ZIP"
hdiutil create -volname "Lidcode" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "Lidcode-$VERSION.dmg" "Lidcode-$VERSION.zip" > SHA256SUMS.txt)
echo "Release artifacts verified"
echo "$DMG"
echo "$ZIP"
