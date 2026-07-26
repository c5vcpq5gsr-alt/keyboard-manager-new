#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <Keyboard Manager.dmg> [--require-notarization]" >&2
  exit 2
}

DMG_PATH="${1:-}"
[[ -n "$DMG_PATH" && -f "$DMG_PATH" ]] || usage
shift || true
REQUIRE_NOTARIZATION=false
if [[ "${1:-}" == "--require-notarization" ]]; then
  REQUIRE_NOTARIZATION=true
  shift
fi
[[ $# -eq 0 ]] || usage

MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keyboard-manager-verify.XXXXXX")"
detach() {
  hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
  rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap detach EXIT

codesign --verify --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"
if [[ "$REQUIRE_NOTARIZATION" == true ]]; then
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
fi

hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_DIR" >/dev/null
APP_PATH="$MOUNT_DIR/Keyboard Manager.app"
[[ -d "$APP_PATH" ]] || {
  echo "The DMG does not contain Keyboard Manager.app at its root." >&2
  exit 1
}

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH" 2>&1
if [[ "$REQUIRE_NOTARIZATION" == true ]]; then
  spctl --assess --type execute --verbose=4 "$APP_PATH"
fi

echo "Verified: $DMG_PATH"
