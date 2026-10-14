#!/bin/sh
# Build a universal app, ZIP, DMG and checksum manifest. Never publishes.
set -eu
cd "$(dirname "$0")/.."
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
mkdir -p "$OUT"
STAGE=$(mktemp -d "$PWD/build/.release-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Boltbar.app"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/Boltbar.app" "$OUT/Boltbar-$VERSION-universal.zip"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Boltbar -srcfolder "$STAGE" -fs HFS+ -format UDZO "$OUT/Boltbar_${VERSION}_universal.dmg"
(
  cd "$OUT"
  shasum -a 256 "Boltbar-$VERSION-universal.zip" "Boltbar_${VERSION}_universal.dmg" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
printf 'Release artifacts: %s\n' "$OUT"
