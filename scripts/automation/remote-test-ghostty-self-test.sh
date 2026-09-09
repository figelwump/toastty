#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d /tmp/toastty-remote-test-ghostty.XXXXXX)"
cleanup() {
  local status=$?
  if [[ "$status" != 0 ]]; then
    cat "$TEST_ROOT/"*.log >&2
  fi
  rm -rf "$TEST_ROOT"
  return "$status"
}
trap cleanup EXIT
FIXTURE_ROOT="$TEST_ROOT/worktree"
mkdir -p "$FIXTURE_ROOT/scripts/remote" "$FIXTURE_ROOT/scripts/dev" "$TEST_ROOT/bin"
cp "$ROOT_DIR/scripts/remote/"{test.sh,live-gateway-test-environment.sh,ios-simulator-run.sh} "$FIXTURE_ROOT/scripts/remote/"

cat >"$FIXTURE_ROOT/scripts/dev/bootstrap-worktree.sh" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$FIXTURE_MODE" == generation-failed ]]; then exit 42; fi
mkdir -p toastty.xcodeproj
case "$FIXTURE_MODE" in
  ghostty) printf 'TOASTTY_HAS_GHOSTTY_KIT\n' >toastty.xcodeproj/project.pbxproj ;;
  misleading) printf 'TOASTTY_HAS_GHOSTTY_KIT_STUB\n' >toastty.xcodeproj/project.pbxproj ;;
  fallback) printf 'TOASTTY_EXPLICIT_GHOSTTY_TEST_FALLBACK\n' >toastty.xcodeproj/project.pbxproj ;;
  missing) rm -f toastty.xcodeproj/project.pbxproj ;;
esac
BOOTSTRAP
cat >"$TEST_ROOT/bin/xcodebuild" <<'XCODEBUILD'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FIXTURE_XCODEBUILD_RECORD"
XCODEBUILD
cat >"$TEST_ROOT/bin/caffeinate" <<'CAFFEINATE'
#!/usr/bin/env bash
exit 0
CAFFEINATE
chmod +x "$FIXTURE_ROOT/scripts/dev/bootstrap-worktree.sh" "$TEST_ROOT/bin/"*

for mode in ghostty fallback misleading missing generation-failed; do
  run_root="$TEST_ROOT/test-runs/$mode"
  record="$TEST_ROOT/$mode.xcodebuild"
  status=0
  (
    cd "$FIXTURE_ROOT"
    PATH="$TEST_ROOT/bin:$PATH" \
    FIXTURE_MODE="$mode" FIXTURE_XCODEBUILD_RECORD="$record" \
    TOASTTY_REMOTE_TEST_RUN_LABEL="$mode" \
    TOASTTY_REMOTE_TEST_REMOTE_RUN_ROOT="$run_root" \
    TOASTTY_REMOTE_TEST_REMOTE_WORKTREE_DIR="$FIXTURE_ROOT" \
    TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS=0 \
    TOASTTY_REMOTE_TEST_PLATFORM=macos \
    TOASTTY_REMOTE_TEST_XCODEBUILD_ARGS_B64="$(printf '%s\n' '-only-testing:ToasttyAppTests/FocusedSuite' | base64 | tr -d '\n')" \
      bash scripts/remote/test.sh --remote-exec
  ) >"$TEST_ROOT/$mode.log" 2>&1 || status=$?
  if [[ "$mode" == ghostty ]]; then
    [[ "$status" == 0 && -f "$record" ]]
    grep -q 'Ghostty-backed macOS app and test coverage is enabled.' "$run_root/xcodebuild.log"
    grep -q -- '-only-testing:ToasttyAppTests/FocusedSuite' "$record"
    jq -e '.status == "pass"' "$run_root/result.json" >/dev/null
  else
    [[ "$status" == 78 && ! -e "$record" ]]
    jq -e '.status == "setup_error" and (.failureSummary | length > 0)' "$run_root/result.json" >/dev/null
  fi
  [[ -f "$run_root/COMPLETED" ]]
done
printf 'Remote Ghostty coverage self-test passed.\n'
