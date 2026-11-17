#!/usr/bin/env bash
# Install the Linux build into a throwaway prefix, check the bundled
# resources an install must carry (Toastty agent skills, workflow example
# skills, web panels), then run scripts/linux/e2e-app-logic.sh against the
# installed binaries, so resource lookup goes through the install layout.
#
# Usage: scripts/linux/e2e-install.sh [--release]   (default: the debug build, not rebuilt)
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
configuration=--debug
[[ "${1:-}" == "--release" ]] && configuration=--release
prefix=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/ttinst.XXXX")
trap 'rm -rf "$prefix"' EXIT

"$repo_root/scripts/linux/install.sh" --prefix "$prefix" $configuration --no-build > "$prefix.log" 2>&1 \
  || { cat "$prefix.log"; rm -f "$prefix.log"; exit 1; }
rm -f "$prefix.log"

fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
resources="$prefix/lib/toastty/share/toastty/Resources"
bundle="$resources/ToasttyAgentPluginBundle"
check "install bundles the Codex marketplace manifest" "[ -f '$bundle/.agents/plugins/marketplace.json' ]"
check "install bundles the five shipped Toastty skills" \
  "[ \$(ls '$bundle/plugins/toastty/skills' | grep -c '^toastty-') -eq 5 ] && [ -f '$bundle/plugins/toastty/.claude-plugin/plugin.json' ]"
check "install bundles the workflow example skills" "[ -f '$resources/WorkflowExamples/skills/worktree-create/SKILL.md' ]"
check "install bundles the web panels" "[ -d '$resources/WebPanels' ]"

TOASTTY_LINUX_E2E_BIN="$prefix/lib/toastty/bin" "$repo_root/scripts/linux/e2e-app-logic.sh" || fail=1
exit $fail
