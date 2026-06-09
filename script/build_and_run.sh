#!/usr/bin/env bash
set -euo pipefail

MODE="run"
DEMO_MODE=""

usage() {
  echo "usage: $0 [run|--debug|debug|--lldb|lldb|--crash-debug|crash-debug|--logs|logs|--telemetry|telemetry|--verify|verify] [--demo quiet|single|overlap|linkless|fallback]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    run|--debug|debug|--lldb|lldb|--crash-debug|crash-debug|--logs|logs|--telemetry|telemetry|--verify|verify)
      MODE="$1"
      shift
      ;;
    --demo)
      DEMO_MODE="${2:-overlap}"
      if [[ $# -gt 1 ]]; then
        shift 2
      else
        shift
      fi
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
APP_NAME="MeetingShield"
BUNDLE_ID="com.skeptomenos.meetingshield"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
DIST_DSYM="$DIST_DIR/$APP_NAME.dSYM"
LOCAL_GOOGLE_CLIENT_ID_FILE="$ROOT_DIR/.local/google-oauth-client-id"
LOCAL_GOOGLE_CLIENT_SECRET_FILE="$ROOT_DIR/.local/google-oauth-client-secret"
APP_ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"
CODESIGN_IDENTITY="${MEETING_SHIELD_CODESIGN_IDENTITY:-}"

GOOGLE_CLIENT_ID="${MEETING_SHIELD_GOOGLE_CLIENT_ID:-}"
if [[ -z "$GOOGLE_CLIENT_ID" && -f "$LOCAL_GOOGLE_CLIENT_ID_FILE" ]]; then
  GOOGLE_CLIENT_ID="$(tr -d '[:space:]' <"$LOCAL_GOOGLE_CLIENT_ID_FILE")"
fi
GOOGLE_CLIENT_SECRET="${MEETING_SHIELD_GOOGLE_CLIENT_SECRET:-}"
if [[ -z "$GOOGLE_CLIENT_SECRET" && -f "$LOCAL_GOOGLE_CLIENT_SECRET_FILE" ]]; then
  GOOGLE_CLIENT_SECRET="$(tr -d '[:space:]' <"$LOCAL_GOOGLE_CLIENT_SECRET_FILE")"
fi

GOOGLE_CLIENT_ID_PLIST_ENTRY=""
if [[ -n "$GOOGLE_CLIENT_ID" ]]; then
  GOOGLE_CLIENT_ID_PLIST_ENTRY="  <key>MSGoogleOAuthClientID</key>
  <string>$GOOGLE_CLIENT_ID</string>"
fi
GOOGLE_CLIENT_SECRET_PLIST_ENTRY=""
if [[ -n "$GOOGLE_CLIENT_SECRET" ]]; then
  GOOGLE_CLIENT_SECRET_PLIST_ENTRY="  <key>MSGoogleOAuthClientSecret</key>
  <string>$GOOGLE_CLIENT_SECRET</string>"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BUILD_DIR="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
BUILD_DSYM="$BUILD_BINARY.dSYM"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
rm -rf "$DIST_DSYM"
if [[ -d "$BUILD_DSYM" ]]; then
  cp -R "$BUILD_DSYM" "$DIST_DSYM"
fi
if [[ -f "$APP_ICON_SOURCE" ]]; then
  cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Meeting Shield</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
${GOOGLE_CLIENT_ID_PLIST_ENTRY}
${GOOGLE_CLIENT_SECRET_PLIST_ENTRY}
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsSuddenTermination</key>
  <false/>
</dict>
</plist>
PLIST

sign_app() {
  local identity="-"
  if [[ -n "$CODESIGN_IDENTITY" ]]; then
    identity="$CODESIGN_IDENTITY"
  fi
  /usr/bin/codesign --force --sign "$identity" --timestamp=none --identifier "$BUNDLE_ID" "$APP_BUNDLE"
}

sign_app

open_app() {
  if [[ -n "$DEMO_MODE" ]]; then
    /usr/bin/open -n "$APP_BUNDLE" --args --demo-calendar "$DEMO_MODE"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

run_binary_direct() {
  if [[ -n "$DEMO_MODE" ]]; then
    "$APP_BINARY" --demo-calendar "$DEMO_MODE"
  else
    "$APP_BINARY"
  fi
}

run_lldb() {
  if [[ -n "$DEMO_MODE" ]]; then
    lldb -- "$APP_BINARY" --demo-calendar "$DEMO_MODE"
  else
    lldb -- "$APP_BINARY"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug|--lldb|lldb)
    run_lldb
    ;;
  --crash-debug|crash-debug)
    export NSZombieEnabled=YES
    export MallocScribble=1
    export MallocStackLogging=1
    run_binary_direct
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
    usage
    exit 2
    ;;
esac
