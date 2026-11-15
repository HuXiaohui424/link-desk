#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SOURCE="${LINKDESK_APP_SOURCE:-$ROOT/flutter/build/macos/Build/Products/Debug/LinkDesk.app}"
INSTANCE="${1:-a}"
MODE="${2:-}"
DATA_DIR="${LINKDESK_CONFIG_DIR:-$ROOT/.instances/$INSTANCE}"
RUNTIME_ROOT="${LINKDESK_INSTANCE_ROOT:-${TMPDIR:-/tmp}/linkdesk-instances}"
APP_NAME="LinkDesk-$INSTANCE.app"
APP_TARGET="$RUNTIME_ROOT/$APP_NAME"
BUNDLE_ID="com.wanxiang.linkdesk.instance.$INSTANCE"
SERVER_URL="${LINKDESK_SERVER_URL:-http://127.0.0.1:22119}"
RENDEZVOUS_SERVER="${LINKDESK_RENDEZVOUS_SERVER:-127.0.0.1:22116}"

[[ "$INSTANCE" =~ ^[a-zA-Z0-9_-]+$ ]] || {
  echo "instance name must contain only letters, numbers, '_' or '-'" >&2
  exit 2
}
[[ -d "$APP_SOURCE" ]] || {
  echo "built app not found: $APP_SOURCE" >&2
  exit 1
}
curl --fail --silent --show-error --max-time 2 "$SERVER_URL/healthz" >/dev/null || {
  echo "LinkDesk server is not reachable at $SERVER_URL" >&2
  echo "Start link-desk-serve before launching this instance." >&2
  exit 1
}

mkdir -p "$RUNTIME_ROOT" "$DATA_DIR"
rm -rf "$APP_TARGET"
ditto "$APP_SOURCE" "$APP_TARGET"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" \
  "$APP_TARGET/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName LinkDesk-$INSTANCE" \
  "$APP_TARGET/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" \
  "$APP_TARGET/Contents/Info.plist" 2>/dev/null || true
for entry in \
  "LINKDESK_CONFIG_DIR $DATA_DIR" \
  "LINKDESK_SERVER_URL $SERVER_URL" \
  "LINKDESK_RENDEZVOUS_SERVER $RENDEZVOUS_SERVER"; do
  key="${entry%% *}"
  value="${entry#* }"
  /usr/libexec/PlistBuddy -c "Delete :LSEnvironment:$key" \
    "$APP_TARGET/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:$key string $value" \
    "$APP_TARGET/Contents/Info.plist"
done
codesign --force --deep --sign - "$APP_TARGET" >/dev/null

if [[ "$MODE" == "--prepare-only" ]]; then
  printf 'prepared %s with config %s\n' "$APP_TARGET" "$DATA_DIR"
  exit 0
fi

LINKDESK_CONFIG_DIR="$DATA_DIR" LINKDESK_SERVER_URL="$SERVER_URL" \
  LINKDESK_RENDEZVOUS_SERVER="$RENDEZVOUS_SERVER" \
  "$APP_TARGET/Contents/MacOS/LinkDesk" >/dev/null 2>&1 &
printf 'started %s with config %s (PID %s)\n' "$APP_TARGET" "$DATA_DIR" "$!"
