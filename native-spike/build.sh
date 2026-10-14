#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="build/Boltbar Swift Spike.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -swift-version 5 -framework AppKit -framework SwiftUI -framework Carbon -framework Security BoltbarSpike.swift -o "$APP/Contents/MacOS/BoltbarSwiftSpike"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BoltbarSwiftSpike</string>
<key>CFBundleIdentifier</key><string>com.boltbar.swift-spike</string>
<key>CFBundleName</key><string>Boltbar Swift Spike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf '%s\n' "$PWD/$APP"
