#!/usr/bin/env bash
set -euo pipefail
# Stops one detached remote run on purpose. The run's own cleanup still runs,
# and its evidence stays on the remote host until a rerun of the same command
# reattaches to it or the scheduled cleaner removes it.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ $# -eq 1 && "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || { echo 'usage: scripts/remote/cancel.sh <run-label>' >&2; exit 64; }
[[ -n "${TOASTTY_REMOTE_GUI_HOST:-}" ]] || { echo 'error: TOASTTY_REMOTE_GUI_HOST is required; use sv exec' >&2; exit 78; }
remote_repo="${TOASTTY_REMOTE_GUI_REPO_ROOT:-$ROOT_DIR}"
remote_root="${TOASTTY_REMOTE_GUI_ROOT:-$(dirname "$remote_repo")/toastty-remote-gui}"
printf -v remote_command '%q ' /usr/bin/python3 - cancel --root "$remote_root" --label "$1"
ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  "$TOASTTY_REMOTE_GUI_HOST" "$remote_command" <"$ROOT_DIR/scripts/remote/admission.py"
