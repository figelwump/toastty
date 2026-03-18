#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT_PATH="scripts/remote/gui-validate.sh"

REMOTE_EXEC=0
RUN_LABEL="${RUN_LABEL:-gui-validate-$(date +%Y%m%d-%H%M%S)}"
VALIDATION_SCOPE="working-tree"
REF_SPEC=""
VALIDATION_COMMAND=""
KEEP_REMOTE=0
declare -a TEST_CASES=()

DEFAULT_REMOTE_REPO_ROOT="$ROOT_DIR"
DEFAULT_REMOTE_GUI_ROOT="$(cd "$(dirname "$ROOT_DIR")" && pwd -P)/toastty-remote-gui"
REMOTE_HOST="${TOASTTY_REMOTE_GUI_HOST:-}"
REMOTE_REPO_ROOT="${TOASTTY_REMOTE_GUI_REPO_ROOT:-$DEFAULT_REMOTE_REPO_ROOT}"
REMOTE_GUI_ROOT="${TOASTTY_REMOTE_GUI_ROOT:-$DEFAULT_REMOTE_GUI_ROOT}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/remote/gui-validate.sh [options]

Runs foreground-capable Toastty GUI validation on a remote macOS host over SSH.
The local wrapper creates a disposable remote worktree, syncs the requested
change scope into it, launches Toastty on the remote GUI host, runs a remote
validation command such as Peekaboo, then copies the artifacts back locally.

Options:
  --scope working-tree|head|ref   Local change scope to validate (default: working-tree)
  --ref <git-ref>                 Git ref to export when --scope ref is used
  --run-label <label>             Stable run label used for local and remote artifacts
  --validation-command <command>  Remote shell command to run after launch
  --test-case <description>       Repeatable note stored alongside validation artifacts
  --keep-remote                   Keep the remote worktree and run directory after completion
  --remote-exec                   Internal mode used on the remote host
  -h, --help                      Show this help

Required local environment:
  TOASTTY_REMOTE_GUI_HOST         SSH host for the dedicated GUI validation machine

Optional local environment:
  TOASTTY_REMOTE_GUI_REPO_ROOT    Absolute Toastty repo path on the remote host
  TOASTTY_REMOTE_GUI_ROOT         Remote directory that will hold disposable worktrees and runs

Default remote validation command:
  peekaboo menu list --pid "$TOASTTY_PID" --json | tee "$TOASTTY_ARTIFACTS_DIR/peekaboo-menu.json"
EOF
}

log() {
  printf '[gui-validate] %s\n' "$*"
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

default_validation_command() {
  cat <<'EOF'
peekaboo menu list --pid "$TOASTTY_PID" --json | tee "$TOASTTY_ARTIFACTS_DIR/peekaboo-menu.json"
EOF
}

write_test_cases_file() {
  local path="$1"
  if [[ "${#TEST_CASES[@]}" -eq 0 ]]; then
    return 0
  fi

  : >"$path"
  local test_case
  for test_case in "${TEST_CASES[@]}"; do
    printf '%s\n' "$test_case" >>"$path"
  done
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
  ssh "$REMOTE_HOST" /bin/bash -s -- <<EOF
set -euo pipefail
$script
EOF
}

wait_for_remote_completion() {
  local remote_worktree_dir="$1"
  local remote_run_root="$2"
  local validation_command_b64="$3"

  local remote_stdout="$LOCAL_ARTIFACTS_DIR/remote-stdout.log"
  local remote_stderr="$LOCAL_ARTIFACTS_DIR/remote-stderr.log"
  local ssh_exit_code=0

  if ! ssh "$REMOTE_HOST" /bin/bash -s -- \
      "$RUN_LABEL" \
      "$remote_run_root" \
      "$validation_command_b64" \
      "$remote_worktree_dir" \
      "$SCRIPT_PATH" \
      > >(tee "$remote_stdout") \
      2> >(tee "$remote_stderr" >&2) <<'EOF'; then
set -euo pipefail
run_label="$1"
remote_run_root="$2"
validation_command_b64="$3"
remote_worktree_dir="$4"
script_path="$5"
export TOASTTY_REMOTE_GUI_RUN_LABEL="$run_label"
export TOASTTY_REMOTE_GUI_REMOTE_RUN_ROOT="$remote_run_root"
export TOASTTY_REMOTE_GUI_VALIDATION_COMMAND_B64="$validation_command_b64"
cd "$remote_worktree_dir"
/bin/bash "$script_path" --remote-exec
EOF
    ssh_exit_code=$?
  fi

  return "$ssh_exit_code"
}

run_local_mode() {
  require_command git
  require_command rsync
  require_command ssh

  [[ -n "$REMOTE_HOST" ]] || fail "TOASTTY_REMOTE_GUI_HOST is required"

  LOCAL_ARTIFACTS_DIR="$ROOT_DIR/artifacts/remote-gui/$RUN_LABEL"
  mkdir -p "$LOCAL_ARTIFACTS_DIR"

  local validation_command="${VALIDATION_COMMAND:-$(default_validation_command)}"
  local validation_command_b64
  validation_command_b64="$(encode_base64 "$validation_command")"

  local local_metadata_path="$LOCAL_ARTIFACTS_DIR/request.env"
  cat >"$local_metadata_path" <<EOF
run_label=$RUN_LABEL
scope=$VALIDATION_SCOPE
remote_host=$REMOTE_HOST
remote_repo_root=$REMOTE_REPO_ROOT
remote_gui_root=$REMOTE_GUI_ROOT
validation_command=$validation_command
EOF
  write_test_cases_file "$LOCAL_ARTIFACTS_DIR/test-cases.txt"

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
    export_root=""
  fi

  if [[ -f "$LOCAL_ARTIFACTS_DIR/test-cases.txt" ]]; then
    rsync -a "$LOCAL_ARTIFACTS_DIR/test-cases.txt" "$REMOTE_HOST:$remote_run_root/test-cases.txt"
  fi

  log "Running remote GUI validation"
  local remote_validation_exit_code=0
  if ! wait_for_remote_completion "$remote_worktree_dir" "$remote_run_root" "$validation_command_b64"; then
    remote_validation_exit_code=$?
    warn "Remote GUI validation failed"
  fi

  log "Copying remote artifacts back"
  mkdir -p "$LOCAL_ARTIFACTS_DIR/remote"
  rsync -a "$REMOTE_HOST:$remote_run_root/" "$LOCAL_ARTIFACTS_DIR/remote/"

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

run_remote_mode() {
  require_command xcodebuild
  require_command peekaboo

  local run_label="${TOASTTY_REMOTE_GUI_RUN_LABEL:?TOASTTY_REMOTE_GUI_RUN_LABEL is required}"
  local remote_run_root="${TOASTTY_REMOTE_GUI_REMOTE_RUN_ROOT:?TOASTTY_REMOTE_GUI_REMOTE_RUN_ROOT is required}"
  local validation_command_b64="${TOASTTY_REMOTE_GUI_VALIDATION_COMMAND_B64:-}"
  local validation_command
  if [[ -n "$validation_command_b64" ]]; then
    validation_command="$(decode_base64 "$validation_command_b64")"
  else
    validation_command="$(default_validation_command)"
  fi

  local derived_path="$remote_run_root/Derived"
  local artifacts_dir="$remote_run_root/artifacts"
  local runtime_home="$remote_run_root/runtime-home"
  local socket_path="${TMPDIR:-/tmp}/toastty-${run_label}.sock"
  local arch="${ARCH:-$(uname -m)}"
  local app_binary="$derived_path/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty"
  local instance_json="$runtime_home/instance.json"
  local session_env_path="$remote_run_root/session.env"
  local app_pid=""

  mkdir -p "$artifacts_dir" "$runtime_home" "$(dirname "$socket_path")"
  rm -f "$socket_path"

  cleanup_remote_mode() {
    local exit_code=$?
    rm -f "$socket_path"
    if [[ -n "$app_pid" ]]; then
      kill "$app_pid" >/dev/null 2>&1 || true
      wait "$app_pid" >/dev/null 2>&1 || true
    fi
    return "$exit_code"
  }
  trap cleanup_remote_mode EXIT

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

  [[ -f "$instance_json" ]] || fail "Remote instance.json was not written: $instance_json"

  local recorded_pid="$app_pid"
  if command -v jq >/dev/null 2>&1; then
    recorded_pid="$(jq -r '.pid // empty' "$instance_json")"
    if [[ -n "$recorded_pid" ]]; then
      app_pid="$recorded_pid"
    fi
  fi
  kill -0 "$app_pid" >/dev/null 2>&1 || fail "Remote Toastty process is not running"

  cat >"$session_env_path" <<EOF
TOASTTY_PID=$app_pid
TOASTTY_INSTANCE_JSON=$instance_json
TOASTTY_RUNTIME_HOME=$runtime_home
TOASTTY_ARTIFACTS_DIR=$artifacts_dir
TOASTTY_SOCKET_PATH=$socket_path
TOASTTY_DERIVED_PATH=$derived_path
TOASTTY_APP_BUNDLE=$derived_path/Build/Products/Debug/Toastty.app
EOF

  printf '%s\n' "$validation_command" >"$artifacts_dir/validation-command.sh"

  export TOASTTY_PID="$app_pid"
  export TOASTTY_INSTANCE_JSON="$instance_json"
  export TOASTTY_RUNTIME_HOME="$runtime_home"
  export TOASTTY_ARTIFACTS_DIR="$artifacts_dir"
  export TOASTTY_SOCKET_PATH="$socket_path"
  export TOASTTY_DERIVED_PATH="$derived_path"
  export TOASTTY_APP_BUNDLE="$derived_path/Build/Products/Debug/Toastty.app"

  /bin/bash -lc "set -euo pipefail; $validation_command" \
    >"$artifacts_dir/validation-stdout.log" \
    2>"$artifacts_dir/validation-stderr.log"

  printf 'remote_run_root=%s\n' "$remote_run_root"
  printf 'instance_json=%s\n' "$instance_json"
  printf 'artifacts_dir=%s\n' "$artifacts_dir"
  printf 'pid=%s\n' "$app_pid"
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
    --validation-command)
      [[ $# -ge 2 ]] || fail "--validation-command requires a value"
      VALIDATION_COMMAND="$2"
      shift 2
      ;;
    --test-case)
      [[ $# -ge 2 ]] || fail "--test-case requires a value"
      TEST_CASES+=("$2")
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
