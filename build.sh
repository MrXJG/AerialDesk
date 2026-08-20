#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/build/AerialDesk.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -target arm64-apple-macos14.0 \
  -parse-as-library -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework IOKit \
  -framework ServiceManagement \
  "$ROOT"/Sources/*.swift \
  -o "$APP/Contents/MacOS/AerialDesk"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signing is enough for local development. Distribution builds should
# use the developer's own Apple Developer identity and notarization workflow.
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
echo "Run:   open '$APP'"

