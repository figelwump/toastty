#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT_PATH="scripts/remote/test.sh"
LIVE_GATEWAY_ENV_HELPER="$ROOT_DIR/scripts/remote/live-gateway-test-environment.sh"
IOS_SIMULATOR_RUN_HELPER="$ROOT_DIR/scripts/remote/ios-simulator-run.sh"

# shellcheck source=live-gateway-test-environment.sh
source "$LIVE_GATEWAY_ENV_HELPER"
# shellcheck source=ios-simulator-run.sh
source "$IOS_SIMULATOR_RUN_HELPER"

REMOTE_EXEC=0
TEST_PLATFORM="macos"
RUN_LABEL="${RUN_LABEL:-test-$(date +%Y%m%d-%H%M%S)}"
VALIDATION_SCOPE="working-tree"
REF_SPEC=""
KEEP_REMOTE=0
LIVE_GATEWAY=0
ALLOW_DESTRUCTIVE_LIVE_REVOCATION=0
LIVE_GATEWAY_URL_VALUE=""
LIVE_GATEWAY_CREDENTIAL_VALUE=""
SETUP_ERROR_EXIT_CODE=78
DEFAULT_REMOTE_TEST_TIMEOUT_SECONDS=3600
DEFAULT_XCODEBUILD_ARGS_SENTINEL="__toastty_default_xcodebuild_args__"
MERGED_XCODEBUILD_ARGS=()

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
  --platform macos|ios                   Project graph to test (default: macos)
  --scope working-tree|head|ref         Local change scope to test (default: working-tree)
  --ref <git-ref>                       Git ref to export when --scope ref is used
  --run-label <label>                   Stable label used for local and remote artifacts
  --keep-remote                         Keep the remote worktree and run directory after completion
  --live-gateway                        Forward the manifest-scoped live URL and credential over SSH stdin
  --allow-destructive-live-revocation   Revoke the forwarded credential; requires --live-gateway
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

  ./scripts/remote/test.sh \
    --platform ios \
    --scope working-tree

  # With no xcodebuild options, the macOS wrapper defaults to:
  #   -workspace toastty.xcworkspace
  #   -scheme ToasttyApp
  #   -configuration Debug
  #   -destination "platform=macOS,arch=$(uname -m)"
  # The iOS wrapper generates the separate ios/ Tuist graph and defaults to
  # ios/ToasttyMobile.xcworkspace, ToasttyMobileApp, and a compatible iPhone
  # Simulator destination reported by xcodebuild.

Required local environment:
  TOASTTY_REMOTE_GUI_HOST               SSH host for the dedicated remote validation machine

Optional local environment:
  TOASTTY_REMOTE_GUI_REPO_ROOT          Absolute Toastty repo path on the remote host
  TOASTTY_REMOTE_GUI_ROOT               Remote directory that will hold disposable worktrees and test runs
  TOASTTY_MOBILE_LIVE_GATEWAY_URL       Canonical HTTPS *.ts.net gateway URL used only with --live-gateway
  TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL
                                        43-character native credential used only with --live-gateway
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
  if [[ "$TEST_PLATFORM" == "ios" ]]; then
    DEFAULT_XCODEBUILD_ARGS=(
      -workspace
      ios/ToasttyMobile.xcworkspace
      -scheme
      ToasttyMobileApp
      -configuration
      Debug
      -parallel-testing-enabled
      NO
    )
    return
  fi

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

xcodebuild_arg_count() {
  local option="$1"
  shift
  local count=0
  local arg

  for arg in "$@"; do
    if [[ "$arg" == "$option" || "$arg" == "$option="* ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

xcodebuild_args_have_option() {
  local option="$1"
  shift
  local arg

  for arg in "$@"; do
    if [[ "$arg" == "$option" || "$arg" == "$option="* ]]; then
      return 0
    fi
  done
  return 1
}

xcodebuild_arg_value() {
  local option="$1"
  shift
  local args=("$@")
  local index
  local arg

  for ((index = 0; index < ${#args[@]}; index += 1)); do
    arg="${args[$index]}"
    if [[ "$arg" == "$option" ]]; then
      if (( index + 1 < ${#args[@]} )); then
        printf '%s\n' "${args[$((index + 1))]}"
        return 0
      fi
      return 1
    fi
    if [[ "$arg" == "$option="* ]]; then
      printf '%s\n' "${arg#*=}"
      return 0
    fi
  done
  return 1
}

validate_paired_xcodebuild_args() {
  local args=("$@")
  local index
  local arg
  local option
  local value
  local workspace_count
  local project_count
  local option_count

  for ((index = 0; index < ${#args[@]}; index += 1)); do
    arg="${args[$index]}"
    case "$arg" in
      -workspace|-project|-scheme|-configuration|-parallel-testing-enabled|-destination)
        option="$arg"
        if (( index + 1 >= ${#args[@]} )); then
          fail "$option requires a value after --"
        fi
        value="${args[$((index + 1))]}"
        if [[ -z "$value" || "$value" == -* ]]; then
          fail "$option requires a non-option value after --"
        fi
        index=$((index + 1))
        ;;
      -workspace=*|-project=*|-scheme=*|-configuration=*|-parallel-testing-enabled=*|-destination=*)
        option="${arg%%=*}"
        value="${arg#*=}"
        [[ -n "$value" ]] || fail "$option requires a non-empty value after --"
        ;;
    esac
  done

  workspace_count="$(xcodebuild_arg_count -workspace "${args[@]}")"
  project_count="$(xcodebuild_arg_count -project "${args[@]}")"
  if (( workspace_count + project_count > 1 )); then
    fail "pass only one -workspace or -project after --"
  fi

  for option in -scheme -configuration -parallel-testing-enabled; do
    option_count="$(xcodebuild_arg_count "$option" "${args[@]}")"
    if (( option_count > 1 )); then
      fail "pass $option at most once after --"
    fi
  done
}

merge_default_xcodebuild_args() {
  local custom_args=("$@")
  MERGED_XCODEBUILD_ARGS=()

  validate_paired_xcodebuild_args "${custom_args[@]}"

  if ! xcodebuild_args_have_option -workspace "${custom_args[@]}" \
    && ! xcodebuild_args_have_option -project "${custom_args[@]}"; then
    if [[ "$TEST_PLATFORM" == "ios" ]]; then
      MERGED_XCODEBUILD_ARGS+=( -workspace ios/ToasttyMobile.xcworkspace )
    else
      MERGED_XCODEBUILD_ARGS+=( -workspace toastty.xcworkspace )
    fi
  fi
  if ! xcodebuild_args_have_option -scheme "${custom_args[@]}"; then
    if [[ "$TEST_PLATFORM" == "ios" ]]; then
      MERGED_XCODEBUILD_ARGS+=( -scheme ToasttyMobileApp )
    else
      MERGED_XCODEBUILD_ARGS+=( -scheme ToasttyApp )
    fi
  fi
  if ! xcodebuild_args_have_option -configuration "${custom_args[@]}"; then
    MERGED_XCODEBUILD_ARGS+=( -configuration Debug )
  fi
  if [[ "$TEST_PLATFORM" == "ios" ]] \
    && ! xcodebuild_args_have_option -parallel-testing-enabled "${custom_args[@]}"; then
    MERGED_XCODEBUILD_ARGS+=( -parallel-testing-enabled NO )
  fi
  if [[ "$TEST_PLATFORM" == "macos" ]] \
    && ! xcodebuild_args_have_option -destination "${custom_args[@]}"; then
    local arch="${ARCH:-$(uname -m)}"
    MERGED_XCODEBUILD_ARGS+=( -destination "platform=macOS,arch=${arch}" )
  fi

  MERGED_XCODEBUILD_ARGS+=( "${custom_args[@]}" )
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
    printf 'platform=%q\n' "$TEST_PLATFORM"
    printf 'requested_target=%q\n' "remote"
    printf 'remote_host=%q\n' "$REMOTE_HOST"
    printf 'remote_repo_root=%q\n' "$REMOTE_REPO_ROOT"
    printf 'remote_gui_root=%q\n' "$REMOTE_GUI_ROOT"
    printf 'xcodebuild_command=%q\n' "$xcodebuild_command"
    printf 'live_gateway=%q\n' "$([[ "$LIVE_GATEWAY" == "1" ]] && printf enabled || printf disabled)"
    printf 'destructive_live_revocation=%q\n' "$([[ "$ALLOW_DESTRUCTIVE_LIVE_REVOCATION" == "1" ]] && printf enabled || printf disabled)"
  } >"$path"
}

configure_live_gateway_environment() {
  if [[ "$ALLOW_DESTRUCTIVE_LIVE_REVOCATION" == "1" && "$LIVE_GATEWAY" != "1" ]]; then
    fail "--allow-destructive-live-revocation requires --live-gateway"
  fi
  if [[ "$LIVE_GATEWAY" != "1" ]]; then
    return 0
  fi

  # Do this before the inputs are read. It also protects callers that invoke
  # the wrapper with tracing enabled from recording credentials in local logs.
  set +xv
  unset BASH_XTRACEFD 2>/dev/null || true

  LIVE_GATEWAY_URL_VALUE="${TOASTTY_MOBILE_LIVE_GATEWAY_URL:-}"
  LIVE_GATEWAY_CREDENTIAL_VALUE="${TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL:-}"
  unset TOASTTY_MOBILE_LIVE_GATEWAY_URL TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL
  if ! toastty_live_gateway_url_is_valid "$LIVE_GATEWAY_URL_VALUE" \
    || ! toastty_live_gateway_credential_is_valid "$LIVE_GATEWAY_CREDENTIAL_VALUE"; then
    fail "--live-gateway requires canonical URL and credential inputs"
  fi
}

write_result_json() {
  local path="$1"
  local status="$2"
  local started_at="$3"
  local ended_at="$4"
  local remote_run_root="$5"
  local failure_summary="$6"
  local xcodebuild_command="$7"
  local test_failure_summary="${8:-$failure_summary}"
  local cleanup_failure_summary="${9:-}"

  mkdir -p "$(dirname "$path")"

  local remote_run_root_value='null'
  local failure_summary_value='null'
  local xcodebuild_command_value='null'
  local test_failure_summary_value='null'
  local cleanup_failure_summary_value='null'

  if [[ -n "$remote_run_root" ]]; then
    remote_run_root_value="\"$(json_escape "$remote_run_root")\""
  fi
  if [[ -n "$failure_summary" ]]; then
    failure_summary_value="\"$(json_escape "$failure_summary")\""
  fi
  if [[ -n "$xcodebuild_command" ]]; then
    xcodebuild_command_value="\"$(json_escape "$xcodebuild_command")\""
  fi
  if [[ -n "$test_failure_summary" ]]; then
    test_failure_summary_value="\"$(json_escape "$test_failure_summary")\""
  fi
  if [[ -n "$cleanup_failure_summary" ]]; then
    cleanup_failure_summary_value="\"$(json_escape "$cleanup_failure_summary")\""
  fi

  cat >"$path" <<EOF
{
  "schemaVersion": 2,
  "requestedTarget": "remote",
  "executionTarget": "remote",
  "platform": "$(json_escape "$TEST_PLATFORM")",
  "status": "$(json_escape "$status")",
  "startedAt": "$(json_escape "$started_at")",
  "endedAt": "$(json_escape "$ended_at")",
  "remoteRunRoot": $remote_run_root_value,
  "failureSummary": $failure_summary_value,
  "testFailureSummary": $test_failure_summary_value,
  "cleanupFailureSummary": $cleanup_failure_summary_value,
  "xcodebuildCommand": $xcodebuild_command_value
}
EOF
}

write_remote_run_ownership() {
  local manifest_path="$1"
  local run_label="$2"
  local remote_run_root="$3"
  local remote_worktree_dir="$4"
  local derived_path="$5"
  local runtime_home="$6"
  local platform="$7"
  local owner_pid="$$"
  local owner_pgid
  local temporary_path

  [[ ! -e "$manifest_path" && ! -L "$manifest_path" ]] || {
    printf 'error: refusing to replace existing remote-run ownership: %s\n' "$manifest_path" >&2
    return 1
  }
  owner_pgid="$(ps -o pgid= -p "$owner_pid" | tr -d '[:space:]')" || return 1
  [[ "$owner_pgid" =~ ^[0-9]+$ ]] || return 1
  temporary_path="${manifest_path}.tmp-${owner_pid}-${RANDOM}"
  jq -n \
    --arg runLabel "$run_label" \
    --arg remoteRunRoot "$remote_run_root" \
    --arg remoteWorktreePath "$remote_worktree_dir" \
    --arg derivedDataPath "$derived_path" \
    --arg runtimeHomePath "$runtime_home" \
    --arg platform "$platform" \
    --argjson ownerPID "$owner_pid" \
    --argjson ownerPGID "$owner_pgid" \
    --arg ownerStartedAt "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$owner_pid" | awk '{$1=$1; print}')" \
    --arg createdAt "$(timestamp_utc)" '
      {
        schemaVersion: 1,
        ownership: "toastty-remote-test",
        runLabel: $runLabel,
        remoteRunRoot: $remoteRunRoot,
        remoteWorktreePath: $remoteWorktreePath,
        derivedDataPath: $derivedDataPath,
        runtimeHomePath: $runtimeHomePath,
        platform: $platform,
        owner: {pid: $ownerPID, pgid: $ownerPGID, startedAt: $ownerStartedAt},
        createdAt: $createdAt
      }
    ' >"$temporary_path" || {
      rm -f -- "$temporary_path"
      return 1
  }
  if ! chmod 0444 "$temporary_path"; then
    rm -f -- "$temporary_path"
    return 1
  fi
  if ! ln "$temporary_path" "$manifest_path"; then
    rm -f -- "$temporary_path"
    return 1
  fi
  rm -f -- "$temporary_path"
  : >"$remote_run_root/STARTED"
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
    merge_default_xcodebuild_args "$@"
    args=("${MERGED_XCODEBUILD_ARGS[@]}")
  fi

  join_shell_words xcodebuild "${args[@]}" test
}

assert_supported_xcodebuild_args() {
  validate_paired_xcodebuild_args "$@"

  local arg
  for arg in "$@"; do
    case "$arg" in
      test|build|archive|analyze)
        fail "Do not pass xcodebuild actions after --. scripts/remote/test.sh always runs the test action."
        ;;
      -derivedDataPath|-derivedDataPath=*|-resultBundlePath|-resultBundlePath=*)
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

  emit_remote_test_script() {
    cat <<'EOF'
set +xv
unset BASH_XTRACEFD 2>/dev/null || true
set -euo pipefail
unset TOASTTY_MOBILE_LIVE_GATEWAY_URL
unset TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL
unset TOASTTY_MOBILE_LIVE_ALLOW_DESTRUCTIVE_REVOCATION
unset TOASTTY_MOBILE_LIVE_FORWARDING_PROBE
unset TEST_RUNNER_TOASTTY_MOBILE_LIVE_GATEWAY_URL
unset TEST_RUNNER_TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL
unset TEST_RUNNER_TOASTTY_MOBILE_LIVE_ALLOW_DESTRUCTIVE_REVOCATION
unset TEST_RUNNER_TOASTTY_MOBILE_LIVE_FORWARDING_PROBE
unset TEST_RUNNER_TOASTTY_MOBILE_LIVE_BROKER_PORT
unset TEST_RUNNER_TOASTTY_MOBILE_LIVE_BROKER_TOKEN
live_gateway_url=""
live_gateway_credential=""
live_gateway_allow_destructive="false"
EOF
    if [[ "$LIVE_GATEWAY" == "1" ]]; then
      toastty_emit_live_gateway_remote_setup \
        "$LIVE_GATEWAY_URL_VALUE" \
        "$LIVE_GATEWAY_CREDENTIAL_VALUE" \
        "$ALLOW_DESTRUCTIVE_LIVE_REVOCATION"
    fi
    cat <<'EOF'
run_label="$1"
remote_run_root="$2"
remote_worktree_dir="$3"
script_path="$4"
xcodebuild_args_b64="$5"
remote_timeout_seconds="$6"
allow_remote_x86_64_tests="$7"
test_platform="$8"
export TOASTTY_REMOTE_TEST_RUN_LABEL="$run_label"
export TOASTTY_REMOTE_TEST_REMOTE_RUN_ROOT="$remote_run_root"
export TOASTTY_REMOTE_TEST_REMOTE_WORKTREE_DIR="$remote_worktree_dir"
export TOASTTY_REMOTE_TEST_XCODEBUILD_ARGS_B64="$xcodebuild_args_b64"
export TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS="$remote_timeout_seconds"
export TOASTTY_ALLOW_REMOTE_X86_64_TESTS="$allow_remote_x86_64_tests"
export TOASTTY_REMOTE_TEST_PLATFORM="$test_platform"

live_gateway_broker_pid=""
live_gateway_broker_root=""
live_gateway_broker_state=""
cleanup_live_gateway_broker() {
  local cleanup_status=$?
  if [[ -n "${live_gateway_broker_pid:-}" ]]; then
    kill -TERM "$live_gateway_broker_pid" >/dev/null 2>&1 || true
    for ((cleanup_attempt = 0; cleanup_attempt < 20; cleanup_attempt += 1)); do
      kill -0 "$live_gateway_broker_pid" >/dev/null 2>&1 || break
      sleep 0.05
    done
    kill -KILL "$live_gateway_broker_pid" >/dev/null 2>&1 || true
    wait "$live_gateway_broker_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "${live_gateway_broker_root:-}" ]]; then
    rm -f \
      "$live_gateway_broker_root/state.json" \
      "$live_gateway_broker_root"/state.json.tmp-* \
      "$live_gateway_broker_root/stdout.log" \
      "$live_gateway_broker_root/stderr.log"
    rmdir "$live_gateway_broker_root" >/dev/null 2>&1 || true
  fi
  return "$cleanup_status"
}
trap cleanup_live_gateway_broker EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "$live_gateway_url" || -n "$live_gateway_credential" ]]; then
  if ! command -v node >/dev/null 2>&1; then
    printf 'error: live gateway broker requires node\n' >&2
    exit 78
  fi
  live_gateway_broker_root="$(mktemp -d "$remote_run_root.live-gateway-broker.XXXXXX")"
  live_gateway_broker_state="$live_gateway_broker_root/state.json"
  printf '%s\n%s\n%s\n' \
      "$live_gateway_url" \
      "$live_gateway_credential" \
      "$live_gateway_allow_destructive" \
    | node "$remote_worktree_dir/scripts/remote/live-gateway-test-broker.mjs" \
        --state-file "$live_gateway_broker_state" \
        >"$live_gateway_broker_root/stdout.log" \
        2>"$live_gateway_broker_root/stderr.log" &
  live_gateway_broker_pid=$!
  unset live_gateway_url live_gateway_credential live_gateway_allow_destructive

  for ((attempt = 0; attempt < 100; attempt += 1)); do
    if [[ -s "$live_gateway_broker_state" ]]; then
      break
    fi
    if ! kill -0 "$live_gateway_broker_pid" >/dev/null 2>&1; then
      wait "$live_gateway_broker_pid" >/dev/null 2>&1 || true
      printf 'error: live gateway broker did not start\n' >&2
      exit 78
    fi
    sleep 0.05
  done
  if [[ ! -s "$live_gateway_broker_state" ]]; then
    printf 'error: live gateway broker readiness timed out\n' >&2
    exit 78
  fi

  broker_metadata="$(node -e '
    const fs = require("node:fs");
    const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (!Number.isInteger(state.port) || state.port < 1 || state.port > 65535
        || typeof state.token !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(state.token)) {
      process.exit(1);
    }
    process.stdout.write(`${state.port} ${state.token}`);
  ' "$live_gateway_broker_state")" || {
    printf 'error: live gateway broker produced invalid state\n' >&2
    exit 78
  }
  read -r broker_port broker_token <<<"$broker_metadata"
  unset broker_metadata
  export TEST_RUNNER_TOASTTY_MOBILE_LIVE_BROKER_PORT="$broker_port"
  export TEST_RUNNER_TOASTTY_MOBILE_LIVE_BROKER_TOKEN="$broker_token"
fi

cd "$remote_worktree_dir"
/bin/bash "$script_path" --remote-exec
EOF
  }

  if ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -l -s -- \
      "$RUN_LABEL" \
      "$remote_run_root" \
      "$remote_worktree_dir" \
      "$SCRIPT_PATH" \
      "$xcodebuild_args_b64" \
      "$remote_timeout_seconds" \
      "$allow_remote_x86_64_tests" \
      "$TEST_PLATFORM" \
      > >(tee "$remote_stdout") \
      2> >(tee "$remote_stderr" >&2) \
      < <(emit_remote_test_script); then
    :
  else
    ssh_exit_code=$?
  fi

  return "$ssh_exit_code"
}

run_local_mode() {
  require_command git
  require_command jq
  require_command ssh
  require_command rsync
  [[ "$RUN_LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
    || fail "--run-label must use 1-128 letters, numbers, dots, underscores, or hyphens"

  configure_live_gateway_environment

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
[[ ! -e \"\$REMOTE_RUN_ROOT\" ]] || {
  printf 'error: remote test run label already exists: %s\\n' \"\$REMOTE_RUN_ROOT\" >&2
  exit 1
}
[[ ! -e \"\$REMOTE_WORKTREE_DIR\" ]] || {
  printf 'error: remote test worktree label already exists: %s\\n' \"\$REMOTE_WORKTREE_DIR\" >&2
  exit 1
}
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
    # SSH command argument forwarding can drop an empty positional argument.
    # Use a sentinel for the default-arguments case so the remote side still
    # receives the timeout and architecture guard arguments in their slots.
    xcodebuild_args_b64="$DEFAULT_XCODEBUILD_ARGS_SENTINEL"
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

  local cleanup_confirmed=0
  if [[ -f "$LOCAL_ARTIFACTS_DIR/COMPLETED" ]] \
    && [[ ! -e "$LOCAL_ARTIFACTS_DIR/INTERRUPTED" && ! -e "$LOCAL_ARTIFACTS_DIR/CLEANUP_FAILED" ]] \
    && jq -e '
      .schemaVersion == 2
      and .cleanupFailureSummary == null
      and (.status == "pass" or .status == "fail" or .status == "setup_error")
    ' "$LOCAL_ARTIFACTS_DIR/result.json" >/dev/null 2>&1; then
    cleanup_confirmed=1
  fi

  if [[ "$KEEP_REMOTE" != "1" && "$cleanup_confirmed" == "1" ]]; then
    log "Cleaning up remote worktree"
    remote_shell "
REMOTE_REPO_ROOT=$(escape_sh "$REMOTE_REPO_ROOT")
REMOTE_WORKTREE_DIR=$(escape_sh "$remote_worktree_dir")
REMOTE_RUN_ROOT=$(escape_sh "$remote_run_root")
git -C \"\$REMOTE_REPO_ROOT\" worktree remove --force \"\$REMOTE_WORKTREE_DIR\" >/dev/null 2>&1 || rm -rf \"\$REMOTE_WORKTREE_DIR\"
rm -rf \"\$REMOTE_RUN_ROOT\"
"
  elif [[ "$KEEP_REMOTE" != "1" ]]; then
    warn "Retaining remote run because run-owned cleanup was not confirmed: $remote_run_root"
  fi

  if [[ "$remote_test_exit_code" != "0" ]]; then
    return "$remote_test_exit_code"
  fi
  return 0
}

run_remote_mode() {
  require_command jq
  require_command xcodebuild

  local run_label="${TOASTTY_REMOTE_TEST_RUN_LABEL:?TOASTTY_REMOTE_TEST_RUN_LABEL is required}"
  local remote_run_root="${TOASTTY_REMOTE_TEST_REMOTE_RUN_ROOT:?TOASTTY_REMOTE_TEST_REMOTE_RUN_ROOT is required}"
  local remote_worktree_dir="${TOASTTY_REMOTE_TEST_REMOTE_WORKTREE_DIR:?TOASTTY_REMOTE_TEST_REMOTE_WORKTREE_DIR is required}"
  local xcodebuild_args_b64="${TOASTTY_REMOTE_TEST_XCODEBUILD_ARGS_B64:-}"
  TEST_PLATFORM="${TOASTTY_REMOTE_TEST_PLATFORM:-macos}"
  [[ "$run_label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
    || fail "remote run label is invalid"
  local decoded_args
  if [[ "$xcodebuild_args_b64" == "$DEFAULT_XCODEBUILD_ARGS_SENTINEL" ]]; then
    decoded_args=""
  else
    decoded_args="$(decode_base64 "$xcodebuild_args_b64")"
  fi

  local xcodebuild_args=()
  if [[ -n "$decoded_args" ]]; then
    local custom_xcodebuild_args=()
    while IFS= read -r arg; do
      custom_xcodebuild_args+=("$arg")
    done <<EOF
$decoded_args
EOF
    merge_default_xcodebuild_args "${custom_xcodebuild_args[@]}"
    xcodebuild_args=("${MERGED_XCODEBUILD_ARGS[@]}")
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
  local destination_probe_log="$remote_run_root/destination-probe.log"
  local timeout_marker="$remote_run_root/xcodebuild.timeout"
  local watchdog_timer_record="$remote_run_root/watchdog-timer.pid"
  local watchdog_reaped_marker="$remote_run_root/watchdog-timer.reaped"
  local xcodebuild_command
  xcodebuild_command="$(join_shell_words xcodebuild "${xcodebuild_args[@]}" -derivedDataPath "$derived_path" -resultBundlePath "$result_bundle" test)"
  local exit_code=0
  local status="pass"
  local failure_summary=""
  local test_failure_summary=""
  local cleanup_failure_summary=""
  local remote_arch
  remote_arch="$(uname -m)"
  local timeout_seconds="${TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS:-$DEFAULT_REMOTE_TEST_TIMEOUT_SECONDS}"
  local allow_remote_x86_64_tests="${TOASTTY_ALLOW_REMOTE_X86_64_TESTS:-0}"
  local xcodebuild_pid=""
  local tail_pid=""
  local watchdog_pid=""
  local owned_simulator_udid=""
  local owned_simulator_name=""
  local remote_resources_finalized=0
  local remote_finalize_in_progress=0
  local remote_finalize_status=1

  mkdir -p "$remote_run_root" "$runtime_home"
  rm -rf "$derived_path" "$result_bundle" "$timeout_marker" "$watchdog_timer_record" "$watchdog_reaped_marker"
  rm -f "$destination_probe_log"
  : >"$xcodebuild_log"
  write_remote_run_ownership \
    "$remote_run_root/run-ownership.json" \
    "$run_label" \
    "$remote_run_root" \
    "$remote_worktree_dir" \
    "$derived_path" \
    "$runtime_home" \
    "$TEST_PLATFORM"

  finalize_remote_resources() {
    local cleanup_failed=0
    if [[ "$remote_resources_finalized" == "1" ]]; then
      return "$remote_finalize_status"
    fi
    if [[ "$remote_finalize_in_progress" == "1" ]]; then
      return "$remote_finalize_status"
    fi
    remote_finalize_in_progress=1
    remote_finalize_status=1
    trap '' HUP INT TERM QUIT PIPE
    toastty_ios_cancel_bounded_simctl
    if [[ -n "${watchdog_pid:-}" ]]; then
      kill "$watchdog_pid" >/dev/null 2>&1 || true
      wait "$watchdog_pid" >/dev/null 2>&1 || true
      watchdog_pid=""
    fi
    if [[ -n "${tail_pid:-}" ]]; then
      kill "$tail_pid" >/dev/null 2>&1 || true
      wait "$tail_pid" >/dev/null 2>&1 || true
      tail_pid=""
    fi
    if [[ -n "${xcodebuild_pid:-}" ]] && kill -0 "$xcodebuild_pid" >/dev/null 2>&1; then
      kill_process_tree "$xcodebuild_pid" TERM
      sleep 2
      if kill -0 "$xcodebuild_pid" >/dev/null 2>&1; then
        kill_process_tree "$xcodebuild_pid" KILL
      fi
      wait "$xcodebuild_pid" >/dev/null 2>&1 || true
      if kill -0 "$xcodebuild_pid" >/dev/null 2>&1; then
        warn "Remote xcodebuild process survived TERM and KILL: $xcodebuild_pid"
        cleanup_failed=1
      fi
    fi
    xcodebuild_pid=""

    if [[ "$cleanup_failed" == "0" ]] \
      && ! toastty_cleanup_run_owned_host_apps "$derived_path"; then
      warn "One or more run-owned Toastty host processes survived cleanup"
      cleanup_failed=1
    fi
    if [[ "$cleanup_failed" == "0" ]] \
      && toastty_run_paths_have_live_process "$derived_path" "$runtime_home"; then
      warn "A process still references the run-owned DerivedData or runtime home"
      cleanup_failed=1
    fi
    if [[ "$cleanup_failed" == "0" && -z "$owned_simulator_udid" \
      && -e "$remote_run_root/simulator-ownership.json" ]]; then
      if [[ -f "$remote_run_root/simulator-ownership.json" \
        && ! -L "$remote_run_root/simulator-ownership.json" ]] \
        && owned_simulator_udid="$(jq -er '.simulator.udid' "$remote_run_root/simulator-ownership.json")" \
        && owned_simulator_name="$(jq -er '.simulator.name' "$remote_run_root/simulator-ownership.json")"; then
        :
      else
        warn "Simulator ownership exists but cannot be read safely"
        cleanup_failed=1
      fi
    fi
    if [[ "$cleanup_failed" == "0" && -n "$owned_simulator_udid" ]]; then
      if ! toastty_ios_simulator_delete_owned_clone \
        "$run_label" "$remote_run_root" "$remote_worktree_dir" \
        "$derived_path" "$runtime_home" \
        "$owned_simulator_udid" "$owned_simulator_name"; then
        warn "Run-owned simulator cleanup failed: $owned_simulator_name ($owned_simulator_udid)"
        cleanup_failed=1
      fi
    fi
    remote_resources_finalized=1
    remote_finalize_in_progress=0
    if [[ "$cleanup_failed" == "0" ]]; then
      remote_finalize_status=0
    fi
    return "$remote_finalize_status"
  }

  cleanup_remote_test_on_exit() {
    local cleanup_exit_code=$?
    if [[ "$remote_resources_finalized" != "1" ]]; then
      if finalize_remote_resources; then
        : >"$remote_run_root/INTERRUPTED"
      else
        : >"$remote_run_root/CLEANUP_FAILED"
      fi
    fi
    return "$cleanup_exit_code"
  }

  handle_remote_test_signal() {
    local signal_exit_code="$1"
    trap '' HUP INT TERM QUIT PIPE
    exit "$signal_exit_code"
  }
  trap cleanup_remote_test_on_exit EXIT
  trap 'handle_remote_test_signal 129' HUP
  trap 'handle_remote_test_signal 130' INT
  trap 'handle_remote_test_signal 143' TERM
  trap 'handle_remote_test_signal 131' QUIT
  trap 'handle_remote_test_signal 141' PIPE

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
    if [[ "$TEST_PLATFORM" == "ios" ]]; then
      if ! command -v node >/dev/null 2>&1; then
        exit_code=$SETUP_ERROR_EXIT_CODE
        status="setup_error"
        failure_summary="Missing required command: node"
      else
        log "Generating the iOS Tuist graph"
        if (
          unset TOASTTY_IOS_DESTINATION
          export TOASTTY_IOS_WORKTREE_ID="$run_label"
          export TOASTTY_IOS_RUN_ID="$run_label"
          export TOASTTY_IOS_RUN_ROOT="$remote_run_root/ios-dispatcher"
          export TOASTTY_IOS_DERIVED_DATA_PATH="$derived_path"
          node ios/scripts/toastty-ios.mjs generate
        ) >>"$xcodebuild_log" 2>&1; then
          :
        else
          local generate_status=$?
          exit_code=$SETUP_ERROR_EXIT_CODE
          status="setup_error"
          failure_summary="iOS project generation exited with status ${generate_status}; see xcodebuild.log"
        fi
      fi

      if [[ "$status" != "setup_error" ]]; then
        local has_destination=0
        local arg
        for arg in "${xcodebuild_args[@]}"; do
          if [[ "$arg" == "-destination" || "$arg" == -destination=* ]]; then
            has_destination=1
            break
          fi
        done
        if [[ "$has_destination" == "0" ]]; then
          local simulator_setup_status=0
          if toastty_ios_simulator_create_owned_clone \
            "$run_label" "$remote_run_root" "$remote_worktree_dir" \
            "$derived_path" "$runtime_home" >>"$xcodebuild_log" 2>&1; then
            :
          else
            simulator_setup_status=$?
          fi
          owned_simulator_udid="$TOASTTY_IOS_OWNED_SIMULATOR_UDID"
          owned_simulator_name="$TOASTTY_IOS_OWNED_SIMULATOR_NAME"
          if [[ "$simulator_setup_status" == "0" ]]; then
            xcodebuild_args+=( -destination "platform=iOS Simulator,id=${owned_simulator_udid}" )
            xcodebuild_command="$(join_shell_words xcodebuild "${xcodebuild_args[@]}" -derivedDataPath "$derived_path" -resultBundlePath "$result_bundle" test)"
          else
            exit_code=$SETUP_ERROR_EXIT_CODE
            status="setup_error"
            failure_summary="Failed to create and boot a run-owned iPhone Simulator clone; see xcodebuild.log"
          fi
        fi
      fi
    else
      ./scripts/dev/bootstrap-worktree.sh >/dev/null
    fi

    if [[ "$status" == "setup_error" ]]; then
      :
    else

      tail -n +1 -f "$xcodebuild_log" &
      tail_pid=$!

    (
      cd "$remote_worktree_dir"
      TOASTTY_RUNTIME_HOME="$runtime_home" \
      TOASTTY_RUNTIME_LABEL="$run_label" \
      TOASTTY_RUN_ID="$run_label" \
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
          watchdog_sleep_pid=""
          cleanup_watchdog_timer() {
            if [[ -n "${watchdog_sleep_pid:-}" ]]; then
              kill "$watchdog_sleep_pid" >/dev/null 2>&1 || true
              wait "$watchdog_sleep_pid" >/dev/null 2>&1 || true
            fi
            rm -f "$watchdog_timer_record"
            : >"$watchdog_reaped_marker"
          }
          trap cleanup_watchdog_timer EXIT
          trap 'exit 0' HUP INT TERM
          sleep "$timeout_seconds" &
          watchdog_sleep_pid=$!
          printf '%s\n' "$watchdog_sleep_pid" >"$watchdog_timer_record"
          wait "$watchdog_sleep_pid" || exit 0
          watchdog_sleep_pid=""
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
      if [[ ! -f "$watchdog_reaped_marker" ]]; then
        exit_code=1
        status="fail"
        failure_summary="Remote timeout watchdog did not confirm that it reaped its timer child"
      fi
    fi
    if [[ -n "$tail_pid" ]]; then
      kill "$tail_pid" >/dev/null 2>&1 || true
      wait "$tail_pid" >/dev/null 2>&1 || true
      tail_pid=""
    fi
    fi
  fi

  test_failure_summary="$failure_summary"
  if finalize_remote_resources; then
    : >"$remote_run_root/COMPLETED"
  else
    cleanup_failure_summary="Run-owned remote test resource cleanup failed; inspect CLEANUP_FAILED and xcodebuild.log"
    : >"$remote_run_root/CLEANUP_FAILED"
    status="fail"
    if [[ "$exit_code" == "0" ]]; then
      exit_code=1
    fi
    if [[ -n "$failure_summary" ]]; then
      failure_summary+="; ${cleanup_failure_summary}"
    else
      failure_summary="$cleanup_failure_summary"
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
    "$xcodebuild_command" \
    "$test_failure_summary" \
    "$cleanup_failure_summary"

  trap - EXIT HUP INT TERM QUIT PIPE
  return "$exit_code"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope)
        [[ $# -ge 2 ]] || fail "--scope requires a value"
        VALIDATION_SCOPE="$2"
        shift 2
        ;;
      --platform)
        [[ $# -ge 2 ]] || fail "--platform requires a value"
        case "$2" in
          macos|ios) TEST_PLATFORM="$2" ;;
          *) fail "--platform must be macos or ios" ;;
        esac
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
      --live-gateway)
        LIVE_GATEWAY=1
        shift
        ;;
      --allow-destructive-live-revocation)
        ALLOW_DESTRUCTIVE_LIVE_REVOCATION=1
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
        return 0
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
