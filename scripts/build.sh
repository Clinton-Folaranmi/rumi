#!/bin/zsh
# Build Rumi.app with the Command Line Tools only (no Xcode, no SwiftPM).
#   scripts/build.sh            → build/Rumi.app
#   scripts/build.sh --install  → also replace /Applications/Rumi.app and open it
set -euo pipefail
ROOT=${0:A:h:h}
OUT=$ROOT/build
APP=${RUMI_APP_OUT:-$OUT/Rumi.app}   # scripts/release.sh builds its copy somewhere else
# A stable signature keeps Full Disk Access across rebuilds. Name a code-signing identity from your keychain in RUMI_SIGN_ID,
# or in a file called .signing-identity beside this repo's README (it isn't committed). Without one the app is signed ad hoc:
# it runs, but macOS asks for Full Disk Access again after each build.
IDENTITY=${RUMI_SIGN_ID:-$(cat "$ROOT/.signing-identity" 2>/dev/null || echo "-")}

mkdir -p "$OUT"
[[ -f $OUT/AppIcon.icns && $OUT/AppIcon.icns -nt $ROOT/mac/AppIcon-1024.png ]] || "$ROOT/scripts/make-icon.sh"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "→ compiling"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" \
  "$ROOT"/mac/Sources/*.swift -o "$APP/Contents/MacOS/Rumi"
cp "$ROOT/mac/Info.plist" "$APP/Contents/Info.plist"
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
rsync -a --delete --exclude .DS_Store --exclude mascot.html "$ROOT/web/" "$APP/Contents/Resources/web/"
echo "→ signing with \"$IDENTITY\""
codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null || {
  echo "→ no \"$IDENTITY\" identity in the keychain: signing ad hoc"
  codesign --force --deep --sign - "$APP"
}
echo "✓ built $APP"

if [[ ${1:-} == --install ]]; then
  osascript -e 'tell application id "com.clinton.rumi" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/Rumi.app
  ditto "$APP" /Applications/Rumi.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Rumi.app
  echo "✓ installed /Applications/Rumi.app"
  open /Applications/Rumi.app
fi
