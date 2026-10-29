#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/remote/cleanup-remote-runs.sh"
TEST_ROOT="$(mktemp -d /tmp/toastty-remote-run-cleanup.XXXXXX)"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
FAKE_BIN="$TEST_ROOT/bin"
REMOTE_REPO="$TEST_ROOT/remote-repo"
REMOTE_GUI="$TEST_ROOT/remote-gui"
DELETE_LOG="$TEST_ROOT/simulator-deleted.log"
PS_CALL_LOG="$TEST_ROOT/ps-calls"
NOW_EPOCH=1735689600
SIMULATOR_ID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

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

write_manifest() {
  local run_label="$1"
  local created_at="$2"
  local owner_pid="${3:-999999}"
  local owner_started_at="${4:-Mon Jan  1 00:00:00 2024}"
  local run_dir="$REMOTE_GUI/test-runs/$run_label"
  local worktree="$REMOTE_GUI/worktrees/$run_label"
  mkdir -p "$run_dir/runtime-home" "$worktree"
  jq -n \
    --arg runLabel "$run_label" \
    --arg runRoot "$run_dir" \
    --arg worktree "$worktree" \
    --arg createdAt "$created_at" \
    --arg ownerStartedAt "$owner_started_at" \
    --argjson ownerPID "$owner_pid" '{
      schemaVersion:1,
      ownership:"toastty-remote-test",
      runLabel:$runLabel,
      remoteRunRoot:$runRoot,
      remoteWorktreePath:$worktree,
      derivedDataPath:($runRoot + "/Derived"),
      runtimeHomePath:($runRoot + "/runtime-home"),
      platform:"ios",
      owner:{pid:$ownerPID,pgid:$ownerPID,startedAt:$ownerStartedAt},
      createdAt:$createdAt
  }' >"$run_dir/run-ownership.json"
  : >"$run_dir/STARTED"
  case "$created_at" in
    2024-12-20T00:00:00Z) touch -t 202412200000 "$run_dir" ;;
    2024-12-31T23:30:00Z) touch -t 202412312330 "$run_dir" ;;
  esac
}

run_remote_fixture() {
  local mode="$1"
  PATH="$FAKE_BIN:$PATH" \
  FAKE_GIT_TOPLEVEL="$REMOTE_REPO" \
  FAKE_SIMULATOR_DELETE_LOG="$DELETE_LOG" \
  FAKE_SIMULATOR_ID="$SIMULATOR_ID" \
  FAKE_PROCESS_RUN_PATH="$REMOTE_GUI/test-runs/process-run" \
  FAKE_PROCESS_WORKTREE_PATH="$REMOTE_GUI/worktrees/process-worktree" \
  FAKE_PS_MODE="${FAKE_PS_MODE:-normal}" \
  FAKE_PS_CALL_LOG="$PS_CALL_LOG" \
  FAKE_FIND_MODE="${FAKE_FIND_MODE:-normal}" \
    /bin/bash "$SCRIPT" \
      --remote-exec \
      "$mode" \
      "$NOW_EPOCH" \
      24 \
      10 \
      "$(encode_base64 "$REMOTE_REPO")" \
      "$(encode_base64 "$REMOTE_GUI")" \
      cleanup-remote-runs.sh
}

mkdir -p \
  "$FAKE_BIN" \
  "$REMOTE_REPO/scripts/remote" \
  "$REMOTE_GUI/test-runs" \
  "$REMOTE_GUI/worktrees"
touch "$REMOTE_REPO/Project.swift" "$REMOTE_REPO/scripts/remote/test.sh" "$DELETE_LOG"

cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-C" && "$3" == "rev-parse" && "$4" == "--show-toplevel" ]]; then
  printf '%s\n' "$FAKE_GIT_TOPLEVEL"
  exit 0
fi
if [[ "$1" == "-C" && "$3" == "worktree" && "$4" == "remove" && "$5" == "--force" ]]; then
  rm -rf -- "$6"
  exit 0
fi
if [[ "$1" == "-C" && "$3" == "worktree" && "$4" == "prune" ]]; then
  exit 0
fi
exit 1
EOF

cat >"$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -axww ]]; then
  case "$FAKE_PS_MODE" in
    fail)
      printf 'fixture-private-command=do-not-log\n' >&2
      exit 1
      ;;
    empty) exit 0 ;;
    unparseable)
      printf 'unparseable process inventory\n'
      exit 0
      ;;
    fail-recheck|fail-worktree)
      count=0
      [[ ! -f "$FAKE_PS_CALL_LOG" ]] || count="$(cat "$FAKE_PS_CALL_LOG")"
      count=$((count + 1))
      printf '%s\n' "$count" >"$FAKE_PS_CALL_LOG"
      if [[ "$FAKE_PS_MODE" == fail-worktree ]]; then
        (( count <= 1 )) || exit 1
      else
        (( count <= 2 )) || exit 1
      fi
      ;;
  esac
  printf '424241 fixture --private-token=do-not-log %s\n' "$FAKE_PROCESS_RUN_PATH"
  printf '424242 fixture --private-token=do-not-log %s\n' "$FAKE_PROCESS_WORKTREE_PATH"
  exit 0
fi
exec /bin/ps "$@"
EOF

cat >"$FAKE_BIN/find" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/find "$@"
[[ "$FAKE_FIND_MODE" != fail ]]
EOF

cat >"$FAKE_BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == simctl ]] || exit 1
if [[ "$2" == list && "$3" == devices && "$4" == --json ]]; then
  if grep -qx "$FAKE_SIMULATOR_ID" "$FAKE_SIMULATOR_DELETE_LOG"; then
    jq -nc '{devices:{runtime:[]}}'
  else
    jq -nc --arg udid "$FAKE_SIMULATOR_ID" '{devices:{runtime:[{
      name:"Toastty Remote test-eligible-simulator-fixture",
      udid:$udid,
      state:"Shutdown"
    }]}}'
  fi
  exit 0
fi
if [[ "$2" == delete && "$3" == "$FAKE_SIMULATOR_ID" ]]; then
  printf '%s\n' "$3" >>"$FAKE_SIMULATOR_DELETE_LOG"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/ps" "$FAKE_BIN/find" "$FAKE_BIN/xcrun"

write_manifest eligible-simple 2024-12-20T00:00:00Z
write_manifest eligible-simulator 2024-12-20T00:00:00Z
simulator_run="$REMOTE_GUI/test-runs/eligible-simulator"
jq -n \
  --arg runRoot "$simulator_run" \
  --arg worktree "$REMOTE_GUI/worktrees/eligible-simulator" \
  --arg udid "$SIMULATOR_ID" '{
    schemaVersion:1,
    ownership:"toastty-remote-test",
    runLabel:"eligible-simulator",
    remoteRunRoot:$runRoot,
    remoteWorktreePath:$worktree,
    derivedDataPath:($runRoot + "/Derived"),
    runtimeHomePath:($runRoot + "/runtime-home"),
    simulator:{udid:$udid,name:"Toastty Remote test-eligible-simulator-fixture"}
  }' >"$simulator_run/simulator-ownership.json"
touch -t 202412200000 "$simulator_run"

write_manifest recent 2024-12-31T23:30:00Z
write_manifest modified 2024-12-20T00:00:00Z
TZ=UTC touch -t 202412312330 "$REMOTE_GUI/test-runs/modified"
write_manifest kept 2024-12-20T00:00:00Z
: >"$REMOTE_GUI/test-runs/kept/.keep"

live_started_at="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$$" | awk '{$1=$1; print}')"
write_manifest live 2024-12-20T00:00:00Z "$$" "$live_started_at"
write_manifest process-run 2024-12-20T00:00:00Z
write_manifest process-worktree 2024-12-20T00:00:00Z

mkdir -p "$REMOTE_GUI/test-runs/malformed" "$REMOTE_GUI/worktrees/malformed"
printf '{not-json\n' >"$REMOTE_GUI/test-runs/malformed/run-ownership.json"
mkdir -p "$REMOTE_GUI/test-runs/unowned"
mkdir -p "$TEST_ROOT/outside"
ln -s "$TEST_ROOT/outside" "$REMOTE_GUI/test-runs/symlink"

dry_output="$(run_remote_fixture dry-run 2>&1)"
[[ "$dry_output" == *'mode=dry-run eligible=2 deleted=0 retained=6'* ]] || {
  printf '%s\n' "$dry_output" >&2
  fail_test "dry-run summary did not preserve retained runs"
}
[[ "$dry_output" == *'manual_review=3 delete_failures=0'* ]] \
  || fail_test "dry-run summary did not report unowned/malformed paths"
[[ ! -s "$DELETE_LOG" ]] || fail_test "dry run deleted a simulator"
for reason in keep-marker recent-creation recent-modification live-owner run-process worktree-process; do
  [[ "$dry_output" == *"retained reason=$reason "* ]] \
    || fail_test "dry run omitted retained reason: $reason"
done
[[ "$dry_output" == *'reason=run-process pid=424241 '* ]] \
  || fail_test "run process diagnostic omitted matched PID"
[[ "$dry_output" == *'reason=worktree-process pid=424242 '* ]] \
  || fail_test "worktree process diagnostic omitted matched PID"
[[ "$dry_output" != *'do-not-log'* ]] || fail_test "cleanup exposed process command text"

apply_output="$(run_remote_fixture apply 2>&1)"
[[ "$apply_output" == *'mode=apply eligible=2 deleted=2 retained=6'* ]] || {
  printf '%s\n' "$apply_output" >&2
  fail_test "apply summary did not report exact deletions"
}
[[ "$apply_output" == *'manual_review=3 delete_failures=0'* ]] \
  || fail_test "apply summary changed manual-review accounting"
[[ ! -e "$REMOTE_GUI/test-runs/eligible-simple" ]] \
  || fail_test "apply retained an eligible manifest-owned run"
[[ ! -e "$REMOTE_GUI/test-runs/eligible-simulator" ]] \
  || fail_test "apply retained an eligible simulator-owned run"
[[ "$(cat "$DELETE_LOG")" == "$SIMULATOR_ID" ]] \
  || fail_test "apply did not delete exactly the manifest-owned shutdown simulator"
for retained in recent modified kept live process-run process-worktree malformed unowned symlink; do
  [[ -e "$REMOTE_GUI/test-runs/$retained" || -L "$REMOTE_GUI/test-runs/$retained" ]] \
    || fail_test "apply removed protected path: $retained"
done

write_manifest inventory-failure 2024-12-20T00:00:00Z
for inventory_mode in fail empty unparseable; do
  failure_output="$(FAKE_PS_MODE="$inventory_mode" run_remote_fixture apply 2>&1)"
  [[ "$failure_output" == *'mode=apply eligible=0 deleted=0 retained=4'* \
    && "$failure_output" == *'manual_review=6 delete_failures=0'* ]] \
    || fail_test "process inventory mode=$inventory_mode was not classified as manual review"
  [[ "$failure_output" == *'reason=process-inventory-failed '* ]] \
    || fail_test "process inventory mode=$inventory_mode diagnostic was missing"
  [[ "$failure_output" != *'do-not-log'* ]] || fail_test "cleanup exposed process inventory error text"
  [[ -d "$REMOTE_GUI/test-runs/inventory-failure" \
    && -d "$REMOTE_GUI/worktrees/inventory-failure" ]] \
    || fail_test "process inventory mode=$inventory_mode allowed deletion"
done

# Isolate one candidate so the third inventory request is its apply recheck.
rm -rf "$REMOTE_GUI/test-runs" "$REMOTE_GUI/worktrees"
mkdir -p "$REMOTE_GUI/test-runs" "$REMOTE_GUI/worktrees"
write_manifest recheck-failure 2024-12-20T00:00:00Z
worktree_output="$(FAKE_PS_MODE=fail-worktree run_remote_fixture apply 2>&1)"
[[ "$worktree_output" == *'mode=apply eligible=0 deleted=0 retained=0'* \
  && "$worktree_output" == *'manual_review=1 delete_failures=0'* \
  && "$worktree_output" == *'reason=process-inventory-failed '* ]] \
  || fail_test "failed worktree process inventory was not classified as manual review"
[[ -d "$REMOTE_GUI/test-runs/recheck-failure" \
  && -d "$REMOTE_GUI/worktrees/recheck-failure" ]] \
  || fail_test "failed worktree process inventory allowed deletion"
rm -f "$PS_CALL_LOG"
if recheck_output="$(FAKE_PS_MODE=fail-recheck run_remote_fixture apply 2>&1)"; then
  fail_test "failed apply inventory recheck returned success"
fi
[[ "$recheck_output" == *'mode=apply eligible=1 deleted=0 retained=0'* \
  && "$recheck_output" == *'delete_failures=1'* \
  && "$recheck_output" == *'reason=process-inventory-failed '* ]] \
  || fail_test "failed apply inventory recheck was not visible"
[[ -d "$REMOTE_GUI/test-runs/recheck-failure" \
  && -d "$REMOTE_GUI/worktrees/recheck-failure" ]] \
  || fail_test "failed apply inventory recheck allowed deletion"

if enumeration_output="$(FAKE_FIND_MODE=fail run_remote_fixture apply 2>&1)"; then
  fail_test "failed candidate enumeration returned success"
fi
[[ "$enumeration_output" == *'could not enumerate remote test runs; no candidates were deleted'* ]] \
  || fail_test "failed candidate enumeration diagnostic was missing"
[[ -d "$REMOTE_GUI/test-runs/recheck-failure" \
  && -d "$REMOTE_GUI/worktrees/recheck-failure" ]] \
  || fail_test "failed candidate enumeration allowed deletion"

printf 'ok: remote run cleanup self-test passed\n'
