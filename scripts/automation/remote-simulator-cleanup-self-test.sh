#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/remote/cleanup-simulators.sh"
TEST_ROOT="$(mktemp -d /tmp/toastty-remote-simulator-cleanup.XXXXXX)"
FAKE_BIN="$TEST_ROOT/bin"
REMOTE_REPO="$TEST_ROOT/remote-repo"
REMOTE_GUI="$TEST_ROOT/remote-gui"
INITIAL_JSON="$TEST_ROOT/devices.json"
RECHECK_JSON="$TEST_ROOT/recheck-devices.json"
DELETE_LOG="$TEST_ROOT/deleted.log"
LIST_COUNT="$TEST_ROOT/list-count"
NOW_EPOCH=1735689600

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

encode_base64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

run_remote_fixture() {
  local mode="$1"
  PATH="$FAKE_BIN:$PATH" \
  FAKE_SIMCTL_INITIAL_JSON="$INITIAL_JSON" \
  FAKE_SIMCTL_RECHECK_JSON="$RECHECK_JSON" \
  FAKE_SIMCTL_DELETE_LOG="$DELETE_LOG" \
  FAKE_SIMCTL_LIST_COUNT="$LIST_COUNT" \
  FAKE_GIT_TOPLEVEL="${FAKE_GIT_TOPLEVEL:-$REMOTE_REPO}" \
    /bin/bash "$SCRIPT" \
      --remote-exec \
      "$mode" \
      "$NOW_EPOCH" \
      24 \
      "$(encode_base64 "$REMOTE_REPO")" \
      "$(encode_base64 "$REMOTE_GUI")"
}

mkdir -p \
  "$FAKE_BIN" \
  "$REMOTE_REPO/scripts/remote" \
  "$REMOTE_GUI/worktrees" \
  "$REMOTE_GUI/test-runs"
touch "$REMOTE_REPO/Project.swift" "$REMOTE_REPO/scripts/remote/test.sh"
: >"$DELETE_LOG"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$1" == "-C" && "$3" == "rev-parse" && "$4" == "--show-toplevel" ]]; then' \
  '  printf "%s\\n" "$FAKE_GIT_TOPLEVEL"' \
  '  exit 0' \
  'fi' \
  'exit 1' \
  >"$FAKE_BIN/git"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ "$1" == simctl ]] || exit 1' \
  'if [[ "$2" == list && "$3" == devices && "$4" == available && "$5" == --json ]]; then' \
  '  count=0' \
  '  if [[ -f "$FAKE_SIMCTL_LIST_COUNT" ]]; then count="$(cat "$FAKE_SIMCTL_LIST_COUNT")"; fi' \
  '  count=$((count + 1))' \
  '  printf "%s\\n" "$count" >"$FAKE_SIMCTL_LIST_COUNT"' \
  '  if (( count > 1 )); then cat "$FAKE_SIMCTL_RECHECK_JSON"; else cat "$FAKE_SIMCTL_INITIAL_JSON"; fi' \
  '  exit 0' \
  'fi' \
  'if [[ "$2" == delete && $# == 3 ]]; then' \
  '  printf "%s\\n" "$3" >>"$FAKE_SIMCTL_DELETE_LOG"' \
  '  exit 0' \
  'fi' \
  'exit 1' \
  >"$FAKE_BIN/xcrun"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'while [[ $# -gt 0 ]]; do' \
  '  if [[ "$1" == /bin/bash ]]; then' \
  '    shift' \
  '    exec /bin/bash "$@"' \
  '  fi' \
  '  shift' \
  'done' \
  'exit 1' \
  >"$FAKE_BIN/ssh"
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/xcrun" "$FAKE_BIN/ssh"

OLD_SHUTDOWN_ID="11111111-1111-1111-1111-111111111111"
OLD_BOOTED_ID="22222222-2222-2222-2222-222222222222"
RECENT_SHUTDOWN_ID="33333333-3333-3333-3333-333333333333"
MISSING_BOOT_ID="44444444-4444-4444-4444-444444444444"
INVALID_ID="not-a-udid"
ORDINARY_ID="55555555-5555-5555-5555-555555555555"
CURRENT_TOASTTY_ID="66666666-6666-6666-6666-666666666666"

printf '%s\n' "$(jq -nc \
  --arg oldShutdownID "$OLD_SHUTDOWN_ID" \
  --arg oldBootedID "$OLD_BOOTED_ID" \
  --arg recentShutdownID "$RECENT_SHUTDOWN_ID" \
  --arg missingBootID "$MISSING_BOOT_ID" \
  --arg invalidID "$INVALID_ID" \
  --arg ordinaryID "$ORDINARY_ID" \
  --arg currentToasttyID "$CURRENT_TOASTTY_ID" \
  '{devices:{"com.apple.CoreSimulator.SimRuntime.iOS-26-3":[
    {name:"Plate Remote remote-test-20241220-old",udid:$oldShutdownID,state:"Shutdown",lastBootedAt:"2024-12-20T00:00:00Z",dataPathSize:1073741824},
    {name:"Plate Remote remote-validate-20241220-booted",udid:$oldBootedID,state:"Booted",lastBootedAt:"2024-12-20T00:00:00Z",dataPathSize:2147483648},
    {name:"Plate Remote remote-test-20241231-recent",udid:$recentShutdownID,state:"Shutdown",lastBootedAt:"2024-12-31T23:30:00Z",dataPathSize:536870912},
    {name:"Plate Remote remote-test-20241220-never-booted",udid:$missingBootID,state:"Shutdown",dataPathSize:18337792},
    {name:"Plate Remote remote-test-20241220-invalid-id",udid:$invalidID,state:"Shutdown",lastBootedAt:"2024-12-20T00:00:00Z",dataPathSize:1024},
    {name:"iPhone 17",udid:$ordinaryID,state:"Shutdown",lastBootedAt:"2024-01-01T00:00:00Z",dataPathSize:999},
    {name:"Toastty Mobile worktree",udid:$currentToasttyID,state:"Shutdown",lastBootedAt:"2024-01-01T00:00:00Z",dataPathSize:999}
  ]}}')" >"$INITIAL_JSON"
cp "$INITIAL_JSON" "$RECHECK_JSON"

: >"$LIST_COUNT"
dry_run_output="$(run_remote_fixture dry-run 2>&1)"
[[ ! -s "$DELETE_LOG" ]] || fail_test "dry run deleted a simulator"
[[ "$dry_run_output" == *'mode=dry-run eligible=1 deleted=0 retained=1 eligible_size=1.0 GiB reclaimed=0 B manual_review=3 delete_failures=0'* ]] \
  || {
    printf '%s\n' "$dry_run_output" >&2
    fail_test "dry-run summary did not match the fail-closed fixture"
  }
[[ "$dry_run_output" != *'iPhone 17'* && "$dry_run_output" != *'Toastty Mobile worktree'* ]] \
  || fail_test "cleanup considered a non-legacy simulator"

: >"$LIST_COUNT"
local_wrapper_output="$(
  PATH="$FAKE_BIN:$PATH" \
  FAKE_SIMCTL_INITIAL_JSON="$INITIAL_JSON" \
  FAKE_SIMCTL_RECHECK_JSON="$RECHECK_JSON" \
  FAKE_SIMCTL_DELETE_LOG="$DELETE_LOG" \
  FAKE_SIMCTL_LIST_COUNT="$LIST_COUNT" \
  FAKE_GIT_TOPLEVEL="$REMOTE_REPO" \
  TOASTTY_REMOTE_GUI_HOST=fixture-host \
  TOASTTY_REMOTE_GUI_REPO_ROOT="$REMOTE_REPO" \
  TOASTTY_REMOTE_GUI_ROOT="$REMOTE_GUI" \
    /bin/bash "$SCRIPT" --dry-run 2>&1
)"
[[ "$local_wrapper_output" == *'target=fixture-host mode=dry-run retention_hours=24'* ]] \
  || fail_test "local wrapper did not preserve the configured remote target"
[[ "$local_wrapper_output" == *'mode=dry-run eligible=2 deleted=0'* ]] \
  || fail_test "local wrapper did not pipe and execute the remote cleanup script"

: >"$LIST_COUNT"
: >"$DELETE_LOG"
apply_output="$(run_remote_fixture apply 2>&1)"
[[ "$(cat "$DELETE_LOG")" == "$OLD_SHUTDOWN_ID" ]] \
  || fail_test "apply did not delete exactly the old shutdown legacy simulator"
[[ "$apply_output" == *'mode=apply eligible=1 deleted=1 retained=1 eligible_size=1.0 GiB reclaimed=1.0 GiB manual_review=3 delete_failures=0'* ]] \
  || {
    printf '%s\n' "$apply_output" >&2
    fail_test "apply summary did not report the deleted simulator"
  }

jq --arg udid "$OLD_SHUTDOWN_ID" '
  .devices[] |= map(if .udid == $udid then .state = "Booted" else . end)
' "$INITIAL_JSON" >"$RECHECK_JSON"
: >"$LIST_COUNT"
: >"$DELETE_LOG"
recheck_output="$(run_remote_fixture apply 2>&1)"
[[ ! -s "$DELETE_LOG" ]] || fail_test "apply deleted a simulator that became booted"
[[ "$recheck_output" == *'mode=apply eligible=1 deleted=0'* ]] \
  || fail_test "safety recheck did not retain a changed simulator"

if FAKE_GIT_TOPLEVEL="$TEST_ROOT/different-repo" run_remote_fixture dry-run >/dev/null 2>&1; then
  fail_test "cleanup accepted a remote repository identity mismatch"
fi

if TOASTTY_REMOTE_GUI_HOST= \
   TOASTTY_REMOTE_GUI_REPO_ROOT= \
   TOASTTY_REMOTE_GUI_ROOT= \
   /bin/bash "$SCRIPT" --dry-run >/dev/null 2>&1; then
  fail_test "local wrapper accepted missing remote identity configuration"
fi

printf 'ok: remote simulator cleanup self-test passed\n'
