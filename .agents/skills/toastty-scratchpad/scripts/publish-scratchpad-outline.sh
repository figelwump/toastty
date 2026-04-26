#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: publish-scratchpad-outline.sh [title]

Publishes a minimal animated loading screen before deeper analysis.
The loading screen contains only the title and an animated indicator —
it deliberately does not pre-mock the final artifact's structure.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

title="${1:-Scratchpad Draft}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$title" <<'PY' | "$script_dir/publish-scratchpad-html.sh" --title "$title"
import html
import sys

title = sys.argv[1]

print(f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>{html.escape(title)}</title>
  <style>
    :root {{
      color-scheme: dark;
      font-family: -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", sans-serif;
    }}
    html, body {{ height: 100%; margin: 0; }}
    body {{
      background: radial-gradient(ellipse at 50% 30%, #1f2937 0%, #0b1220 70%);
      color: #e5e7eb;
      display: grid;
      place-items: center;
      padding: 24px;
      box-sizing: border-box;
    }}
    main {{
      text-align: center;
      max-width: 720px;
    }}
    h1 {{
      margin: 0 0 18px;
      font-size: clamp(20px, 4vw, 30px);
      font-weight: 600;
      letter-spacing: -0.01em;
      color: #f8fafc;
    }}
    .status {{
      color: #94a3b8;
      font-size: 13px;
      letter-spacing: .08em;
      text-transform: uppercase;
      margin-bottom: 26px;
    }}
    .dots {{
      display: inline-flex;
      gap: 10px;
      align-items: center;
    }}
    .dot {{
      width: 9px;
      height: 9px;
      border-radius: 999px;
      background: #38bdf8;
      opacity: .35;
      animation: bob 1.2s ease-in-out infinite;
    }}
    .dot:nth-child(2) {{ animation-delay: .15s; }}
    .dot:nth-child(3) {{ animation-delay: .30s; }}
    @keyframes bob {{
      0%, 100% {{ opacity: .35; transform: translateY(0); }}
      50%      {{ opacity: 1;   transform: translateY(-4px); }}
    }}
  </style>
</head>
<body>
  <main>
    <h1>{html.escape(title)}</h1>
    <div class="status">Preparing visual</div>
    <div class="dots" aria-hidden="true">
      <span class="dot"></span>
      <span class="dot"></span>
      <span class="dot"></span>
    </div>
  </main>
</body>
</html>""")
PY
