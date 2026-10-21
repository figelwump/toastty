#!/usr/bin/env bash
# Run the Linux test suites (shared Tests/ mirrors + linux/Tests) with an
# isolated home, XDG directories, and TMPDIR.
#
# Usage: scripts/linux/test.sh [--shared-only|--app-logic] [FILTER] [-- extra swift test args]
#
#   --shared-only  test only the shared-core subset of linux/Package.swift
#                  (CoreStateTests, ToasttyCLITests, CodexReconciliationTests)
#   --app-logic    shared-core plus the app-logic block (adds ToasttyAppLogicTests);
#                  builds without the GTK targets
#   FILTER   optional `swift test --filter` pattern, e.g. CoreStateTests,
#            ToasttyCLITests.AgentEventParsersTests, RemotePreview
#
# Isolation: tests never see the operator's ~/.toastty, XDG dirs, Toastty
# session variables, or ~/.local/bin and ~/bin (installed agent CLIs). Without a
# FILTER each test target runs in its own isolation directory. TMPDIR is kept
# outside any git checkout and away from /tmp (RepositoryRootLocator tests
# require a temp dir with no enclosing repository) and short enough for 108-byte AF_UNIX socket paths. Linux
# Foundation's NSHomeDirectory() ignores $HOME, so CFFIXED_USER_HOME is set.
# Set TOASTTY_LINUX_TEST_KEEP=1 to keep the isolation directory afterwards.
# umask is 022 like macOS: Toastty's ownership checks reject group-writable
# directories, and Ubuntu's default user umask (002) would trip them in tests.
# Swift Testing runs serially (--no-parallel): the App-layer suites share
# process-wide state (UserDefaults, environment, NotificationCenter, platform
# services) and a parallel ToasttyAppLogicTests run races and can stall.
# TOASTTY_LINUX_TEST_PARALLEL=1 restores swift test's default.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$repo_root/linux/env.sh"

shared_only=0
app_logic=0
filter=()
extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; extra=("$@"); break ;;
    --shared-only) shared_only=1 ;;
    --app-logic) app_logic=1 ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) filter=(--filter "$1") ;;
  esac
  shift
done

base="${XDG_RUNTIME_DIR:-}"
if [[ -z "$base" || ! -d "$base" || ! -w "$base" ]]; then
  base="${XDG_CACHE_HOME:-$HOME/.cache}"
fi
mkdir -p "$base"

python3 "$repo_root/scripts/linux/sync-shared-sources.py"
package_dir="$repo_root/linux"
if [[ "$shared_only" == "1" ]]; then
  package_dir="$(python3 "$repo_root/scripts/linux/shared-only-package.py")"
elif [[ "$app_logic" == "1" ]]; then
  package_dir="$(python3 "$repo_root/scripts/linux/shared-only-package.py" --with-app-logic)"
fi
# Build with the operator's environment (SwiftPM caches live under $HOME);
# only the test processes run isolated.
(cd "$package_dir" && swift build --build-tests)

# Without a FILTER every test target runs on its own (one test runner holds
# all targets, so one home would let app runs from the UI suites leave agent
# state behind for ToasttyAppLogicTests).
runs=()
if [[ ${#filter[@]} -gt 0 ]]; then
  runs=("${filter[1]}")
else
  while IFS= read -r target; do runs+=("^${target}\\."); done < <(
    cd "$package_dir" && swift package dump-package |
      python3 -c 'import json,sys; [print(t["name"]) for t in json.load(sys.stdin)["targets"] if t["type"] == "test"]'
  )
fi

# Drop session state inherited from a Toastty terminal or agent.
while IFS='=' read -r name _; do
  case "$name" in TOASTTY_*|CODEX_*|CLAUDE*) unset "$name" ;; esac
done < <(env)

# Agent CLIs the operator installed (codex, claude in ~/.local/bin) change
# what the launch tests plan (e.g. Codex skills provisioning), so the test
# processes do not see the operator's per-user bin directories.
test_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF -e "$HOME/.local/bin" -e "$HOME/bin" | paste -sd: -)"

parallel=(--no-parallel)
[[ "${TOASTTY_LINUX_TEST_PARALLEL:-0}" == "1" ]] && parallel=()
umask 022
cd "$package_dir"
isolations=()
cleanup() { [[ "${TOASTTY_LINUX_TEST_KEEP:-0}" == "1" ]] || rm -rf "${isolations[@]}"; }
trap cleanup EXIT
status=0
for run_filter in "${runs[@]}"; do
  isolation="$(mktemp -d "$base/toastty-tests.XXXXXX")"
  isolations+=("$isolation")
  [[ "${TOASTTY_LINUX_TEST_KEEP:-0}" == "1" ]] && echo "test.sh: isolation directory kept at $isolation" >&2
  mkdir -p "$isolation/tmp" "$isolation/home" "$isolation/run"
  chmod 700 "$isolation/run"
  (
    export TMPDIR="$isolation/tmp/"
    export HOME="$isolation/home"
    export CFFIXED_USER_HOME="$isolation/home"
    export XDG_RUNTIME_DIR="$isolation/run"
    export XDG_CONFIG_HOME="$isolation/home/.config"
    export XDG_DATA_HOME="$isolation/home/.local/share"
    export XDG_STATE_HOME="$isolation/home/.local/state"
    export XDG_CACHE_HOME="$isolation/home/.cache"
    export PATH="$test_path"
    swift test --skip-build "${parallel[@]}" --filter "$run_filter" "${extra[@]}"
  ) || status=$?
done
exit "$status"
