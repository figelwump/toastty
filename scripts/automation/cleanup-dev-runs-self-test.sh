#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/toastty-cleanup-dev-runs.XXXXXX)"
DEV_RUNS_ROOT="$TEST_ROOT/dev-runs"
OLD_TIMESTAMP="202001010000"

trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$DEV_RUNS_ROOT"

write_manifest() {
  local run_name="$1"
  local pid="$2"
  local runtime_home="${3:-$DEV_RUNS_ROOT/$run_name/runtime-home}"
  local run_id="${4:-$run_name}"
  local run_dir="$DEV_RUNS_ROOT/$run_name"

  mkdir -p "$run_dir/runtime-home"
  cat > "$run_dir/runtime-home/instance.json" <<EOF
{
  "pid": $pid,
  "runtimeHomePath": "$runtime_home",
  "runID": "$run_id"
}
EOF
  find "$run_dir" -exec touch -t "$OLD_TIMESTAMP" {} +
}

write_manifest "stale-owned" 999999
write_manifest "live-owned" "$$"
write_manifest "wrong-home" 999999 "$TEST_ROOT/other-runtime-home"
write_manifest "wrong-run-id" 999999 "$DEV_RUNS_ROOT/wrong-run-id/runtime-home" "another-run"

mkdir -p "$DEV_RUNS_ROOT/missing-pid/runtime-home"
printf '{"runtimeHomePath":"%s","runID":"missing-pid"}\n' \
  "$DEV_RUNS_ROOT/missing-pid/runtime-home" \
  > "$DEV_RUNS_ROOT/missing-pid/runtime-home/instance.json"
find "$DEV_RUNS_ROOT/missing-pid" -exec touch -t "$OLD_TIMESTAMP" {} +

mkdir -p "$DEV_RUNS_ROOT/malformed/runtime-home"
printf '{not-json\n' > "$DEV_RUNS_ROOT/malformed/runtime-home/instance.json"
find "$DEV_RUNS_ROOT/malformed" -exec touch -t "$OLD_TIMESTAMP" {} +

mkdir -p "$DEV_RUNS_ROOT/unowned"
touch -t "$OLD_TIMESTAMP" "$DEV_RUNS_ROOT/unowned"

write_manifest "recent-owned" 999999
touch "$DEV_RUNS_ROOT/recent-owned/runtime-home/activity.log"

dry_run_output="$(
  DEV_RUNS_ROOT="$DEV_RUNS_ROOT" OLDER_THAN_HOURS=24 \
    "$ROOT_DIR/scripts/automation/cleanup-dev-runs.sh" --dry-run 2>"$TEST_ROOT/dry-run.stderr"
)"

if [[ "$dry_run_output" != "$DEV_RUNS_ROOT/stale-owned" ]]; then
  echo "error: unexpected default dry-run candidates" >&2
  printf '%s\n' "$dry_run_output" >&2
  exit 1
fi

if ! rg -q 'malformed instance.json' "$TEST_ROOT/dry-run.stderr"; then
  echo "error: malformed manifests should be reported and skipped" >&2
  exit 1
fi
if ! rg -q 'without instance.json' "$TEST_ROOT/dry-run.stderr"; then
  echo "error: unowned runs should be reported and skipped by default" >&2
  exit 1
fi

include_unowned_output="$(
  DEV_RUNS_ROOT="$DEV_RUNS_ROOT" OLDER_THAN_HOURS=24 \
    "$ROOT_DIR/scripts/automation/cleanup-dev-runs.sh" --dry-run --include-unowned 2>/dev/null \
    | sort
)"
expected_include_unowned="$(printf '%s\n%s\n' "$DEV_RUNS_ROOT/stale-owned" "$DEV_RUNS_ROOT/unowned" | sort)"
if [[ "$include_unowned_output" != "$expected_include_unowned" ]]; then
  echo "error: --include-unowned candidates did not match" >&2
  printf '%s\n' "$include_unowned_output" >&2
  exit 1
fi

DEV_RUNS_ROOT="$DEV_RUNS_ROOT" OLDER_THAN_HOURS=24 \
  "$ROOT_DIR/scripts/automation/cleanup-dev-runs.sh" >/dev/null

if [[ -e "$DEV_RUNS_ROOT/stale-owned" ]]; then
  echo "error: stale owned run was not removed" >&2
  exit 1
fi
for protected_run in live-owned wrong-home wrong-run-id missing-pid malformed unowned recent-owned; do
  if [[ ! -d "$DEV_RUNS_ROOT/$protected_run" ]]; then
    echo "error: protected run was removed: $protected_run" >&2
    exit 1
  fi
done

if DEV_RUNS_ROOT="$DEV_RUNS_ROOT" OLDER_THAN_HOURS=invalid \
  "$ROOT_DIR/scripts/automation/cleanup-dev-runs.sh" --dry-run >/dev/null 2>&1; then
  echo "error: invalid OLDER_THAN_HOURS should fail" >&2
  exit 1
fi

if DEV_RUNS_ROOT="$DEV_RUNS_ROOT" OLDER_THAN_HOURS=0 \
  "$ROOT_DIR/scripts/automation/cleanup-dev-runs.sh" --dry-run >/dev/null 2>&1; then
  echo "error: zero OLDER_THAN_HOURS should fail" >&2
  exit 1
fi

echo "ok: cleanup dev-runs self-test passed"
