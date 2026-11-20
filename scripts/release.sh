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
rm -rf "$STAGE" "$OUT/Rumi.dmg"; mkdir -p "$STAGE"   # a run that fails leaves no older download behind to be mistaken for this one
trap 'rm -rf "$STAGE"' EXIT
RUMI_SIGN_ID=$ID RUMI_APP_OUT=$STAGE/Rumi.app "$ROOT/scripts/build.sh"
# build.sh signs ad hoc when it can't find the identity. Fine for a build of your own, wrong for a release: an ad hoc
# signature is different every time, and everyone would lose Full Disk Access with each update
SIGNED=$(codesign -dvv "$STAGE/Rumi.app" 2>&1)
[[ $SIGNED == *$'\n'"Authority=$ID"$'\n'* ]] || { echo "not signed with \"$ID\": no release made"; exit 1 }

ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Rumi -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUT/Rumi.dmg"
hdiutil verify -quiet "$OUT/Rumi.dmg"
echo "✓ Rumi $VERSION → $OUT/Rumi.dmg ($(du -h "$OUT/Rumi.dmg" | cut -f1 | tr -d ' '))"
