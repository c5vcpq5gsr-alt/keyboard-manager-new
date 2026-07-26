#!/usr/bin/env bash
set -euo pipefail

# Produces the actual Developer-ID-signed, notarized DMG. Development builds
# intentionally stay in build_and_run.sh and must never be mistaken for this.

APP_NAME="Keyboard Manager"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/KeyboardManager.xcodeproj"
SCHEME="KeyboardManager"
RELEASE_ROOT="$ROOT_DIR/.release"
ARCHIVE_PATH="$RELEASE_ROOT/$APP_NAME.xcarchive"
EXPORT_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist/release"
STAGING_DIR=""

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to the Apple Developer Team ID.}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity.}"

cleanup() {
  [[ -z "$STAGING_DIR" ]] || rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

require_tool() {
  command -v "$1" >/dev/null || {
    echo "Required tool is missing: $1" >&2
    exit 2
  }
}

for tool in xcodebuild codesign ditto hdiutil xcrun shasum; do
  require_tool "$tool"
done

NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_API_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  NOTARY_ARGS=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  echo "Set NOTARY_PROFILE or NOTARY_API_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID." >&2
  exit 2
fi

mkdir -p "$RELEASE_ROOT" "$DIST_DIR"
rm -rf "$ARCHIVE_PATH"

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  OTHER_CODE_SIGN_FLAGS='--timestamp' \
  ENABLE_HARDENED_RUNTIME=YES \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO

[[ -d "$EXPORT_APP" ]] || {
  echo "Archive did not contain $APP_NAME.app." >&2
  exit 1
}

codesign --verify --deep --strict --verbose=2 "$EXPORT_APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXPORT_APP/Contents/Info.plist")"
DMG_PATH="$DIST_DIR/Keyboard-Manager-$VERSION-universal.dmg"
SHA_PATH="$DMG_PATH.sha256"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keyboard-manager-release.XXXXXX")"

ditto "$EXPORT_APP" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH" "$SHA_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -format UDZO -ov "$DMG_PATH"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"

xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG_PATH"
"$ROOT_DIR/script/verify_release.sh" "$DMG_PATH" --require-notarization
shasum -a 256 "$DMG_PATH" > "$SHA_PATH"

echo "$DMG_PATH"
echo "$SHA_PATH"
