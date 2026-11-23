#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT_DIR/scripts/remote/run-support.sh"
source "$ROOT_DIR/scripts/automation/runtime-ownership.sh"

if [[ $# != 3 ]]; then
  echo "Usage: sv exec -- $0 <candidate.dmg> <source-commit> <new-evidence-directory>" >&2
  exit 64
fi

dmg="$1"
commit="$2"
evidence="$3"
[[ -s "$dmg" && "$commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'error: a non-empty candidate DMG and full source commit are required' >&2
  exit 64
}
dmg="$(toastty_canonical_path "$dmg")"
REMOTE_HOST="${TOASTTY_REMOTE_GUI_HOST:?use sv exec to configure the release verification host}"
remote_repo="${TOASTTY_REMOTE_GUI_REPO_ROOT:-$ROOT_DIR}"
remote_root="${TOASTTY_REMOTE_GUI_ROOT:-$(dirname "$remote_repo")/toastty-remote-gui}"
run_label="$(toastty_default_run_label release-first-launch)"
run_root="$remote_root/runs/$run_label"
timeout="${TOASTTY_REMOTE_QUEUE_TIMEOUT_SECONDS:-3600}"
ssh_options=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
driver="$ROOT_DIR/scripts/release/first-launch.py"

remote() {
  local command
  printf -v command '%q ' "$@"
  ssh -T "${ssh_options[@]}" "$REMOTE_HOST" "$command"
}

toastty_allocate_local_artifacts "$evidence"
digest="$(/usr/bin/python3 "$driver" digest "$dmg")"

# Stage just the checker and the finished DMG. Do not forward signing inputs.
remote /bin/mkdir -p "$remote_root/runs"
remote /bin/mkdir -m 700 "$run_root"
echo "[release-first-launch] Remote run: $run_root"
scp "${ssh_options[@]}" "$ROOT_DIR/scripts/remote/admission.py" \
  "$ROOT_DIR/scripts/automation/ax-drive.swift" "$driver" "$REMOTE_HOST:$run_root/"
scp "${ssh_options[@]}" "$dmg" "$REMOTE_HOST:$run_root/candidate.dmg"
remote /bin/mkdir "$run_root/evidence"

status=0
remote /usr/bin/python3 "$run_root/admission.py" run --root "$remote_root" \
  --label "$run_label" --resource compute --timeout "$timeout" \
  --report "$run_root/evidence/admission.json" --release-marker "$run_root/desktop-active" \
  -- /usr/bin/python3 "$run_root/first-launch.py" check "$run_root" "$commit" "$digest" \
  > >(tee "$evidence/remote-stdout.log") 2> >(tee "$evidence/remote-stderr.log" >&2) || status=$?

# Keep the remote run if evidence transfer or cleanup confirmation fails.
scp -r "${ssh_options[@]}" "$REMOTE_HOST:$run_root/evidence" "$evidence/remote"
remote /usr/bin/python3 "$run_root/first-launch.py" cleanup "$run_root"

if [[ "$status" != 0 ]]; then
  echo "error: candidate first launch failed (exit $status). Evidence: $evidence" >&2
  exit "$status"
fi
/usr/bin/python3 "$driver" verify "$dmg" "$commit" "$evidence/remote"
echo "[release-first-launch] Passed: $evidence/remote/result.json"
