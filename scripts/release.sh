#!/bin/zsh
# Make the download: build/Rumi.dmg, a disk image holding Rumi and a shortcut to Applications.
#   scripts/release.sh
# The version is the one in mac/Info.plist. The app is signed with the identity named in RUMI_RELEASE_ID, or in a file
# called .release-identity beside this repo's README (it isn't committed). Use the same identity for every release: macOS
# ties Full Disk Access to the signature, so people keep their access when they update. scripts/signing-setup.sh makes one.
set -euo pipefail
ROOT=${0:A:h:h}
OUT=$ROOT/build
ID=${RUMI_RELEASE_ID:-$(cat "$ROOT/.release-identity" 2>/dev/null || true)}
[[ -n $ID ]] || { echo "name the release identity in RUMI_RELEASE_ID or .release-identity (scripts/signing-setup.sh makes one)"; exit 1 }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/mac/Info.plist")

STAGE=$OUT/release
rm -rf "$STAGE" "$OUT/Rumi.dmg" "$OUT/Rumi-rw.dmg"; mkdir -p "$STAGE"   # a run that fails leaves no older download behind to be mistaken for this one
RUMI_SIGN_ID=$ID RUMI_APP_OUT=$STAGE/Rumi.app "$ROOT/scripts/build.sh"
# build.sh signs ad hoc when it can't find the identity. Fine for a build of your own, wrong for a release: an ad hoc
# signature is different every time, and everyone would lose Full Disk Access with each update
SIGNED=$(codesign -dvv "$STAGE/Rumi.app" 2>&1)
[[ $SIGNED == *$'\n'"Authority=$ID"$'\n'* ]] || { echo "not signed with \"$ID\": no release made"; exit 1 }

ln -s /Applications "$STAGE/Applications"

# The window people see when they open it: Rumi's dark screen behind the two icons, Rumi on the left and Applications on
# the right. Finder is the only thing that can save that arrangement, so the image is made writable first, opened, laid
# out, and then squeezed. If Finder isn't allowed (macOS asks once), the download still works, in Finder's plain view.
[[ ! -e /Volumes/Rumi ]] || { echo "a disk called Rumi is already open: eject it first"; exit 1 }
RW=$OUT/Rumi-rw.dmg
trap 'rm -rf "$STAGE" "$RW"' EXIT
hdiutil create -quiet -volname Rumi -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW"
mkdir /Volumes/Rumi/.background
tiffutil -cathidpicheck "$ROOT/mac/dmg-background.png" "$ROOT/mac/dmg-background@2x.png" -out /Volumes/Rumi/.background/screen.tiff 2>/dev/null
osascript >/dev/null 2>&1 <<'APPLESCRIPT' || echo "→ Finder wasn't allowed to arrange the window: it will open in the plain view"
with timeout of 60 seconds
  tell application "Finder"
    tell disk "Rumi"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 760, 508}
      set opts to the icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 96
      set text size of opts to 13
      set background picture of opts to file ".background:screen.tiff"
      set position of item "Rumi.app" of container window to {150, 178}
      set position of item "Applications" of container window to {410, 178}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end timeout
APPLESCRIPT
sync
rm -rf /Volumes/Rumi/.fseventsd
hdiutil detach -quiet /Volumes/Rumi
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT/Rumi.dmg"
hdiutil verify -quiet "$OUT/Rumi.dmg"
echo "✓ Rumi $VERSION → $OUT/Rumi.dmg ($(du -h "$OUT/Rumi.dmg" | cut -f1 | tr -d ' '))"
