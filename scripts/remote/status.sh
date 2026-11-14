#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ -n "${TOASTTY_REMOTE_GUI_HOST:-}" ]] || { echo 'error: TOASTTY_REMOTE_GUI_HOST is required; use sv exec' >&2; exit 78; }
remote_repo="${TOASTTY_REMOTE_GUI_REPO_ROOT:-$ROOT_DIR}"
remote_root="${TOASTTY_REMOTE_GUI_ROOT:-$(dirname "$remote_repo")/toastty-remote-gui}"
printf -v remote_command '%q ' /usr/bin/python3 - status --root "$remote_root"
# Runs the current read-only status implementation even on an older remote repo.
ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  "$TOASTTY_REMOTE_GUI_HOST" "$remote_command" <"$ROOT_DIR/scripts/remote/admission.py"
