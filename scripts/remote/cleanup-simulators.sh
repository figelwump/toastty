#!/usr/bin/env bash
set -euo pipefail

REMOTE_EXEC=0
if [[ "${1:-}" == "--remote-exec" ]]; then
  REMOTE_EXEC=1
  ROOT_DIR=""
  SCRIPT_PATH=""
else
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
  SCRIPT_PATH="$ROOT_DIR/scripts/remote/cleanup-simulators.sh"
fi

MODE="dry-run"
MAX_AGE_HOURS=24
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
EVALUATION_REASON=""
DEVICE_NAME=""
DEVICE_UDID=""
DEVICE_STATE=""
DEVICE_BYTES=0

usage() {
  cat <<'EOF'
Usage: ./scripts/remote/cleanup-simulators.sh --dry-run|--apply

Safely evaluates legacy Plate Remote simulators on the configured Toastty
remote validation Mac. Only shutdown automation-owned devices whose last boot
was more than 24 hours ago are eligible. The default is a dry run.

Run this script through `sv exec --` so the manifest-scoped remote host and
path configuration are available.

Options:
  --dry-run   Report eligible simulators without deleting them.
  --apply     Revalidate and delete eligible shutdown simulators.
  -h, --help  Show this help.

Required environment:
  TOASTTY_REMOTE_GUI_HOST       SSH host for the dedicated validation Mac.
  TOASTTY_REMOTE_GUI_REPO_ROOT  Absolute Toastty repository path on that Mac.
  TOASTTY_REMOTE_GUI_ROOT       Absolute remote validation data root.
EOF
}

log() {
  printf '[remote-simulator-cleanup] %s\n' "$*"
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
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
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

human_bytes() {
  awk -v bytes="$1" 'BEGIN {
    if (bytes >= 1073741824) printf "%.1f GiB", bytes / 1073741824;
    else if (bytes >= 1048576) printf "%.1f MiB", bytes / 1048576;
    else if (bytes >= 1024) printf "%.1f KiB", bytes / 1024;
    else printf "%d B", bytes;
  }'
}

is_legacy_automation_name() {
  local name="$1"
  case "$name" in
    "Plate Remote remote-test-"*|"Plate Remote remote-validate-"*) return 0 ;;
    *) return 1 ;;
  esac
}

evaluate_device_json() {
  local device_json="$1"
  local last_booted_epoch
  local cutoff_epoch="$((NOW_EPOCH - MAX_AGE_HOURS * 3600))"

  EVALUATION_REASON=""
  DEVICE_NAME="$(jq -er '.name | select(type == "string" and length > 0)' <<<"$device_json" 2>/dev/null)" || {
    EVALUATION_REASON="missing or invalid name"
    return 2
  }
  if ! is_legacy_automation_name "$DEVICE_NAME"; then
    EVALUATION_REASON="not a legacy Toastty remote-automation simulator"
    return 3
  fi

  DEVICE_UDID="$(jq -er '.udid | select(type == "string" and test("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"))' \
    <<<"$device_json" 2>/dev/null)" || {
    EVALUATION_REASON="missing or invalid UDID"
    return 2
  }
  DEVICE_STATE="$(jq -er '.state | select(type == "string" and length > 0)' <<<"$device_json" 2>/dev/null)" || {
    EVALUATION_REASON="missing or invalid state"
    return 2
  }
  DEVICE_BYTES="$(jq -er '(.dataPathSize // 0) | select(type == "number" and . >= 0 and floor == .)' \
    <<<"$device_json" 2>/dev/null)" || {
    EVALUATION_REASON="missing or invalid dataPathSize"
    return 2
  }
  last_booted_epoch="$(jq -er '.lastBootedAt | select(type == "string") | fromdateiso8601' \
    <<<"$device_json" 2>/dev/null)" || {
    EVALUATION_REASON="missing or invalid lastBootedAt"
    return 2
  }

  if (( last_booted_epoch > NOW_EPOCH )); then
    EVALUATION_REASON="lastBootedAt is in the future"
    return 2
  fi
  if (( last_booted_epoch > cutoff_epoch )); then
    EVALUATION_REASON="last boot is within ${MAX_AGE_HOURS}h retention"
    return 1
  fi
  if [[ "$DEVICE_STATE" == "Booted" ]]; then
    EVALUATION_REASON="stale automation simulator is still booted"
    return 2
  fi
  if [[ "$DEVICE_STATE" != "Shutdown" ]]; then
    EVALUATION_REASON="unsupported simulator state: $DEVICE_STATE"
    return 2
  fi

  EVALUATION_REASON="shutdown automation simulator last booted more than ${MAX_AGE_HOURS}h ago"
  return 0
}

validate_remote_identity() {
  local configured_repo_root
  local git_repo_root
  local configured_gui_root

  [[ "$REMOTE_REPO_ROOT" == /* ]] || fail "remote repository root must be absolute"
  [[ "$REMOTE_GUI_ROOT" == /* ]] || fail "remote validation root must be absolute"
  [[ -d "$REMOTE_REPO_ROOT" ]] || fail "remote repository root does not exist: $REMOTE_REPO_ROOT"
  [[ -f "$REMOTE_REPO_ROOT/Project.swift" ]] || fail "remote repository marker is missing: Project.swift"
  [[ -f "$REMOTE_REPO_ROOT/scripts/remote/test.sh" ]] || fail "remote repository marker is missing: scripts/remote/test.sh"
  [[ -d "$REMOTE_GUI_ROOT/worktrees" && -d "$REMOTE_GUI_ROOT/test-runs" ]] \
    || fail "remote validation root is missing expected worktrees/test-runs directories: $REMOTE_GUI_ROOT"

  configured_repo_root="$(cd "$REMOTE_REPO_ROOT" && pwd -P)"
  git_repo_root="$(git -C "$REMOTE_REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "configured remote repository root is not a git worktree: $REMOTE_REPO_ROOT"
  git_repo_root="$(cd "$git_repo_root" && pwd -P)"
  [[ "$configured_repo_root" == "$git_repo_root" ]] \
    || fail "configured remote repository root is not the git top level"

  configured_gui_root="$(cd "$REMOTE_GUI_ROOT" && pwd -P)"
  case "$configured_gui_root" in
    "$configured_repo_root"|"$configured_repo_root"/*)
      fail "remote validation root must not be inside the repository root"
      ;;
  esac
}

load_devices() {
  local output_path="$1"
  xcrun simctl list devices available --json >"$output_path"
  jq -e '
    .devices | type == "object" and
    all(to_entries[]; .value | type == "array")
  ' "$output_path" >/dev/null || fail "simctl returned malformed device JSON"
}

find_device_by_udid() {
  local devices_path="$1"
  local udid="$2"
  jq -c --arg udid "$udid" '
    [.devices[][] | select(.udid == $udid)] |
    if length == 1 then .[0] else empty end
  ' "$devices_path"
}

process_devices() {
  local devices_path="$1"
  local encoded_device
  local device_json
  local evaluation_status
  local recheck_path
  local recheck_json
  local original_name
  local original_udid
  local original_bytes

  while IFS= read -r encoded_device; do
    [[ -n "$encoded_device" ]] || continue
    device_json="$(decode_base64 "$encoded_device")"
    if evaluate_device_json "$device_json"; then
      original_name="$DEVICE_NAME"
      original_udid="$DEVICE_UDID"
      original_bytes="$DEVICE_BYTES"
      ELIGIBLE=$((ELIGIBLE + 1))
      ELIGIBLE_BYTES=$((ELIGIBLE_BYTES + original_bytes))
      log "eligible size=$(human_bytes "$original_bytes") udid=$original_udid name=\"$original_name\" reason=\"$EVALUATION_REASON\""

      if [[ "$MODE" == "apply" ]]; then
        recheck_path="$TEMP_DIR/recheck-${original_udid}.json"
        load_devices "$recheck_path"
        recheck_json="$(find_device_by_udid "$recheck_path" "$original_udid")"
        if [[ -z "$recheck_json" ]]; then
          RETAINED=$((RETAINED + 1))
          warn "retained after safety recheck: $original_name ($original_udid was not uniquely available)"
          continue
        fi
        if evaluate_device_json "$recheck_json" \
          && [[ "$DEVICE_NAME" == "$original_name" && "$DEVICE_UDID" == "$original_udid" ]]; then
          if xcrun simctl delete "$original_udid"; then
            DELETED=$((DELETED + 1))
            RECLAIMED_BYTES=$((RECLAIMED_BYTES + original_bytes))
          else
            DELETE_FAILURES=$((DELETE_FAILURES + 1))
            warn "failed to delete eligible simulator: $original_name ($original_udid)"
          fi
        else
          evaluation_status=$?
          RETAINED=$((RETAINED + 1))
          if [[ "$evaluation_status" == "2" ]]; then
            MANUAL_REVIEW=$((MANUAL_REVIEW + 1))
          fi
          warn "retained after safety recheck: $original_name ($EVALUATION_REASON)"
        fi
      fi
    else
      evaluation_status=$?
      if [[ "$evaluation_status" == "2" ]]; then
        MANUAL_REVIEW=$((MANUAL_REVIEW + 1))
        warn "manual review: ${DEVICE_NAME:-unknown simulator} ($EVALUATION_REASON)"
      elif [[ "$evaluation_status" == "1" ]]; then
        RETAINED=$((RETAINED + 1))
      fi
    fi
  done < <(jq -r '.devices[][] | @base64' "$devices_path")
}

run_remote_mode() {
  [[ $# -eq 5 ]] || fail "invalid remote cleanup invocation"
  MODE="$1"
  NOW_EPOCH="$2"
  MAX_AGE_HOURS="$3"
  REMOTE_REPO_ROOT="$(decode_base64 "$4")"
  REMOTE_GUI_ROOT="$(decode_base64 "$5")"

  case "$MODE" in
    dry-run|apply) ;;
    *) fail "invalid remote cleanup mode: $MODE" ;;
  esac
  [[ "$NOW_EPOCH" =~ ^[0-9]+$ ]] || fail "cleanup clock must be a Unix timestamp"
  [[ "$MAX_AGE_HOURS" =~ ^[0-9]+$ && "$MAX_AGE_HOURS" != "0" ]] \
    || fail "retention must be a positive number of hours"

  require_command base64
  require_command git
  require_command jq
  require_command xcrun
  validate_remote_identity

  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/toastty-simulator-cleanup.XXXXXX")"
  if [[ "$MODE" == "apply" ]]; then
    LOCK_DIR="$REMOTE_GUI_ROOT/.simulator-cleanup.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_DIR=""
      fail "remote simulator cleanup is already running or left a stale lock"
    fi
  fi

  local devices_path="$TEMP_DIR/devices.json"
  load_devices "$devices_path"
  process_devices "$devices_path"

  log "mode=$MODE eligible=$ELIGIBLE deleted=$DELETED retained=$RETAINED eligible_size=$(human_bytes "$ELIGIBLE_BYTES") reclaimed=$(human_bytes "$RECLAIMED_BYTES") manual_review=$MANUAL_REVIEW delete_failures=$DELETE_FAILURES"
  [[ "$DELETE_FAILURES" == "0" ]]
}

run_local_mode() {
  [[ -n "$REMOTE_HOST" ]] || fail "TOASTTY_REMOTE_GUI_HOST is required; run through sv exec --"
  [[ -n "$REMOTE_REPO_ROOT" ]] || fail "TOASTTY_REMOTE_GUI_REPO_ROOT is required for the remote identity guard"
  [[ -n "$REMOTE_GUI_ROOT" ]] || fail "TOASTTY_REMOTE_GUI_ROOT is required for the remote identity guard"
  require_command base64
  require_command ssh

  log "target=$REMOTE_HOST mode=$MODE retention_hours=$MAX_AGE_HOURS"
  ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -s -- \
    --remote-exec \
    "$MODE" \
    "$NOW_EPOCH" \
    "$MAX_AGE_HOURS" \
    "$(encode_base64 "$REMOTE_REPO_ROOT")" \
    "$(encode_base64 "$REMOTE_GUI_ROOT")" \
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
      -h|--help)
        usage
        return 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
    if [[ "$1" == "--dry-run" ]]; then
      DRY_RUN_EXPLICIT=1
    fi
    shift
  done

  run_local_mode
}

main "$@"
