#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/build/接力剪贴板.app"
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework SwiftUI -framework Carbon -framework CryptoKit -framework ApplicationServices -framework ImageIO \
  Sources/*.swift -o "$APP/Contents/MacOS/HarmonyPanel"
/bin/cp Info.plist "$APP/Contents/Info.plist"
/bin/cp phone.py "$APP/Contents/Resources/phone.py"
/bin/cp -R Bridge "$APP/Contents/Resources/Bridge"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
echo "$APP"
