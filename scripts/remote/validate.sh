#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT_PATH="scripts/remote/validate.sh"

REMOTE_EXEC=0
RUN_LABEL="${RUN_LABEL:-validate-$(date +%Y%m%d-%H%M%S)}"
VALIDATION_SCOPE="working-tree"
REF_SPEC=""
SMOKE_TEST=""
VALIDATION_COMMAND=""
KEEP_REMOTE=0
REQUIRE_REMOTE=0

DEFAULT_REMOTE_REPO_ROOT="$ROOT_DIR"
REMOTE_HOST="${TOASTTY_REMOTE_GUI_HOST:-}"
REMOTE_REPO_ROOT="${TOASTTY_REMOTE_GUI_REPO_ROOT:-$DEFAULT_REMOTE_REPO_ROOT}"
DEFAULT_REMOTE_GUI_ROOT="$(dirname "$REMOTE_REPO_ROOT")/toastty-remote-gui"
REMOTE_GUI_ROOT="${TOASTTY_REMOTE_GUI_ROOT:-$DEFAULT_REMOTE_GUI_ROOT}"

LOCAL_ARTIFACTS_DIR=""
REMOTE_PREFLIGHT_ERROR=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/remote/validate.sh [options]

Runs Toastty validation on a remote macOS host over SSH. The wrapper creates a
disposable remote worktree, syncs the requested change scope into it, runs the
selected validation flow, and copies the artifacts back locally.

Options:
  --smoke-test smoke-ui|workspace-tabs  Remote smoke test to run
  --scope working-tree|head|ref         Local change scope to validate (default: working-tree)
  --ref <git-ref>                       Git ref to export when --scope ref is used
  --run-label <label>                   Stable run label used for local and remote artifacts
  --require-remote                      Fail instead of falling back to local smoke when remote preflight fails
  --keep-remote                         Keep the remote worktree and run directory after completion
  --remote-exec                         Internal mode used on the remote host
  -h, --help                            Show this help

Required local environment:
  TOASTTY_REMOTE_GUI_HOST               SSH host for the dedicated remote validation machine when remote execution is desired

Optional local environment:
  TOASTTY_REMOTE_GUI_REPO_ROOT          Absolute Toastty repo path on the remote host
  TOASTTY_REMOTE_GUI_ROOT               Remote directory that will hold disposable worktrees and runs

Notes:
  - If the remote host is unavailable during preflight, smoke tests fall back to
    a local run by default.
  - Pass --require-remote to disable that fallback and fail fast instead.
  - --validation-command remains available as an undocumented debug escape hatch
    for ad-hoc remote validation commands.
EOF
}

log() {
  printf '[validate] %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
}

escape_sh() {
  printf "%q" "$1"
}

encode_base64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

decode_base64() {
  local value="$1"
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    printf '%s' "$value" | base64 --decode
    return
  fi
  printf '%s' "$value" | base64 -D
}

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '%s' "$value"
}

smoke_script_path() {
  case "$1" in
    smoke-ui)
      printf 'scripts/automation/smoke-ui.sh\n'
      ;;
    workspace-tabs)
      printf 'scripts/automation/workspace-tabs-smoke.sh\n'
      ;;
    *)
      return 1
      ;;
  esac
}

smoke_run_id() {
  local smoke_test="$1"
  local run_label="$2"
  case "$smoke_test" in
    smoke-ui)
      printf 'smoke-%s\n' "$run_label"
      ;;
    workspace-tabs)
      printf 'workspace-tabs-smoke-%s\n' "$run_label"
      ;;
    *)
      return 1
      ;;
  esac
}

write_request_env() {
  local path="$1"
  cat >"$path" <<EOF
run_label=$RUN_LABEL
scope=$VALIDATION_SCOPE
smoke_test=$SMOKE_TEST
requested_target=remote
require_remote=$REQUIRE_REMOTE
remote_host=$REMOTE_HOST
remote_repo_root=$REMOTE_REPO_ROOT
remote_gui_root=$REMOTE_GUI_ROOT
EOF
}

write_result_json() {
  local path="$1"
  local requested_target="$2"
  local execution_target="$3"
  local status="$4"
  local smoke_test="$5"
  local started_at="$6"
  local ended_at="$7"
  local remote_run_root="$8"
  local fallback_reason="$9"
  local failure_summary="${10}"

  mkdir -p "$(dirname "$path")"

  local smoke_value='null'
  local remote_run_root_value='null'
  local fallback_reason_value='null'
  local failure_summary_value='null'

  if [[ -n "$smoke_test" ]]; then
    smoke_value="\"$(json_escape "$smoke_test")\""
  fi
  if [[ -n "$remote_run_root" ]]; then
    remote_run_root_value="\"$(json_escape "$remote_run_root")\""
  fi
  if [[ -n "$fallback_reason" ]]; then
    fallback_reason_value="\"$(json_escape "$fallback_reason")\""
  fi
  if [[ -n "$failure_summary" ]]; then
    failure_summary_value="\"$(json_escape "$failure_summary")\""
  fi

  cat >"$path" <<EOF
{
  "schemaVersion": 1,
  "requestedTarget": "$(json_escape "$requested_target")",
  "executionTarget": "$(json_escape "$execution_target")",
  "status": "$(json_escape "$status")",
  "smokeTest": $smoke_value,
  "startedAt": "$(json_escape "$started_at")",
  "endedAt": "$(json_escape "$ended_at")",
  "remoteRunRoot": $remote_run_root_value,
  "fallbackReason": $fallback_reason_value,
  "failureSummary": $failure_summary_value
}
EOF
}

export_ref_tree() {
  local ref_name="$1"
  local export_root
  export_root="$(mktemp -d)"
  git -C "$ROOT_DIR" archive "$ref_name" | tar -x -C "$export_root"
  printf '%s\n' "$export_root"
}

sync_worktree_to_remote() {
  local source_root="$1"
  local remote_worktree_dir="$2"

  rsync -a --delete \
    -e 'ssh -o BatchMode=yes -o ConnectTimeout=5' \
    --exclude '.git' \
    --exclude '.DS_Store' \
    --exclude 'artifacts' \
    --exclude 'Derived' \
    --exclude 'Derived*' \
    --exclude 'toastty.xcodeproj' \
    --exclude 'toastty.xcworkspace' \
    --exclude 'Tuist/.build' \
    --exclude 'Dependencies/GhosttyKit.Debug.xcframework' \
    --exclude 'Dependencies/GhosttyKit.Release.xcframework' \
    --exclude 'Dependencies/GhosttyKit.Debug.metadata.env' \
    --exclude 'Dependencies/GhosttyKit.Release.metadata.env' \
    "$source_root/" \
    "$REMOTE_HOST:$remote_worktree_dir/"
}

remote_shell() {
  local script="$1"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -l -s -- <<EOF
set -euo pipefail
$script
EOF
}

run_remote_preflight() {
  local output
  if ! output="$(
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -l -s -- \
      "$REMOTE_REPO_ROOT" \
      "$REMOTE_GUI_ROOT" <<'EOF' 2>&1
set -euo pipefail
remote_repo_root="$1"
remote_gui_root="$2"
git -C "$remote_repo_root" rev-parse --is-inside-work-tree >/dev/null
mkdir -p "$remote_gui_root/worktrees" "$remote_gui_root/runs"
test -w "$remote_gui_root/worktrees"
test -w "$remote_gui_root/runs"
EOF
  )"; then
    REMOTE_PREFLIGHT_ERROR="$output"
    return 1
  fi

  REMOTE_PREFLIGHT_ERROR=""
  return 0
}

prepare_local_artifacts() {
  LOCAL_ARTIFACTS_DIR="$ROOT_DIR/artifacts/remote-gui/$RUN_LABEL"
  mkdir -p "$LOCAL_ARTIFACTS_DIR"
  write_request_env "$LOCAL_ARTIFACTS_DIR/request.env"
}

run_smoke_locally() {
  local smoke_test="$1"
  local started_at="$2"
  local fallback_reason="$3"

  local script_relative_path
  script_relative_path="$(smoke_script_path "$smoke_test")" || fail "Unsupported smoke test: $smoke_test"

  local local_root="$LOCAL_ARTIFACTS_DIR/local"
  local local_run_root="$local_root/run"
  local stdout_log="$local_root/validation-stdout.log"
  local stderr_log="$local_root/validation-stderr.log"
  local script_exit_code=0
  local status="pass"
  local failure_summary=""
  local run_id
  run_id="$(smoke_run_id "$smoke_test" "$RUN_LABEL")"
  local execution_root="$ROOT_DIR"
  local fallback_worktree=""
  local fallback_ref=""

  mkdir -p "$local_root"

  case "$VALIDATION_SCOPE" in
    working-tree)
      ;;
    head)
      fallback_ref="HEAD"
      ;;
    ref)
      [[ -n "$REF_SPEC" ]] || fail "--ref is required when --scope ref is used"
      fallback_ref="$REF_SPEC"
      ;;
    *)
      fail "Unsupported validation scope: $VALIDATION_SCOPE"
      ;;
  esac

  if [[ -n "$fallback_ref" ]]; then
    fallback_worktree="$local_root/fallback-worktree"
    rm -rf "$fallback_worktree"
    if git -C "$ROOT_DIR" worktree add --detach "$fallback_worktree" "$fallback_ref" >/dev/null 2>&1; then
      execution_root="$fallback_worktree"
    else
      script_exit_code=1
      status="fail"
      failure_summary="Failed to prepare local fallback worktree for scope ${VALIDATION_SCOPE}"

      local ended_at
      ended_at="$(timestamp_utc)"
      write_result_json \
        "$LOCAL_ARTIFACTS_DIR/result.json" \
        "remote" \
        "local-fallback" \
        "$status" \
        "$smoke_test" \
        "$started_at" \
        "$ended_at" \
        "" \
        "$fallback_reason" \
        "$failure_summary"
      return "$script_exit_code"
    fi
  fi

  if (
    cd "$execution_root"
    RUN_ID="$run_id" \
    DEV_RUN_ROOT="$local_run_root" \
    /bin/bash "$script_relative_path"
  ) >"$stdout_log" 2>"$stderr_log"; then
    :
  else
    script_exit_code=$?
    status="fail"
    failure_summary="Local fallback ${smoke_test} exited with status ${script_exit_code}"
  fi

  local ended_at
  ended_at="$(timestamp_utc)"
  write_result_json \
    "$LOCAL_ARTIFACTS_DIR/result.json" \
    "remote" \
    "local-fallback" \
    "$status" \
    "$smoke_test" \
    "$started_at" \
    "$ended_at" \
    "" \
    "$fallback_reason" \
    "$failure_summary"

  if [[ -n "$fallback_worktree" ]]; then
    git -C "$ROOT_DIR" worktree remove --force "$fallback_worktree" >/dev/null 2>&1 || rm -rf "$fallback_worktree"
  fi

  return "$script_exit_code"
}

wait_for_remote_completion() {
  local remote_worktree_dir="$1"
  local remote_run_root="$2"
  local smoke_test="$3"
  local validation_command_b64="$4"
  local smoke_test_arg="${smoke_test:-__TOASTTY_EMPTY__}"
  local validation_command_arg="${validation_command_b64:-__TOASTTY_EMPTY__}"

  local remote_stdout="$LOCAL_ARTIFACTS_DIR/remote-stdout.log"
  local remote_stderr="$LOCAL_ARTIFACTS_DIR/remote-stderr.log"
  local ssh_exit_code=0

  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -l -s -- \
      "$RUN_LABEL" \
      "$remote_run_root" \
      "$remote_worktree_dir" \
      "$SCRIPT_PATH" \
      "$smoke_test_arg" \
      "$validation_command_arg" \
      > >(tee "$remote_stdout") \
      2> >(tee "$remote_stderr" >&2) <<'EOF'; then
set -euo pipefail
run_label="$1"
remote_run_root="$2"
remote_worktree_dir="$3"
script_path="$4"
smoke_test="$5"
validation_command_b64="$6"
if [[ "$smoke_test" == "__TOASTTY_EMPTY__" ]]; then
  smoke_test=""
fi
if [[ "$validation_command_b64" == "__TOASTTY_EMPTY__" ]]; then
  validation_command_b64=""
fi
export TOASTTY_REMOTE_VALIDATE_RUN_LABEL="$run_label"
export TOASTTY_REMOTE_VALIDATE_REMOTE_RUN_ROOT="$remote_run_root"
export TOASTTY_REMOTE_VALIDATE_REMOTE_WORKTREE_DIR="$remote_worktree_dir"
export TOASTTY_REMOTE_VALIDATE_SMOKE_TEST="$smoke_test"
export TOASTTY_REMOTE_VALIDATE_VALIDATION_COMMAND_B64="$validation_command_b64"
cd "$remote_worktree_dir"
/bin/bash "$script_path" --remote-exec
EOF
    :
  else
    ssh_exit_code=$?
  fi

  return "$ssh_exit_code"
}

copy_remote_result_to_root() {
  if [[ -f "$LOCAL_ARTIFACTS_DIR/remote/result.json" ]]; then
    cp "$LOCAL_ARTIFACTS_DIR/remote/result.json" "$LOCAL_ARTIFACTS_DIR/result.json"
    return 0
  fi

  return 1
}

run_local_mode() {
  require_command git

  [[ -n "$SMOKE_TEST" || -n "$VALIDATION_COMMAND" ]] || fail "--smoke-test or --validation-command is required"
  [[ -n "$SMOKE_TEST" && -n "$VALIDATION_COMMAND" ]] && fail "Use either --smoke-test or --validation-command, not both"

  if [[ -n "$SMOKE_TEST" ]]; then
    smoke_script_path "$SMOKE_TEST" >/dev/null || fail "Unsupported smoke test: $SMOKE_TEST"
  fi

  prepare_local_artifacts

  local started_at
  started_at="$(timestamp_utc)"

  if [[ -n "$VALIDATION_COMMAND" ]]; then
    REQUIRE_REMOTE=1
  fi

  local fallback_reason=""
  if [[ -z "$REMOTE_HOST" ]]; then
    fallback_reason="TOASTTY_REMOTE_GUI_HOST is not set"
  elif ! command -v ssh >/dev/null 2>&1; then
    fallback_reason="ssh is not installed locally"
  elif ! command -v rsync >/dev/null 2>&1; then
    fallback_reason="rsync is not installed locally"
  elif ! run_remote_preflight; then
    fallback_reason="$REMOTE_PREFLIGHT_ERROR"
  fi

  if [[ -n "$fallback_reason" ]]; then
    warn "Remote preflight failed: $fallback_reason"
    if [[ "$REQUIRE_REMOTE" == "1" || -n "$VALIDATION_COMMAND" ]]; then
      local ended_at
      ended_at="$(timestamp_utc)"
      write_result_json \
        "$LOCAL_ARTIFACTS_DIR/result.json" \
        "remote" \
        "remote" \
        "setup_error" \
        "$SMOKE_TEST" \
        "$started_at" \
        "$ended_at" \
        "" \
        "$fallback_reason" \
        "Remote validation preflight failed"
      return 1
    fi

    run_smoke_locally "$SMOKE_TEST" "$started_at" "$fallback_reason"
    return $?
  fi

  require_command ssh
  require_command rsync

  local remote_worktree_dir="$REMOTE_GUI_ROOT/worktrees/$RUN_LABEL"
  local remote_run_root="$REMOTE_GUI_ROOT/runs/$RUN_LABEL"

  log "Preparing remote worktree on $REMOTE_HOST"
  remote_shell "
REMOTE_REPO_ROOT=$(escape_sh "$REMOTE_REPO_ROOT")
REMOTE_WORKTREE_DIR=$(escape_sh "$remote_worktree_dir")
REMOTE_RUN_ROOT=$(escape_sh "$remote_run_root")
git -C \"\$REMOTE_REPO_ROOT\" rev-parse --is-inside-work-tree >/dev/null
mkdir -p \"\$(dirname \"\$REMOTE_WORKTREE_DIR\")\" \"\$(dirname \"\$REMOTE_RUN_ROOT\")\"
rm -rf \"\$REMOTE_RUN_ROOT\"
if [[ -e \"\$REMOTE_WORKTREE_DIR\" ]]; then
  git -C \"\$REMOTE_REPO_ROOT\" worktree remove --force \"\$REMOTE_WORKTREE_DIR\" >/dev/null 2>&1 || rm -rf \"\$REMOTE_WORKTREE_DIR\"
fi
git -C \"\$REMOTE_REPO_ROOT\" worktree add --detach \"\$REMOTE_WORKTREE_DIR\" >/dev/null
mkdir -p \"\$REMOTE_RUN_ROOT\"
"

  local sync_source_root="$ROOT_DIR"
  local export_root=""
  case "$VALIDATION_SCOPE" in
    working-tree)
      ;;
    head)
      export_root="$(export_ref_tree HEAD)"
      sync_source_root="$export_root"
      ;;
    ref)
      [[ -n "$REF_SPEC" ]] || fail "--ref is required when --scope ref is used"
      export_root="$(export_ref_tree "$REF_SPEC")"
      sync_source_root="$export_root"
      ;;
    *)
      fail "Unsupported validation scope: $VALIDATION_SCOPE"
      ;;
  esac

  log "Syncing local files to remote worktree"
  if ! sync_worktree_to_remote "$sync_source_root" "$remote_worktree_dir"; then
    if [[ -n "$export_root" && -d "$export_root" ]]; then
      rm -rf "$export_root"
    fi
    fail "Failed syncing local files to remote worktree"
  fi
  if [[ -n "$export_root" && -d "$export_root" ]]; then
    rm -rf "$export_root"
  fi

  local validation_command_b64=""
  if [[ -n "$VALIDATION_COMMAND" ]]; then
    validation_command_b64="$(encode_base64 "$VALIDATION_COMMAND")"
  fi

  log "Running remote validation"
  local remote_validation_exit_code=0
  if wait_for_remote_completion "$remote_worktree_dir" "$remote_run_root" "$SMOKE_TEST" "$validation_command_b64"; then
    :
  else
    remote_validation_exit_code=$?
    warn "Remote validation failed"
  fi

  log "Copying remote artifacts back"
  mkdir -p "$LOCAL_ARTIFACTS_DIR/remote"
  if rsync -a "$REMOTE_HOST:$remote_run_root/" "$LOCAL_ARTIFACTS_DIR/remote/"; then
    :
  else
    remote_validation_exit_code=1
    warn "Failed copying remote artifacts back"
  fi

  if ! copy_remote_result_to_root; then
    local ended_at
    ended_at="$(timestamp_utc)"
    write_result_json \
      "$LOCAL_ARTIFACTS_DIR/result.json" \
      "remote" \
      "remote" \
      "fail" \
      "$SMOKE_TEST" \
      "$started_at" \
      "$ended_at" \
      "$remote_run_root" \
      "" \
      "Remote result.json was not produced"
    remote_validation_exit_code=1
  fi

  if [[ "$KEEP_REMOTE" != "1" ]]; then
    log "Cleaning up remote worktree"
    remote_shell "
REMOTE_REPO_ROOT=$(escape_sh "$REMOTE_REPO_ROOT")
REMOTE_WORKTREE_DIR=$(escape_sh "$remote_worktree_dir")
REMOTE_RUN_ROOT=$(escape_sh "$remote_run_root")
git -C \"\$REMOTE_REPO_ROOT\" worktree remove --force \"\$REMOTE_WORKTREE_DIR\" >/dev/null 2>&1 || rm -rf \"\$REMOTE_WORKTREE_DIR\"
rm -rf \"\$REMOTE_RUN_ROOT\"
"
  fi

  if [[ "$remote_validation_exit_code" != "0" ]]; then
    return "$remote_validation_exit_code"
  fi
}

run_remote_smoke_mode() {
  local run_label="$1"
  local remote_run_root="$2"
  local remote_worktree_dir="$3"
  local smoke_test="$4"

  local script_relative_path
  script_relative_path="$(smoke_script_path "$smoke_test")" || fail "Unsupported smoke test: $smoke_test"

  local started_at
  started_at="$(timestamp_utc)"
  local run_root="$remote_run_root/run"
  local stdout_log="$remote_run_root/validation-stdout.log"
  local stderr_log="$remote_run_root/validation-stderr.log"
  local run_id
  run_id="$(smoke_run_id "$smoke_test" "$run_label")"
  local script_exit_code=0
  local status="pass"
  local failure_summary=""

  mkdir -p "$remote_run_root"

  if (
    cd "$remote_worktree_dir"
    RUN_ID="$run_id" \
    DEV_RUN_ROOT="$run_root" \
    /bin/bash "$script_relative_path"
  ) >"$stdout_log" 2>"$stderr_log"; then
    :
  else
    script_exit_code=$?
    status="fail"
    failure_summary="${smoke_test} exited with status ${script_exit_code}"
  fi

  local ended_at
  ended_at="$(timestamp_utc)"
  write_result_json \
    "$remote_run_root/result.json" \
    "remote" \
    "remote" \
    "$status" \
    "$smoke_test" \
    "$started_at" \
    "$ended_at" \
    "$remote_run_root" \
    "" \
    "$failure_summary"

  return "$script_exit_code"
}

run_remote_custom_mode() {
  require_command xcodebuild
  require_command peekaboo

  local run_label="${TOASTTY_REMOTE_VALIDATE_RUN_LABEL:?TOASTTY_REMOTE_VALIDATE_RUN_LABEL is required}"
  local remote_run_root="${TOASTTY_REMOTE_VALIDATE_REMOTE_RUN_ROOT:?TOASTTY_REMOTE_VALIDATE_REMOTE_RUN_ROOT is required}"
  local validation_command_b64="${TOASTTY_REMOTE_VALIDATE_VALIDATION_COMMAND_B64:-}"
  local validation_command
  if [[ -n "$validation_command_b64" ]]; then
    validation_command="$(decode_base64 "$validation_command_b64")"
  else
    fail "validation command is required for custom remote mode"
  fi

  local started_at
  started_at="$(timestamp_utc)"
  local derived_path="$remote_run_root/Derived"
  local artifacts_dir="$remote_run_root/artifacts"
  local runtime_home="$remote_run_root/runtime-home"
  local socket_path="${TMPDIR:-/tmp}/toastty-${run_label}.sock"
  local arch="${ARCH:-$(uname -m)}"
  local app_binary="$derived_path/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty"
  local instance_json="$runtime_home/instance.json"
  local app_pid=""
  local exit_code=0
  local status="pass"
  local failure_summary=""

  mkdir -p "$artifacts_dir" "$runtime_home" "$(dirname "$socket_path")"
  rm -f "$socket_path"

  cleanup_remote_custom_mode() {
    local cleanup_exit_code=$?
    rm -f "$socket_path"
    if [[ -n "$app_pid" ]]; then
      kill "$app_pid" >/dev/null 2>&1 || true
      wait "$app_pid" >/dev/null 2>&1 || true
    fi
    return "$cleanup_exit_code"
  }
  trap cleanup_remote_custom_mode EXIT

  ./scripts/dev/bootstrap-worktree.sh >/dev/null

  xcodebuild \
    -workspace toastty.xcworkspace \
    -scheme ToasttyApp \
    -configuration Debug \
    -destination "platform=macOS,arch=${arch}" \
    -derivedDataPath "$derived_path" \
    build >/dev/null

  TOASTTY_RUNTIME_HOME="$runtime_home" \
  TOASTTY_SOCKET_PATH="$socket_path" \
  TOASTTY_DERIVED_PATH="$derived_path" \
  "$app_binary" >"$artifacts_dir/app.log" 2>&1 &
  app_pid=$!

  for _ in $(seq 1 200); do
    if [[ -f "$instance_json" ]]; then
      break
    fi
    if ! kill -0 "$app_pid" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  if [[ ! -f "$instance_json" ]]; then
    exit_code=1
    status="fail"
    failure_summary="Remote instance.json was not written: $instance_json"
  else
    local recorded_pid="$app_pid"
    if command -v jq >/dev/null 2>&1; then
      recorded_pid="$(jq -r '.pid // empty' "$instance_json")"
      if [[ -n "$recorded_pid" ]]; then
        app_pid="$recorded_pid"
      fi
    fi

    if ! kill -0 "$app_pid" >/dev/null 2>&1; then
      exit_code=1
      status="fail"
      failure_summary="Remote Toastty process is not running"
    fi
  fi

  if [[ "$exit_code" == "0" ]]; then
    export TOASTTY_PID="$app_pid"
    export TOASTTY_INSTANCE_JSON="$instance_json"
    export TOASTTY_RUNTIME_HOME="$runtime_home"
    export TOASTTY_ARTIFACTS_DIR="$artifacts_dir"
    export TOASTTY_SOCKET_PATH="$socket_path"
    export TOASTTY_DERIVED_PATH="$derived_path"
    export TOASTTY_APP_BUNDLE="$derived_path/Build/Products/Debug/Toastty.app"

    printf '%s\n' "$validation_command" >"$artifacts_dir/validation-command.sh"

    if /bin/bash -lc "set -euo pipefail; $validation_command" \
      >"$remote_run_root/validation-stdout.log" \
      2>"$remote_run_root/validation-stderr.log"; then
      :
    else
      exit_code=$?
      status="fail"
      failure_summary="Custom validation command exited with status ${exit_code}"
    fi
  fi

  local ended_at
  ended_at="$(timestamp_utc)"
  write_result_json \
    "$remote_run_root/result.json" \
    "remote" \
    "remote" \
    "$status" \
    "" \
    "$started_at" \
    "$ended_at" \
    "$remote_run_root" \
    "" \
    "$failure_summary"

  return "$exit_code"
}

run_remote_mode() {
  local run_label="${TOASTTY_REMOTE_VALIDATE_RUN_LABEL:?TOASTTY_REMOTE_VALIDATE_RUN_LABEL is required}"
  local remote_run_root="${TOASTTY_REMOTE_VALIDATE_REMOTE_RUN_ROOT:?TOASTTY_REMOTE_VALIDATE_REMOTE_RUN_ROOT is required}"
  local remote_worktree_dir="${TOASTTY_REMOTE_VALIDATE_REMOTE_WORKTREE_DIR:?TOASTTY_REMOTE_VALIDATE_REMOTE_WORKTREE_DIR is required}"
  local smoke_test="${TOASTTY_REMOTE_VALIDATE_SMOKE_TEST:-}"

  if [[ -n "$smoke_test" ]]; then
    run_remote_smoke_mode "$run_label" "$remote_run_root" "$remote_worktree_dir" "$smoke_test"
    return
  fi

  run_remote_custom_mode
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke-test)
      [[ $# -ge 2 ]] || fail "--smoke-test requires a value"
      SMOKE_TEST="$2"
      shift 2
      ;;
    --scope)
      [[ $# -ge 2 ]] || fail "--scope requires a value"
      VALIDATION_SCOPE="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || fail "--ref requires a value"
      REF_SPEC="$2"
      shift 2
      ;;
    --run-label)
      [[ $# -ge 2 ]] || fail "--run-label requires a value"
      RUN_LABEL="$2"
      shift 2
      ;;
    --require-remote)
      REQUIRE_REMOTE=1
      shift
      ;;
    --keep-remote)
      KEEP_REMOTE=1
      shift
      ;;
    --validation-command)
      [[ $# -ge 2 ]] || fail "--validation-command requires a value"
      VALIDATION_COMMAND="$2"
      shift 2
      ;;
    --remote-exec)
      REMOTE_EXEC=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ "$REMOTE_EXEC" == "1" ]]; then
  run_remote_mode
else
  run_local_mode
fi
