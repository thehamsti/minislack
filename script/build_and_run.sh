#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MiniSlack"
BUNDLE_ID="com.hamsti.minislack"
BUILD_CONFIGURATION="release"
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  BUILD_CONFIGURATION="debug"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INFO_PLIST_SOURCE="$ROOT_DIR/Config/MiniSlack-Info.plist"
STAGING_DIR="$(mktemp -d /private/tmp/mini-slack-app.XXXXXX)"
STAGED_APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
STAGED_APP_CONTENTS="$STAGED_APP_BUNDLE/Contents"
STAGED_APP_MACOS="$STAGED_APP_CONTENTS/MacOS"
STAGED_APP_BINARY="$STAGED_APP_MACOS/$APP_NAME"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --package-path "$ROOT_DIR" --configuration "$BUILD_CONFIGURATION"
BUILD_BINARY="$(
  swift build \
    --package-path "$ROOT_DIR" \
    --configuration "$BUILD_CONFIGURATION" \
    --show-bin-path
)/$APP_NAME"

mkdir -p "$STAGED_APP_MACOS"
cp "$BUILD_BINARY" "$STAGED_APP_BINARY"
chmod +x "$STAGED_APP_BINARY"
plutil -lint "$INFO_PLIST_SOURCE" >/dev/null
cp "$INFO_PLIST_SOURCE" "$STAGED_APP_CONTENTS/Info.plist"

xattr -cr "$STAGED_APP_BUNDLE"
codesign --force --sign - "$STAGED_APP_BUNDLE"
codesign --verify --deep --strict "$STAGED_APP_BUNDLE"

mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
ditto --noextattr --noqtn "$STAGED_APP_BUNDLE" "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"

open_app() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
