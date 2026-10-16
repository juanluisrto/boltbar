#!/bin/sh
# Build a universal app, ZIP, DMG and checksum manifest. Never publishes.
set -eu
cd "$(dirname "$0")/.."
# Public updates must have a stable Developer ID identity and notarization.
: "${BOLTBAR_SIGN_IDENTITY:?Set BOLTBAR_SIGN_IDENTITY to a Developer ID Application identity}"
: "${BOLTBAR_NOTARY_PROFILE:?Set BOLTBAR_NOTARY_PROFILE to a notarytool Keychain profile}"
BOLTBAR_UNIVERSAL=1 sh scripts/build-native.sh
APP="$PWD/build/Boltbar.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUT="$PWD/build/releases/v$VERSION"
[ ! -e "$OUT" ] || { printf 'Refusing to overwrite %s\n' "$OUT" >&2; exit 1; }
ARCHS=$(lipo -archs "$APP/Contents/MacOS/Boltbar")
for ARCH in arm64 x86_64; do
  case " $ARCHS " in
    *" $ARCH "*) ;;
    *) printf 'Missing architecture: %s\n' "$ARCH" >&2; exit 1 ;;
  esac
done
codesign --verify --deep --strict "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'Authority=Developer ID Application:' || {
  printf 'Public releases require Developer ID Application signing.\n' >&2; exit 1;
}
NOTARY_ZIP="$PWD/build/Boltbar-notarization.zip"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$BOLTBAR_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
mkdir -p "$OUT"
STAGE=$(mktemp -d "$PWD/build/.release-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Boltbar.app"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/Boltbar.app" "$OUT/Boltbar-$VERSION-universal.zip"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Boltbar -srcfolder "$STAGE" -fs HFS+ -format UDZO "$OUT/Boltbar_${VERSION}_universal.dmg"
xcrun notarytool submit "$OUT/Boltbar_${VERSION}_universal.dmg" --keychain-profile "$BOLTBAR_NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT/Boltbar_${VERSION}_universal.dmg"
xcrun stapler validate "$OUT/Boltbar_${VERSION}_universal.dmg"
# Generate from the ZIP only, so each build has a single update enclosure.
FEED_STAGE=$(mktemp -d "$PWD/build/.appcast-stage.XXXXXX")
trap 'rm -rf "$STAGE" "$FEED_STAGE"' EXIT
cp "$OUT/Boltbar-$VERSION-universal.zip" "$FEED_STAGE/"
.build/arm64/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account com.boltbar.native --maximum-deltas 0 \
  --download-url-prefix "https://github.com/juanluisrto/boltbar/releases/download/v$VERSION/" \
  "$FEED_STAGE"
cp "$FEED_STAGE/appcast.xml" "$OUT/appcast.xml"
(
  cd "$OUT"
  shasum -a 256 "Boltbar-$VERSION-universal.zip" "Boltbar_${VERSION}_universal.dmg" appcast.xml > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
printf 'Release artifacts: %s\n' "$OUT"
