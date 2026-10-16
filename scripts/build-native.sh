#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "${BOLTBAR_UNIVERSAL:-0}" = 1 ]; then
  mkdir -p .build/universal
  for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx13.0" --scratch-path ".build/$arch"
    ARCH_BIN=$(swift build -c release --triple "$arch-apple-macosx13.0" --scratch-path ".build/$arch" --show-bin-path)
    cp "$ARCH_BIN/Boltbar" ".build/universal/Boltbar.$arch"
  done
  lipo -create .build/universal/Boltbar.arm64 .build/universal/Boltbar.x86_64 -output .build/universal/Boltbar
  BINARY=.build/universal/Boltbar
  ARTIFACTS=.build/arm64/artifacts
else
  swift build -c release
  BINARY=.build/release/Boltbar
  ARTIFACTS=.build/artifacts
fi
APP="build/Boltbar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Boltbar"
mkdir -p "$APP/Contents/Frameworks"
FRAMEWORK="$ARTIFACTS/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/AppIcon.icns "$APP/Contents/Resources/icon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Boltbar</string>
<key>CFBundleIdentifier</key><string>com.boltbar.native</string>
<key>CFBundleName</key><string>Boltbar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>icon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 scripts/configure-bundle.py "$APP/Contents/Info.plist"
IDENTITY="${BOLTBAR_SIGN_IDENTITY:--}"
# Sign nested executables inside-out; --deep signing can miss helper entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for PART in "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework" "$APP"; do
  if [ "$IDENTITY" = - ]; then
    codesign --force --sign "$IDENTITY" "$PART"
  else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$PART"
  fi
done
codesign --verify --deep --strict "$APP"
printf '%s\n' "$PWD/$APP"
