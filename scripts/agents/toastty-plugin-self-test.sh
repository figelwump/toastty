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
  # Claude also scans Cursor's documented lower-camel-case hooks file and
  # warns that those event names are not Claude hook events. Non-strict mode
  # still fails on manifest or skill errors while allowing those expected
  # cross-host warnings.
  claude_fixture_root="$(mktemp -d /tmp/toastty-claude-plugin.XXXXXX)"
  cp -R "$ROOT_DIR/plugins/toastty" "$claude_fixture_root/toastty"
  HOME="$isolated_home" CLAUDE_CONFIG_DIR="$isolated_claude_home" \
    claude plugin validate "$claude_fixture_root/toastty" >/dev/null
else
  printf 'warning: claude is unavailable; skipped live Claude plugin validation\n' >&2
fi

fake_cli="$fixture_root/fake-toastty"
cat > "$fake_cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

joined=" $* "
if [[ "$joined" == *" session ingest-agent-event --source cursor-hooks "* ]]; then
  cat > "${TOASTTY_FORWARDER_CAPTURE_PREFIX}.payload"
  printf '%s\n' "$@" > "${TOASTTY_FORWARDER_CAPTURE_PREFIX}.args"
  if [[ "${TOASTTY_FAKE_CLI_FAIL:-}" == "1" ]]; then
    exit 7
  fi
elif [[ "$joined" == *" query run terminal.state "* ]]; then
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

cursor_forwarder="$cache_root/plugins/toastty/hooks/forwarder.sh"
capture_prefix="$fixture_root/cursor-forwarder"
cursor_payload='{"hook_event_name":"beforeSubmitPrompt","conversation_id":"conv-1","generation_id":"gen-1","prompt":"test"}'
forwarder_output="$(
  printf '%s' "$cursor_payload" | \
    TOASTTY_AGENT=cursor \
    TOASTTY_SESSION_ID="session-1" \
    TOASTTY_PANEL_ID="33333333-3333-3333-3333-333333333333" \
    TOASTTY_SOCKET_PATH="$fixture_root/toastty.sock" \
    TOASTTY_CLI_PATH="$fake_cli" \
    TOASTTY_FORWARDER_CAPTURE_PREFIX="$capture_prefix" \
    "$cursor_forwarder" beforeSubmitPrompt
)"
if [[ "$forwarder_output" != '{}' ]]; then
  printf 'error: Cursor forwarder emitted a decision-changing response: %s\n' "$forwarder_output" >&2
  exit 1
fi
if [[ "$(cat "$capture_prefix.payload")" != "$cursor_payload" ]]; then
  printf 'error: Cursor forwarder did not preserve the hook payload\n' >&2
  exit 1
fi
expected_cursor_args="$fixture_root/cursor-forwarder-expected.args"
printf '%s\n' \
  --socket-path "$fixture_root/toastty.sock" \
  session ingest-agent-event \
  --source cursor-hooks \
  --session session-1 \
  --panel 33333333-3333-3333-3333-333333333333 \
  > "$expected_cursor_args"
if ! cmp -s "$expected_cursor_args" "$capture_prefix.args"; then
  printf 'error: Cursor forwarder invoked Toastty with unexpected arguments\n' >&2
  exit 1
fi

rm -f "$capture_prefix.payload" "$capture_prefix.args"
session_payload='{"hook_event_name":"sessionStart","conversation_id":"conv-1","generation_id":"gen-1"}'
session_output="$(
  printf '%s' "$session_payload" | \
    TOASTTY_AGENT=cursor \
    TOASTTY_SESSION_ID="session-1" \
    TOASTTY_PANEL_ID="33333333-3333-3333-3333-333333333333" \
    TOASTTY_SOCKET_PATH="$fixture_root/toastty.sock" \
    TOASTTY_CLI_PATH="$fake_cli" \
    TOASTTY_SKILLS_ROOT="$cache_root/plugins/toastty/skills" \
    TOASTTY_FORWARDER_CAPTURE_PREFIX="$capture_prefix" \
    "$cursor_forwarder" sessionStart
)"
expected_session_output='{"additional_context":"Toastty-managed skills shown in the available skills list are already installed. When using one, copy its supplied fullPath exactly. If reading it fails, resolve the skill through the TOASTTY_SKILLS_ROOT environment variable and retry before reporting that the skill is unavailable."}'
if [[ "$session_output" != "$expected_session_output" ]]; then
  printf 'error: Cursor session-start hook omitted its skill path recovery context: %s\n' "$session_output" >&2
  exit 1
fi
if [[ "$(cat "$capture_prefix.payload")" != "$session_payload" ]]; then
  printf 'error: Cursor session-start hook did not preserve the hook payload\n' >&2
  exit 1
fi

for passive_event in beforeSubmitPrompt preToolUse postToolUseFailure stop sessionEnd; do
  rm -f "$capture_prefix.payload" "$capture_prefix.args"
  passive_payload="{\"hook_event_name\":\"$passive_event\",\"conversation_id\":\"conv-1\",\"generation_id\":\"gen-1\"}"
  passive_output="$(
    printf '%s' "$passive_payload" | \
      TOASTTY_AGENT=cursor \
      TOASTTY_SESSION_ID="session-1" \
      TOASTTY_PANEL_ID="33333333-3333-3333-3333-333333333333" \
      TOASTTY_SOCKET_PATH="$fixture_root/toastty.sock" \
      TOASTTY_CLI_PATH="$fake_cli" \
      TOASTTY_SKILLS_ROOT="$cache_root/plugins/toastty/skills" \
      TOASTTY_FORWARDER_CAPTURE_PREFIX="$capture_prefix" \
      "$cursor_forwarder" "$passive_event"
  )"
  if [[ "$passive_output" != '{}' ]]; then
    printf 'error: Cursor %s hook emitted unexpected context: %s\n' "$passive_event" "$passive_output" >&2
    exit 1
  fi
  if [[ "$(cat "$capture_prefix.payload")" != "$passive_payload" ]]; then
    printf 'error: Cursor %s hook did not preserve the hook payload\n' "$passive_event" >&2
    exit 1
  fi
done

rm -f "$capture_prefix.payload" "$capture_prefix.args"
inert_output="$(
  printf '%s' "$cursor_payload" | \
    TOASTTY_AGENT=claude \
    TOASTTY_SESSION_ID="session-1" \
    TOASTTY_PANEL_ID="33333333-3333-3333-3333-333333333333" \
    TOASTTY_SOCKET_PATH="$fixture_root/toastty.sock" \
    TOASTTY_CLI_PATH="$fake_cli" \
    TOASTTY_SKILLS_ROOT="$cache_root/plugins/toastty/skills" \
    TOASTTY_FORWARDER_CAPTURE_PREFIX="$capture_prefix" \
    "$cursor_forwarder" sessionStart
)"
if [[ "$inert_output" != '{}' ]] || [[ -e "$capture_prefix.payload" ]] || [[ -e "$capture_prefix.args" ]]; then
  printf 'error: Cursor forwarder was not inert outside a managed Cursor session\n' >&2
  exit 1
fi

missing_root_output="$(
  printf '%s' "$session_payload" | \
    env -u TOASTTY_SKILLS_ROOT \
      TOASTTY_AGENT=cursor \
      TOASTTY_SESSION_ID="session-1" \
      TOASTTY_PANEL_ID="33333333-3333-3333-3333-333333333333" \
      TOASTTY_SOCKET_PATH="$fixture_root/toastty.sock" \
      TOASTTY_CLI_PATH="$fake_cli" \
      TOASTTY_FORWARDER_CAPTURE_PREFIX="$capture_prefix" \
      "$cursor_forwarder" sessionStart
)"
if [[ "$missing_root_output" != '{}' ]]; then
  printf 'error: Cursor session-start hook emitted context without a skills root\n' >&2
  exit 1
fi

non_directory_skills_root="$fixture_root/not-a-skills-directory"
printf 'not a directory\n' > "$non_directory_skills_root"
invalid_root_output="$(
  printf '%s' "$session_payload" | \
    TOASTTY_AGENT=cursor \
    TOASTTY_SESSION_ID="session-1" \
    TOASTTY_PANEL_ID="33333333-3333-3333-3333-333333333333" \
    TOASTTY_SOCKET_PATH="$fixture_root/toastty.sock" \
    TOASTTY_CLI_PATH="$fake_cli" \
    TOASTTY_SKILLS_ROOT="$non_directory_skills_root" \
    TOASTTY_FORWARDER_CAPTURE_PREFIX="$capture_prefix" \
    "$cursor_forwarder" sessionStart
)"
if [[ "$invalid_root_output" != '{}' ]]; then
  printf 'error: Cursor session-start hook emitted context for a non-directory skills root\n' >&2
  exit 1
fi

missing_event_output="$(
  printf '%s' "$session_payload" | \
    TOASTTY_AGENT=cursor \
    TOASTTY_SESSION_ID="session-1" \
    TOASTTY_PANEL_ID="33333333-3333-3333-3333-333333333333" \
    TOASTTY_SOCKET_PATH="$fixture_root/toastty.sock" \
    TOASTTY_CLI_PATH="$fake_cli" \
    TOASTTY_SKILLS_ROOT="$cache_root/plugins/toastty/skills" \
    TOASTTY_FORWARDER_CAPTURE_PREFIX="$capture_prefix" \
    "$cursor_forwarder"
)"
if [[ "$missing_event_output" != '{}' ]]; then
  printf 'error: Cursor forwarder emitted context without an event argument\n' >&2
  exit 1
fi

failure_output="$(
  printf '%s' "$cursor_payload" | \
    TOASTTY_AGENT=cursor \
    TOASTTY_SESSION_ID="session-1" \
    TOASTTY_PANEL_ID="33333333-3333-3333-3333-333333333333" \
    TOASTTY_SOCKET_PATH="$fixture_root/toastty.sock" \
    TOASTTY_CLI_PATH="$fake_cli" \
    TOASTTY_FORWARDER_CAPTURE_PREFIX="$capture_prefix" \
    TOASTTY_FAKE_CLI_FAIL=1 \
    "$cursor_forwarder" beforeSubmitPrompt
)"
if [[ "$failure_output" != '{}' ]]; then
  printf 'error: Cursor forwarder did not suppress a Toastty CLI failure\n' >&2
  exit 1
fi

rm -f "$capture_prefix.payload" "$capture_prefix.args"
failure_session_output="$(
  printf '%s' "$session_payload" | \
    TOASTTY_AGENT=cursor \
    TOASTTY_SESSION_ID="session-1" \
    TOASTTY_PANEL_ID="33333333-3333-3333-3333-333333333333" \
    TOASTTY_SOCKET_PATH="$fixture_root/toastty.sock" \
    TOASTTY_CLI_PATH="$fake_cli" \
    TOASTTY_SKILLS_ROOT="$cache_root/plugins/toastty/skills" \
    TOASTTY_FORWARDER_CAPTURE_PREFIX="$capture_prefix" \
    TOASTTY_FAKE_CLI_FAIL=1 \
    "$cursor_forwarder" sessionStart
)"
if [[ "$failure_session_output" != "$expected_session_output" ]]; then
  printf 'error: Cursor session-start hook lost recovery context after a Toastty CLI failure\n' >&2
  exit 1
fi

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

printf 'Toastty three-host plugin copied-cache self-test passed\n'
