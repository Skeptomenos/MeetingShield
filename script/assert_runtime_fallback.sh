#!/usr/bin/env bash
set -euo pipefail
umask 077

APP_BUNDLE=""
OUTPUT_DIR=""
SCENARIO="timeout"
TIMEOUT_SECONDS=30
USE_ZOMBIES=0
CHILD_PID=""

usage() {
  echo "usage: $0 --app-bundle path --output-dir new-directory [--scenario timeout|close|reopen|dismiss|overlap|all] [--timeout seconds] [--zombies]" >&2
  exit 2
}

fail() {
  echo "RUNTIME CHECK FAILED: $1" >&2
  [[ -z "$OUTPUT_DIR" ]] || echo "Evidence: $OUTPUT_DIR" >&2
  exit 1
}

block_identity() {
  echo "identity_evidence=blocked" >>"$OUTPUT_DIR/metadata.txt"
  echo "RUNTIME CHECK BLOCKED: $1" >&2
  echo "Evidence: $OUTPUT_DIR" >&2
  exit 78
}

stop_child() {
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    local deadline=$((SECONDS + 2))
    while kill -0 "$CHILD_PID" 2>/dev/null && ((SECONDS < deadline)); do
      sleep 0.1
    done
    if kill -0 "$CHILD_PID" 2>/dev/null; then
      kill -KILL "$CHILD_PID" 2>/dev/null || true
    fi
  fi
}

cleanup() {
  stop_child
  if [[ -n "$CHILD_PID" ]]; then
    wait "$CHILD_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle)
      [[ $# -ge 2 && -n "$2" ]] || usage
      APP_BUNDLE="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 && -n "$2" ]] || usage
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --scenario)
      [[ $# -ge 2 ]] || usage
      SCENARIO="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || usage
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --zombies)
      USE_ZOMBIES=1
      shift
      ;;
    *) usage ;;
  esac
done

[[ -n "$APP_BUNDLE" && -n "$OUTPUT_DIR" ]] || usage
case "$SCENARIO" in timeout|close|reopen|dismiss|overlap|all) ;; *) usage ;; esac
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]?$ ]] || usage
((TIMEOUT_SECONDS <= 60)) || usage
[[ -d "$APP_BUNDLE" ]] || fail "exact app bundle does not exist: $APP_BUNDLE"
APP_BUNDLE="$(cd "$APP_BUNDLE" && pwd -P)"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/MeetingShield"
[[ -x "$APP_BINARY" && -f "$APP_BUNDLE/Contents/Info.plist" ]] || fail "exact app bundle is incomplete"
mkdir -p "$(dirname "$OUTPUT_DIR")"
mkdir "$OUTPUT_DIR" || fail "output directory must not already exist"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "app_bundle=$APP_BUNDLE"
  echo "app_binary=$APP_BINARY"
  echo "scenario=$SCENARIO"
  echo "timeout_seconds=$TIMEOUT_SECONDS"
  echo "zombies=$USE_ZOMBIES"
} >"$OUTPUT_DIR/metadata.txt"
SHA_STATUS=0
UUID_STATUS=0
CODESIGN_STATUS=0
SIGNATURE_STATUS=0
shasum -a 256 "$APP_BINARY" >"$OUTPUT_DIR/binary-sha256.txt" 2>&1 || SHA_STATUS=$?
/usr/bin/dwarfdump --uuid "$APP_BINARY" >"$OUTPUT_DIR/binary-uuid.txt" 2>&1 || UUID_STATUS=$?
/usr/bin/codesign -d --verbose=4 "$APP_BUNDLE" >"$OUTPUT_DIR/codesign.txt" 2>&1 || CODESIGN_STATUS=$?
/usr/bin/codesign --verify --strict --verbose=2 "$APP_BUNDLE" >"$OUTPUT_DIR/codesign-verify.txt" 2>&1 || SIGNATURE_STATUS=$?
{
  echo "sha_exit_status=$SHA_STATUS"
  echo "uuid_exit_status=$UUID_STATUS"
  echo "codesign_exit_status=$CODESIGN_STATUS"
  echo "signature_exit_status=$SIGNATURE_STATUS"
} >>"$OUTPUT_DIR/metadata.txt"
BINARY_SHA256="$(awk 'NR == 1 {print $1}' "$OUTPUT_DIR/binary-sha256.txt")"
[[ "$SHA_STATUS" -eq 0 && "$BINARY_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || block_identity "exact binary SHA-256 is unavailable"
[[ "$UUID_STATUS" -eq 0 ]] && grep -Eq '^UUID: [[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12} ' "$OUTPUT_DIR/binary-uuid.txt" || block_identity "exact binary UUID is unavailable"
[[ "$CODESIGN_STATUS" -eq 0 && "$SIGNATURE_STATUS" -eq 0 ]] && grep -q '^CDHash=' "$OUTPUT_DIR/codesign.txt" || block_identity "exact app signature metadata or verification failed"
{
  echo "binary_sha256=$BINARY_SHA256"
  echo "identity_evidence=verified"
} >>"$OUTPUT_DIR/metadata.txt"

SCENARIOS=("$SCENARIO")
if [[ "$SCENARIO" == all ]]; then
  SCENARIOS=(timeout close reopen dismiss overlap)
fi

run_scenario() {
  local scenario="$1"
  local run_dir="$OUTPUT_DIR/$scenario"
  mkdir "$run_dir"
  local isolated_home
  isolated_home="$(mktemp -d "$run_dir/home.XXXXXX")"
  local stdout_file="$run_dir/stdout.log"
  local stderr_file="$run_dir/stderr.log"
  local env_args=(
    -u NSZombieEnabled -u NSDeallocateZombies
    -u MallocStackLogging -u MallocStackLoggingNoCompact
    -u MallocScribble -u MallocPreScribble -u MallocGuardEdges
    -u DYLD_INSERT_LIBRARIES
    "CFFIXED_USER_HOME=$isolated_home"
    "MEETING_SHIELD_RUNTIME_HOME=$isolated_home"
  )
  if [[ "$USE_ZOMBIES" -eq 1 ]]; then
    env_args+=("NSZombieEnabled=YES")
  fi

  echo "Runtime fallback: $scenario (deadline ${TIMEOUT_SECONDS}s)"
  local started=$SECONDS
  env "${env_args[@]}" "$APP_BINARY" --runtime-fallback-check "$scenario" >"$stdout_file" 2>"$stderr_file" &
  CHILD_PID=$!
  {
    echo "scenario=$scenario"
    echo "child_pid=$CHILD_PID"
    echo "isolated_home=$isolated_home"
  } >"$run_dir/result.txt"

  local timed_out=0
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    if ((SECONDS - started >= TIMEOUT_SECONDS)); then
      timed_out=1
      stop_child
      break
    fi
    sleep 0.1
  done
  local status=0
  wait "$CHILD_PID" 2>/dev/null || status=$?
  CHILD_PID=""
  {
    echo "elapsed_seconds=$((SECONDS - started))"
    echo "exit_status=$status"
    echo "deadline_exceeded=$timed_out"
  } >>"$run_dir/result.txt"

  [[ "$timed_out" -eq 0 ]] || fail "$scenario exceeded its deadline"
  if [[ "$status" -eq 78 ]]; then
    echo "RUNTIME CHECK BLOCKED: $scenario requires an interactive Mac WindowServer and the isolated runtime home." >&2
    echo "Evidence: $run_dir" >&2
    exit 78
  fi
  [[ "$status" -eq 0 ]] || fail "$scenario child exited with status $status"
  if grep -q '^RUNTIME_CHECK result=' "$stderr_file"; then
    fail "$scenario emitted an unexpected runtime result on stderr"
  fi
  local marker="RUNTIME_CHECK result=passed scenario=$scenario"
  [[ "$(grep -Fxc "$marker" "$stdout_file" || true)" == 1 ]] || fail "$scenario is missing its single success marker"
  if ! awk -v success="$marker" '
    BEGIN {
      split("initial_alert launch_recorded fallback_visible fallback_closed later_alert completed", checkpoints)
      for (checkpointIndex in checkpoints) required[checkpoints[checkpointIndex]] = 1
      nextCheckpoint = 1
    }
    /^RUNTIME_CHECK checkpoint=/ {
      if (resultSeen) invalid = 1
      code = substr($0, length("RUNTIME_CHECK checkpoint=") + 1)
      if (code in required) {
        if (code != checkpoints[nextCheckpoint]) invalid = 1
        nextCheckpoint++
      }
    }
    /^RUNTIME_CHECK result=/ {
      if ($0 != success || nextCheckpoint != 7) invalid = 1
      resultSeen++
    }
    END { exit nextCheckpoint == 7 && resultSeen == 1 && !invalid ? 0 : 1 }
  ' "$stdout_file"; then
    fail "$scenario is missing ordered lifecycle checkpoints"
  fi
  echo "assertions=passed" >>"$run_dir/result.txt"
}

for scenario in "${SCENARIOS[@]}"; do
  run_scenario "$scenario"
done

if [[ "$USE_ZOMBIES" -eq 1 ]]; then
  echo "RUNTIME CHECK DIAGNOSTIC ONLY: zombie instrumentation passed; repeat without --zombies for acceptance."
  echo "Evidence: $OUTPUT_DIR"
  exit 3
fi

echo "RUNTIME CHECK PASSED: ${SCENARIOS[*]}; normal child exit and lifecycle assertions verified."
echo "Evidence: $OUTPUT_DIR"
