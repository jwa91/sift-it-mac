#!/usr/bin/env bash
# Fetches the sift-it release the app ships with (ENGINE_VERSION) into .build/engine/<version>/, once per version:
# its binaries as the release has them, signed with a Developer ID and notarized, after checking the archive against
# the release's checksums and each binary's signature. Prints the folder.
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(tr -d '[:space:]' < ENGINE_VERSION)"
folder=".build/engine/$version"
binaries=(sift-it sift-it-transcribe)
if [[ -x "$folder/sift-it" && -x "$folder/sift-it-transcribe" ]]; then
  echo "$folder"
  exit 0
fi

base="https://github.com/jwa91/sift-it/releases/download/v$version"
archive="sift-it_${version}_darwin_arm64.tar.gz"
stage="$(mktemp -d -t sift-it-engine)"
trap 'rm -rf "$stage"' EXIT
curl -fsSL --retry 3 "$base/$archive" -o "$stage/$archive"
curl -fsSL --retry 3 "$base/checksums.txt" -o "$stage/checksums.txt"
(cd "$stage" && shasum -a 256 -c checksums.txt > /dev/null) || {
  echo "fetch-engine: $archive doesn't match the release's checksum" >&2
  exit 1
}
tar -xzf "$stage/$archive" -C "$stage" "${binaries[@]}"
for binary in "${binaries[@]}"; do
  codesign --verify --strict "$stage/$binary"
  signature="$(codesign -dvv "$stage/$binary" 2>&1)"
  grep -q "^Authority=Developer ID Application" <<< "$signature" && grep -q "flags=.*runtime" <<< "$signature" || {
    echo "fetch-engine: $binary isn't signed with a Developer ID and hardened runtime" >&2
    exit 1
  }
done

rm -rf "$folder"
mkdir -p "$folder"
for binary in "${binaries[@]}"; do mv "$stage/$binary" "$folder/"; done
echo "$folder"
