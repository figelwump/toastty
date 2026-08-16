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
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/xcrun"

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
write_manifest kept 2024-12-20T00:00:00Z
: >"$REMOTE_GUI/test-runs/kept/.keep"

live_started_at="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$$" | awk '{$1=$1; print}')"
write_manifest live 2024-12-20T00:00:00Z "$$" "$live_started_at"

mkdir -p "$REMOTE_GUI/test-runs/malformed" "$REMOTE_GUI/worktrees/malformed"
printf '{not-json\n' >"$REMOTE_GUI/test-runs/malformed/run-ownership.json"
mkdir -p "$REMOTE_GUI/test-runs/unowned"
mkdir -p "$TEST_ROOT/outside"
ln -s "$TEST_ROOT/outside" "$REMOTE_GUI/test-runs/symlink"

dry_output="$(run_remote_fixture dry-run 2>&1)"
[[ "$dry_output" == *'mode=dry-run eligible=2 deleted=0 retained=3'* ]] || {
  printf '%s\n' "$dry_output" >&2
  fail_test "dry-run summary did not preserve retained runs"
}
[[ "$dry_output" == *'manual_review=3 delete_failures=0'* ]] \
  || fail_test "dry-run summary did not report unowned/malformed paths"
[[ ! -s "$DELETE_LOG" ]] || fail_test "dry run deleted a simulator"

apply_output="$(run_remote_fixture apply 2>&1)"
[[ "$apply_output" == *'mode=apply eligible=2 deleted=2 retained=3'* ]] || {
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
for retained in recent kept live malformed unowned symlink; do
  [[ -e "$REMOTE_GUI/test-runs/$retained" || -L "$REMOTE_GUI/test-runs/$retained" ]] \
    || fail_test "apply removed protected path: $retained"
done

printf 'ok: remote run cleanup self-test passed\n'
