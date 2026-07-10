#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_ARTIFACTS_ROOT="$ROOT_DIR/artifacts"
DEFAULT_POLICY_FILE="$ROOT_DIR/scripts/automation/artifact-retention.json"
ARTIFACTS_ROOT="${TOASTTY_ARTIFACTS_ROOT:-$DEFAULT_ARTIFACTS_ROOT}"
POLICY_FILE="${TOASTTY_ARTIFACT_RETENTION_CONFIG:-$DEFAULT_POLICY_FILE}"
TESTING="${TOASTTY_ARTIFACT_CLEANUP_TESTING:-0}"
APPLY=0
INCLUDE_UNOWNED=0
VERBOSE=0
SELECTED_CATEGORY=""
LOCK_DIR=""
TEMP_DIR=""
NOW_EPOCH="${TOASTTY_ARTIFACT_CLEANUP_NOW_EPOCH:-$(date +%s)}"

TOTAL_ELIGIBLE=0
TOTAL_DELETED=0
TOTAL_MANUAL_REVIEW=0
TOTAL_ELIGIBLE_BYTES=0
TOTAL_RECLAIMED_BYTES=0
EVALUATION_REASON=""

source "$ROOT_DIR/scripts/automation/runtime-ownership.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/automation/cleanup-artifacts.sh [options]

Safely evaluates Toastty's gitignored artifact categories against
scripts/automation/artifact-retention.json. The default is a dry run.

Options:
  --apply             Delete eligible artifact directories.
  --category <name>   Evaluate only one configured category.
  --include-unowned   Allow old dev-runs without instance.json to be eligible.
  --verbose           Report each retained or manual-review directory.
  -h, --help          Show this help.
EOF
}

log() {
  printf '%s\n' "$*"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      ;;
    --category)
      [[ $# -ge 2 ]] || fail "--category requires a value"
      SELECTED_CATEGORY="$2"
      shift
      ;;
    --include-unowned)
      INCLUDE_UNOWNED=1
      ;;
    --verbose)
      VERBOSE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
  shift
done

if [[ "$TESTING" != "1" ]]; then
  [[ "$ARTIFACTS_ROOT" == "$DEFAULT_ARTIFACTS_ROOT" ]] \
    || fail "TOASTTY_ARTIFACTS_ROOT is available only when TOASTTY_ARTIFACT_CLEANUP_TESTING=1"
  [[ "$POLICY_FILE" == "$DEFAULT_POLICY_FILE" ]] \
    || fail "TOASTTY_ARTIFACT_RETENTION_CONFIG is available only when TOASTTY_ARTIFACT_CLEANUP_TESTING=1"
  [[ -z "${TOASTTY_ARTIFACT_CLEANUP_NOW_EPOCH:-}" ]] \
    || fail "TOASTTY_ARTIFACT_CLEANUP_NOW_EPOCH is available only when TOASTTY_ARTIFACT_CLEANUP_TESTING=1"
fi

[[ "$NOW_EPOCH" =~ ^[0-9]+$ ]] || fail "cleanup clock must be a Unix timestamp"
command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ -f "$POLICY_FILE" ]] || fail "retention policy not found: $POLICY_FILE"

if ! jq -e '
  .schemaVersion == 1 and
  (.categories | type == "object") and
  all(.categories | to_entries[];
    (.key | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.value | type == "object") and
    (.value.strategy == "manual" or
      (.value.strategy == "owned-dev-run" and
        (.value.maxAgeHours | type == "number" and . > 0 and floor == .)) or
      (.value.strategy == "result-status" and
        (.value.statusMaxAgeHours | type == "object") and
        all(.value.statusMaxAgeHours[];
          type == "number" and . > 0 and floor == .)))
  )
' "$POLICY_FILE" >/dev/null; then
  fail "invalid or unsupported retention policy: $POLICY_FILE"
fi

if [[ -n "$SELECTED_CATEGORY" ]] \
  && ! jq -e --arg category "$SELECTED_CATEGORY" '.categories[$category] != null' "$POLICY_FILE" >/dev/null; then
  fail "category is not configured in the retention policy: $SELECTED_CATEGORY"
fi

if [[ ! -d "$ARTIFACTS_ROOT" ]]; then
  log "No artifacts directory found: $ARTIFACTS_ROOT"
  exit 0
fi
if [[ -L "$ARTIFACTS_ROOT" ]]; then
  fail "refusing to clean a symlinked artifacts root: $ARTIFACTS_ROOT"
fi

ARTIFACTS_ROOT="$(toastty_canonical_path "$ARTIFACTS_ROOT")"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/toastty-artifact-cleanup.XXXXXX")"

if (( APPLY == 1 )); then
  LOCK_DIR="$ARTIFACTS_ROOT/.cleanup.lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_DIR=""
    fail "artifact cleanup is already running or left a stale lock: $ARTIFACTS_ROOT/.cleanup.lock"
  fi
fi

human_bytes() {
  awk -v bytes="$1" 'BEGIN {
    if (bytes >= 1073741824) printf "%.1f GiB", bytes / 1073741824;
    else if (bytes >= 1048576) printf "%.1f MiB", bytes / 1048576;
    else if (bytes >= 1024) printf "%.1f KiB", bytes / 1024;
    else printf "%d B", bytes;
  }'
}

directory_bytes() {
  local directory="$1"
  local blocks
  blocks="$(du -sk "$directory" 2>/dev/null | awk '{print $1}')" || return 1
  [[ "$blocks" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((blocks * 1024))"
}

cutoff_reference() {
  local hours="$1"
  local reference="$TEMP_DIR/cutoff-${hours}"
  local cutoff_epoch="$((NOW_EPOCH - hours * 3600))"
  local timestamp=""

  if [[ ! -e "$reference" ]]; then
    if timestamp="$(date -r "$cutoff_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null)"; then
      :
    elif timestamp="$(date -d "@$cutoff_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null)"; then
      :
    else
      return 1
    fi
    touch -t "$timestamp" "$reference" || return 1
  fi
  printf '%s\n' "$reference"
}

has_recent_activity() {
  local directory="$1"
  local hours="$2"
  local reference
  local recent_path

  reference="$(cutoff_reference "$hours")" || return 2
  if ! recent_path="$(find "$directory" -mindepth 0 -newer "$reference" -print -quit 2>/dev/null)"; then
    return 2
  fi
  [[ -n "$recent_path" ]]
}

pid_state() {
  local pid="$1"
  local perl_status
  local ps_output=""
  local ps_error="$TEMP_DIR/ps-${pid}.stderr"

  if [[ "$TESTING" == "1" && "$pid" == "${TOASTTY_ARTIFACT_CLEANUP_TEST_UNKNOWN_PID:-}" ]]; then
    return 2
  fi
  if kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi

  # Bash does not expose whether kill(2) failed with ESRCH (absent) or EPERM
  # (present but inaccessible). Perl lets us inspect errno without parsing
  # localized stderr, including in sandboxes where `ps` is unavailable.
  if [[ -x /usr/bin/perl ]]; then
    if /usr/bin/perl -MErrno=ESRCH -e '
      $pid = shift;
      exit 0 if kill 0, $pid;
      exit(($! == ESRCH) ? 1 : 2);
    ' "$pid"; then
      return 0
    else
      perl_status=$?
      if [[ "$perl_status" == "1" ]]; then
        return 1
      fi
      return 2
    fi
  fi

  if ps_output="$(ps -p "$pid" -o pid= 2>"$ps_error")"; then
    if [[ -n "${ps_output//[[:space:]]/}" ]]; then
      return 0
    fi
    return 1
  fi
  if [[ -n "${ps_output//[[:space:]]/}" ]]; then
    return 0
  fi
  if [[ -s "$ps_error" ]]; then
    return 2
  fi
  return 1
}

evaluate_dev_run() {
  local run_dir="$1"
  local max_age_hours="$2"
  local instance_file="$run_dir/runtime-home/instance.json"
  local expected_runtime_home="$run_dir/runtime-home"
  local actual_runtime_home
  local actual_run_id
  local pid
  local recent_status
  local process_status

  EVALUATION_REASON=""
  if [[ -e "$run_dir/.keep" ]]; then
    EVALUATION_REASON="protected by .keep"
    return 1
  fi
  if has_recent_activity "$run_dir" "$max_age_hours"; then
    EVALUATION_REASON="recent activity"
    return 1
  else
    recent_status=$?
    if [[ "$recent_status" == "2" ]]; then
      EVALUATION_REASON="activity could not be inspected"
      return 2
    fi
  fi

  if [[ ! -f "$instance_file" ]]; then
    if (( INCLUDE_UNOWNED == 1 )); then
      EVALUATION_REASON="old unowned dev run"
      return 0
    fi
    EVALUATION_REASON="missing instance.json"
    return 2
  fi
  if ! jq -e 'type == "object"' "$instance_file" >/dev/null 2>&1; then
    EVALUATION_REASON="malformed instance.json"
    return 2
  fi

  actual_runtime_home="$(jq -r '.runtimeHomePath // empty' "$instance_file")"
  if [[ -z "$actual_runtime_home" ]]; then
    EVALUATION_REASON="missing runtimeHomePath"
    return 2
  fi
  if [[ "$(toastty_canonical_path "$actual_runtime_home")" != "$(toastty_canonical_path "$expected_runtime_home")" ]]; then
    EVALUATION_REASON="runtimeHomePath points elsewhere"
    return 2
  fi

  actual_run_id="$(jq -r '.runID // empty' "$instance_file")"
  if [[ -n "$actual_run_id" && "$(basename "$run_dir")" != "$actual_run_id" ]]; then
    EVALUATION_REASON="runID does not match the directory"
    return 2
  fi

  pid="$(jq -r '.pid // empty' "$instance_file")"
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    EVALUATION_REASON="invalid pid"
    return 2
  fi
  if pid_state "$pid"; then
    EVALUATION_REASON="recorded pid is live"
    return 1
  else
    process_status=$?
    if [[ "$process_status" == "2" ]]; then
      EVALUATION_REASON="recorded pid state is ambiguous"
      return 2
    fi
  fi

  EVALUATION_REASON="inactive owned dev run older than ${max_age_hours}h"
  return 0
}

evaluate_result_run() {
  local run_dir="$1"
  local category="$2"
  local result_file="$run_dir/result.json"
  local status
  local max_age_hours
  local ended_epoch
  local cutoff_epoch
  local recent_status

  EVALUATION_REASON=""
  if [[ -e "$run_dir/.keep" ]]; then
    EVALUATION_REASON="protected by .keep"
    return 1
  fi
  if [[ ! -f "$result_file" ]]; then
    EVALUATION_REASON="missing result.json"
    return 2
  fi
  if ! jq -e '.schemaVersion == 1 and (.status | type == "string") and (.endedAt | type == "string")' \
    "$result_file" >/dev/null 2>&1; then
    EVALUATION_REASON="malformed or unsupported result.json"
    return 2
  fi

  status="$(jq -r '.status' "$result_file")"
  max_age_hours="$(jq -r --arg category "$category" --arg status "$status" \
    '.categories[$category].statusMaxAgeHours[$status] // empty' "$POLICY_FILE")"
  if [[ -z "$max_age_hours" ]]; then
    EVALUATION_REASON="unrecognized result status: $status"
    return 2
  fi
  if ! ended_epoch="$(jq -er '.endedAt | fromdateiso8601' "$result_file" 2>/dev/null)"; then
    EVALUATION_REASON="endedAt is not a supported UTC timestamp"
    return 2
  fi
  cutoff_epoch="$((NOW_EPOCH - max_age_hours * 3600))"
  if (( ended_epoch > cutoff_epoch )); then
    EVALUATION_REASON="result is within ${max_age_hours}h retention"
    return 1
  fi

  if has_recent_activity "$run_dir" "$max_age_hours"; then
    EVALUATION_REASON="files changed within ${max_age_hours}h retention"
    return 1
  else
    recent_status=$?
    if [[ "$recent_status" == "2" ]]; then
      EVALUATION_REASON="activity could not be inspected"
      return 2
    fi
  fi

  EVALUATION_REASON="$status result older than ${max_age_hours}h"
  return 0
}

evaluate_candidate() {
  local run_dir="$1"
  local category="$2"
  local strategy="$3"
  local max_age_hours

  case "$strategy" in
    owned-dev-run)
      max_age_hours="$(jq -r --arg category "$category" '.categories[$category].maxAgeHours' "$POLICY_FILE")"
      evaluate_dev_run "$run_dir" "$max_age_hours"
      ;;
    result-status)
      evaluate_result_run "$run_dir" "$category"
      ;;
    *)
      EVALUATION_REASON="unsupported strategy: $strategy"
      return 2
      ;;
  esac
}

process_category() {
  local category="$1"
  local strategy
  local category_root="$ARTIFACTS_ROOT/$category"
  local canonical_category_root
  local run_dir
  local canonical_run_dir
  local evaluation_status
  local bytes
  local category_eligible=0
  local category_deleted=0
  local category_manual_review=0
  local category_eligible_bytes=0
  local category_reclaimed_bytes=0

  strategy="$(jq -r --arg category "$category" '.categories[$category].strategy' "$POLICY_FILE")"
  if [[ "$strategy" == "manual" ]]; then
    if [[ -d "$category_root" ]]; then
      log "category=$category strategy=manual action=retained"
    fi
    return 0
  fi
  if [[ ! -e "$category_root" ]]; then
    return 0
  fi
  if [[ ! -d "$category_root" || -L "$category_root" ]]; then
    warn "manual review required for non-directory or symlinked category: $category_root"
    TOTAL_MANUAL_REVIEW=$((TOTAL_MANUAL_REVIEW + 1))
    return 0
  fi

  canonical_category_root="$(toastty_canonical_path "$category_root")"
  case "$canonical_category_root" in
    "$ARTIFACTS_ROOT"/*) ;;
    *) fail "category escaped the artifacts root: $category_root" ;;
  esac

  for run_dir in "$category_root"/*; do
    [[ -e "$run_dir" ]] || continue
    if [[ ! -d "$run_dir" || -L "$run_dir" ]]; then
      category_manual_review=$((category_manual_review + 1))
      (( VERBOSE == 0 )) || warn "manual review: $run_dir (not a normal directory)"
      continue
    fi
    canonical_run_dir="$(toastty_canonical_path "$run_dir")"
    case "$canonical_run_dir" in
      "$canonical_category_root"/*) ;;
      *)
        category_manual_review=$((category_manual_review + 1))
        (( VERBOSE == 0 )) || warn "manual review: $run_dir (path escaped category root)"
        continue
        ;;
    esac

    if evaluate_candidate "$run_dir" "$category" "$strategy"; then
      bytes="$(directory_bytes "$run_dir")" || {
        category_manual_review=$((category_manual_review + 1))
        (( VERBOSE == 0 )) || warn "manual review: $run_dir (size could not be inspected)"
        continue
      }
      category_eligible=$((category_eligible + 1))
      category_eligible_bytes=$((category_eligible_bytes + bytes))
      log "eligible category=$category size=$(human_bytes "$bytes") path=$run_dir reason=\"$EVALUATION_REASON\""

      if (( APPLY == 1 )); then
        if evaluate_candidate "$run_dir" "$category" "$strategy"; then
          rm -rf -- "$run_dir"
          category_deleted=$((category_deleted + 1))
          category_reclaimed_bytes=$((category_reclaimed_bytes + bytes))
        else
          warn "retained after safety recheck: $run_dir ($EVALUATION_REASON)"
        fi
      fi
    else
      evaluation_status=$?
      if [[ "$evaluation_status" == "2" ]]; then
        category_manual_review=$((category_manual_review + 1))
        (( VERBOSE == 0 )) || warn "manual review: $run_dir ($EVALUATION_REASON)"
      elif (( VERBOSE == 1 )); then
        log "retained category=$category path=$run_dir reason=\"$EVALUATION_REASON\""
      fi
    fi
  done

  TOTAL_ELIGIBLE=$((TOTAL_ELIGIBLE + category_eligible))
  TOTAL_DELETED=$((TOTAL_DELETED + category_deleted))
  TOTAL_MANUAL_REVIEW=$((TOTAL_MANUAL_REVIEW + category_manual_review))
  TOTAL_ELIGIBLE_BYTES=$((TOTAL_ELIGIBLE_BYTES + category_eligible_bytes))
  TOTAL_RECLAIMED_BYTES=$((TOTAL_RECLAIMED_BYTES + category_reclaimed_bytes))
  log "category=$category strategy=$strategy eligible=$category_eligible deleted=$category_deleted eligible_size=$(human_bytes "$category_eligible_bytes") reclaimed=$(human_bytes "$category_reclaimed_bytes") manual_review=$category_manual_review"
}

if [[ -n "$SELECTED_CATEGORY" ]]; then
  process_category "$SELECTED_CATEGORY"
else
  while IFS= read -r category; do
    process_category "$category"
  done < <(jq -r '.categories | keys[]' "$POLICY_FILE")

  for category_path in "$ARTIFACTS_ROOT"/*; do
    [[ -e "$category_path" ]] || continue
    category="$(basename "$category_path")"
    if ! jq -e --arg category "$category" '.categories[$category] != null' "$POLICY_FILE" >/dev/null; then
      warn "manual review: unconfigured artifact category retained: $category_path"
      TOTAL_MANUAL_REVIEW=$((TOTAL_MANUAL_REVIEW + 1))
    fi
  done
fi

log "mode=$([[ "$APPLY" == "1" ]] && printf apply || printf dry-run) eligible=$TOTAL_ELIGIBLE deleted=$TOTAL_DELETED eligible_size=$(human_bytes "$TOTAL_ELIGIBLE_BYTES") reclaimed=$(human_bytes "$TOTAL_RECLAIMED_BYTES") manual_review=$TOTAL_MANUAL_REVIEW"
