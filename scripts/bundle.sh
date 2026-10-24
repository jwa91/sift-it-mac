#!/usr/bin/env bash
# Builds "Sift It.app" into build/: the release binary, its Info.plist (with the commit count as its build number), its
# icon, and the sift-it release it ships with (ENGINE_VERSION) in Contents/Helpers, signed ad hoc to run on this Mac.
# A release signs it again with the Developer ID (scripts/codesign.sh); the engine's binaries keep their own signature.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
binary="$(swift build -c release --arch arm64 --show-bin-path)/SiftIt"
engine="$(scripts/fetch-engine.sh)"

app="build/Sift It.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$binary" "$app/Contents/MacOS/SiftIt"
ditto "$engine/sift-it" "$engine/sift-it-transcribe" "$app/Contents/Helpers/"
cp Resources/Info.plist "$app/Contents/Info.plist"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --timestamp=none --entitlements Resources/SiftIt.entitlements --sign - "$app"
echo "$app"
