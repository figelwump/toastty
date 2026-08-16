#!/usr/bin/env bash
set -euo pipefail

REMOTE_EXEC=0
if [[ "${1:-}" == "--remote-exec" ]]; then
  REMOTE_EXEC=1
  ROOT_DIR=""
  SCRIPT_PATH=""
else
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
  SCRIPT_PATH="$ROOT_DIR/scripts/remote/cleanup-remote-runs.sh"
fi

MODE="dry-run"
MAX_AGE_HOURS=24
MAX_DELETE_COUNT=10
NOW_EPOCH="$(date +%s)"
REMOTE_HOST="${TOASTTY_REMOTE_GUI_HOST:-}"
REMOTE_REPO_ROOT="${TOASTTY_REMOTE_GUI_REPO_ROOT:-}"
REMOTE_GUI_ROOT="${TOASTTY_REMOTE_GUI_ROOT:-}"
LOCK_DIR=""
TEMP_DIR=""

ELIGIBLE=0
DELETED=0
RETAINED=0
MANUAL_REVIEW=0
DELETE_FAILURES=0
ELIGIBLE_BYTES=0
RECLAIMED_BYTES=0

usage() {
  cat <<'EOF'
Usage: ./scripts/remote/cleanup-remote-runs.sh --dry-run|--apply

Safely evaluates run-manifest-owned remote test directories and paired git
worktrees. A run is eligible only after its immutable ownership paths match,
its owner and path-scoped processes are gone, its retention has expired, and
any recorded run-owned simulator is shutdown. Unowned paths are manual review.

Run through `sv exec --` so the manifest-scoped remote host and roots are
available. The default is a dry run.

Options:
  --dry-run             Report eligible remote runs without deleting them.
  --apply               Revalidate and delete eligible remote runs.
  --max-age-hours <n>   Retention in hours (default: 24).
  --max-delete <n>      Maximum runs deleted per apply (default: 10).
  -h, --help            Show this help.
EOF
}

log() {
  printf '[remote-run-cleanup] %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
    rm -f -- "$LOCK_DIR/owner.json"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

encode_base64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

decode_base64() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    printf '%s' "$1" | base64 --decode
  else
    printf '%s' "$1" | base64 -D
  fi
}

human_bytes() {
  awk -v bytes="$1" 'BEGIN {
    if (bytes >= 1073741824) printf "%.1f GiB", bytes / 1073741824;
    else if (bytes >= 1048576) printf "%.1f MiB", bytes / 1048576;
    else if (bytes >= 1024) printf "%.1f KiB", bytes / 1024;
    else printf "%d B", bytes;
  }'
}

directory_bytes() {
  local path="$1"
  local kib
  kib="$(du -sk "$path" 2>/dev/null | awk '{print $1}')" || return 1
  [[ "$kib" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((kib * 1024))"
}

validate_remote_identity() {
  local repo_root
  local git_root
  local gui_root

  [[ "$REMOTE_REPO_ROOT" == /* && "$REMOTE_GUI_ROOT" == /* ]] \
    || fail "remote repository and validation roots must be absolute"
  [[ -f "$REMOTE_REPO_ROOT/Project.swift" && -f "$REMOTE_REPO_ROOT/scripts/remote/test.sh" ]] \
    || fail "remote repository markers are missing"
  [[ -d "$REMOTE_GUI_ROOT/test-runs" && -d "$REMOTE_GUI_ROOT/worktrees" ]] \
    || fail "remote validation root is missing test-runs/worktrees"
  [[ ! -L "$REMOTE_GUI_ROOT/test-runs" && ! -L "$REMOTE_GUI_ROOT/worktrees" ]] \
    || fail "remote test-runs/worktrees containers must not be symlinks"
  [[ -O "$REMOTE_GUI_ROOT/test-runs" && -O "$REMOTE_GUI_ROOT/worktrees" ]] \
    || fail "remote test-runs/worktrees containers must be owned by the cleanup user"

  repo_root="$(cd "$REMOTE_REPO_ROOT" && pwd -P)"
  git_root="$(git -C "$REMOTE_REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "remote repository root is not a git worktree"
  git_root="$(cd "$git_root" && pwd -P)"
  [[ "$repo_root" == "$git_root" ]] || fail "remote repository root is not the git top level"
  gui_root="$(cd "$REMOTE_GUI_ROOT" && pwd -P)"
  case "$gui_root" in
    "$repo_root"|"$repo_root"/*) fail "remote validation root must not be inside the repository" ;;
  esac
  case "$gui_root" in
    /|/Users|/Users/*/GiantThings) fail "remote validation root is too broad: $gui_root" ;;
  esac

  REMOTE_REPO_ROOT="$repo_root"
  REMOTE_GUI_ROOT="$gui_root"
}

process_matches_live_owner() {
  local pid="$1"
  local expected_started_at="$2"
  local actual_started_at
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  actual_started_at="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null | awk '{$1=$1; print}' || true)"
  if [[ -n "$actual_started_at" ]]; then
    [[ "$actual_started_at" == "$expected_started_at" ]]
    return
  fi
  kill -0 "$pid" >/dev/null 2>&1
}

cleanup_lock_is_stale() {
  local lock_dir="$1"
  local owner_path="$lock_dir/owner.json"
  local created_epoch
  local owner_pid
  local owner_started_at

  [[ -f "$owner_path" && ! -L "$owner_path" ]] || return 1
  created_epoch="$(jq -er '.createdAtEpoch | select(type == "number" and floor == .)' "$owner_path" 2>/dev/null)" \
    || return 1
  owner_pid="$(jq -er '.pid | select(type == "number" and floor == . and . > 0)' "$owner_path" 2>/dev/null)" \
    || return 1
  owner_started_at="$(jq -er '.startedAt | select(type == "string" and length > 0)' "$owner_path" 2>/dev/null)" \
    || return 1
  (( NOW_EPOCH - created_epoch >= 7200 )) || return 1
  ! process_matches_live_owner "$owner_pid" "$owner_started_at"
}

path_has_live_process() {
  local target_path="$1"
  local pid
  local command_line
  [[ -n "$target_path" && "$target_path" == /* ]] || return 0
  while read -r pid command_line; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    case "$command_line" in
      *"$target_path"*) return 0 ;;
    esac
  done < <(ps -axww -o pid=,command=)
  return 1
}

validate_run_manifest() {
  local run_dir="$1"
  local manifest="$run_dir/run-ownership.json"
  local run_label
  local expected_worktree
  local created_epoch
  local cutoff_epoch="$((NOW_EPOCH - MAX_AGE_HOURS * 3600))"
  local owner_pid
  local owner_started_at
  local directory_modified_epoch

  [[ -d "$run_dir" && ! -L "$run_dir" ]] || return 2
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 2
  run_label="$(basename "$run_dir")"
  [[ "$run_label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 2
  expected_worktree="$REMOTE_GUI_ROOT/worktrees/$run_label"

  jq -e \
    --arg runLabel "$run_label" \
    --arg runRoot "$run_dir" \
    --arg worktree "$expected_worktree" '
      .schemaVersion == 1
      and .ownership == "toastty-remote-test"
      and .runLabel == $runLabel
      and .remoteRunRoot == $runRoot
      and .remoteWorktreePath == $worktree
      and .derivedDataPath == ($runRoot + "/Derived")
      and .runtimeHomePath == ($runRoot + "/runtime-home")
      and (.platform == "ios" or .platform == "macos")
      and (.owner.pid | type == "number" and floor == . and . > 0)
      and (.owner.pgid | type == "number" and floor == . and . > 0)
      and (.owner.startedAt | type == "string" and length > 0)
      and (.createdAt | type == "string")
    ' "$manifest" >/dev/null 2>&1 || return 2

  [[ ! -e "$run_dir/.keep" ]] || return 1
  created_epoch="$(jq -er '.createdAt | fromdateiso8601' "$manifest" 2>/dev/null)" || return 2
  (( created_epoch <= NOW_EPOCH )) || return 2
  (( created_epoch <= cutoff_epoch )) || return 1
  directory_modified_epoch="$(stat -f %m "$run_dir" 2>/dev/null)" || return 2
  [[ "$directory_modified_epoch" =~ ^[0-9]+$ ]] || return 2
  (( directory_modified_epoch <= NOW_EPOCH )) || return 2
  (( directory_modified_epoch <= cutoff_epoch )) || return 1

  owner_pid="$(jq -r '.owner.pid' "$manifest")"
  owner_started_at="$(jq -r '.owner.startedAt' "$manifest")"
  process_matches_live_owner "$owner_pid" "$owner_started_at" && return 1
  path_has_live_process "$run_dir" && return 1
  if [[ -e "$expected_worktree" ]]; then
    [[ -d "$expected_worktree" && ! -L "$expected_worktree" ]] || return 2
    path_has_live_process "$expected_worktree" && return 1
  fi
  return 0
}

validate_and_delete_owned_simulator() {
  local run_dir="$1"
  local action="${2:-validate}"
  local manifest="$run_dir/simulator-ownership.json"
  local run_label="$(basename "$run_dir")"
  local simulator_udid
  local simulator_name
  local devices
  local matches
  local state

  [[ -e "$manifest" ]] || return 0
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 2
  jq -e \
    --arg runLabel "$run_label" \
    --arg runRoot "$run_dir" \
    --arg worktree "$REMOTE_GUI_ROOT/worktrees/$run_label" '
      .schemaVersion == 1
      and .ownership == "toastty-remote-test"
      and .runLabel == $runLabel
      and .remoteRunRoot == $runRoot
      and .remoteWorktreePath == $worktree
      and (.simulator.udid | type == "string" and test("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"))
      and (.simulator.name | type == "string" and startswith("Toastty Remote test-"))
    ' "$manifest" >/dev/null 2>&1 || return 2
  simulator_udid="$(jq -r '.simulator.udid' "$manifest")"
  simulator_name="$(jq -r '.simulator.name' "$manifest")"
  devices="$(xcrun simctl list devices --json)" || return 2
  matches="$(jq -c --arg udid "$simulator_udid" '[.devices[][] | select(.udid == $udid)]' <<<"$devices")" \
    || return 2
  [[ "$(jq -r 'length' <<<"$matches")" == "0" ]] && return 0
  [[ "$(jq -r 'length' <<<"$matches")" == "1" ]] || return 2
  [[ "$(jq -r '.[0].name' <<<"$matches")" == "$simulator_name" ]] || return 2
  state="$(jq -r '.[0].state' <<<"$matches")"
  [[ "$state" == "Shutdown" ]] || return 2
  if [[ "$action" == "delete" ]]; then
    xcrun simctl delete "$simulator_udid" || return 3
  fi
  return 0
}

delete_run() {
  local run_dir="$1"
  local run_label="$(basename "$run_dir")"
  local worktree="$REMOTE_GUI_ROOT/worktrees/$run_label"

  validate_run_manifest "$run_dir" || return 1
  validate_and_delete_owned_simulator "$run_dir" delete || return 1
  if [[ -e "$worktree" ]]; then
    [[ -d "$worktree" && ! -L "$worktree" ]] || return 1
    git -C "$REMOTE_REPO_ROOT" worktree remove --force "$worktree" >/dev/null 2>&1 || return 1
  fi
  [[ -d "$REMOTE_GUI_ROOT/test-runs" && ! -L "$REMOTE_GUI_ROOT/test-runs" ]] || return 1
  [[ -d "$REMOTE_GUI_ROOT/worktrees" && ! -L "$REMOTE_GUI_ROOT/worktrees" ]] || return 1
  [[ "$run_dir" == "$REMOTE_GUI_ROOT/test-runs/"* && "$run_dir" != "$REMOTE_GUI_ROOT/test-runs" ]] \
    || return 1
  rm -rf -- "$run_dir" || return 1
  [[ ! -e "$run_dir" && ! -L "$run_dir" ]]
}

process_runs() {
  local run_dir
  local status
  local bytes
  local simulator_status

  while IFS= read -r -d '' run_dir; do
    if validate_run_manifest "$run_dir"; then
      if validate_and_delete_owned_simulator "$run_dir"; then
        bytes="$(directory_bytes "$run_dir")" || {
          MANUAL_REVIEW=$((MANUAL_REVIEW + 1))
          warn "manual review: could not size $run_dir"
          continue
        }
        ELIGIBLE=$((ELIGIBLE + 1))
        ELIGIBLE_BYTES=$((ELIGIBLE_BYTES + bytes))
        log "eligible size=$(human_bytes "$bytes") run=$(basename "$run_dir")"
        if [[ "$MODE" == "apply" ]]; then
          if (( DELETED >= MAX_DELETE_COUNT )); then
            RETAINED=$((RETAINED + 1))
            warn "retained by deletion cap: $run_dir"
          elif delete_run "$run_dir"; then
            DELETED=$((DELETED + 1))
            RECLAIMED_BYTES=$((RECLAIMED_BYTES + bytes))
          else
            DELETE_FAILURES=$((DELETE_FAILURES + 1))
            warn "failed safety recheck or deletion: $run_dir"
          fi
        fi
      else
        simulator_status=$?
        MANUAL_REVIEW=$((MANUAL_REVIEW + 1))
        warn "manual review: simulator ownership/state is ambiguous for $run_dir (status=$simulator_status)"
      fi
    else
      status=$?
      if [[ "$status" == "1" ]]; then
        RETAINED=$((RETAINED + 1))
      else
        MANUAL_REVIEW=$((MANUAL_REVIEW + 1))
        warn "manual review: missing or invalid run ownership for $run_dir"
      fi
    fi
  done < <(find "$REMOTE_GUI_ROOT/test-runs" -mindepth 1 -maxdepth 1 -print0)
}

run_remote_mode() {
  [[ $# -eq 7 ]] || fail "invalid remote cleanup invocation"
  MODE="$1"
  NOW_EPOCH="$2"
  MAX_AGE_HOURS="$3"
  MAX_DELETE_COUNT="$4"
  REMOTE_REPO_ROOT="$(decode_base64 "$5")"
  REMOTE_GUI_ROOT="$(decode_base64 "$6")"
  local expected_script_name="$7"
  [[ "$expected_script_name" == "cleanup-remote-runs.sh" ]] || fail "invalid script identity"

  [[ "$MODE" == "dry-run" || "$MODE" == "apply" ]] || fail "invalid mode: $MODE"
  [[ "$NOW_EPOCH" =~ ^[0-9]+$ ]] || fail "cleanup clock must be a Unix timestamp"
  [[ "$MAX_AGE_HOURS" =~ ^[0-9]+$ && "$MAX_AGE_HOURS" != "0" ]] || fail "retention must be positive"
  [[ "$MAX_DELETE_COUNT" =~ ^[0-9]+$ && "$MAX_DELETE_COUNT" != "0" ]] || fail "deletion cap must be positive"

  require_command base64
  require_command find
  require_command git
  require_command jq
  require_command ps
  require_command xcrun
  validate_remote_identity
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/toastty-remote-run-cleanup.XXXXXX")"
  if [[ "$MODE" == "apply" ]]; then
    LOCK_DIR="$REMOTE_GUI_ROOT/.remote-run-cleanup.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      if cleanup_lock_is_stale "$LOCK_DIR"; then
        local stale_lock_dir="${LOCK_DIR}.stale-$$-${RANDOM}"
        if mv "$LOCK_DIR" "$stale_lock_dir" 2>/dev/null; then
          rm -rf -- "$stale_lock_dir"
          mkdir "$LOCK_DIR" || fail "failed to reacquire stale cleanup lock"
        else
          LOCK_DIR=""
          fail "remote run cleanup lock changed during stale-lock recovery"
        fi
      else
        LOCK_DIR=""
        fail "remote run cleanup is already running or has an ambiguous lock"
      fi
    fi
    if ! jq -n \
      --argjson pid "$$" \
      --arg startedAt "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$$" | awk '{$1=$1; print}')" \
      --argjson createdAtEpoch "$NOW_EPOCH" \
      '{pid:$pid,startedAt:$startedAt,createdAtEpoch:$createdAtEpoch}' \
      >"$LOCK_DIR/owner.json"; then
      fail "failed to write cleanup lock ownership"
    fi
  fi

  process_runs
  log "mode=$MODE eligible=$ELIGIBLE deleted=$DELETED retained=$RETAINED eligible_size=$(human_bytes "$ELIGIBLE_BYTES") reclaimed=$(human_bytes "$RECLAIMED_BYTES") manual_review=$MANUAL_REVIEW delete_failures=$DELETE_FAILURES"
  [[ "$DELETE_FAILURES" == "0" ]]
}

run_local_mode() {
  [[ -n "$REMOTE_HOST" ]] || fail "TOASTTY_REMOTE_GUI_HOST is required; run through sv exec --"
  [[ -n "$REMOTE_REPO_ROOT" && -n "$REMOTE_GUI_ROOT" ]] || fail "remote roots are required"
  require_command base64
  require_command ssh
  log "target=$REMOTE_HOST mode=$MODE retention_hours=$MAX_AGE_HOURS max_delete=$MAX_DELETE_COUNT"
  ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -s -- \
    --remote-exec \
    "$MODE" \
    "$NOW_EPOCH" \
    "$MAX_AGE_HOURS" \
    "$MAX_DELETE_COUNT" \
    "$(encode_base64 "$REMOTE_REPO_ROOT")" \
    "$(encode_base64 "$REMOTE_GUI_ROOT")" \
    "cleanup-remote-runs.sh" \
    <"$SCRIPT_PATH"
}

main() {
  if [[ "$REMOTE_EXEC" == "1" ]]; then
    shift
    run_remote_mode "$@"
    return
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        [[ "$MODE" != "apply" ]] || fail "--dry-run and --apply cannot be combined"
        MODE="dry-run"
        ;;
      --apply)
        [[ "$MODE" != "dry-run" || "${DRY_RUN_EXPLICIT:-0}" != "1" ]] \
          || fail "--dry-run and --apply cannot be combined"
        MODE="apply"
        ;;
      --max-age-hours)
        [[ $# -ge 2 ]] || fail "--max-age-hours requires a value"
        MAX_AGE_HOURS="$2"
        shift
        ;;
      --max-delete)
        [[ $# -ge 2 ]] || fail "--max-delete requires a value"
        MAX_DELETE_COUNT="$2"
        shift
        ;;
      -h|--help)
        usage
        return
        ;;
      *) fail "unknown argument: $1" ;;
    esac
    [[ "$1" == "--dry-run" ]] && DRY_RUN_EXPLICIT=1
    shift
  done
  run_local_mode
}

main "$@"
