#!/usr/bin/env bash
set -euo pipefail

# Debug builds compile incrementally (per-file) and are far faster in the
# edit→run loop; release uses whole-module optimization, so every edit
# recompiles the whole module. Default to debug; use --release for optimized
# builds.
MODE="run"
BUILD_CONFIGURATION="debug"
for arg in "$@"; do
  case "$arg" in
    --release|release)
      BUILD_CONFIGURATION="release"
      ;;
    --lldb|--debug|debug)
      MODE="--lldb"
      ;;
    run|--logs|logs|--telemetry|telemetry|--verify|verify)
      MODE="$arg"
      ;;
    *)
      echo "usage: $0 [run|--lldb|--logs|--telemetry|--verify] [--release]" >&2
      exit 2
      ;;
  esac
done
APP_NAME="MiniSlack"
BUNDLE_ID="com.hamsti.minislack"

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

# Sign with a stable identity rather than ad-hoc. An ad-hoc signature changes
# the app's cdhash on every build, which invalidates the keychain ACL entries
# for the stored Slack credentials — macOS then asks for the login keychain
# password once per item on every launch. A persistent self-signed certificate
# keeps the code requirement stable across rebuilds, so "Always Allow" sticks.
CODESIGN_IDENTITY="${MINISLACK_CODESIGN_IDENTITY:-MiniSlack Local Development}"

# Note: a self-signed identity is untrusted, so `find-identity -v` excludes it;
# check presence without -v and let codesign (which needs no trust) use it.
identity_available() {
  security find-identity | grep -Fq "\"$CODESIGN_IDENTITY\""
}

create_codesign_identity() {
  local cert_dir="$1"
  cat > "$cert_dir/openssl.cnf" <<EOF
[ req ]
prompt = no
distinguished_name = dn
x509_extensions = ext

[ dn ]
CN = $CODESIGN_IDENTITY

[ ext ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$cert_dir/openssl.cnf" \
    -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" >/dev/null 2>&1 || return 1
  local p12_password
  p12_password="$(openssl rand -hex 16)"
  # macOS `security import` only parses legacy PKCS#12 algorithms; OpenSSL 3
  # defaults to SHA-256 MAC + AES, which fails with "MAC verification failed".
  openssl pkcs12 -export \
    -inkey "$cert_dir/key.pem" -in "$cert_dir/cert.pem" \
    -out "$cert_dir/identity.p12" -passout "pass:$p12_password" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 >/dev/null 2>&1 || return 1
  security import "$cert_dir/identity.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$p12_password" -T /usr/bin/codesign -T /usr/bin/security >/dev/null || return 1
}

SIGN_IDENTITY="-"
if [[ -n "${MINISLACK_CODESIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$MINISLACK_CODESIGN_IDENTITY"
elif identity_available; then
  SIGN_IDENTITY="$CODESIGN_IDENTITY"
else
  echo "Creating self-signed signing certificate '$CODESIGN_IDENTITY' (one-time setup)…" >&2
  CERT_DIR="$(mktemp -d /private/tmp/minislack-cert.XXXXXX)"
  if create_codesign_identity "$CERT_DIR" && identity_available; then
    SIGN_IDENTITY="$CODESIGN_IDENTITY"
  else
    echo "warning: no signing certificate available; falling back to ad-hoc signing." >&2
    echo "warning: expect keychain password prompts on each launch." >&2
  fi
  rm -rf "$CERT_DIR"
fi

xattr -cr "$STAGED_APP_BUNDLE"
codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$STAGED_APP_BUNDLE"
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
  --lldb)
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
    echo "usage: $0 [run|--lldb|--logs|--telemetry|--verify] [--release]" >&2
    exit 2
    ;;
esac
