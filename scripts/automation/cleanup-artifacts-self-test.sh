#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/automation/cleanup-artifacts.sh"
POLICY="$ROOT_DIR/scripts/automation/artifact-retention.json"
TEST_ROOT="$(mktemp -d /tmp/toastty-cleanup-artifacts.XXXXXX)"
ARTIFACTS_ROOT="$TEST_ROOT/artifacts"
NOW_EPOCH="1735689600"
TEN_DAYS_AGO="$(jq -nr --argjson epoch "$((NOW_EPOCH - 10 * 86400))" '$epoch | todateiso8601')"
PASS_CUTOFF="$(jq -nr --argjson epoch "$((NOW_EPOCH - 168 * 3600))" '$epoch | todateiso8601')"
PASS_INSIDE_CUTOFF="$(jq -nr --argjson epoch "$((NOW_EPOCH - 168 * 3600 + 1))" '$epoch | todateiso8601')"
RECENT_ACTIVITY_TIMESTAMP="$(date -r "$((NOW_EPOCH - 86400))" '+%Y%m%d%H%M.%S')"
OLD_TIMESTAMP="202001010000"
ABSENT_PID="999991"
UNKNOWN_PID="999992"

trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$ARTIFACTS_ROOT/dev-runs" "$ARTIFACTS_ROOT/remote-tests" "$ARTIFACTS_ROOT/remote-gui" "$ARTIFACTS_ROOT/release"

run_cleanup() {
  TOASTTY_ARTIFACT_CLEANUP_TESTING=1 \
  TOASTTY_ARTIFACTS_ROOT="$ARTIFACTS_ROOT" \
  TOASTTY_ARTIFACT_RETENTION_CONFIG="$POLICY" \
  TOASTTY_ARTIFACT_CLEANUP_NOW_EPOCH="$NOW_EPOCH" \
  TOASTTY_ARTIFACT_CLEANUP_TEST_UNKNOWN_PID="$UNKNOWN_PID" \
    "$SCRIPT" "$@"
}

age_directory() {
  find "$1" -exec touch -t "$OLD_TIMESTAMP" {} +
}

write_manifest() {
  local run_name="$1"
  local pid="$2"
  local runtime_home="${3:-$ARTIFACTS_ROOT/dev-runs/$run_name/runtime-home}"
  local run_id="${4:-$run_name}"
  local run_dir="$ARTIFACTS_ROOT/dev-runs/$run_name"

  mkdir -p "$run_dir/runtime-home"
  printf '{"pid":%s,"runtimeHomePath":"%s","runID":"%s"}\n' \
    "$pid" "$runtime_home" "$run_id" > "$run_dir/runtime-home/instance.json"
  age_directory "$run_dir"
}

write_result() {
  local category="$1"
  local run_name="$2"
  local status="$3"
  local ended_at="$4"
  local run_dir="$ARTIFACTS_ROOT/$category/$run_name"

  mkdir -p "$run_dir"
  printf '{"schemaVersion":1,"status":"%s","endedAt":"%s"}\n' \
    "$status" "$ended_at" > "$run_dir/result.json"
  age_directory "$run_dir"
}

write_manifest "stale-owned" "$ABSENT_PID"
write_manifest "live-owned" "$$"
write_manifest "unknown-pid" "$UNKNOWN_PID"
write_manifest "wrong-home" "$ABSENT_PID" "$TEST_ROOT/other-runtime-home"
write_manifest "wrong-run-id" "$ABSENT_PID" "$ARTIFACTS_ROOT/dev-runs/wrong-run-id/runtime-home" "another-run"

mkdir -p "$ARTIFACTS_ROOT/dev-runs/missing-pid/runtime-home"
printf '{"runtimeHomePath":"%s","runID":"missing-pid"}\n' \
  "$ARTIFACTS_ROOT/dev-runs/missing-pid/runtime-home" \
  > "$ARTIFACTS_ROOT/dev-runs/missing-pid/runtime-home/instance.json"
age_directory "$ARTIFACTS_ROOT/dev-runs/missing-pid"

mkdir -p "$ARTIFACTS_ROOT/dev-runs/malformed/runtime-home"
printf '{not-json\n' > "$ARTIFACTS_ROOT/dev-runs/malformed/runtime-home/instance.json"
age_directory "$ARTIFACTS_ROOT/dev-runs/malformed"

mkdir -p "$ARTIFACTS_ROOT/dev-runs/unowned"
age_directory "$ARTIFACTS_ROOT/dev-runs/unowned"

write_manifest "recent-owned" "$ABSENT_PID"
touch "$ARTIFACTS_ROOT/dev-runs/recent-owned/runtime-home/activity.log"

write_manifest "kept-owned" "$ABSENT_PID"
touch "$ARTIFACTS_ROOT/dev-runs/kept-owned/.keep"
age_directory "$ARTIFACTS_ROOT/dev-runs/kept-owned"

write_result "remote-tests" "old-pass" "pass" "2020-01-01T00:00:00Z"
write_result "remote-tests" "old-fail" "fail" "2020-01-01T00:00:00Z"
write_result "remote-tests" "ten-day-pass" "pass" "$TEN_DAYS_AGO"
write_result "remote-tests" "ten-day-fail" "fail" "$TEN_DAYS_AGO"
write_result "remote-tests" "boundary-pass" "pass" "$PASS_CUTOFF"
write_result "remote-tests" "inside-boundary-pass" "pass" "$PASS_INSIDE_CUTOFF"
write_result "remote-tests" "recent-pass" "pass" "2099-01-01T00:00:00Z"
write_result "remote-tests" "recent-files-pass" "pass" "2020-01-01T00:00:00Z"
touch -t "$RECENT_ACTIVITY_TIMESTAMP" "$ARTIFACTS_ROOT/remote-tests/recent-files-pass/activity.log"
write_result "remote-tests" "unknown-status" "cancelled" "2020-01-01T00:00:00Z"
write_result "remote-tests" "invalid-ended-at" "pass" "not-a-timestamp"
write_result "remote-tests" "kept-pass" "pass" "2020-01-01T00:00:00Z"
touch "$ARTIFACTS_ROOT/remote-tests/kept-pass/.keep"
age_directory "$ARTIFACTS_ROOT/remote-tests/kept-pass"
mkdir -p "$ARTIFACTS_ROOT/remote-tests/missing-result"
age_directory "$ARTIFACTS_ROOT/remote-tests/missing-result"
mkdir -p "$ARTIFACTS_ROOT/remote-tests/malformed-result"
printf '{bad\n' > "$ARTIFACTS_ROOT/remote-tests/malformed-result/result.json"
age_directory "$ARTIFACTS_ROOT/remote-tests/malformed-result"
mkdir -p "$TEST_ROOT/outside-symlink-run"
touch "$TEST_ROOT/outside-symlink-run/must-survive"
ln -s "$TEST_ROOT/outside-symlink-run" "$ARTIFACTS_ROOT/remote-tests/symlink-run"

write_result "remote-gui" "old-timeout" "timeout" "2020-01-01T00:00:00Z"

mkdir -p "$ARTIFACTS_ROOT/release/old-release"
age_directory "$ARTIFACTS_ROOT/release/old-release"

dry_run_output="$(run_cleanup --dry-run --category dev-runs)"
if [[ ! -d "$ARTIFACTS_ROOT/dev-runs/stale-owned" ]]; then
  echo "error: the default dry run deleted an eligible directory" >&2
  exit 1
fi

if run_cleanup --dry-run --apply >/dev/null 2>&1; then
  echo "error: --dry-run and --apply should be mutually exclusive" >&2
  exit 1
fi
if ! printf '%s\n' "$dry_run_output" | grep -q 'eligible category=dev-runs .*stale-owned'; then
  echo "error: stale owned dev run was not reported as eligible" >&2
  exit 1
fi
if ! printf '%s\n' "$dry_run_output" | grep -q 'manual_review=6'; then
  echo "error: ambiguous dev runs were not counted for manual review" >&2
  printf '%s\n' "$dry_run_output" >&2
  exit 1
fi

include_unowned_output="$(run_cleanup --category dev-runs --include-unowned)"
if ! printf '%s\n' "$include_unowned_output" | grep -q 'eligible category=dev-runs .*unowned'; then
  echo "error: --include-unowned did not include the old unowned dev run" >&2
  exit 1
fi

run_cleanup --category dev-runs --apply >/dev/null
if [[ -e "$ARTIFACTS_ROOT/dev-runs/stale-owned" ]]; then
  echo "error: stale owned dev run was not deleted" >&2
  exit 1
fi
for protected_run in live-owned unknown-pid wrong-home wrong-run-id missing-pid malformed unowned recent-owned kept-owned; do
  if [[ ! -d "$ARTIFACTS_ROOT/dev-runs/$protected_run" ]]; then
    echo "error: protected dev run was deleted: $protected_run" >&2
    exit 1
  fi
done

run_cleanup --category dev-runs --include-unowned --apply >/dev/null
if [[ -e "$ARTIFACTS_ROOT/dev-runs/unowned" ]]; then
  echo "error: --include-unowned --apply did not delete the old unowned dev run" >&2
  exit 1
fi

remote_output="$(run_cleanup --category remote-tests --apply)"
for deleted_run in old-pass old-fail ten-day-pass boundary-pass; do
  if [[ -e "$ARTIFACTS_ROOT/remote-tests/$deleted_run" ]]; then
    echo "error: eligible remote test was not deleted: $deleted_run" >&2
    exit 1
  fi
done
for protected_run in ten-day-fail inside-boundary-pass recent-pass recent-files-pass unknown-status invalid-ended-at kept-pass missing-result malformed-result symlink-run; do
  if [[ ! -d "$ARTIFACTS_ROOT/remote-tests/$protected_run" ]]; then
    echo "error: protected remote test was deleted: $protected_run" >&2
    exit 1
  fi
done
if ! printf '%s\n' "$remote_output" | grep -q 'manual_review=5'; then
  echo "error: remote test metadata problems were not counted for manual review" >&2
  printf '%s\n' "$remote_output" >&2
  exit 1
fi
if [[ ! -e "$TEST_ROOT/outside-symlink-run/must-survive" ]]; then
  echo "error: cleanup followed a symlinked run directory" >&2
  exit 1
fi

mkdir "$ARTIFACTS_ROOT/.cleanup.lock"
if run_cleanup --category remote-gui --apply >/dev/null 2>&1; then
  echo "error: an existing cleanup lock should block apply mode" >&2
  exit 1
fi
rmdir "$ARTIFACTS_ROOT/.cleanup.lock"

run_cleanup --category remote-gui --apply >/dev/null
if [[ -e "$ARTIFACTS_ROOT/remote-gui/old-timeout" ]]; then
  echo "error: eligible remote GUI run was not deleted" >&2
  exit 1
fi

mkdir -p "$TEST_ROOT/outside-symlink-category"
touch "$TEST_ROOT/outside-symlink-category/must-survive"
rmdir "$ARTIFACTS_ROOT/remote-gui"
ln -s "$TEST_ROOT/outside-symlink-category" "$ARTIFACTS_ROOT/remote-gui"
run_cleanup --category remote-gui --apply >/dev/null 2>&1
if [[ ! -e "$TEST_ROOT/outside-symlink-category/must-survive" ]]; then
  echo "error: cleanup followed a symlinked category" >&2
  exit 1
fi
rm "$ARTIFACTS_ROOT/remote-gui"
mkdir "$ARTIFACTS_ROOT/remote-gui"

run_cleanup --category release --apply >/dev/null
if [[ ! -d "$ARTIFACTS_ROOT/release/old-release" ]]; then
  echo "error: manual-retention release artifact was deleted" >&2
  exit 1
fi

mkdir -p "$ARTIFACTS_ROOT/future-category/old-run"
age_directory "$ARTIFACTS_ROOT/future-category/old-run"
full_output="$(run_cleanup --apply 2>&1)"
if [[ ! -d "$ARTIFACTS_ROOT/future-category/old-run" ]]; then
  echo "error: full cleanup deleted an unconfigured category" >&2
  exit 1
fi
if ! printf '%s\n' "$full_output" | grep -q 'unconfigured artifact category retained'; then
  echo "error: full cleanup did not report the unconfigured category" >&2
  exit 1
fi

INVALID_POLICY="$TEST_ROOT/invalid-policy.json"
printf '{"schemaVersion":1,"categories":{"bad":{"strategy":"future"}}}\n' > "$INVALID_POLICY"
if TOASTTY_ARTIFACT_CLEANUP_TESTING=1 \
  TOASTTY_ARTIFACTS_ROOT="$ARTIFACTS_ROOT" \
  TOASTTY_ARTIFACT_RETENTION_CONFIG="$INVALID_POLICY" \
  TOASTTY_ARTIFACT_CLEANUP_NOW_EPOCH="$NOW_EPOCH" \
    "$SCRIPT" >/dev/null 2>&1; then
  echo "error: an unsupported retention strategy should fail validation" >&2
  exit 1
fi

if TOASTTY_ARTIFACTS_ROOT="$ARTIFACTS_ROOT" "$SCRIPT" >/dev/null 2>&1; then
  echo "error: production mode accepted a test root override" >&2
  exit 1
fi

echo "ok: artifact cleanup self-test passed"
