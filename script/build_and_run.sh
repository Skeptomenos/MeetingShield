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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

"$ROOT_DIR/script/assemble_app.sh"

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
