#!/bin/bash
# LimitBar build: compile Swift -> .app bundle -> ad-hoc codesign
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LimitBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "[build] swiftc..."
swiftc -O -module-name LimitBar \
  -framework AppKit -framework CoreGraphics -framework UserNotifications -framework ServiceManagement -framework IOKit \
  -o "$APP/Contents/MacOS/LimitBar" \
  main.swift DFR.swift Providers.swift Advisor.swift Hermes.swift Views.swift Settings.swift Stats.swift ClaudeAuth.swift \
  BrandPaths.swift TinySVGPath.swift

cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "[build] codesign (ad-hoc)..."
codesign --force --sign - --identifier com.melvern.limitbar "$APP" 2>/dev/null

echo "[build] OK -> $APP"
