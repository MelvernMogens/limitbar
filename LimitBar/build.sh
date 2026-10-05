#!/bin/bash
# LimitBar build: compile Swift -> .app bundle -> ad-hoc codesign
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LimitBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "[build] swiftc..."
swiftc -O -framework AppKit -framework CoreGraphics -o "$APP/Contents/MacOS/LimitBar" main.swift BrandPaths.swift TinySVGPath.swift

cp Info.plist "$APP/Contents/Info.plist"

echo "[build] codesign (ad-hoc)..."
codesign --force --sign - "$APP" 2>/dev/null

echo "[build] OK -> $APP"
