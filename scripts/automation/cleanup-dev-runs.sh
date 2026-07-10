#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV_RUNS_ROOT="${DEV_RUNS_ROOT:-$ROOT_DIR/artifacts/dev-runs}"
OLDER_THAN_HOURS="${OLDER_THAN_HOURS:-24}"
DRY_RUN=0
INCLUDE_UNOWNED=0
CUTOFF_REFERENCE=""

source "$ROOT_DIR/scripts/automation/runtime-ownership.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/automation/cleanup-dev-runs.sh [--dry-run] [--include-unowned]

Removes inactive Toastty dev-run directories older than OLDER_THAN_HOURS
(default: 24). Runs with malformed or mismatched ownership metadata are skipped.
Directories without instance.json are skipped unless --include-unowned is passed.

Options:
  --dry-run          Print eligible directories without deleting them.
  --include-unowned  Include old directories that have no instance.json.
  -h, --help         Show this help.
EOF
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

cleanup() {
  if [[ -n "$CUTOFF_REFERENCE" ]]; then
    rm -f "$CUTOFF_REFERENCE"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --include-unowned)
      INCLUDE_UNOWNED=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ ! -d "$DEV_RUNS_ROOT" ]]; then
  exit 0
fi

if ! [[ "$OLDER_THAN_HOURS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: OLDER_THAN_HOURS must be a positive integer" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to verify Toastty dev-run ownership" >&2
  exit 1
fi

cutoff_timestamp=""
if cutoff_timestamp="$(date -v-"${OLDER_THAN_HOURS}"H '+%Y%m%d%H%M.%S' 2>/dev/null)"; then
  :
elif cutoff_timestamp="$(date -d "${OLDER_THAN_HOURS} hours ago" '+%Y%m%d%H%M.%S' 2>/dev/null)"; then
  :
else
  echo "error: unable to calculate the dev-run cleanup cutoff" >&2
  exit 1
fi

CUTOFF_REFERENCE="$(mktemp "${TMPDIR:-/tmp}/toastty-dev-run-cutoff.XXXXXX")"
if ! touch -t "$cutoff_timestamp" "$CUTOFF_REFERENCE"; then
  echo "error: unable to create the dev-run cleanup cutoff reference" >&2
  exit 1
fi

has_recent_activity() {
  local run_dir="$1"
  local recent_path=""

  if ! recent_path="$(find "$run_dir" -mindepth 0 -newer "$CUTOFF_REFERENCE" -print -quit 2>/dev/null)"; then
    warn "skipping dev run whose activity could not be inspected: $run_dir"
    return 0
  fi

  [[ -n "$recent_path" ]]
}

manifest_allows_cleanup() {
  local run_dir="$1"
  local instance_file="$run_dir/runtime-home/instance.json"
  local expected_runtime_home="$run_dir/runtime-home"
  local actual_runtime_home
  local actual_run_id
  local pid

  if [[ ! -f "$instance_file" ]]; then
    if (( INCLUDE_UNOWNED == 1 )); then
      return 0
    fi
    warn "skipping unowned dev run without instance.json: $run_dir"
    return 1
  fi

  if ! jq -e 'type == "object"' "$instance_file" >/dev/null 2>&1; then
    warn "skipping dev run with malformed instance.json: $run_dir"
    return 1
  fi

  actual_runtime_home="$(jq -r '.runtimeHomePath // empty' "$instance_file")"
  if [[ -z "$actual_runtime_home" ]]; then
    warn "skipping dev run without runtimeHomePath ownership metadata: $run_dir"
    return 1
  fi
  if [[ "$(toastty_canonical_path "$actual_runtime_home")" != "$(toastty_canonical_path "$expected_runtime_home")" ]]; then
    warn "skipping dev run whose instance.json points at another runtime home: $run_dir"
    return 1
  fi

  actual_run_id="$(jq -r '.runID // empty' "$instance_file")"
  if [[ -n "$actual_run_id" && "$(basename "$run_dir")" != "$actual_run_id" ]]; then
    warn "skipping dev run whose instance.json has a different runID: $run_dir"
    return 1
  fi

  pid="$(jq -r '.pid // empty' "$instance_file")"
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    warn "skipping dev run whose instance.json has an invalid pid: $run_dir"
    return 1
  fi
  if kill -0 "$pid" >/dev/null 2>&1; then
    return 1
  fi

  return 0
}

for run_dir in "$DEV_RUNS_ROOT"/*; do
  [[ -d "$run_dir" ]] || continue

  if has_recent_activity "$run_dir"; then
    continue
  fi
  if ! manifest_allows_cleanup "$run_dir"; then
    continue
  fi

  if (( DRY_RUN == 1 )); then
    printf '%s\n' "$run_dir"
    continue
  fi

  # Re-check immediately before deletion. This keeps a run that became active
  # or refreshed its ownership metadata during the initial scan.
  if has_recent_activity "$run_dir" || ! manifest_allows_cleanup "$run_dir"; then
    continue
  fi

  rm -rf -- "$run_dir"
done
