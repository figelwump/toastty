#!/usr/bin/env bash
# Full local gate for the Linux port; scripts/automation/check.sh runs this
# on Linux. Same shape as the macOS gate: platform-neutral self-tests and web
# panel tests, Ghostty-backed build, smoke runs, then the test suites. GUI
# steps run on private Broadway displays; nothing appears on the desktop.
#
# Usage: scripts/linux/check.sh
#
# Exit codes match the macOS gate: 10 for a failed check, 11 for failing
# test suites.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

log() { printf '[check] %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 10; }

for command_name in jq node npm nc uuidgen gtk4-broadwayd; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

step() {
  local label="$1"
  shift
  log "$label"
  "$@" || fail "$label failed"
}

run_web_panel_tests() {
  local package_dir
  for package_dir in "$ROOT_DIR/WebPanels/LocalDocumentApp" "$ROOT_DIR/WebPanels/ScratchpadApp"; do
    log "Installing and testing $(basename "$package_dir")"
    (cd "$package_dir" && npm ci --no-audit --no-fund && npm test) || return 1
  done
}

# Platform-neutral checks shared with the macOS gate. The remote-* self-tests
# cover the macOS remote validation wrappers and stay in that gate.
step "Runtime ownership self-test" scripts/automation/runtime-ownership-self-test.sh
step "Artifact cleanup self-test" scripts/automation/cleanup-artifacts-self-test.sh
step "Tailscale Serve auth probe self-test" scripts/automation/tailscale-serve-auth-probe-self-test.sh
step "Agent plugin self-test" scripts/agents/toastty-plugin-self-test.sh
step "Computer Use protocol tests" node --test Tests/RemoteScripts/ComputerUseProtocolTests.mjs
step "Remote web client tests" node --test Tests/RemoteWebClient/RemoteWebClientReconnectTests.mjs
step "Web panel tests" run_web_panel_tests

# The gate is Ghostty-backed, as on macOS.
[[ -d "$ROOT_DIR/linux/.deps/ghostty/lib" ]] \
  || fail "libghostty is missing; run linux/ghostty/build-libghostty.sh first"
step "Ghostty widget test" linux/ghostty/test/run-tests.sh --no-build

step "Debug build" scripts/linux/build.sh --product toastty-linux --product toastty --product toastty-agent-shim
step "Release build" scripts/linux/build.sh --release --product toastty-linux --product toastty --product toastty-agent-shim

# Smoke runs use the shared smoke scripts on Broadway.
step "Workspace tabs smoke" scripts/automation/workspace-tabs-smoke.sh
step "UI smoke" scripts/automation/smoke-ui.sh
# The release install layout (bundled CLI, shim, skills, web panels) and the
# app-logic end-to-end run against it.
step "Release install end-to-end" scripts/linux/e2e-install.sh --release

log "Test suites"
scripts/linux/test.sh || exit 11
log "Linux gate passed"
