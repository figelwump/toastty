#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT_DIR/scripts/remote/run-support.sh"
source "$ROOT_DIR/scripts/automation/runtime-ownership.sh"

if [[ $# != 4 ]]; then
  cat >&2 <<EOF
Usage: sv exec -- $0 <candidate.dmg> <source-commit> <previous-release-tag> <new-evidence-directory>

Checks the candidate DMG on the Toastty validation Mac as a user meets it:
a clean first launch, then an update over the state of the previous release,
a relaunch with a coordinator and task agents to resume, Restart Coordinator
with a waiting message, and Claude Code's compact offer.

The previous release's DMG comes from its GitHub release. Set
TOASTTY_PREVIOUS_DMG to a local DMG of that release to skip the download.
EOF
  exit 64
fi

dmg="$1"
commit="$2"
previous_tag="$3"
evidence="$4"
[[ -s "$dmg" && "$commit" =~ ^[0-9a-f]{40}$ && -n "$previous_tag" ]] || {
  echo 'error: a non-empty candidate DMG, full source commit and previous release tag are required' >&2
  exit 64
}
dmg="$(toastty_canonical_path "$dmg")"
REMOTE_HOST="${TOASTTY_REMOTE_GUI_HOST:?use sv exec to configure the release verification host}"
remote_repo="${TOASTTY_REMOTE_GUI_REPO_ROOT:-$ROOT_DIR}"
remote_root="${TOASTTY_REMOTE_GUI_ROOT:-$(dirname "$remote_repo")/toastty-remote-gui}"
run_label="$(toastty_default_run_label release-candidate)"
run_root="$remote_root/runs/$run_label"
timeout="${TOASTTY_REMOTE_QUEUE_TIMEOUT_SECONDS:-3600}"
ssh_options=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
driver="$ROOT_DIR/scripts/release/candidate-check.py"

remote() {
  local command
  printf -v command '%q ' "$@"
  ssh -T "${ssh_options[@]}" "$REMOTE_HOST" "$command"
}

toastty_allocate_local_artifacts "$evidence"
evidence="$(toastty_canonical_path "$evidence")"

previous_dmg="${TOASTTY_PREVIOUS_DMG:-}"
if [[ -z "$previous_dmg" ]]; then
  echo "[release-candidate] Downloading the DMG of $previous_tag"
  mkdir "$evidence/previous"
  (cd "$ROOT_DIR" && gh release download "$previous_tag" --pattern 'Toastty-*.dmg' --dir "$evidence/previous")
  previous_dmg="$(find "$evidence/previous" -name 'Toastty-*.dmg' -print -quit)"
fi
[[ -s "$previous_dmg" ]] || { echo "error: no DMG for $previous_tag" >&2; exit 66; }
digest="$(/usr/bin/python3 "$driver" digest "$dmg")"
previous_digest="$(/usr/bin/python3 "$driver" digest "$previous_dmg")"
printf '%s\n' "$previous_tag" >"$evidence/previous-tag.txt"

# Stage the checkers and both finished DMGs. Do not forward signing inputs.
remote /bin/mkdir -p "$remote_root/runs"
remote /bin/mkdir -m 700 "$run_root"
echo "[release-candidate] Remote run: $run_root"
scp "${ssh_options[@]}" "$ROOT_DIR/scripts/remote/admission.py" \
  "$ROOT_DIR/scripts/automation/ax-drive.swift" "$driver" \
  "$ROOT_DIR/scripts/release/candidate-use-check.py" "$REMOTE_HOST:$run_root/"
# The stages reuse the live checks' helpers.
scp -r -q "${ssh_options[@]}" "$ROOT_DIR/scripts/automation" "$REMOTE_HOST:$run_root/automation"
scp "${ssh_options[@]}" "$dmg" "$REMOTE_HOST:$run_root/candidate.dmg"
scp "${ssh_options[@]}" "$previous_dmg" "$REMOTE_HOST:$run_root/previous.dmg"
remote /bin/mkdir "$run_root/evidence"

status=0
remote /usr/bin/python3 "$run_root/admission.py" run --root "$remote_root" \
  --label "$run_label" --resource compute --timeout "$timeout" \
  --report "$run_root/evidence/admission.json" --release-marker "$run_root/desktop-active" \
  -- /usr/bin/python3 "$run_root/candidate-check.py" check "$run_root" "$commit" "$digest" "$previous_digest" \
  > >(tee "$evidence/remote-stdout.log") 2> >(tee "$evidence/remote-stderr.log" >&2) || status=$?

# Keep the remote run if evidence transfer or cleanup confirmation fails.
scp -r "${ssh_options[@]}" "$REMOTE_HOST:$run_root/evidence" "$evidence/remote"
remote /usr/bin/python3 "$run_root/candidate-check.py" cleanup "$run_root"

if [[ "$status" != 0 ]]; then
  echo "error: the candidate check failed (exit $status). Evidence: $evidence" >&2
  exit "$status"
fi
/usr/bin/python3 "$driver" verify "$dmg" "$commit" "$evidence/remote"
echo "[release-candidate] Passed: $evidence/remote/result.json"
