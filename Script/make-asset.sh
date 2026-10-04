#!/bin/bash
# Re-render the brand assets: Resource/LidCode.icns and Asset/banner.png.
#
# Both are committed, so a normal build never needs this — run it only when the
# mark or the tint changes.
#
#   ./Script/make-asset.sh            # shipping master artwork
#   ./Script/make-asset.sh E0A030     # try another
set -euo pipefail

cd "$(dirname "$0")/.."
TINT="${1:-4A7DC9}"
STAGE=".build/icon/LidCode.iconset"

rm -rf "$STAGE"
mkdir -p "$(dirname "$STAGE")" Resource Asset

if [[ $# -eq 0 ]]; then
    swift Script/makebrand.swift
fi

swift Script/makeicon.swift "${1:-Asset/app-icon.png}" "$STAGE"
iconutil -c icns "$STAGE" -o Resource/LidCode.icns
swift Script/makebanner.swift "$TINT" Asset/banner.png

# Keep browser and Add to Home Screen artwork in sync with the Mac icon.
WEB_MASTER="$STAGE/icon_512x512@2x.png"
if [[ $# -eq 0 ]]; then WEB_MASTER=".build/icon/web-master.png"; fi
sips -z 192 192 "$WEB_MASTER" --out web/public/icon-192.png >/dev/null
sips -z 512 512 "$WEB_MASTER" --out web/public/icon-512.png >/dev/null
sips -z 180 180 "$WEB_MASTER" --out web/public/apple-touch-icon.png >/dev/null

echo "==> wrote Mac icon, banner, and web icons"
