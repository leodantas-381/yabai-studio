#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TARGET="$(uname -m)-apple-macosx14.0"
mkdir -p build/module-cache dist
APP="$PWD/build/Yabai Studio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Tools"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
clang -target "$TARGET" ThirdParty/skhd/src/skhd.c -std=c99 -O2 -framework Cocoa -framework Carbon -framework CoreServices -o "$APP/Contents/Resources/Tools/skhd"
cp ThirdParty/skhd/LICENSE.txt "$APP/Contents/Resources/Tools/skhd-LICENSE.txt"
codesign --force --sign - --identifier local.yabai.studio.skhd "$APP/Contents/Resources/Tools/skhd"
swiftc -target "$TARGET" -parse-as-library Sources/Navigator.swift Sources/NavigatorMain.swift -module-cache-path build/module-cache -o "$APP/Contents/Resources/Tools/space-switch"
codesign --force --sign - --identifier local.yabai.studio.navigation "$APP/Contents/Resources/Tools/space-switch"
swiftc -target "$TARGET" -parse-as-library Sources/main.swift Sources/Hotkeys.swift Sources/HotkeyConfig.swift Sources/Navigator.swift -framework SwiftUI -framework AppKit -module-cache-path build/module-cache -o "$APP/Contents/MacOS/YabaiStudio"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "App criado: $APP"
if [ "${1:-}" = "--dmg" ]; then
    STAGE="$PWD/build/dmg-stage"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/Yabai Studio.app"
    ln -sfn /Applications "$STAGE/Applications"
    hdiutil create -volname 'Yabai Studio' -srcfolder "$STAGE" -ov -format UDZO "$PWD/dist/Yabai Studio.dmg"
    hdiutil verify "$PWD/dist/Yabai Studio.dmg"
fi
