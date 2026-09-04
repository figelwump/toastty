#!/bin/sh

if [ "${TOASTTY_AGENT:-}" = "cursor" ] &&
   [ -n "${TOASTTY_SESSION_ID:-}" ] &&
   [ -n "${TOASTTY_PANEL_ID:-}" ] &&
   [ -n "${TOASTTY_SOCKET_PATH:-}" ] &&
   [ -n "${TOASTTY_CLI_PATH:-}" ]; then
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

# An empty JSON object is valid for each observed hook and cannot alter
# Cursor's permission, continuation, or follow-up decisions.
printf '{}\n'
exit 0
