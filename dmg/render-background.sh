#!/bin/bash
# Render dmg/background.html to the HiDPI background.tiff used by the DMG.
# Uses headless Chrome at 1x and 2x, then packs both into a multi-resolution
# TIFF so Finder shows it crisp on Retina. Run from the repo root; commit the
# resulting dmg/background.tiff (the .png intermediates are throwaway).
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HTML="file://$PWD/dmg/background.html"
W=760; H=472
TMP=$(mktemp -d)

render() { # scale -> out
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --default-background-color=00000000 \
    --force-device-scale-factor="$1" --window-size="$W,$H" \
    --virtual-time-budget=2500 \
    --screenshot="$2" "$HTML" >/dev/null 2>&1
}

render 1 "$TMP/bg.png"
render 2 "$TMP/bg@2x.png"
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out dmg/background.tiff
rm -rf "$TMP"
echo "wrote dmg/background.tiff"
sips -g pixelWidth -g pixelHeight dmg/background.tiff 2>/dev/null | tail -2
