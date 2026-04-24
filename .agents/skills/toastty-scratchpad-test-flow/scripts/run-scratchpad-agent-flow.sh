#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: run-scratchpad-agent-flow.sh [title] [message]

Runs two panel.scratchpad.set-content calls through the Toastty CLI using
stdin content for the active TOASTTY_SESSION_ID.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

title="${1:-Scratchpad Agent Flow Test}"
message="${2:-Testing the managed-session Scratchpad path}"

if [[ -z "${TOASTTY_CLI_PATH:-}" ]]; then
  echo "error: TOASTTY_CLI_PATH is required; run this from a Toastty-managed agent session" >&2
  exit 1
fi
if [[ ! -x "${TOASTTY_CLI_PATH}" ]]; then
  echo "error: TOASTTY_CLI_PATH is not executable: ${TOASTTY_CLI_PATH}" >&2
  exit 1
fi
if [[ -z "${TOASTTY_SESSION_ID:-}" ]]; then
  echo "error: TOASTTY_SESSION_ID is required; run this from a Toastty-managed agent session" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

render_fixture() {
  local step="$1"
  python3 - "$step" "$title" "$message" "$TOASTTY_SESSION_ID" <<'PY'
import datetime
import html
import sys

step, title, message, session_id = sys.argv[1:]
stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
accent = "#2563eb" if step == "create" else "#059669"
print(f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>{html.escape(title)}</title>
  <style>
    body {{
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: #111827;
      color: #f9fafb;
      font: 14px -apple-system, BlinkMacSystemFont, sans-serif;
    }}
    main {{
      width: min(680px, calc(100vw - 48px));
      border: 1px solid #374151;
      border-left: 6px solid {accent};
      border-radius: 8px;
      padding: 24px;
      background: #1f2937;
    }}
    h1 {{ margin: 0 0 12px; font-size: 24px; }}
    dl {{ display: grid; grid-template-columns: max-content 1fr; gap: 8px 16px; }}
    dt {{ color: #9ca3af; }}
    dd {{ margin: 0; word-break: break-word; }}
    [data-live] {{ color: #93c5fd; font-weight: 600; }}
  </style>
</head>
<body>
  <main>
    <h1>{html.escape(title)}</h1>
    <p>{html.escape(message)}</p>
    <dl>
      <dt>Step</dt><dd>{html.escape(step)}</dd>
      <dt>Session</dt><dd>{html.escape(session_id)}</dd>
      <dt>Generated</dt><dd>{html.escape(stamp)}</dd>
      <dt>Script</dt><dd data-live>pending</dd>
    </dl>
  </main>
  <script>
    document.querySelector("[data-live]").textContent = "JavaScript executed";
  </script>
</body>
</html>""")
PY
}

set_content() {
  local step="$1"
  render_fixture "$step" \
    | "$TOASTTY_CLI_PATH" --json action run panel.scratchpad.set-content \
        --stdin content \
        "sessionID=$TOASTTY_SESSION_ID" \
        "title=$title"
}

first_response="$(set_content create)"
second_response="$(set_content update)"

python3 - "$first_response" "$second_response" <<'PY'
import json
import sys

def result(raw):
    envelope = json.loads(raw)
    if not envelope.get("ok"):
        error = envelope.get("error") or {}
        raise SystemExit(f"error: request failed: {error.get('code', '<unknown>')}: {error.get('message', '<no message>')}")
    return envelope.get("result") or {}

first = result(sys.argv[1])
second = result(sys.argv[2])

required = ["windowID", "workspaceID", "panelID", "documentID", "revision", "created"]
for key in required:
    if key not in first:
        raise SystemExit(f"error: first response missing {key}")
    if key not in second:
        raise SystemExit(f"error: second response missing {key}")

if first["panelID"] != second["panelID"]:
    raise SystemExit("error: second write created or targeted a different panel")
if first["documentID"] != second["documentID"]:
    raise SystemExit("error: second write targeted a different document")
if first["created"] is not True:
    raise SystemExit("error: first write did not report created=true")
if second["created"] is not False:
    raise SystemExit("error: second write did not report created=false")
if not isinstance(first["revision"], int) or not isinstance(second["revision"], int):
    raise SystemExit("error: revision fields were not integers")
if second["revision"] <= first["revision"]:
    raise SystemExit("error: second write did not advance revision")

print("scratchpad agent flow ok")
print(f"windowID={second['windowID']}")
print(f"workspaceID={second['workspaceID']}")
print(f"panelID={second['panelID']}")
print(f"documentID={second['documentID']}")
print(f"firstRevision={first['revision']}")
print(f"secondRevision={second['revision']}")
print(f"createdFirst={str(first['created']).lower()}")
print(f"createdSecond={str(second['created']).lower()}")
PY
