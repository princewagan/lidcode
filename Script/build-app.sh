#!/bin/bash
# Assemble LidCode.app from the SwiftPM build.
#
# SwiftPM emits a bare executable; MenuBarExtra needs a real bundle with an
# Info.plist (LSUIElement=1 keeps it out of the Dock and the app switcher).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="dist/LidCode.app"

# Stamped into the bundle so Finder cannot disagree with what `lidcode --version`
# prints — both come from LidCodeVersion.current, which the release workflow
# rewrites from the tag. BUILD is a monotonic counter CI supplies; locally it is
# meaningless and stays 1.
VERSION="${VERSION:-$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/LidCodeKit/Model/LidCodeVersion.swift)}"
BUILD="${BUILD:-1}"
[[ -n "$VERSION" ]] || { echo "could not read version from Sources/LidCodeKit/Model/LidCodeVersion.swift" >&2; exit 1; }

echo "==> building ($CONFIG)"
swift build -c "$CONFIG" --product LidCodeApp
# Bundled so the app can install the helper itself. Without this the only route to
# closed-lid mode is a Terminal, a clone of this repo, and a shell script — which is
# what the menu used to say in an error banner after letting you click a control that
# could never have worked.
swift build -c "$CONFIG" --product lidcode-helper
# The CLI rides along so a downloaded .app is a complete install — otherwise the
# only route to `lidcode` is a clone and a toolchain, which is not an install path
# to put in front of somebody who just downloaded a zip.
swift build -c "$CONFIG" --product lidcode

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
# Built as LidCodeApp so it cannot collide with the `lidcode` CLI on a case-insensitive
# filesystem; it becomes plain LidCode inside the bundle.
cp ".build/$CONFIG/LidCodeApp" "$APP/Contents/MacOS/LidCode"
cp ".build/$CONFIG/lidcode-helper" "$APP/Contents/Helpers/lidcode-helper"
cp ".build/$CONFIG/lidcode" "$APP/Contents/Helpers/lidcode"
# Committed, so a normal build never re-renders it — see Script/make-asset.sh.
cp "Resource/LidCode.icns" "$APP/Contents/Resources/LidCode.icns"
cp -R Resource/ProviderIcons "$APP/Contents/Resources/ProviderIcons"
cp docs/OpenUsage-LICENSE.txt "$APP/Contents/Resources/OpenUsage-LICENSE.txt"

# Installer for the bundled helper. Runs *as root* in its entirety (the app asks for
# authorisation once, through the system prompt), so there is no `sudo` in here — and
# no `swift build` either, because an installed .app has no toolchain and no sources.
cat > "$APP/Contents/Resources/install-helper.sh" <<'INSTALLER'
#!/bin/bash
set -euo pipefail

LABEL="com.lidcode.helper"
BIN="/usr/local/libexec/lidcode-helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
OWNER_UID="${1:?usage: install-helper.sh <uid>}"
SRC="$(cd "$(dirname "$0")/.." && pwd)/Helpers/lidcode-helper"

[[ -x "$SRC" ]] || { echo "bundled helper missing at $SRC" >&2; exit 1; }
[[ "$OWNER_UID" =~ ^[0-9]+$ ]] || { echo "uid must be numeric" >&2; exit 1; }

mkdir -p "$(dirname "$BIN")" /var/db/lidcode
cp "$SRC" "$BIN"
chown root:wheel "$BIN"
chmod 755 "$BIN"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>--uid</string>
    <string>$OWNER_UID</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/lidcode-helper.log</string>
</dict>
</plist>
PLIST

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

for _ in $(seq 1 20); do
  [[ -S /var/run/lidcode-helper.sock ]] && exit 0
  sleep 0.25
done
echo "socket did not appear — check /var/log/lidcode-helper.log" >&2
exit 1
INSTALLER
chmod +x "$APP/Contents/Resources/install-helper.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Lidcode</string>
  <key>CFBundleDisplayName</key>       <string>Lidcode</string>
  <key>CFBundleIdentifier</key>        <string>com.bygelo.lidcode</string>
  <key>CFBundleExecutable</key>        <string>LidCode</string>
  <key>CFBundleIconFile</key>          <string>LidCode</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <!-- Menu-bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key>               <true/>
  <key>NSHumanReadableCopyright</key>  <string>MIT</string>
</dict>
</plist>
PLIST

# A signature gives the notification and login-item APIs a stable identity. Use a
# real one when the machine has it: an ad-hoc signature gets a fresh cdhash on
# every build, which reads as a different app each time. CI has no identity and
# falls back to ad-hoc, which is why releases tell users to clear quarantine.
#
# The **SHA-1 hash**, not the human-readable name. A developer with two certificates
# for the same Apple ID — which is the normal state after a machine transfer or a
# certificate renewal — has two identities with byte-identical names, and codesign
# rejects a name that matches more than one with "ambiguous (matches ...)". That is
# not a signing failure anyone reads as a *name* problem, so it silently fell through
# to the `||` branch and produced an unsigned bundle on every build.
SIGN="${SIGN:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n '1s/^[^)]*) \([0-9A-F]*\).*/\1/p')}"
SIGN="${SIGN:--}"

# Errors are shown, not swallowed. `2>/dev/null` here is what hid the ambiguity above:
# the build printed a tidy "skipped" line for a failure whose message said exactly what
# was wrong.
sign() {
  codesign --force --sign "$SIGN" "$1" || { echo "!! codesign failed for $1" >&2; return 1; }
}

# The nested helper is its own Mach-O and has to be signed before the bundle
# that contains it, or `codesign --verify --deep` rejects the result.
sign "$APP/Contents/Helpers/lidcode-helper"
sign "$APP/Contents/Helpers/lidcode"
sign "$APP"

echo "==> built $APP"
echo "    open $APP"
