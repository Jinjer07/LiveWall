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
# Постоянная подпись: macOS запоминает разрешения (звук, календарь) по сертификату,
# а не по отпечатку сборки — они не сбрасываются после пересборки и обновлений.
IDENTITY="${LIVEWALL_SIGN_IDENTITY:-LiveWall Code Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 && echo "Подписано: $IDENTITY"
else
  echo "Сертификат «$IDENTITY» не найден — подпись ad-hoc (разрешения macOS будут сбрасываться при пересборке)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Готово: $(pwd)/$APP"
