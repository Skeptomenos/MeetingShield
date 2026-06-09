#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MeetingShield"
SUBSYSTEM="com.skeptomenos.meetingshield"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="${MEETING_SHIELD_APP_BUNDLE:-/Applications/$APP_NAME.app}"
DIST_APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
DEMO_MODE="overlap"
DURATION_SECONDS="75"
USE_ZOMBIES=0
USE_MALLOC=0
OUTPUT_DIR=""

usage() {
  echo "usage: $0 <output-dir> [--demo quiet|single|overlap|linkless|fallback] [--duration seconds] [--zombies] [--malloc] [--app-bundle path]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --demo)
      DEMO_MODE="${2:-overlap}"
      if [[ $# -gt 1 ]]; then shift 2; else shift; fi
      ;;
    --duration)
      DURATION_SECONDS="${2:-75}"
      if [[ $# -gt 1 ]]; then shift 2; else shift; fi
      ;;
    --zombies)
      USE_ZOMBIES=1
      shift
      ;;
    --malloc)
      USE_MALLOC=1
      shift
      ;;
    --app-bundle)
      APP_BUNDLE="${2:-}"
      if [[ $# -gt 1 ]]; then shift 2; else shift; fi
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="$1"
        shift
      else
        usage
        exit 2
      fi
      ;;
  esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
  usage
  exit 2
fi

if [[ ! -d "$APP_BUNDLE" && -d "$DIST_APP_BUNDLE" ]]; then
  APP_BUNDLE="$DIST_APP_BUNDLE"
fi

APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BUNDLE_PARENT="$(dirname "$APP_BUNDLE")"
ADJACENT_DSYM="$APP_BUNDLE_PARENT/$APP_NAME.dSYM"
CRASH_REPORT_DIR="$HOME/Library/Logs/DiagnosticReports"
LOG_FILE="$OUTPUT_DIR/unified.log"
APP_OUTPUT_FILE="$OUTPUT_DIR/app-output.log"
METADATA_FILE="$OUTPUT_DIR/metadata.txt"
CRASH_OUTPUT_DIR="$OUTPUT_DIR/crashes"
MARKER_FILE="$OUTPUT_DIR/start.marker"

mkdir -p "$OUTPUT_DIR" "$CRASH_OUTPUT_DIR"
: >"$APP_OUTPUT_FILE"
touch "$MARKER_FILE"

LOG_PID=""
APP_PID=""

cleanup() {
  if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ ! -x "$APP_BINARY" ]]; then
  echo "App binary not found: $APP_BINARY" >&2
  exit 1
fi

before_count="$(find "$CRASH_REPORT_DIR" -name "$APP_NAME-*.ips" -type f -print 2>/dev/null | wc -l | tr -d '[:space:]')"
before_latest="$(find "$CRASH_REPORT_DIR" -name "$APP_NAME-*.ips" -type f -print 2>/dev/null | sort | tail -n 1 || true)"

/usr/bin/log stream --info --debug --style compact --predicate "subsystem == \"$SUBSYSTEM\"" >"$LOG_FILE" 2>&1 &
LOG_PID="$!"

launch_direct=0
env_args=()
if [[ "$USE_ZOMBIES" -eq 1 ]]; then
  launch_direct=1
  env_args+=("NSZombieEnabled=YES")
fi
if [[ "$USE_MALLOC" -eq 1 ]]; then
  launch_direct=1
  env_args+=("MallocScribble=1" "MallocStackLogging=1")
fi

if [[ "$launch_direct" -eq 1 ]]; then
  env "${env_args[@]}" "$APP_BINARY" --demo-calendar "$DEMO_MODE" >>"$APP_OUTPUT_FILE" 2>&1 &
  APP_PID="$!"
else
  /usr/bin/open -n "$APP_BUNDLE" --args --demo-calendar "$DEMO_MODE" >>"$APP_OUTPUT_FILE" 2>&1
  sleep 2
  APP_PID="$(pgrep -nx "$APP_NAME" || true)"
fi

sleep "$DURATION_SECONDS"

process_state="unknown"
if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
  process_state="alive"
else
  process_state="not-running"
fi

new_crash_count=0
while IFS= read -r crash_report; do
  [[ -n "$crash_report" ]] || continue
  cp "$crash_report" "$CRASH_OUTPUT_DIR/"
  new_crash_count=$((new_crash_count + 1))
done < <(find "$CRASH_REPORT_DIR" -name "$APP_NAME-*.ips" -type f -newer "$MARKER_FILE" -print 2>/dev/null)

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "app_name=$APP_NAME"
  echo "app_bundle=$APP_BUNDLE"
  echo "app_binary=$APP_BINARY"
  echo "subsystem=$SUBSYSTEM"
  echo "demo_mode=$DEMO_MODE"
  echo "duration_seconds=$DURATION_SECONDS"
  echo "zombies=$USE_ZOMBIES"
  echo "malloc=$USE_MALLOC"
  echo "process_state=$process_state"
  echo "app_pid=${APP_PID:-missing}"
  echo "crash_reports_before_count=$before_count"
  echo "crash_reports_before_latest=$before_latest"
  echo "new_crash_reports=$new_crash_count"
  echo "dist_dsym_present=$([[ -d "$ROOT_DIR/dist/$APP_NAME.dSYM" ]] && echo yes || echo no)"
  echo "app_bundle_dsym_present=$([[ -d "$APP_BUNDLE.dSYM" ]] && echo yes || echo no)"
  echo "adjacent_dsym_present=$([[ -d "$ADJACENT_DSYM" ]] && echo yes || echo no)"
  echo
  echo "binary_uuid:"
  /usr/bin/dwarfdump --uuid "$APP_BINARY" 2>/dev/null || echo "unavailable"
  echo
  echo "info_plist_sanitized:"
  if [[ -f "$INFO_PLIST" ]]; then
    /usr/bin/plutil -p "$INFO_PLIST" 2>/dev/null | /usr/bin/grep -Ev "MSGoogleOAuthClient(ID|Secret)" || true
  else
    echo "missing"
  fi
} >"$METADATA_FILE"

echo "Diagnostics written to $OUTPUT_DIR"
