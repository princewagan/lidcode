#!/bin/bash
# Re-render the brand assets: Resource/LidCode.icns and Asset/banner.png.
#
# Both are committed, so a normal build never needs this — run it only when the
# mark or the tint changes.
#
#   ./Script/make-asset.sh            # teal, the shipping tint
#   ./Script/make-asset.sh E0A030     # try another
set -euo pipefail

cd "$(dirname "$0")/.."
TINT="${1:-2F7E7A}"
STAGE=".build/icon/LidCode.iconset"

rm -rf "$STAGE"
mkdir -p "$(dirname "$STAGE")" Resource Asset

swift Script/makeicon.swift "$TINT" "$STAGE"
iconutil -c icns "$STAGE" -o Resource/LidCode.icns
swift Script/makebanner.swift "$TINT" Asset/banner.png

echo "==> wrote Resource/LidCode.icns and Asset/banner.png — tint #$TINT"
