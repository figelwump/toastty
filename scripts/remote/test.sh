#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT_PATH="scripts/remote/test.sh"

REMOTE_EXEC=0
RUN_LABEL="${RUN_LABEL:-test-$(date +%Y%m%d-%H%M%S)}"
VALIDATION_SCOPE="working-tree"
REF_SPEC=""
KEEP_REMOTE=0
SETUP_ERROR_EXIT_CODE=78
DEFAULT_REMOTE_TEST_TIMEOUT_SECONDS=3600

DEFAULT_REMOTE_REPO_ROOT="$ROOT_DIR"
REMOTE_HOST="${TOASTTY_REMOTE_GUI_HOST:-}"
REMOTE_REPO_ROOT="${TOASTTY_REMOTE_GUI_REPO_ROOT:-$DEFAULT_REMOTE_REPO_ROOT}"
DEFAULT_REMOTE_GUI_ROOT="$(dirname "$REMOTE_REPO_ROOT")/toastty-remote-gui"
REMOTE_GUI_ROOT="${TOASTTY_REMOTE_GUI_ROOT:-$DEFAULT_REMOTE_GUI_ROOT}"

LOCAL_ARTIFACTS_DIR=""
REMOTE_PREFLIGHT_ERROR=""
XCODEBUILD_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  ./scripts/remote/test.sh [options] [-- <xcodebuild-options>...]

Runs `xcodebuild test` on the dedicated remote macOS validation host over SSH.
The wrapper creates a disposable remote worktree, syncs the requested local
change scope into it, runs the test invocation there, copies the artifacts back
locally, and removes the remote worktree unless told otherwise.

Options:
  --scope working-tree|head|ref         Local change scope to test (default: working-tree)
  --ref <git-ref>                       Git ref to export when --scope ref is used
  --run-label <label>                   Stable label used for local and remote artifacts
  --keep-remote                         Keep the remote worktree and run directory after completion
  --remote-exec                         Internal mode used on the remote host

Optional environment:
  TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS    Remote xcodebuild timeout in seconds (default: 3600, 0 disables)
  TOASTTY_ALLOW_REMOTE_X86_64_TESTS      Set to 1 to allow Rosetta x86_64 remote test destinations
  -h, --help                            Show this help

Xcodebuild options:
  Pass any `xcodebuild` options after `--`. The wrapper always runs the `test`
  action and owns `-derivedDataPath` plus `-resultBundlePath`.

Examples:
  TOASTTY_REMOTE_GUI_HOST=mac-mini.local \
  ./scripts/remote/test.sh \
    --scope working-tree \
    -- \
    -workspace toastty.xcworkspace \
    -scheme ToasttyApp \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -only-testing:ToasttyAppTests/CommandPaletteControllerTests

  # With no xcodebuild options, the wrapper defaults to:
  #   -workspace toastty.xcworkspace
  #   -scheme ToasttyApp
  #   -configuration Debug
  #   -destination "platform=macOS,arch=$(uname -m)"

Required local environment:
  TOASTTY_REMOTE_GUI_HOST               SSH host for the dedicated remote validation machine

Optional local environment:
  TOASTTY_REMOTE_GUI_REPO_ROOT          Absolute Toastty repo path on the remote host
  TOASTTY_REMOTE_GUI_ROOT               Remote directory that will hold disposable worktrees and test runs
EOF
}

log() {
  printf '[remote-test] %s\n' "$*"
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

join_shell_words() {
  local word
  local result=""
  for word in "$@"; do
    if [[ -n "$result" ]]; then
      result+=" "
    fi
    result+="$(printf '%q' "$word")"
  done
  printf '%s\n' "$result"
}

set_default_xcodebuild_args() {
  local arch="${ARCH:-$(uname -m)}"
  DEFAULT_XCODEBUILD_ARGS=(
    -workspace
    toastty.xcworkspace
    -scheme
    ToasttyApp
    -configuration
    Debug
    -destination
    "platform=macOS,arch=${arch}"
  )
}

serialize_xcodebuild_args() {
  local payload=""
  local arg
  for arg in "$@"; do
    payload+="$arg"$'\n'
  done
  encode_base64 "$payload"
}

write_request_env() {
  local path="$1"
  local xcodebuild_command="$2"
  {
    printf 'run_label=%q\n' "$RUN_LABEL"
    printf 'scope=%q\n' "$VALIDATION_SCOPE"
    printf 'requested_target=%q\n' "remote"
    printf 'remote_host=%q\n' "$REMOTE_HOST"
    printf 'remote_repo_root=%q\n' "$REMOTE_REPO_ROOT"
    printf 'remote_gui_root=%q\n' "$REMOTE_GUI_ROOT"
    printf 'xcodebuild_command=%q\n' "$xcodebuild_command"
  } >"$path"
}

write_result_json() {
  local path="$1"
  local status="$2"
  local started_at="$3"
  local ended_at="$4"
  local remote_run_root="$5"
  local failure_summary="$6"
  local xcodebuild_command="$7"

  mkdir -p "$(dirname "$path")"

  local remote_run_root_value='null'
  local failure_summary_value='null'
  local xcodebuild_command_value='null'

  if [[ -n "$remote_run_root" ]]; then
    remote_run_root_value="\"$(json_escape "$remote_run_root")\""
  fi
  if [[ -n "$failure_summary" ]]; then
    failure_summary_value="\"$(json_escape "$failure_summary")\""
  fi
  if [[ -n "$xcodebuild_command" ]]; then
    xcodebuild_command_value="\"$(json_escape "$xcodebuild_command")\""
  fi

  cat >"$path" <<EOF
{
  "schemaVersion": 1,
  "requestedTarget": "remote",
  "executionTarget": "remote",
  "status": "$(json_escape "$status")",
  "startedAt": "$(json_escape "$started_at")",
  "endedAt": "$(json_escape "$ended_at")",
  "remoteRunRoot": $remote_run_root_value,
  "failureSummary": $failure_summary_value,
  "xcodebuildCommand": $xcodebuild_command_value
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
mkdir -p "$remote_gui_root/worktrees" "$remote_gui_root/test-runs"
test -w "$remote_gui_root/worktrees"
test -w "$remote_gui_root/test-runs"
EOF
  )"; then
    REMOTE_PREFLIGHT_ERROR="$output"
    return 1
  fi

  REMOTE_PREFLIGHT_ERROR=""
  return 0
}

prepare_local_artifacts() {
  LOCAL_ARTIFACTS_DIR="$ROOT_DIR/artifacts/remote-tests/$RUN_LABEL"
  mkdir -p "$LOCAL_ARTIFACTS_DIR"
}

build_display_command() {
  local args=()
  if [[ "$#" == "0" ]]; then
    set_default_xcodebuild_args
    args=("${DEFAULT_XCODEBUILD_ARGS[@]}")
  else
    args=("$@")
  fi

  join_shell_words xcodebuild "${args[@]}" test
}

assert_supported_xcodebuild_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      test|build|archive|analyze)
        fail "Do not pass xcodebuild actions after --. scripts/remote/test.sh always runs the test action."
        ;;
      -derivedDataPath|-resultBundlePath)
        fail "Do not pass $arg after --. scripts/remote/test.sh owns DerivedData and result bundle paths."
        ;;
    esac
  done
}

xcodebuild_args_request_x86_64_macos() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == *"platform=macOS"* && "$arg" == *"arch=x86_64"* ]]; then
      return 0
    fi
  done
  return 1
}

is_non_negative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

kill_process_tree() {
  local root_pid="$1"
  local signal_name="${2:-TERM}"
  local child_pid

  while IFS= read -r child_pid; do
    [[ -n "$child_pid" ]] || continue
    kill_process_tree "$child_pid" "$signal_name"
  done < <(pgrep -P "$root_pid" 2>/dev/null || true)

  kill "-$signal_name" "$root_pid" >/dev/null 2>&1 || true
}

copy_remote_result() {
  local remote_run_root="$1"
  log "Copying remote artifacts back"
  if ! rsync -a "$REMOTE_HOST:$remote_run_root/" "$LOCAL_ARTIFACTS_DIR/"; then
    return 1
  fi
  return 0
}

wait_for_remote_completion() {
  local remote_worktree_dir="$1"
  local remote_run_root="$2"
  local xcodebuild_args_b64="$3"
  local remote_timeout_seconds="${TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS:-$DEFAULT_REMOTE_TEST_TIMEOUT_SECONDS}"
  local allow_remote_x86_64_tests="${TOASTTY_ALLOW_REMOTE_X86_64_TESTS:-0}"
  local remote_stdout="$LOCAL_ARTIFACTS_DIR/remote-stdout.log"
  local remote_stderr="$LOCAL_ARTIFACTS_DIR/remote-stderr.log"
  local ssh_exit_code=0

  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -l -s -- \
      "$RUN_LABEL" \
      "$remote_run_root" \
      "$remote_worktree_dir" \
      "$SCRIPT_PATH" \
      "$xcodebuild_args_b64" \
      "$remote_timeout_seconds" \
      "$allow_remote_x86_64_tests" \
      > >(tee "$remote_stdout") \
      2> >(tee "$remote_stderr" >&2) <<'EOF'; then
set -euo pipefail
run_label="$1"
remote_run_root="$2"
remote_worktree_dir="$3"
script_path="$4"
xcodebuild_args_b64="$5"
remote_timeout_seconds="$6"
allow_remote_x86_64_tests="$7"
export TOASTTY_REMOTE_TEST_RUN_LABEL="$run_label"
export TOASTTY_REMOTE_TEST_REMOTE_RUN_ROOT="$remote_run_root"
export TOASTTY_REMOTE_TEST_REMOTE_WORKTREE_DIR="$remote_worktree_dir"
export TOASTTY_REMOTE_TEST_XCODEBUILD_ARGS_B64="$xcodebuild_args_b64"
export TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS="$remote_timeout_seconds"
export TOASTTY_ALLOW_REMOTE_X86_64_TESTS="$allow_remote_x86_64_tests"
cd "$remote_worktree_dir"
/bin/bash "$script_path" --remote-exec
EOF
    :
  else
    ssh_exit_code=$?
  fi

  return "$ssh_exit_code"
}

run_local_mode() {
  require_command git
  require_command ssh
  require_command rsync

  if [[ "${#XCODEBUILD_ARGS[@]}" != "0" ]]; then
    assert_supported_xcodebuild_args "${XCODEBUILD_ARGS[@]}"
  fi

  prepare_local_artifacts

  local xcodebuild_command_display
  if [[ "${#XCODEBUILD_ARGS[@]}" == "0" ]]; then
    xcodebuild_command_display="$(build_display_command)"
  else
    xcodebuild_command_display="$(build_display_command "${XCODEBUILD_ARGS[@]}")"
  fi
  write_request_env "$LOCAL_ARTIFACTS_DIR/request.env" "$xcodebuild_command_display"

  local started_at
  started_at="$(timestamp_utc)"

  if [[ -z "$REMOTE_HOST" ]]; then
    warn "Remote preflight failed: TOASTTY_REMOTE_GUI_HOST is not set"
    local ended_at
    ended_at="$(timestamp_utc)"
    write_result_json \
      "$LOCAL_ARTIFACTS_DIR/result.json" \
      "setup_error" \
      "$started_at" \
      "$ended_at" \
      "" \
      "TOASTTY_REMOTE_GUI_HOST is not set" \
      "$xcodebuild_command_display"
    return 1
  fi

  if ! run_remote_preflight; then
    warn "Remote preflight failed: $REMOTE_PREFLIGHT_ERROR"
    local ended_at
    ended_at="$(timestamp_utc)"
    write_result_json \
      "$LOCAL_ARTIFACTS_DIR/result.json" \
      "setup_error" \
      "$started_at" \
      "$ended_at" \
      "" \
      "Remote validation preflight failed: $REMOTE_PREFLIGHT_ERROR" \
      "$xcodebuild_command_display"
    return 1
  fi

  local remote_worktree_dir="$REMOTE_GUI_ROOT/worktrees/$RUN_LABEL"
  local remote_run_root="$REMOTE_GUI_ROOT/test-runs/$RUN_LABEL"

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

  local xcodebuild_args_b64
  if [[ "${#XCODEBUILD_ARGS[@]}" == "0" ]]; then
    xcodebuild_args_b64="$(serialize_xcodebuild_args)"
  else
    xcodebuild_args_b64="$(serialize_xcodebuild_args "${XCODEBUILD_ARGS[@]}")"
  fi

  log "Running remote xcodebuild test"
  local remote_test_exit_code=0
  if wait_for_remote_completion "$remote_worktree_dir" "$remote_run_root" "$xcodebuild_args_b64"; then
    :
  else
    remote_test_exit_code=$?
    warn "Remote xcodebuild test failed"
  fi

  if ! copy_remote_result "$remote_run_root"; then
    local ended_at
    ended_at="$(timestamp_utc)"
    write_result_json \
      "$LOCAL_ARTIFACTS_DIR/result.json" \
      "fail" \
      "$started_at" \
      "$ended_at" \
      "$remote_run_root" \
      "Failed copying remote artifacts back" \
      "$xcodebuild_command_display"
    remote_test_exit_code=1
  fi

  if [[ ! -f "$LOCAL_ARTIFACTS_DIR/result.json" ]]; then
    local ended_at
    ended_at="$(timestamp_utc)"
    write_result_json \
      "$LOCAL_ARTIFACTS_DIR/result.json" \
      "fail" \
      "$started_at" \
      "$ended_at" \
      "$remote_run_root" \
      "Remote result.json was not produced" \
      "$xcodebuild_command_display"
    remote_test_exit_code=1
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

  if [[ "$remote_test_exit_code" != "0" ]]; then
    return "$remote_test_exit_code"
  fi
}

run_remote_mode() {
  require_command xcodebuild

  local run_label="${TOASTTY_REMOTE_TEST_RUN_LABEL:?TOASTTY_REMOTE_TEST_RUN_LABEL is required}"
  local remote_run_root="${TOASTTY_REMOTE_TEST_REMOTE_RUN_ROOT:?TOASTTY_REMOTE_TEST_REMOTE_RUN_ROOT is required}"
  local remote_worktree_dir="${TOASTTY_REMOTE_TEST_REMOTE_WORKTREE_DIR:?TOASTTY_REMOTE_TEST_REMOTE_WORKTREE_DIR is required}"
  local xcodebuild_args_b64="${TOASTTY_REMOTE_TEST_XCODEBUILD_ARGS_B64:-}"
  local decoded_args
  decoded_args="$(decode_base64 "$xcodebuild_args_b64")"

  local xcodebuild_args=()
  if [[ -n "$decoded_args" ]]; then
    while IFS= read -r arg; do
      xcodebuild_args+=("$arg")
    done <<EOF
$decoded_args
EOF
  else
    set_default_xcodebuild_args
    xcodebuild_args=("${DEFAULT_XCODEBUILD_ARGS[@]}")
  fi

  assert_supported_xcodebuild_args "${xcodebuild_args[@]}"

  local started_at
  started_at="$(timestamp_utc)"
  local derived_path="$remote_run_root/Derived"
  local runtime_home="$remote_run_root/runtime-home"
  local result_bundle="$remote_run_root/TestResults.xcresult"
  local xcodebuild_log="$remote_run_root/xcodebuild.log"
  local timeout_marker="$remote_run_root/xcodebuild.timeout"
  local xcodebuild_command
  xcodebuild_command="$(join_shell_words xcodebuild "${xcodebuild_args[@]}" -derivedDataPath "$derived_path" -resultBundlePath "$result_bundle" test)"
  local exit_code=0
  local status="pass"
  local failure_summary=""
  local remote_arch
  remote_arch="$(uname -m)"
  local timeout_seconds="${TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS:-$DEFAULT_REMOTE_TEST_TIMEOUT_SECONDS}"
  local allow_remote_x86_64_tests="${TOASTTY_ALLOW_REMOTE_X86_64_TESTS:-0}"
  local xcodebuild_pid=""
  local tail_pid=""
  local watchdog_pid=""

  mkdir -p "$remote_run_root" "$runtime_home"
  rm -rf "$derived_path" "$result_bundle" "$timeout_marker"
  : >"$xcodebuild_log"

  cleanup_remote_xcodebuild() {
    local cleanup_exit_code=$?
    if [[ -n "${watchdog_pid:-}" ]]; then
      kill "$watchdog_pid" >/dev/null 2>&1 || true
      wait "$watchdog_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "${tail_pid:-}" ]]; then
      kill "$tail_pid" >/dev/null 2>&1 || true
      wait "$tail_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "${xcodebuild_pid:-}" ]] && kill -0 "$xcodebuild_pid" >/dev/null 2>&1; then
      kill_process_tree "$xcodebuild_pid" TERM
      sleep 2
      if kill -0 "$xcodebuild_pid" >/dev/null 2>&1; then
        kill_process_tree "$xcodebuild_pid" KILL
      fi
      wait "$xcodebuild_pid" >/dev/null 2>&1 || true
    fi
    return "$cleanup_exit_code"
  }
  trap cleanup_remote_xcodebuild EXIT HUP INT TERM

  if [[ "$remote_arch" == "arm64" && "$allow_remote_x86_64_tests" != "1" ]] &&
     xcodebuild_args_request_x86_64_macos "${xcodebuild_args[@]}"; then
    exit_code=$SETUP_ERROR_EXIT_CODE
    status="setup_error"
    failure_summary="Remote xcodebuild test requested macOS x86_64 on an arm64 host; this has been observed to leave orphaned Rosetta xcodebuild/test-host processes. Use arch=arm64 or set TOASTTY_ALLOW_REMOTE_X86_64_TESTS=1."
  elif ! is_non_negative_integer "$timeout_seconds"; then
    exit_code=$SETUP_ERROR_EXIT_CODE
    status="setup_error"
    failure_summary="TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS must be a non-negative integer: ${timeout_seconds}"
  else
    ./scripts/dev/bootstrap-worktree.sh >/dev/null

    tail -n +1 -f "$xcodebuild_log" &
    tail_pid=$!

    (
      cd "$remote_worktree_dir"
      TOASTTY_RUNTIME_HOME="$runtime_home" \
      TOASTTY_DEV_WORKTREE_ROOT="$remote_worktree_dir" \
      xcodebuild \
        "${xcodebuild_args[@]}" \
        -derivedDataPath "$derived_path" \
        -resultBundlePath "$result_bundle" \
        test >"$xcodebuild_log" 2>&1
    ) &
    xcodebuild_pid=$!

    if [[ "$timeout_seconds" != "0" ]]; then
      (
        sleep "$timeout_seconds"
        if kill -0 "$xcodebuild_pid" >/dev/null 2>&1; then
          printf 'error: remote xcodebuild test timed out after %s seconds\n' "$timeout_seconds" >>"$xcodebuild_log"
          : >"$timeout_marker"
          kill_process_tree "$xcodebuild_pid" TERM
          sleep 5
          if kill -0 "$xcodebuild_pid" >/dev/null 2>&1; then
            kill_process_tree "$xcodebuild_pid" KILL
          fi
        fi
      ) &
      watchdog_pid=$!
    fi

    if wait "$xcodebuild_pid"; then
      :
    else
      exit_code=$?
      status="fail"
      if [[ -f "$timeout_marker" ]]; then
        exit_code=124
        failure_summary="Remote xcodebuild test timed out after ${timeout_seconds} seconds"
      else
        failure_summary="Remote xcodebuild test exited with status ${exit_code}"
      fi
    fi

    xcodebuild_pid=""
    if [[ -n "$watchdog_pid" ]]; then
      kill "$watchdog_pid" >/dev/null 2>&1 || true
      wait "$watchdog_pid" >/dev/null 2>&1 || true
      watchdog_pid=""
    fi
    if [[ -n "$tail_pid" ]]; then
      kill "$tail_pid" >/dev/null 2>&1 || true
      wait "$tail_pid" >/dev/null 2>&1 || true
      tail_pid=""
    fi
  fi

  local ended_at
  ended_at="$(timestamp_utc)"
  write_result_json \
    "$remote_run_root/result.json" \
    "$status" \
    "$started_at" \
    "$ended_at" \
    "$remote_run_root" \
    "$failure_summary" \
    "$xcodebuild_command"

  return "$exit_code"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --keep-remote)
      KEEP_REMOTE=1
      shift
      ;;
    --remote-exec)
      REMOTE_EXEC=1
      shift
      ;;
    --)
      shift
      XCODEBUILD_ARGS=("$@")
      break
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
