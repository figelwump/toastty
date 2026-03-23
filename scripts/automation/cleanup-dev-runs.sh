#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV_RUNS_ROOT="${DEV_RUNS_ROOT:-$ROOT_DIR/artifacts/dev-runs}"
OLDER_THAN_HOURS="${OLDER_THAN_HOURS:-24}"
DRY_RUN=0

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

if [[ ! -d "$DEV_RUNS_ROOT" ]]; then
  exit 0
fi

if ! [[ "$OLDER_THAN_HOURS" =~ ^[0-9]+$ ]]; then
  echo "error: OLDER_THAN_HOURS must be an integer" >&2
  exit 1
fi

cutoff_seconds=$((OLDER_THAN_HOURS * 3600))
now_epoch="$(date +%s)"

extract_pid() {
  local instance_file="$1"
  if [[ ! -f "$instance_file" ]]; then
    printf ''
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r '.pid // empty' "$instance_file"
    return
  fi

  sed -nE 's/.*"pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$instance_file"
}

for run_dir in "$DEV_RUNS_ROOT"/*; do
  [[ -d "$run_dir" ]] || continue

  instance_file="$run_dir/runtime-home/instance.json"
  pid="$(extract_pid "$instance_file")"
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    continue
  fi

  modified_epoch="$(stat -f '%m' "$run_dir")"
  age_seconds=$((now_epoch - modified_epoch))
  if (( age_seconds < cutoff_seconds )); then
    continue
  fi

  if (( DRY_RUN == 1 )); then
    echo "$run_dir"
    continue
  fi

  rm -rf "$run_dir"
done
