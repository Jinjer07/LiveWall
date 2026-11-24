#!/bin/bash
# Сборка LiveWall.app (нужны только Command Line Tools; SwiftPM не используется)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources -name '*.swift')
echo "Компиляция ${#FILES[@]} файлов…"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -O -parse-as-library \
  -module-name LiveWall "${FILES[@]}" -o build/LiveWall
APP="build/LiveWall.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/LiveWall "$APP/Contents/MacOS/LiveWall"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Готово: $(pwd)/$APP"
