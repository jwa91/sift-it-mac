#!/usr/bin/env bash
# Builds "Sift It.app" into build/: the release binary, its Info.plist and icon, signed ad hoc to run on this Mac.
# SIGN_IDENTITY signs it with a Developer ID instead.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
binary="$(swift build -c release --arch arm64 --show-bin-path)/SiftIt"

app="build/Sift It.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/SiftIt"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$app"
echo "$app"
