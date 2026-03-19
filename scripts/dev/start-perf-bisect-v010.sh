#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: start-perf-bisect-v010.sh [target_repo] [bad_ref] [good_ref]

Starts a bisect for the post-v0.1.0 performance regression and pre-skips the
commits classified as docs/release/dev/test-only.

Arguments:
  target_repo  Repo or worktree to bisect. Defaults to the current directory.
  bad_ref      Known-bad ref. Defaults to 0684989d0b7f48654a0ee49886d67157bccd9f67.
  good_ref     Known-good ref. Defaults to v0.1.0.
EOF
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLASSIFICATION_FILE="$ROOT_DIR/docs/plans/perf-bisect-v010-commits.tsv"
TARGET_REPO="${1:-$PWD}"
BAD_REF="${2:-0684989d0b7f48654a0ee49886d67157bccd9f67}"
GOOD_REF="${3:-v0.1.0}"

[[ -f "$CLASSIFICATION_FILE" ]] || fail "classification file not found at $CLASSIFICATION_FILE"
git -C "$TARGET_REPO" rev-parse --show-toplevel >/dev/null 2>&1 || fail "not a git worktree: $TARGET_REPO"

git -C "$TARGET_REPO" rev-parse --verify "${BAD_REF}^{commit}" >/dev/null 2>&1 \
  || fail "bad ref does not resolve to a commit: $BAD_REF"
git -C "$TARGET_REPO" rev-parse --verify "${GOOD_REF}^{commit}" >/dev/null 2>&1 \
  || fail "good ref does not resolve to a commit: $GOOD_REF"
git -C "$TARGET_REPO" merge-base --is-ancestor "$GOOD_REF" "$BAD_REF" >/dev/null 2>&1 \
  || fail "good ref is not an ancestor of bad ref: $GOOD_REF !<= $BAD_REF"

BISECT_LOG_PATH="$(git -C "$TARGET_REPO" rev-parse --git-path BISECT_LOG)"
if [[ -f "$BISECT_LOG_PATH" ]]; then
  fail "git bisect is already in progress in $TARGET_REPO; run 'git -C \"$TARGET_REPO\" bisect reset' first"
fi

if ! git -C "$TARGET_REPO" diff --quiet --ignore-submodules -- \
  || ! git -C "$TARGET_REPO" diff --cached --quiet --ignore-submodules --; then
  fail "target worktree is dirty: $TARGET_REPO"
fi

SKIP_COMMITS=()
while IFS=$'\t' read -r SHA ACTION REASON SUBJECT; do
  if [[ "$SHA" == "sha" ]]; then
    continue
  fi

  [[ -n "$SHA" && -n "$ACTION" && -n "$REASON" && -n "$SUBJECT" ]] \
    || fail "malformed classification row in $CLASSIFICATION_FILE"

  case "$ACTION" in
    skip)
      SKIP_COMMITS+=("$SHA")
      ;;
    test)
      ;;
    *)
      fail "unknown classification action '$ACTION' in $CLASSIFICATION_FILE"
      ;;
  esac
done < "$CLASSIFICATION_FILE"
[[ "${#SKIP_COMMITS[@]}" -gt 0 ]] || fail "no skip commits found in $CLASSIFICATION_FILE"

git -C "$TARGET_REPO" bisect start "$BAD_REF" "$GOOD_REF"
git -C "$TARGET_REPO" bisect skip "${SKIP_COMMITS[@]}"

CURRENT_SHORT_SHA="$(git -C "$TARGET_REPO" rev-parse --short HEAD)"
CURRENT_SUBJECT="$(git -C "$TARGET_REPO" show -s --format=%s HEAD)"

cat <<EOF
Bisect ready.

Target repo: $TARGET_REPO
Good ref:    $GOOD_REF
Bad ref:     $BAD_REF
Pre-skipped: ${#SKIP_COMMITS[@]} commits

Current checkout:
  $CURRENT_SHORT_SHA $CURRENT_SUBJECT

Next commands:
  git -C "$TARGET_REPO" bisect good
  git -C "$TARGET_REPO" bisect bad
  git -C "$TARGET_REPO" bisect skip
  git -C "$TARGET_REPO" bisect reset
EOF
