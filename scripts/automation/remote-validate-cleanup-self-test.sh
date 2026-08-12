#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d /tmp/toastty-remote-validate-cleanup.XXXXXX)"
FIXTURE_ROOT="$TEST_ROOT/worktree"
FAKE_BIN="$TEST_ROOT/bin"
REMOTE_RUN_ROOT="$TEST_ROOT/run"
SOCKET_PATH="$TEST_ROOT/tmp/toastty-cleanup-self-test.sock"

cleanup() {
  local cleanup_exit_code=$?
  if [[ -f "$REMOTE_RUN_ROOT/runtime-home/fake-app.pid" ]]; then
    local fake_app_pid
    fake_app_pid="$(cat "$REMOTE_RUN_ROOT/runtime-home/fake-app.pid")"
    kill "$fake_app_pid" >/dev/null 2>&1 || true
  fi
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
cat >"$TOASTTY_RUNTIME_HOME/instance.json" <<JSON
{
  "pid": $$,
  "runtimeLabel": "$TOASTTY_RUNTIME_LABEL",
  "runtimeHomePath": "$TOASTTY_RUNTIME_HOME",
  "socketPath": "$TOASTTY_SOCKET_PATH"
}
JSON

exec sleep 300
APP
chmod +x "$app_binary"
EOF
chmod +x "$FAKE_BIN/xcodebuild"

validation_command_b64="$(printf 'true' | base64 | tr -d '\n')"

(
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" \
  TMPDIR="$TEST_ROOT/tmp" \
  TOASTTY_REMOTE_VALIDATE_RUN_LABEL="cleanup-self-test" \
  TOASTTY_REMOTE_VALIDATE_REMOTE_RUN_ROOT="$REMOTE_RUN_ROOT" \
  TOASTTY_REMOTE_VALIDATE_REMOTE_WORKTREE_DIR="$FIXTURE_ROOT" \
  TOASTTY_REMOTE_VALIDATE_VALIDATION_COMMAND_B64="$validation_command_b64" \
  /bin/bash scripts/remote/validate.sh --remote-exec
)

if [[ -e "$SOCKET_PATH" ]]; then
  echo "error: remote custom validation left its socket behind" >&2
  exit 1
fi

fake_app_pid="$(cat "$REMOTE_RUN_ROOT/runtime-home/fake-app.pid")"
if kill -0 "$fake_app_pid" >/dev/null 2>&1; then
  echo "error: remote custom validation left its app process running" >&2
  exit 1
fi

if [[ "$(jq -r '.status' "$REMOTE_RUN_ROOT/result.json")" != "pass" ]]; then
  echo "error: remote custom validation did not record a passing result" >&2
  exit 1
fi

echo "ok: remote custom validation cleanup self-test passed"
