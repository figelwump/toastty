#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/remote/cleanup-simulator-app.sh"
TEST_ROOT="$(mktemp -d /tmp/toastty-remote-simulator-app-cleanup.XXXXXX)"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
FAKE_BIN="$TEST_ROOT/bin"
REMOTE_REPO="$TEST_ROOT/remote-repo"
REMOTE_GUI="$TEST_ROOT/remote-gui"
INITIAL_DEVICES="$TEST_ROOT/initial-devices.json"
RECHECK_DEVICES="$TEST_ROOT/recheck-devices.json"
SIMCTL_LIST_COUNT="$TEST_ROOT/simctl-list-count"
PGREP_COUNT="$TEST_ROOT/pgrep-count"
SIMULATOR_PID_FILE="$TEST_ROOT/simulator.pid"
SIMULATOR_PID=""
SIMULATOR_ETIME="01:00:00"
SIMCTL_FAIL=0
PGREP_DISAPPEAR_AFTER_FIRST=0
OSASCRIPT_MODE="quit"
LIVE_OWNER_PID="$$"
LIVE_OWNER_STARTED_AT="Mon Jan 1 00:00:00 2024"

cleanup() {
  if [[ "$SIMULATOR_PID" =~ ^[1-9][0-9]*$ ]] \
    && kill -0 "$SIMULATOR_PID" >/dev/null 2>&1; then
    kill -KILL "$SIMULATOR_PID" >/dev/null 2>&1 || true
    wait "$SIMULATOR_PID" >/dev/null 2>&1 || true
  fi
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

write_devices() {
  local path="$1"
  local state="${2:-Shutdown}"
  if [[ "$state" == "Shutdown" ]]; then
    jq -nc '{devices:{runtime:[]}}' >"$path"
  else
    jq -nc --arg state "$state" '{devices:{runtime:[{name:"iPhone 17 Pro",udid:"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",state:$state}]}}' >"$path"
  fi
}

start_fake_simulator() {
  sleep 300 &
  SIMULATOR_PID=$!
  disown "$SIMULATOR_PID" 2>/dev/null || true
  printf '%s\n' "$SIMULATOR_PID" >"$SIMULATOR_PID_FILE"
}

stop_fake_simulator() {
  if [[ "$SIMULATOR_PID" =~ ^[1-9][0-9]*$ ]] \
    && kill -0 "$SIMULATOR_PID" >/dev/null 2>&1; then
    kill -KILL "$SIMULATOR_PID" >/dev/null 2>&1 || true
  fi
  wait "$SIMULATOR_PID" >/dev/null 2>&1 || true
  SIMULATOR_PID=""
  : >"$SIMULATOR_PID_FILE"
}

write_live_ios_manifest() {
  local run_label="live-ios"
  local run_dir="$REMOTE_GUI/test-runs/$run_label"
  local worktree="$REMOTE_GUI/worktrees/$run_label"
  mkdir -p "$run_dir/runtime-home" "$worktree"
  jq -n \
    --arg runLabel "$run_label" \
    --arg runRoot "$run_dir" \
    --arg worktree "$worktree" \
    --arg ownerStartedAt "$LIVE_OWNER_STARTED_AT" \
    --argjson ownerPID "$LIVE_OWNER_PID" '{
      schemaVersion:1,
      ownership:"toastty-remote-test",
      runLabel:$runLabel,
      remoteRunRoot:$runRoot,
      remoteWorktreePath:$worktree,
      derivedDataPath:($runRoot + "/Derived"),
      runtimeHomePath:($runRoot + "/runtime-home"),
      platform:"ios",
      owner:{pid:$ownerPID,pgid:$ownerPID,startedAt:$ownerStartedAt},
      createdAt:"2025-01-01T00:00:00Z"
    }' >"$run_dir/run-ownership.json"
}

run_remote_fixture() {
  local mode="$1"
  PATH="$FAKE_BIN:$PATH" \
  FAKE_GIT_TOPLEVEL="${FAKE_GIT_TOPLEVEL:-$REMOTE_REPO}" \
  FAKE_SIMULATOR_PID_FILE="$SIMULATOR_PID_FILE" \
  FAKE_SIMULATOR_ETIME="$SIMULATOR_ETIME" \
  FAKE_LIVE_OWNER_PID="$LIVE_OWNER_PID" \
  FAKE_LIVE_OWNER_STARTED_AT="$LIVE_OWNER_STARTED_AT" \
  FAKE_SIMCTL_INITIAL_JSON="$INITIAL_DEVICES" \
  FAKE_SIMCTL_RECHECK_JSON="$RECHECK_DEVICES" \
  FAKE_SIMCTL_LIST_COUNT="$SIMCTL_LIST_COUNT" \
  FAKE_SIMCTL_FAIL="$SIMCTL_FAIL" \
  FAKE_PGREP_COUNT="$PGREP_COUNT" \
  FAKE_PGREP_DISAPPEAR_AFTER_FIRST="$PGREP_DISAPPEAR_AFTER_FIRST" \
  FAKE_OSASCRIPT_MODE="$OSASCRIPT_MODE" \
    /bin/bash "$SCRIPT" \
      --remote-exec \
      "$mode" \
      "$(encode_base64 "$REMOTE_REPO")" \
      "$(encode_base64 "$REMOTE_GUI")" \
      cleanup-simulator-app.sh
}

mkdir -p \
  "$FAKE_BIN" \
  "$REMOTE_REPO/scripts/remote" \
  "$REMOTE_GUI/test-runs" \
  "$REMOTE_GUI/worktrees"
touch "$REMOTE_REPO/Project.swift" "$REMOTE_REPO/scripts/remote/test.sh"
write_devices "$INITIAL_DEVICES"
write_devices "$RECHECK_DEVICES"
: >"$SIMCTL_LIST_COUNT"
: >"$PGREP_COUNT"
: >"$SIMULATOR_PID_FILE"

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
  '[[ "$1" == simctl && "$2" == list && "$3" == devices && "$4" == booted && "$5" == --json ]] || exit 1' \
  '[[ "$FAKE_SIMCTL_FAIL" != 1 ]] || exit 1' \
  'count=0' \
  'if [[ -f "$FAKE_SIMCTL_LIST_COUNT" ]]; then count="$(cat "$FAKE_SIMCTL_LIST_COUNT")"; fi' \
  'count=$((count + 1))' \
  'printf "%s\\n" "$count" >"$FAKE_SIMCTL_LIST_COUNT"' \
  'if (( count > 1 )); then cat "$FAKE_SIMCTL_RECHECK_JSON"; else cat "$FAKE_SIMCTL_INITIAL_JSON"; fi' \
  >"$FAKE_BIN/xcrun"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ "$1" == -x && "$2" == Simulator ]] || exit 1' \
  'count=0' \
  'if [[ -f "$FAKE_PGREP_COUNT" ]]; then count="$(cat "$FAKE_PGREP_COUNT")"; fi' \
  'count=$((count + 1))' \
  'printf "%s\\n" "$count" >"$FAKE_PGREP_COUNT"' \
  'if [[ "$FAKE_PGREP_DISAPPEAR_AFTER_FIRST" == 1 && "$count" -gt 1 ]]; then exit 1; fi' \
  'pid="$(cat "$FAKE_SIMULATOR_PID_FILE" 2>/dev/null || true)"' \
  'if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" >/dev/null 2>&1; then' \
  '  printf "%s\\n" "$pid"' \
  '  exit 0' \
  'fi' \
  'exit 1' \
  >"$FAKE_BIN/pgrep"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'pid="$(cat "$FAKE_SIMULATOR_PID_FILE" 2>/dev/null || true)"' \
  'if [[ "${1:-}" == -o && "${2:-}" == lstart= && "${3:-}" == -p && "${4:-}" == "$FAKE_LIVE_OWNER_PID" ]]; then' \
  '  printf "%s\\n" "$FAKE_LIVE_OWNER_STARTED_AT"' \
  '  exit 0' \
  'fi' \
  'if [[ "${1:-}" == -ww && "${2:-}" == -o && "${3:-}" == comm= && "${4:-}" == -p && "${5:-}" == "$pid" ]]; then' \
  '  if kill -0 "$pid" >/dev/null 2>&1; then' \
  '    printf "%s\\n" "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"' \
  '  fi' \
  '  exit 0' \
  'fi' \
  'if [[ "${1:-}" == -ww && "${2:-}" == -o && "${3:-}" == etime= && "${4:-}" == -p && "${5:-}" == "$pid" ]]; then' \
  '  if kill -0 "$pid" >/dev/null 2>&1; then printf "%s\\n" "$FAKE_SIMULATOR_ETIME"; fi' \
  '  exit 0' \
  'fi' \
  'if [[ "${1:-}" == -ww && "${2:-}" == -o && "${3:-}" == pid= && "${4:-}" == -p && "${5:-}" == "$pid" ]]; then' \
  '  if kill -0 "$pid" >/dev/null 2>&1; then printf "%s\\n" "$pid"; fi' \
  '  exit 0' \
  'fi' \
  'if [[ "${1:-}" == -axww && "${2:-}" == -o && "${3:-}" == pid=,command= ]]; then' \
  '  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" >/dev/null 2>&1; then' \
  '    printf "%s %s\\n" "$pid" "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"' \
  '  fi' \
  '  exit 0' \
  'fi' \
  'exec /bin/ps "$@"' \
  >"$FAKE_BIN/ps"

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

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "$FAKE_OSASCRIPT_MODE" == quit ]]; then' \
  '  pid="$(cat "$FAKE_SIMULATOR_PID_FILE" 2>/dev/null || true)"' \
  '  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then kill -TERM "$pid" >/dev/null 2>&1 || true; fi' \
  '  exit 0' \
  'fi' \
  'sleep 300' \
  >"$FAKE_BIN/osascript"
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/xcrun" "$FAKE_BIN/pgrep" "$FAKE_BIN/ps" "$FAKE_BIN/ssh" "$FAKE_BIN/osascript"

start_fake_simulator
: >"$SIMCTL_LIST_COUNT"
dry_output="$(run_remote_fixture dry-run 2>&1)"
kill -0 "$SIMULATOR_PID" >/dev/null 2>&1 \
  || fail_test "dry run terminated Simulator.app"
[[ "$dry_output" == *'mode=dry-run eligible=1 terminated=0 retained=0 booted_devices=0 active_ios_runs=0 ambiguous_live_runs=0 manual_review=0 terminate_failures=0'* ]] \
  || {
    printf '%s\n' "$dry_output" >&2
    fail_test "dry-run summary did not report the eligible Simulator.app process"
  }

: >"$SIMCTL_LIST_COUNT"
local_wrapper_output="$(
  PATH="$FAKE_BIN:$PATH" \
  FAKE_GIT_TOPLEVEL="$REMOTE_REPO" \
  FAKE_SIMULATOR_PID_FILE="$SIMULATOR_PID_FILE" \
  FAKE_SIMULATOR_ETIME="$SIMULATOR_ETIME" \
  FAKE_LIVE_OWNER_PID="$LIVE_OWNER_PID" \
  FAKE_LIVE_OWNER_STARTED_AT="$LIVE_OWNER_STARTED_AT" \
  FAKE_SIMCTL_INITIAL_JSON="$INITIAL_DEVICES" \
  FAKE_SIMCTL_RECHECK_JSON="$RECHECK_DEVICES" \
  FAKE_SIMCTL_LIST_COUNT="$SIMCTL_LIST_COUNT" \
  FAKE_SIMCTL_FAIL="$SIMCTL_FAIL" \
  FAKE_PGREP_COUNT="$PGREP_COUNT" \
  FAKE_PGREP_DISAPPEAR_AFTER_FIRST="$PGREP_DISAPPEAR_AFTER_FIRST" \
  FAKE_OSASCRIPT_MODE="$OSASCRIPT_MODE" \
  TOASTTY_REMOTE_GUI_HOST=fixture-host \
  TOASTTY_REMOTE_GUI_REPO_ROOT="$REMOTE_REPO" \
  TOASTTY_REMOTE_GUI_ROOT="$REMOTE_GUI" \
    /bin/bash "$SCRIPT" --dry-run 2>&1
)"
[[ "$local_wrapper_output" == *'target=fixture-host mode=dry-run'* ]] \
  || fail_test "local wrapper did not preserve the configured remote target"
[[ "$local_wrapper_output" == *'mode=dry-run eligible=1 terminated=0'* ]] \
  || fail_test "local wrapper did not execute the piped remote cleanup script"

: >"$SIMCTL_LIST_COUNT"
apply_output="$(run_remote_fixture apply 2>&1)"
if kill -0 "$SIMULATOR_PID" >/dev/null 2>&1; then
  fail_test "apply did not terminate the eligible Simulator.app process"
fi
wait "$SIMULATOR_PID" >/dev/null 2>&1 || true
SIMULATOR_PID=""
: >"$SIMULATOR_PID_FILE"
[[ "$apply_output" == *'mode=apply eligible=1 terminated=1 retained=0 booted_devices=0 active_ios_runs=0 ambiguous_live_runs=0 manual_review=0 terminate_failures=0'* ]] \
  || {
    printf '%s\n' "$apply_output" >&2
    fail_test "apply summary did not report exact process termination"
  }

start_fake_simulator
write_devices "$INITIAL_DEVICES" Booted
write_devices "$RECHECK_DEVICES" Booted
: >"$SIMCTL_LIST_COUNT"
booted_output="$(run_remote_fixture apply 2>&1)"
kill -0 "$SIMULATOR_PID" >/dev/null 2>&1 \
  || fail_test "cleanup terminated Simulator.app while a device was booted"
[[ "$booted_output" == *'mode=apply eligible=0 terminated=0 retained=1 booted_devices=1'* ]] \
  || fail_test "cleanup did not retain Simulator.app for a booted device"
stop_fake_simulator

start_fake_simulator
write_devices "$INITIAL_DEVICES" "Shutting Down"
write_devices "$RECHECK_DEVICES" "Shutting Down"
: >"$SIMCTL_LIST_COUNT"
transition_output="$(run_remote_fixture apply 2>&1)"
kill -0 "$SIMULATOR_PID" >/dev/null 2>&1 \
  || fail_test "cleanup terminated Simulator.app during a transitional device state"
[[ "$transition_output" == *'mode=apply eligible=0 terminated=0 retained=1 booted_devices=1'* ]] \
  || fail_test "cleanup did not retain Simulator.app for a transitional device state"
stop_fake_simulator

start_fake_simulator
write_devices "$INITIAL_DEVICES"
write_devices "$RECHECK_DEVICES"
SIMULATOR_ETIME="00:30"
: >"$SIMCTL_LIST_COUNT"
recent_output="$(run_remote_fixture apply 2>&1)"
kill -0 "$SIMULATOR_PID" >/dev/null 2>&1 \
  || fail_test "cleanup terminated a recently launched Simulator.app process"
[[ "$recent_output" == *'mode=apply eligible=0 terminated=0 retained=1'* ]] \
  || fail_test "cleanup did not retain a recent Simulator.app process"
SIMULATOR_ETIME="01:00:00"
stop_fake_simulator

start_fake_simulator
write_devices "$INITIAL_DEVICES"
write_devices "$RECHECK_DEVICES"
SIMCTL_FAIL=1
: >"$SIMCTL_LIST_COUNT"
if run_remote_fixture apply >/dev/null 2>&1; then
  fail_test "cleanup accepted a failed simctl safety probe"
fi
kill -0 "$SIMULATOR_PID" >/dev/null 2>&1 \
  || fail_test "cleanup terminated Simulator.app after a failed simctl probe"
SIMCTL_FAIL=0
stop_fake_simulator

start_fake_simulator
printf '{}\n' >"$INITIAL_DEVICES"
printf '{}\n' >"$RECHECK_DEVICES"
: >"$SIMCTL_LIST_COUNT"
if run_remote_fixture apply >/dev/null 2>&1; then
  fail_test "cleanup accepted malformed simctl safety JSON"
fi
kill -0 "$SIMULATOR_PID" >/dev/null 2>&1 \
  || fail_test "cleanup terminated Simulator.app after malformed simctl JSON"
stop_fake_simulator

start_fake_simulator
write_devices "$INITIAL_DEVICES"
write_devices "$RECHECK_DEVICES"
write_live_ios_manifest
owner_probe="$(
  PATH="$FAKE_BIN:$PATH" \
  FAKE_SIMULATOR_PID_FILE="$SIMULATOR_PID_FILE" \
  FAKE_LIVE_OWNER_PID="$LIVE_OWNER_PID" \
  FAKE_LIVE_OWNER_STARTED_AT="$LIVE_OWNER_STARTED_AT" \
    ps -o lstart= -p "$LIVE_OWNER_PID"
)"
[[ "$owner_probe" == "$LIVE_OWNER_STARTED_AT" ]] \
  || fail_test "live-owner process fixture did not preserve the expected start time"
jq -e \
  --arg runLabel live-ios \
  --arg runRoot "$REMOTE_GUI/test-runs/live-ios" \
  --arg worktree "$REMOTE_GUI/worktrees/live-ios" '
    .schemaVersion == 1
    and .ownership == "toastty-remote-test"
    and .runLabel == $runLabel
    and .remoteRunRoot == $runRoot
    and .remoteWorktreePath == $worktree
    and .derivedDataPath == ($runRoot + "/Derived")
    and .runtimeHomePath == ($runRoot + "/runtime-home")
    and .platform == "ios"
    and (.owner.pid | type == "number" and floor == . and . > 0)
    and (.owner.startedAt | type == "string" and length > 0)
  ' "$REMOTE_GUI/test-runs/live-ios/run-ownership.json" >/dev/null \
  || fail_test "live-owner manifest fixture did not satisfy the cleanup contract"
: >"$SIMCTL_LIST_COUNT"
live_output="$(run_remote_fixture apply 2>&1)"
kill -0 "$SIMULATOR_PID" >/dev/null 2>&1 \
  || fail_test "cleanup terminated Simulator.app during a live iOS run"
[[ "$live_output" == *'mode=apply eligible=0 terminated=0 retained=1 booted_devices=0 active_ios_runs=1'* ]] \
  || {
    printf '%s\n' "$live_output" >&2
    fail_test "cleanup did not retain Simulator.app for a live iOS run"
  }
stop_fake_simulator
rm -rf "$REMOTE_GUI/test-runs/live-ios" "$REMOTE_GUI/worktrees/live-ios"

start_fake_simulator
write_devices "$INITIAL_DEVICES"
write_devices "$RECHECK_DEVICES" Booting
: >"$SIMCTL_LIST_COUNT"
recheck_output="$(run_remote_fixture apply 2>&1)"
kill -0 "$SIMULATOR_PID" >/dev/null 2>&1 \
  || fail_test "cleanup terminated Simulator.app after a device booted during recheck"
[[ "$recheck_output" == *'mode=apply eligible=1 terminated=0 retained=1 booted_devices=1'* ]] \
  || {
    printf '%s\n' "$recheck_output" >&2
    fail_test "safety recheck did not retain Simulator.app"
  }
stop_fake_simulator

start_fake_simulator
write_devices "$INITIAL_DEVICES"
write_devices "$RECHECK_DEVICES"
PGREP_DISAPPEAR_AFTER_FIRST=1
: >"$PGREP_COUNT"
: >"$SIMCTL_LIST_COUNT"
disappeared_output="$(run_remote_fixture apply 2>&1)"
[[ "$disappeared_output" == *'mode=apply eligible=1 terminated=0 retained=0'* ]] \
  || {
    printf '%s\n' "$disappeared_output" >&2
    fail_test "cleanup did not tolerate Simulator.app disappearing during recheck"
  }
PGREP_DISAPPEAR_AFTER_FIRST=0
stop_fake_simulator

write_devices "$INITIAL_DEVICES"
write_devices "$RECHECK_DEVICES"
: >"$SIMCTL_LIST_COUNT"
no_process_output="$(run_remote_fixture dry-run 2>&1)"
[[ "$no_process_output" == *'mode=dry-run eligible=0 terminated=0 retained=0'* ]] \
  || fail_test "cleanup did not treat an absent Simulator.app as a no-op"

if FAKE_GIT_TOPLEVEL="$TEST_ROOT/different-repo" run_remote_fixture dry-run >/dev/null 2>&1; then
  fail_test "cleanup accepted a remote repository identity mismatch"
fi

if TOASTTY_REMOTE_GUI_HOST= \
   TOASTTY_REMOTE_GUI_REPO_ROOT= \
   TOASTTY_REMOTE_GUI_ROOT= \
   /bin/bash "$SCRIPT" --dry-run >/dev/null 2>&1; then
  fail_test "local wrapper accepted missing remote identity configuration"
fi

printf 'ok: remote Simulator.app cleanup self-test passed\n'
