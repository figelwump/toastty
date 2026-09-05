#!/bin/sh

hook_event="${1:-}"
managed_cursor=0
if [ "${TOASTTY_AGENT:-}" = "cursor" ] &&
   [ -n "${TOASTTY_SESSION_ID:-}" ] &&
   [ -n "${TOASTTY_PANEL_ID:-}" ] &&
   [ -n "${TOASTTY_SOCKET_PATH:-}" ] &&
   [ -n "${TOASTTY_CLI_PATH:-}" ]; then
  managed_cursor=1
  "$TOASTTY_CLI_PATH" \
    --socket-path "$TOASTTY_SOCKET_PATH" \
    session ingest-agent-event \
    --source cursor-hooks \
    --session "$TOASTTY_SESSION_ID" \
    --panel "$TOASTTY_PANEL_ID" \
    >/dev/null 2>&1 || :
else
  # Drain stdin even while inert so Cursor never waits on an unread hook pipe.
  cat >/dev/null 2>&1 || :
fi

# Cursor already lists plugin skills with their absolute paths. Reinforce that
# contract once per managed session so a failed read prompts path recovery
# instead of a false claim that the skill was not injected.
if [ "$managed_cursor" -eq 1 ] &&
   [ "$hook_event" = "sessionStart" ] &&
   [ -n "${TOASTTY_SKILLS_ROOT:-}" ] &&
   [ -d "$TOASTTY_SKILLS_ROOT" ]; then
  printf '%s\n' '{"additional_context":"Toastty-managed skills shown in the available skills list are already installed. When using one, copy its supplied fullPath exactly. If reading it fails, resolve the skill through the TOASTTY_SKILLS_ROOT environment variable and retry before reporting that the skill is unavailable."}'
else
  # An empty JSON object is valid for every other observed hook and cannot
  # alter Cursor's permission, continuation, or follow-up decisions.
  printf '%s\n' '{}'
fi
exit 0
