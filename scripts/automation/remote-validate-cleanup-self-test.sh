#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d /tmp/toastty-remote-validate-cleanup.XXXXXX)"
FIXTURE_ROOT="$TEST_ROOT/worktree"
FAKE_BIN="$TEST_ROOT/bin"
UNRELATED_PID=""

kill_test_pid() {
  local pid="$1"
  if [[ "$pid" =~ ^[0-9]+$ ]] && ((pid > 1)); then
    kill -KILL "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local cleanup_exit_code=$?
  local fake_app_pid_file
  local fake_app_pid

  while IFS= read -r fake_app_pid_file; do
    [[ -n "$fake_app_pid_file" ]] || continue
    fake_app_pid="$(cat "$fake_app_pid_file")"
    kill_test_pid "$fake_app_pid"
  done < <(find "$TEST_ROOT" -name fake-app.pid -type f 2>/dev/null || true)
  kill_test_pid "$UNRELATED_PID"
  rm -rf "$TEST_ROOT"
  return "$cleanup_exit_code"
}
trap cleanup EXIT

mkdir -p \
  "$FIXTURE_ROOT/scripts/automation" \
  "$FIXTURE_ROOT/scripts/dev" \
  "$FIXTURE_ROOT/scripts/remote" \
  "$FAKE_BIN" \
  "$TEST_ROOT/tmp"

cp "$ROOT_DIR/scripts/automation/runtime-ownership.sh" "$FIXTURE_ROOT/scripts/automation/runtime-ownership.sh"
cp "$ROOT_DIR/scripts/remote/validate.sh" "$FIXTURE_ROOT/scripts/remote/validate.sh"

cat >"$FIXTURE_ROOT/scripts/dev/bootstrap-worktree.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
chmod +x "$FIXTURE_ROOT/scripts/dev/bootstrap-worktree.sh"

cat >"$FAKE_BIN/peekaboo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/peekaboo"

cat >"$FAKE_BIN/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

derived_path=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-derivedDataPath" ]]; then
    derived_path="$2"
    break
  fi
  shift
done

if [[ -z "$derived_path" ]]; then
  echo "error: fake xcodebuild did not receive -derivedDataPath" >&2
  exit 1
fi

app_binary="$derived_path/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty"
mkdir -p "$(dirname "$app_binary")"
cat >"$app_binary" <<'APP'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$TOASTTY_RUNTIME_HOME" "$(dirname "$TOASTTY_SOCKET_PATH")"
: >"$TOASTTY_SOCKET_PATH"
printf '%s\n' "$$" >"$TOASTTY_RUNTIME_HOME/fake-app.pid"
recorded_pid="${FAKE_RECORDED_PID:-$$}"
cat >"$TOASTTY_RUNTIME_HOME/instance.json" <<JSON
{
  "pid": $recorded_pid,
  "runtimeLabel": "$TOASTTY_RUNTIME_LABEL",
  "runtimeHomePath": "$TOASTTY_RUNTIME_HOME",
  "socketPath": "$TOASTTY_SOCKET_PATH"
}
JSON

if [[ "${FAKE_IGNORE_TERM:-0}" == "1" ]]; then
  trap '' TERM
fi
exec sleep 300
APP
chmod +x "$app_binary"
EOF
chmod +x "$FAKE_BIN/xcodebuild"

run_case() {
  local case_name="$1"
  local expected_exit_code="$2"
  local expected_status="$3"
  local recorded_pid="$4"
  local ignore_term="$5"
  local expected_failure_summary="$6"
  local minimum_elapsed_seconds="$7"
  local run_label="cleanup-self-test-${case_name}"
  local remote_run_root="$TEST_ROOT/run-${case_name}"
  local socket_path="$TEST_ROOT/tmp/toastty-${run_label}.sock"
  local validation_command_b64
  local runner_pid
  local runner_exit_code=0
  local fake_app_pid
  local attempt
  local started_at
  local elapsed_seconds

  validation_command_b64="$(printf 'true' | base64 | tr -d '\n')"
  started_at="$(date +%s)"
  (
    cd "$FIXTURE_ROOT"
    PATH="$FAKE_BIN:$PATH" \
    TMPDIR="$TEST_ROOT/tmp" \
    FAKE_RECORDED_PID="$recorded_pid" \
    FAKE_IGNORE_TERM="$ignore_term" \
    TOASTTY_REMOTE_VALIDATE_RUN_LABEL="$run_label" \
    TOASTTY_REMOTE_VALIDATE_REMOTE_RUN_ROOT="$remote_run_root" \
    TOASTTY_REMOTE_VALIDATE_REMOTE_WORKTREE_DIR="$FIXTURE_ROOT" \
    TOASTTY_REMOTE_VALIDATE_VALIDATION_COMMAND_B64="$validation_command_b64" \
    /bin/bash scripts/remote/validate.sh --remote-exec
  ) >"$TEST_ROOT/${case_name}-stdout.log" 2>"$TEST_ROOT/${case_name}-stderr.log" &
  runner_pid=$!

  # A broken cleanup used to hang indefinitely on TERM-resistant processes.
  # Keep the regression itself bounded so it reports that failure cleanly.
  for attempt in $(seq 1 120); do
    if ! kill -0 "$runner_pid" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$runner_pid" >/dev/null 2>&1; then
    kill -TERM "$runner_pid" >/dev/null 2>&1 || true
    if [[ -f "$remote_run_root/runtime-home/fake-app.pid" ]]; then
      kill_test_pid "$(cat "$remote_run_root/runtime-home/fake-app.pid")"
    fi
    kill -KILL "$runner_pid" >/dev/null 2>&1 || true
    wait "$runner_pid" >/dev/null 2>&1 || true
    echo "error: ${case_name} validation did not finish within 12 seconds" >&2
    exit 1
  fi

  if wait "$runner_pid"; then
    runner_exit_code=0
  else
    runner_exit_code=$?
  fi
  if [[ "$runner_exit_code" != "$expected_exit_code" ]]; then
    cat "$TEST_ROOT/${case_name}-stderr.log" >&2
    echo "error: ${case_name} exited ${runner_exit_code}, expected ${expected_exit_code}" >&2
    exit 1
  fi
  elapsed_seconds="$(($(date +%s) - started_at))"
  if ((elapsed_seconds < minimum_elapsed_seconds)); then
    echo "error: ${case_name} cleanup finished before its TERM grace period elapsed" >&2
    exit 1
  fi

  if [[ -e "$socket_path" ]]; then
    echo "error: ${case_name} left its socket behind" >&2
    exit 1
  fi
  if [[ ! -f "$remote_run_root/runtime-home/fake-app.pid" ]]; then
    echo "error: ${case_name} did not record its fake app pid" >&2
    exit 1
  fi
  fake_app_pid="$(cat "$remote_run_root/runtime-home/fake-app.pid")"
  if kill -0 "$fake_app_pid" >/dev/null 2>&1; then
    echo "error: ${case_name} left its app process running" >&2
    exit 1
  fi

  if [[ "$(jq -r '.status' "$remote_run_root/result.json")" != "$expected_status" ]]; then
    echo "error: ${case_name} did not record status ${expected_status}" >&2
    exit 1
  fi
  if [[ "$(jq -r '.failureSummary // empty' "$remote_run_root/result.json")" != "$expected_failure_summary" ]]; then
    echo "error: ${case_name} recorded the wrong failure summary" >&2
    exit 1
  fi
}

run_case "normal" 0 "pass" "" 0 "" 0
run_case "malformed-pid" 1 "fail" "-1" 0 "Remote instance.json contained an invalid pid" 0

sleep 300 &
UNRELATED_PID=$!
run_case "unrelated-pid" 1 "fail" "$UNRELATED_PID" 0 "Remote instance pid did not match the launched Toastty process" 0
if ! kill -0 "$UNRELATED_PID" >/dev/null 2>&1; then
  echo "error: validation killed the unrelated manifest pid" >&2
  exit 1
fi
kill_test_pid "$UNRELATED_PID"
UNRELATED_PID=""

run_case "term-resistant" 0 "pass" "" 1 "" 1

echo "ok: remote custom validation cleanup safety self-test passed"
