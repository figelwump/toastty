#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

usage() {
  cat >&2 <<'EOF'
usage: create-toastty-worktree.sh --slug <slug> [--base-ref <ref>] [--branch-prefix <prefix>] [--parent-dir <dir>] [--json]

Creates a sibling git worktree and bootstraps it for local Toastty development.
EOF
}

slug=""
base_ref="HEAD"
branch_prefix="codex"
parent_dir="$(dirname "$ROOT_DIR")"
json_output=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)
      slug="${2:-}"
      shift 2
      ;;
    --base-ref)
      base_ref="${2:-}"
      shift 2
      ;;
    --branch-prefix)
      branch_prefix="${2:-}"
      shift 2
      ;;
    --parent-dir)
      parent_dir="${2:-}"
      shift 2
      ;;
    --json)
      json_output=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if [[ -z "$slug" ]]; then
  echo "error: --slug is required" >&2
  usage
  exit 64
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

sanitize_slug() {
  python3 - "$1" <<'PY'
import re
import sys

value = sys.argv[1].strip().lower()
value = re.sub(r"[^a-z0-9]+", "-", value)
value = re.sub(r"-+", "-", value).strip("-")
print(value)
PY
}

emit_json() {
  python3 - "$@" <<'PY'
import json
import sys

keys = [
    "slug",
    "branch_name",
    "worktree_name",
    "worktree_path",
    "handoff_path",
    "base_ref",
]
values = dict(zip(keys, sys.argv[1:]))
print(json.dumps(values, indent=2, sort_keys=True))
PY
}

normalized_slug="$(sanitize_slug "$slug")"
if [[ -z "$normalized_slug" ]]; then
  echo "error: slug became empty after normalization" >&2
  exit 1
fi

repo_name="$(basename "$ROOT_DIR")"
worktree_name="${repo_name}-${normalized_slug}"
worktree_path="${parent_dir}/${worktree_name}"
handoff_path="${worktree_path}/WORKTREE_HANDOFF.md"
branch_name="${branch_prefix}/${normalized_slug}"
created_worktree=0
bootstrap_log=""

cleanup_on_error() {
  local exit_code=$?
  if [[ "$created_worktree" == "1" ]]; then
    git -C "$ROOT_DIR" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    git -C "$ROOT_DIR" branch -D "$branch_name" >/dev/null 2>&1 || true
  fi
  if [[ -n "$bootstrap_log" && -f "$bootstrap_log" ]]; then
    rm -f "$bootstrap_log"
  fi
  exit "$exit_code"
}

trap cleanup_on_error ERR

if [[ -e "$worktree_path" ]]; then
  echo "error: worktree path already exists: $worktree_path" >&2
  exit 1
fi

if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/${branch_name}"; then
  echo "error: branch already exists: $branch_name" >&2
  exit 1
fi

git -C "$ROOT_DIR" rev-parse --verify "$base_ref" >/dev/null 2>&1 || {
  echo "error: base ref does not exist: $base_ref" >&2
  exit 1
}

git -C "$ROOT_DIR" worktree add -b "$branch_name" "$worktree_path" "$base_ref" >/dev/null
created_worktree=1
bootstrap_log="$(mktemp "${TMPDIR:-/tmp}/toastty-worktree-bootstrap.XXXXXX.log")"
if ! "$worktree_path/scripts/dev/bootstrap-worktree.sh" >"$bootstrap_log" 2>&1; then
  echo "error: bootstrap-worktree.sh failed for $worktree_path" >&2
  cat "$bootstrap_log" >&2 || true
  exit 1
fi
rm -f "$bootstrap_log"
bootstrap_log=""
trap - ERR

if [[ "$json_output" == "1" ]]; then
  emit_json \
    "$normalized_slug" \
    "$branch_name" \
    "$worktree_name" \
    "$worktree_path" \
    "$handoff_path" \
    "$base_ref"
else
  cat <<EOF
slug=$normalized_slug
branch_name=$branch_name
worktree_name=$worktree_name
worktree_path=$worktree_path
handoff_path=$handoff_path
base_ref=$base_ref
EOF
fi
