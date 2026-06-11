#!/usr/bin/env bash
# Meeting Shield single validation gate.
# One deterministic, indivisible command that defines "done".
# Stages: build -> test -> smoke -> drift. No credentials, no network.
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

# --- Stage 1: build -------------------------------------------------------
stage "build"
swift build --package-path "$ROOT_DIR" || fail "swift build failed"

# --- Stage 2: tests -------------------------------------------------------
stage "test"
swift test --package-path "$ROOT_DIR" || fail "swift test failed"

# --- Stage 3: smoke (production artifact, documented entry point) ---------
stage "smoke"
"$ROOT_DIR/script/assemble_app.sh" --skip-local-credentials >/dev/null || fail "app bundle assembly failed"
[[ -x "$APP_BINARY" ]] || fail "assembled bundle is missing executable at $APP_BINARY"

SMOKE_OUTPUT="$("$APP_BINARY" --smoke-test 2>/dev/null)" || fail "smoke binary exited non-zero"
if [[ "$SMOKE_OUTPUT" != *"Meeting Shield smoke launch OK"* ]]; then
  fail "smoke output missing marker. got: $SMOKE_OUTPUT"
fi

# --- Stage 4: drift checks ------------------------------------------------
stage "drift"
# Documented commands must exist and be executable.
for doc_cmd in "script/validate.sh" "script/build_and_run.sh" "script/assemble_app.sh"; do
  [[ -x "$ROOT_DIR/$doc_cmd" ]] || fail "documented command missing or not executable: $doc_cmd"
done
# AGENTS.md must reference the gate so future agents find it.
grep -q "validate.sh" "$ROOT_DIR/AGENTS.md" || fail "AGENTS.md does not reference script/validate.sh"
# The deterministic (credential-free) bundle must not embed OAuth credentials.
if /usr/libexec/PlistBuddy -c "Print :MSGoogleOAuthClientID" "$INFO_PLIST" >/dev/null 2>&1; then
  fail "credential-free smoke bundle contains MSGoogleOAuthClientID"
fi
if /usr/libexec/PlistBuddy -c "Print :MSGoogleOAuthClientSecret" "$INFO_PLIST" >/dev/null 2>&1; then
  fail "credential-free smoke bundle contains MSGoogleOAuthClientSecret"
fi
# No machine-specific absolute paths in sources or scripts (pattern split to avoid self-match).
HOME_PATH_PATTERN='/Users/'
if grep -rn "$HOME_PATH_PATTERN" "$ROOT_DIR/Sources" "$ROOT_DIR/script" --include="*.swift" --include="*.sh" --exclude="validate.sh" 2>/dev/null; then
  fail "machine-specific absolute path found in Sources/ or script/"
fi

echo ""
echo "GATE PASSED: build, test, smoke, drift all green."
