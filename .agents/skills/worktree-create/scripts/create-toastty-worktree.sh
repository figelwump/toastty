#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf 'warning: create-toastty-worktree.sh is deprecated; use create-worktree.sh. It now targets the current git repo or --repo-root and does not run Toastty bootstrap automatically.\n' >&2
exec "$SCRIPT_DIR/create-worktree.sh" "$@"
