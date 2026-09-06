#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: create-worktree.sh --slug <slug> [--repo-root <path>] [--base-ref <ref>] [--branch-prefix <prefix>] [--parent-dir <dir>] [--json]

Creates a sibling git worktree for the current repository.
EOF
}

slug=""
repo_root=""
base_ref="HEAD"
branch_prefix="worktree"
parent_dir=""
json_output=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)
      slug="${2:-}"
      shift 2
      ;;
    --repo-root)
      repo_root="${2:-}"
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

if [[ -z "$repo_root" ]]; then
  if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "error: run inside a git worktree or pass --repo-root" >&2
    exit 1
  fi
else
  if ! repo_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "error: --repo-root is not inside a git worktree: $repo_root" >&2
    exit 1
  fi
fi

repo_root="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$repo_root")"
if [[ -z "$parent_dir" ]]; then
  parent_dir="$(dirname "$repo_root")"
else
  parent_dir="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$parent_dir")"
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

repo_name="$(basename "$repo_root")"
worktree_name="${repo_name}-${normalized_slug}"
worktree_path="${parent_dir}/${worktree_name}"
handoff_path="${worktree_path}/WORKTREE_HANDOFF.md"
branch_name="${branch_prefix}/${normalized_slug}"
created_worktree=0

cleanup_on_error() {
  local exit_code=$?
  if [[ "$created_worktree" == "1" ]]; then
    git -C "$repo_root" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    git -C "$repo_root" branch -D "$branch_name" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}

trap cleanup_on_error ERR

if [[ -e "$worktree_path" ]]; then
  echo "error: worktree path already exists: $worktree_path" >&2
  exit 1
fi

if git -C "$repo_root" show-ref --verify --quiet "refs/heads/${branch_name}"; then
  echo "error: branch already exists: $branch_name" >&2
  exit 1
fi

git -C "$repo_root" rev-parse --verify "$base_ref" >/dev/null 2>&1 || {
  echo "error: base ref does not exist: $base_ref" >&2
  exit 1
}

git -C "$repo_root" worktree add --quiet -b "$branch_name" "$worktree_path" "$base_ref" >/dev/null
created_worktree=1
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
