#!/bin/zsh
set -eu
cd "${0:A:h}"
TEST_DEVELOPER="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
TEST_PLATFORM="$TEST_DEVELOPER/Platforms/MacOSX.platform/Developer"
if [[ ! -d "$TEST_PLATFORM/Library/Frameworks/XCTest.framework" ]]; then
  TEST_PLATFORM="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer"
fi
if [[ ! -d "$TEST_PLATFORM/Library/Frameworks/XCTest.framework" ]]; then
  print -u2 '原生测试需要完整 Xcode；可用 DEVELOPER_DIR 指定位置。应用运行不需要 Xcode。'
  exit 1
fi
TEST_WORK=$(mktemp -d)
trap '/bin/rm -rf "$TEST_WORK"' EXIT
/usr/bin/swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macosx14.0 \
  -F "$TEST_PLATFORM/Library/Frameworks" -I "$TEST_PLATFORM/usr/lib" -L "$TEST_PLATFORM/usr/lib" \
  -Xlinker -rpath -Xlinker "$TEST_PLATFORM/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$TEST_PLATFORM/usr/lib" \
  -framework XCTest -framework AppKit -framework SwiftUI -framework VisionKit \
  Sources/Clip.swift Sources/SnippetBackup.swift Sources/SnippetStore.swift Sources/TextOperations.swift \
  Sources/LiveTextImage.swift Sources/ImageRecognition.swift Tests/*.swift -o "$TEST_WORK/NativeTests"
"$TEST_WORK/NativeTests"
