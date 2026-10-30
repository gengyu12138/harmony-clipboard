#!/bin/zsh
set -eu
cd "${0:A:h}"
./test.sh
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
PACKAGE="HarmonyClipboard-${VERSION}-macOS-arm64"
STAGE=$(mktemp -d)
trap '/bin/rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$PACKAGE" release
/usr/bin/ditto --norsrc --noextattr build/接力剪贴板.app "$STAGE/$PACKAGE/接力剪贴板.app"
/bin/cp install.command installer.py README.md LICENSE CHANGELOG.md "$STAGE/$PACKAGE/"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$STAGE/$PACKAGE" "release/$PACKAGE.zip"
(cd release && /usr/bin/shasum -a 256 "$PACKAGE.zip" > "$PACKAGE.zip.sha256")
echo "$PWD/release/$PACKAGE.zip"
