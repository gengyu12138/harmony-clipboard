#!/bin/zsh
set -eu
cd "${0:A:h}"
ICON_SOURCE="$PWD/Resources/AppIcon.png"
ICON_WORK=$(mktemp -d)
trap '/bin/rm -rf "$ICON_WORK"' EXIT
mkdir "$ICON_WORK/AppIcon.iconset"
for POINTS in 16 32 128 256 512; do
  /usr/bin/sips -z "$POINTS" "$POINTS" "$ICON_SOURCE" --out "$ICON_WORK/AppIcon.iconset/icon_${POINTS}x${POINTS}.png" >/dev/null
  PIXELS=$(( POINTS * 2 ))
  /usr/bin/sips -z "$PIXELS" "$PIXELS" "$ICON_SOURCE" --out "$ICON_WORK/AppIcon.iconset/icon_${POINTS}x${POINTS}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$ICON_WORK/AppIcon.icns"
APP="$PWD/build/接力剪贴板.app"
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework SwiftUI -framework Carbon -framework CryptoKit -framework ApplicationServices -framework ImageIO -framework VisionKit \
  Sources/*.swift -o "$APP/Contents/MacOS/HarmonyPanel"
/bin/cp Info.plist "$APP/Contents/Info.plist"
/bin/cp "$ICON_WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/bin/cp phone.py "$APP/Contents/Resources/phone.py"
/bin/cp -R Bridge "$APP/Contents/Resources/Bridge"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
echo "$APP"
