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
else
  swift build -c release
  BINARY=.build/release/Boltbar
fi
APP="build/Boltbar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Boltbar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/icon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Boltbar</string>
<key>CFBundleIdentifier</key><string>com.boltbar.native</string>
<key>CFBundleName</key><string>Boltbar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>icon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${BOLTBAR_SIGN_IDENTITY:--}" "$APP"
printf '%s\n' "$PWD/$APP"
