#!/bin/bash
# Builds SnippetMenu.app, installs it to ~/Applications, and launches it.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/SnippetMenu.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/SnippetMenu"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
pkill -x SnippetMenu 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/SnippetMenu.app"
ditto "$APP" "$HOME/Applications/SnippetMenu.app"
open "$HOME/Applications/SnippetMenu.app"
echo "BUILD_OK"
