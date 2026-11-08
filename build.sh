#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=DockDDC.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -framework Cocoa -framework IOKit -o "$APP/Contents/MacOS/DockDDC" Sources/*.swift
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "built $APP"
