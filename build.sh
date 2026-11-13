#!/bin/bash
# Builds SnippetMenu.app, installs it to ~/Applications, and launches it.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/SnippetMenu.app"
IDENTITY="SnippetMenu Local Signing"

rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/SnippetMenu"
cp Info.plist "$APP/Contents/Info.plist"

# A stable certificate keeps the Accessibility permission across rebuilds.
# Ad-hoc signing changes the app's identity on every build.
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "注意: 証明書がないため署名なしでビルドします。ビルドのたびにアクセシビリティの再許可が必要です。"
  echo "      一度 ./scripts/setup-signing.sh を実行すると、許可が保たれるようになります。"
  codesign --force --sign - "$APP"
fi

pkill -x SnippetMenu 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/SnippetMenu.app"
ditto "$APP" "$HOME/Applications/SnippetMenu.app"
open "$HOME/Applications/SnippetMenu.app"
echo "BUILD_OK"
