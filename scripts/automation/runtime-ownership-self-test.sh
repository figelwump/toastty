#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/scripts/automation/runtime-ownership.sh"

TEST_ROOT="$(mktemp -d /tmp/toastty-runtime-ownership.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

RUNTIME_HOME="$TEST_ROOT/runtime-home"
SOCKET_PATH="$TEST_ROOT/sockets/events-v1.sock"
INSTANCE_JSON="$RUNTIME_HOME/instance.json"
RUN_ID="Smoke Run 01!"
RUNTIME_LABEL="$(toastty_sanitize_runtime_label "$RUN_ID")"

mkdir -p "$RUNTIME_HOME" "$(dirname "$SOCKET_PATH")"
: > "$SOCKET_PATH"

write_manifest() {
  local pid="$1"
  local runtime_label="$2"
  local runtime_home="$3"
  local socket_path="$4"
  local run_id="${5:-$RUN_ID}"

  cat > "$INSTANCE_JSON" <<EOF
{
  "pid": $pid,
  "runtimeLabel": "$runtime_label",
  "runtimeHomePath": "$runtime_home",
  "socketPath": "$socket_path",
  "runID": "$run_id"
}
EOF
}

assert_accepts() {
  toastty_assert_run_owned_instance "$INSTANCE_JSON" "$RUN_ID" "$RUNTIME_HOME" "$SOCKET_PATH" 1
}

assert_rejects() {
  local description="$1"
  shift
  if "$@" >"$TEST_ROOT/stdout.log" 2>"$TEST_ROOT/stderr.log"; then
    echo "error: expected rejection for $description" >&2
    exit 1
  fi
}

write_manifest "$$" "$RUNTIME_LABEL" "$RUNTIME_HOME" "$SOCKET_PATH"
assert_accepts

write_manifest "$$" "other-run" "$RUNTIME_HOME" "$SOCKET_PATH"
assert_rejects "mismatched runtime label" \
  toastty_assert_run_owned_instance "$INSTANCE_JSON" "$RUN_ID" "$RUNTIME_HOME" "$SOCKET_PATH" 1

write_manifest "$$" "$RUNTIME_LABEL" "$TEST_ROOT/other-runtime-home" "$SOCKET_PATH"
assert_rejects "mismatched runtime home" \
  toastty_assert_run_owned_instance "$INSTANCE_JSON" "$RUN_ID" "$RUNTIME_HOME" "$SOCKET_PATH" 1

write_manifest "$$" "$RUNTIME_LABEL" "$RUNTIME_HOME" "$TEST_ROOT/sockets/other.sock"
assert_rejects "mismatched socket path" \
  toastty_assert_run_owned_instance "$INSTANCE_JSON" "$RUN_ID" "$RUNTIME_HOME" "$SOCKET_PATH" 1

write_manifest "$$" "$RUNTIME_LABEL" "$RUNTIME_HOME" "$SOCKET_PATH" "other-run"
assert_rejects "mismatched run id" \
  toastty_assert_run_owned_instance "$INSTANCE_JSON" "$RUN_ID" "$RUNTIME_HOME" "$SOCKET_PATH" 1

write_manifest 999999 "$RUNTIME_LABEL" "$RUNTIME_HOME" "$SOCKET_PATH"
assert_rejects "stale pid" \
  toastty_assert_run_owned_instance "$INSTANCE_JSON" "$RUN_ID" "$RUNTIME_HOME" "$SOCKET_PATH" 1

echo "ok: runtime ownership guard self-test passed"
