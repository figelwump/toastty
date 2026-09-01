#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
VALIDATOR="$ROOT_DIR/scripts/agents/validate-toastty-plugin.py"

"$VALIDATOR" --repo-root "$ROOT_DIR"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/toastty-plugin-cache.XXXXXX")"
claude_fixture_root=""
cleanup() {
  rm -rf "$fixture_root"
  if [[ -n "$claude_fixture_root" ]]; then
    rm -rf "$claude_fixture_root"
  fi
}
trap cleanup EXIT

cache_root="$fixture_root/-Cache Copy Δ quote' dollar\$ star* back\\slash"
mkdir -p "$cache_root/.agents/plugins" "$cache_root/plugins"
cp "$ROOT_DIR/.agents/plugins/marketplace.json" "$cache_root/.agents/plugins/marketplace.json"
cp -R "$ROOT_DIR/plugins/toastty" "$cache_root/plugins/toastty"

"$VALIDATOR" --repo-root "$ROOT_DIR" --marketplace-root "$cache_root"

isolated_home="$fixture_root/home"
isolated_codex_home="$fixture_root/codex-home"
isolated_claude_home="$fixture_root/claude-home"
mkdir -p "$isolated_home" "$isolated_codex_home" "$isolated_claude_home"

if command -v codex >/dev/null 2>&1; then
  marketplace_result="$(
    HOME="$isolated_home" CODEX_HOME="$isolated_codex_home" \
      codex plugin marketplace add "$cache_root" --json
  )"
  if [[ "$marketplace_result" != *'"marketplaceName": "toastty"'* ]]; then
    printf 'error: Codex did not register the copied Toastty marketplace\n%s\n' "$marketplace_result" >&2
    exit 1
  fi
  HOME="$isolated_home" CODEX_HOME="$isolated_codex_home" \
    codex plugin add toastty@toastty --json >/dev/null
else
  printf 'warning: codex is unavailable; skipped live marketplace acceptance check\n' >&2
fi

if command -v claude >/dev/null 2>&1; then
  # Claude Code 2.1.251 misclassifies skill directories as symlinks when an
  # ancestor contains a backslash. Recheck this isolation on CLI upgrades;
  # the hostile path remains covered above by Toastty and Codex validation.
  claude_fixture_root="$(mktemp -d /tmp/toastty-claude-plugin.XXXXXX)"
  cp -R "$ROOT_DIR/plugins/toastty" "$claude_fixture_root/toastty"
  HOME="$isolated_home" CLAUDE_CONFIG_DIR="$isolated_claude_home" \
    claude plugin validate --strict "$claude_fixture_root/toastty" >/dev/null
else
  printf 'warning: claude is unavailable; skipped live Claude plugin validation\n' >&2
fi

fake_cli="$fixture_root/fake-toastty"
cat > "$fake_cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

joined=" $* "
if [[ "$joined" == *" query run terminal.state "* ]]; then
  printf '%s\n' '{"ok":true,"result":{"workspaceID":"11111111-1111-1111-1111-111111111111"}}'
elif [[ "$joined" == *" action run panel.create.local-document "* ]]; then
  printf '%s\n' '{"ok":true,"result":{}}'
elif [[ "$joined" == *" action run panel.scratchpad.set-content "* ]]; then
  cat >/dev/null
  printf '%s\n' '{"ok":true,"result":{"windowID":"22222222-2222-2222-2222-222222222222","workspaceID":"11111111-1111-1111-1111-111111111111","panelID":"33333333-3333-3333-3333-333333333333","documentID":"44444444-4444-4444-4444-444444444444","revision":1,"created":true}}'
else
  printf 'error: unexpected fake Toastty invocation: %s\n' "$*" >&2
  exit 1
fi
EOF
chmod +x "$fake_cli"

export TOASTTY_SKILLS_ROOT="$cache_root/plugins/toastty/skills"
export TOASTTY_CLI_PATH="$fake_cli"
export TOASTTY_PANEL_ID="33333333-3333-3333-3333-333333333333"
export TOASTTY_SESSION_ID="55555555-5555-5555-5555-555555555555"

markdown_file="$fixture_root/Review Δ.md"
printf '# Review\n' > "$markdown_file"
"$TOASTTY_SKILLS_ROOT/toastty-open-markdown/scripts/open-markdown-file.sh" "$markdown_file" >/dev/null
"$TOASTTY_SKILLS_ROOT/toastty-scratchpad/scripts/publish-scratchpad-outline.sh" "Cache Test" >/dev/null

"$TOASTTY_SKILLS_ROOT/worktree-create/scripts/create-worktree.sh" --help >/dev/null 2>&1
"$TOASTTY_SKILLS_ROOT/worktree-create/scripts/create-toastty-worktree.sh" --help >/dev/null 2>&1
"$TOASTTY_SKILLS_ROOT/worktree-create/scripts/open-toastty-worktree-session.sh" --help >/dev/null 2>&1

printf 'Toastty dual-host plugin copied-cache self-test passed\n'
