#!/usr/bin/env bash
# build-app-bundle.sh
#
# Assembles WarpMonitor.app from the SPM release binary.
# This wraps the bare WarpMonitorApp executable in a minimal .app bundle so that:
#   - macOS treats it as a proper application (Finder-launchable, Gatekeeper-ready)
#   - LSUIElement=YES suppresses the Dock icon
#   - SMAppService.mainApp can register it as a login item
#
# Usage (run from mac-app/ directory):
#   chmod +x build-app-bundle.sh
#   ./build-app-bundle.sh
#
# Output:
#   ./WarpMonitor.app  — drag to /Applications to install
#
# Requirements: Swift toolchain (swift build), codesign (Xcode CLI tools)
# No Xcode project required. No developer account required (ad-hoc signing).
#
# NOTE: App Sandbox is intentionally NOT enabled. Warp's group container path is only
# accessible without sandboxing. See plan §"Xcode Project Settings".

set -euo pipefail

BUNDLE_ID="ph.advo.warp-monitor"
APP_NAME="WarpMonitor"
BINARY_NAME="WarpMonitorApp"
MIN_OS="14.0"

# ── 1. Build release binary ────────────────────────────────────────────────────
echo "==> Building release binary..."
swift build -c release --product "${BINARY_NAME}"

BINARY=".build/release/${BINARY_NAME}"
if [[ ! -f "${BINARY}" ]]; then
    echo "ERROR: Build succeeded but binary not found at ${BINARY}" >&2
    exit 1
fi

# ── 2. Assemble .app bundle structure ─────────────────────────────────────────
APP_DIR="${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

echo "==> Assembling ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Copy binary
cp "${BINARY}" "${MACOS_DIR}/${APP_NAME}"

# ── 3. Write Info.plist ────────────────────────────────────────────────────────
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Warp Monitor</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_OS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# ── 4. Codesign ───────────────────────────────────────────────────────────────
#
# Prefer a real signing identity over ad-hoc, because of how TCC works.
#
# An ad-hoc signature ("-") is derived from the binary's own hash, so every
# rebuild produces a different code identity. macOS treats that as a brand new
# app and silently revokes anything already granted to it — most painfully Full
# Disk Access, which this app needs to read Warp's SQLite database in its Group
# Container. The symptom is nasty: the app launches, the menu bar icon appears,
# and it then hangs forever inside sqlite3_open_v2 without ever erroring.
#
# Signing with a stable certificate instead means TCC keys on that certificate
# plus the bundle id, both of which survive a rebuild. Grant Full Disk Access
# once and it keeps working across future updates.
#
# An Apple Development certificate is enough — this app only ever runs on this
# Mac. Distribution to other machines would still need a Developer ID plus
# notarization.
# Match by certificate SHA-1, not by name: a keychain can hold several
# certificates with the identical display name, and codesign then refuses with
# "ambiguous (matches ... and ...)". Sorting the hashes keeps the choice
# deterministic across runs, which matters because switching certificates
# between builds would reset TCC just like ad-hoc signing does.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '[0-9A-F]{40}' | sort -u | head -1)"

if [[ -n "${SIGN_ID}" ]]; then
    SIGN_NAME="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "${SIGN_ID}" | sed -E 's/.*"(.*)".*/\1/' | head -1)"
    echo "==> Codesigning ${APP_DIR} with: ${SIGN_NAME}"
    echo "    cert ${SIGN_ID}"
    echo "    (stable identity — Full Disk Access will survive rebuilds)"
else
    SIGN_ID="-"
    echo "==> No developer certificate found; ad-hoc codesigning ${APP_DIR}..."
    echo "    WARNING: ad-hoc signatures change on every build, so macOS will"
    echo "    revoke Full Disk Access and the app will hang on launch until you"
    echo "    re-grant it in System Settings → Privacy & Security."
fi

# No 2>/dev/null here: this step silently falling back to an unsigned bundle is
# exactly the failure that costs an hour of debugging a "hanging" app later.
if ! codesign --force --deep --sign "${SIGN_ID}" \
        --entitlements entitlements.plist "${APP_DIR}"; then
    echo "ERROR: codesign failed for ${APP_DIR}" >&2
    exit 1
fi

# Confirm the signature actually took. A bundle that reports the linker's
# ad-hoc signature here did NOT get signed with the certificate above.
if codesign -dv "${APP_DIR}" 2>&1 | grep -q "adhoc"; then
    if [[ "${SIGN_ID}" != "-" ]]; then
        echo "ERROR: ${APP_DIR} is still ad-hoc signed after signing with ${SIGN_ID}" >&2
        exit 1
    fi
fi

echo ""
echo "==> Done: ${APP_DIR}"
echo ""
echo "Next steps:"
echo "  1. Move to Applications:  mv ${APP_DIR} /Applications/"
echo "  2. Launch it:             open /Applications/${APP_NAME}.app"
echo "  3. Click the terminal icon in the menu bar."
echo "  4. Use the 'Launch at login' toggle in the popover."
echo ""
echo "Note: macOS may warn 'app cannot be opened because it is from an unidentified developer'."
echo "To bypass: System Settings → Privacy & Security → scroll down → 'Open Anyway'."
echo "Or: xattr -rd com.apple.quarantine /Applications/${APP_NAME}.app"
