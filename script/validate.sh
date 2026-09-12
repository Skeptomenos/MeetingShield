#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MeetingShield"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

stage() {
  echo ""
  echo "==> gate stage: $1"
}

fail() {
  echo "GATE FAILED: $1" >&2
  exit 1
}

stage "build"
swift build --package-path "$ROOT_DIR" || fail "swift build failed"

stage "test"
TEST_USER_HOME="$(mktemp -d "$ROOT_DIR/.build/test-home.XXXXXX")"
CFFIXED_USER_HOME="$TEST_USER_HOME" swift test --package-path "$ROOT_DIR" || fail "swift test failed"

stage "smoke"
"$ROOT_DIR/script/assemble_app.sh" --skip-local-credentials >/dev/null || fail "app bundle assembly failed"
[[ -x "$APP_BINARY" ]] || fail "assembled bundle is missing executable at $APP_BINARY"

SMOKE_USER_HOME="$(mktemp -d "$ROOT_DIR/.build/smoke-home.XXXXXX")"
SMOKE_OUTPUT="$(CFFIXED_USER_HOME="$SMOKE_USER_HOME" "$APP_BINARY" --smoke-test 2>/dev/null)" || fail "smoke binary exited non-zero"
if [[ "$SMOKE_OUTPUT" != *"Meeting Shield smoke launch OK"* ]]; then
  fail "smoke output missing marker. got: $SMOKE_OUTPUT"
fi

stage "runtime fallback"
RUNTIME_OUTPUT_DIR="$(mktemp -d "$ROOT_DIR/.build/runtime-fallback.XXXXXX")/evidence"
"$ROOT_DIR/script/assert_runtime_fallback.sh" --app-bundle "$APP_BUNDLE" --output-dir "$RUNTIME_OUTPUT_DIR" --scenario all || fail "native runtime fallback check failed or is BLOCKED; evidence: $RUNTIME_OUTPUT_DIR"

stage "drift"
for doc_cmd in "script/validate.sh" "script/build_and_run.sh" "script/assemble_app.sh" "script/assert_runtime_fallback.sh"; do
  [[ -x "$ROOT_DIR/$doc_cmd" ]] || fail "documented command missing or not executable: $doc_cmd"
done
grep -q "validate.sh" "$ROOT_DIR/AGENTS.md" || fail "AGENTS.md does not reference script/validate.sh"
if /usr/libexec/PlistBuddy -c "Print :MSGoogleOAuthClientID" "$INFO_PLIST" >/dev/null 2>&1; then
  fail "credential-free smoke bundle contains MSGoogleOAuthClientID"
fi
if /usr/libexec/PlistBuddy -c "Print :MSGoogleOAuthClientSecret" "$INFO_PLIST" >/dev/null 2>&1; then
  fail "credential-free smoke bundle contains MSGoogleOAuthClientSecret"
fi
HOME_PATH_PATTERN='/Users/'
if grep -rn "$HOME_PATH_PATTERN" "$ROOT_DIR/Sources" "$ROOT_DIR/script" --include="*.swift" --include="*.sh" --exclude="validate.sh" 2>/dev/null; then
  fail "machine-specific absolute path found in Sources/ or script/"
fi

echo ""
echo "GATE PASSED: build, test, smoke, runtime fallback, drift all green."
