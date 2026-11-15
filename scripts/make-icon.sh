#!/bin/zsh
# Pack Rumi's icon into build/AppIcon.icns.
# The artwork is mac/AppIcon-1024.png (Rumi the mascot, rendered from web/rumi.js by scripts/render-icon.mjs).
# mac/make-icon.swift is the older three-cartridge icon, used only if the PNG is missing.
set -euo pipefail
ROOT=${0:A:h:h}
OUT=$ROOT/build; mkdir -p "$OUT"
SET=$OUT/AppIcon.iconset; rm -rf "$SET"; mkdir -p "$SET"
if [[ -f $ROOT/mac/AppIcon-1024.png ]]; then
  cp "$ROOT/mac/AppIcon-1024.png" "$OUT/icon-1024.png"
else
  swiftc -O -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" "$ROOT/mac/make-icon.swift" -o "$OUT/make-icon"
  "$OUT/make-icon" "$OUT/icon-1024.png"
fi
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$OUT/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$OUT/AppIcon.icns"
echo "✓ $OUT/AppIcon.icns"
