#!/usr/bin/env bash
set -euo pipefail
# Stops one detached remote run on purpose. The run's own cleanup still runs.
# A run that never left the queue has no evidence: its remote worktree and run
# folder are removed. A run that had started keeps its evidence on the remote
# host for inspection. The same command run again starts a new run.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT_DIR/scripts/remote/run-support.sh"
[[ $# -eq 1 && "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || { echo 'usage: scripts/remote/cancel.sh <run-label>' >&2; exit 64; }
[[ -n "${TOASTTY_REMOTE_GUI_HOST:-}" ]] || { echo 'error: TOASTTY_REMOTE_GUI_HOST is required; use sv exec' >&2; exit 78; }
remote_repo="${TOASTTY_REMOTE_GUI_REPO_ROOT:-$ROOT_DIR}"
remote_root="${TOASTTY_REMOTE_GUI_ROOT:-$(dirname "$remote_repo")/toastty-remote-gui}"
ssh_options=(-T -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
printf -v remote_command '%q ' /usr/bin/python3 - cancel --root "$remote_root" --label "$1"
ssh "${ssh_options[@]}" "$TOASTTY_REMOTE_GUI_HOST" "$remote_command" <"$ROOT_DIR/scripts/remote/admission.py"
ssh "${ssh_options[@]}" "$TOASTTY_REMOTE_GUI_HOST" /bin/bash -l -s -- "$remote_repo" "$remote_root" "$1" <<EOF
set -euo pipefail
$(declare -f toastty_remove_remote_run)
repo="\$1" root="\$2" label="\$3"
for parent in test-runs runs; do
  run_root="\$root/\$parent/\$label"
  [[ -f "\$run_root/detached.json" ]] || continue
  for _ in \$(seq 1 120); do
    [[ ! -e "\$run_root/detached-exit.json" ]] || break
    sleep 1
  done
  if [[ ! -e "\$run_root/detached-exit.json" ]]; then
    printf '[cancel] %s has not ended yet; its folders stay: %s\n' "\$label" "\$run_root" >&2
    exit 1
  fi
  if [[ -f "\$run_root/admission.json" ]] && ! jq -e 'has("startedAt")' "\$run_root/admission.json" >/dev/null; then
    toastty_remove_remote_run "\$repo" "\$root/worktrees/\$label" "\$run_root"
    printf '[cancel] %s never started; removed its remote folders\n' "\$label"
  else
    printf '[cancel] %s had started; its evidence stays: %s\n' "\$label" "\$run_root"
  fi
done
EOF
