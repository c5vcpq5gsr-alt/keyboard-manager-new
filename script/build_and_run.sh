#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Keyboard Manager"
BUNDLE_ID="de.r3d42.KeyboardManagerV2"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/KeyboardManager.xcodeproj"
SCHEME="KeyboardManager"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

stop_v2_app() {
  local pid executable
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    executable="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$executable" in
      "$APP_BINARY"|"$APP_BINARY "*|"$BUILT_APP/Contents/MacOS/$APP_NAME"|"$BUILT_APP/Contents/MacOS/$APP_NAME "*)
        kill "$pid" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(pgrep -x "$APP_NAME" 2>/dev/null || true)
}

build_app() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

  mkdir -p "$DIST_DIR"
  rm -rf "$APP_BUNDLE"
  ditto "$BUILT_APP" "$APP_BUNDLE"
  codesign --force --deep --sign - "$APP_BUNDLE"
}

case "$MODE" in
  --build|build)
    ;;
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    stop_v2_app
    ;;
  *)
    echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

build_app

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --build|build)
    echo "$APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
esac
