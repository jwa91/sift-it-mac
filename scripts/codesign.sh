#!/usr/bin/env bash
# Signs Sift It.app with a Developer ID and notarizes it, with what this Mac's keychain holds, as Apple intends:
#   - a "Developer ID Application" certificate with its private key. With exactly one, that's the one; with several,
#     SIFT_IT_SIGN_IDENTITY names it (its name or SHA-1).
#   - a notarytool keychain profile: "notarytool", or the one SIFT_IT_NOTARY_PROFILE names.
# The same as sift-it's: a Mac that releases sift-it can release this. The repo holds no credentials and no references
# to any.
#
#   scripts/codesign.sh <app>     sign it, notarize it, and staple the ticket to it
#   scripts/codesign.sh --check   check that this Mac can (make release runs it before building)
set -euo pipefail

profile="${SIFT_IT_NOTARY_PROFILE:-notarytool}"
entitlements="$(cd "$(dirname "$0")/.." && pwd)/Resources/SiftIt.entitlements"

# The certificate to sign with: its SHA-1, or what SIFT_IT_SIGN_IDENTITY says.
identity() {
  if [ -n "${SIFT_IT_SIGN_IDENTITY:-}" ]; then
    echo "$SIFT_IT_SIGN_IDENTITY"
    return
  fi
  local found count
  found="$(security find-identity -v -p codesigning | grep '"Developer ID Application' || true)"
  count="$(printf '%s' "$found" | grep -c . || true)"
  case "$count" in
    0)
      echo "codesign: no Developer ID Application certificate (with its private key) in this Mac's keychain" >&2
      return 1
      ;;
    1) printf '%s\n' "$found" | awk '{print $2}' ;;
    *)
      echo "codesign: several Developer ID Application certificates; name one in SIFT_IT_SIGN_IDENTITY:" >&2
      printf '%s\n' "$found" >&2
      return 1
      ;;
  esac
}

check() {
  command -v xcrun > /dev/null || {
    echo "codesign: xcrun missing; install Xcode's command line tools" >&2
    return 1
  }
  identity > /dev/null
  xcrun notarytool history --keychain-profile "$profile" > /dev/null 2>&1 || {
    echo "codesign: no working notarytool keychain profile \"$profile\"" \
      "(xcrun notarytool store-credentials $profile)" >&2
    return 1
  }
}

if [ "${1:-}" = "--check" ]; then
  check
  echo "codesign: this Mac can sign and notarize"
  exit 0
fi

app="${1:?usage: scripts/codesign.sh <app> | --check}"
check
codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$(identity)" "$app"
codesign --verify --strict --deep "$app"
echo "codesign: signed $app"

zip="$(mktemp -d -t sift-it-mac-notarize)/app.zip"
ditto -c -k --keepParent "$app" "$zip"
echo "notarytool: submitting $app (profile $profile)"
result="$(xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait 2>&1)"
echo "$result"
rm -rf "$(dirname "$zip")"
if ! grep -q "status: Accepted" <<< "$result"; then
  id="$(awk '/^ *id:/ {print $2; exit}' <<< "$result")"
  echo "notarytool: not accepted; why: xcrun notarytool log $id --keychain-profile $profile" >&2
  exit 1
fi

# The ticket goes with the app, so Gatekeeper accepts it without asking Apple.
xcrun stapler staple "$app"
spctl --assess --type execute "$app"
echo "notarytool: accepted and stapled $app"
