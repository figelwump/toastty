#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: publish-scratchpad-outline.sh [title] [kind]

Publishes a quick animated rough Scratchpad outline before deeper analysis.
kind may be: generic, architecture, data, flow, ui, timeline
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

title="${1:-Scratchpad Draft}"
kind="${2:-generic}"
case "$kind" in
  generic|architecture|data|flow|ui|timeline)
    ;;
  *)
    echo "error: unknown kind: $kind" >&2
    usage
    exit 64
    ;;
esac

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

python3 - "$title" "$kind" <<'PY' | "$script_dir/publish-scratchpad-html.sh" --title "$title"
import html
import sys

title, kind = sys.argv[1:]
palette = {
    "architecture": ("#60a5fa", "System outline"),
    "data": ("#34d399", "Data view outline"),
    "flow": ("#f59e0b", "Flow outline"),
    "ui": ("#a78bfa", "Wireframe outline"),
    "timeline": ("#f472b6", "Timeline outline"),
    "generic": ("#38bdf8", "Visual outline"),
}
accent, label = palette.get(kind, palette["generic"])

def block(cls="", text=""):
    return f'<div class="block {cls}"><span>{html.escape(text)}</span></div>'

if kind == "data":
    body = """
      <section class="metrics">
        <div class="metric"></div><div class="metric short"></div><div class="metric"></div>
      </section>
      <section class="chart">
        <div class="axis y"></div><div class="axis x"></div>
        <div class="bar b1"></div><div class="bar b2"></div><div class="bar b3"></div><div class="bar b4"></div>
      </section>
      <section class="table"><div></div><div></div><div></div><div></div></section>
    """
elif kind == "ui":
    body = """
      <section class="wire">
        <div class="nav"></div><div class="hero"></div>
        <div class="panel"></div><div class="panel"></div><div class="panel wide"></div>
      </section>
    """
elif kind == "timeline":
    body = """
      <section class="timeline">
        <div></div><div></div><div></div><div></div>
      </section>
    """
else:
    body = f"""
      <section class="map">
        {block("large", "Input")}
        <div class="connector"></div>
        {block("", "Group")}
        <div class="connector"></div>
        {block("large", "Output")}
      </section>
      <section class="grid">
        {block("", "Area")}
        {block("", "Area")}
        {block("", "Area")}
      </section>
    """

print(f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>{html.escape(title)}</title>
  <style>
    :root {{
      color-scheme: dark;
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      --accent: {accent};
      --bg: #0f172a;
      --panel: #1e293b;
      --line: #475569;
      --muted: #94a3b8;
    }}
    body {{ margin: 0; min-height: 100vh; background: var(--bg); color: #f8fafc; }}
    main {{ max-width: 1120px; margin: 0 auto; padding: 28px; }}
    header {{ display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 24px; }}
    h1 {{ margin: 0; font-size: 26px; }}
    .status {{ color: var(--muted); font-size: 13px; }}
    .pulse {{ width: 10px; height: 10px; border-radius: 999px; background: var(--accent); box-shadow: 0 0 0 0 color-mix(in srgb, var(--accent), transparent 35%); animation: pulse 1.4s infinite; }}
    .stage {{ border: 1px solid #334155; border-radius: 10px; padding: 22px; background: linear-gradient(180deg, #172033, #111827); overflow: hidden; }}
    .map {{ display: grid; grid-template-columns: 1fr 50px 1fr 50px 1fr; align-items: center; gap: 12px; margin-bottom: 18px; }}
    .grid, .metrics {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; }}
    .block, .metric, .panel, .hero, .nav, .table div, .timeline div {{
      position: relative; min-height: 82px; border: 1px solid var(--line); border-radius: 8px; background: #1f2937; overflow: hidden;
    }}
    .block.large {{ min-height: 120px; }}
    .block span {{ position: absolute; left: 14px; top: 12px; color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }}
    .connector {{ height: 2px; background: linear-gradient(90deg, transparent, var(--accent), transparent); animation: move 1.8s linear infinite; }}
    .chart {{ position: relative; height: 300px; margin: 18px 0; border: 1px solid var(--line); border-radius: 10px; background: #111827; }}
    .axis {{ position: absolute; background: var(--line); }}
    .axis.x {{ left: 40px; right: 20px; bottom: 34px; height: 1px; }}
    .axis.y {{ left: 40px; top: 24px; bottom: 34px; width: 1px; }}
    .bar {{ position: absolute; bottom: 35px; width: 13%; background: var(--accent); opacity: .45; border-radius: 6px 6px 0 0; animation: rise 1.6s ease-in-out infinite alternate; }}
    .b1 {{ left: 13%; height: 34%; }} .b2 {{ left: 31%; height: 58%; animation-delay: .15s; }} .b3 {{ left: 49%; height: 42%; animation-delay: .3s; }} .b4 {{ left: 67%; height: 70%; animation-delay: .45s; }}
    .table {{ display: grid; gap: 8px; }}
    .table div {{ min-height: 34px; }}
    .wire {{ display: grid; grid-template-columns: 190px 1fr 1fr; gap: 14px; }}
    .nav {{ grid-row: span 3; min-height: 340px; }} .hero {{ grid-column: span 2; min-height: 120px; }} .panel.wide {{ grid-column: span 2; }}
    .timeline {{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 18px; align-items: center; }}
    .timeline div {{ min-height: 170px; }}
    .block::after, .metric::after, .panel::after, .hero::after, .nav::after, .table div::after, .timeline div::after {{
      content: ""; position: absolute; inset: 0; transform: translateX(-100%); background: linear-gradient(90deg, transparent, rgba(255,255,255,.12), transparent); animation: shimmer 1.7s infinite;
    }}
    @keyframes shimmer {{ to {{ transform: translateX(100%); }} }}
    @keyframes move {{ from {{ background-position: -80px 0; }} to {{ background-position: 80px 0; }} }}
    @keyframes pulse {{ 70% {{ box-shadow: 0 0 0 14px transparent; }} 100% {{ box-shadow: 0 0 0 0 transparent; }} }}
    @keyframes rise {{ from {{ transform: scaleY(.86); transform-origin: bottom; }} to {{ transform: scaleY(1); transform-origin: bottom; }} }}
    @media (max-width: 760px) {{ .map, .grid, .metrics, .wire, .timeline {{ grid-template-columns: 1fr; }} .connector {{ height: 28px; width: 2px; justify-self: center; }} .hero, .panel.wide, .nav {{ grid-column: auto; }} }}
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>{html.escape(title)}</h1>
        <div class="status">{html.escape(label)} - rough placeholder before analysis</div>
      </div>
      <div class="pulse" aria-hidden="true"></div>
    </header>
    <section class="stage">
      {body}
    </section>
  </main>
</body>
</html>""")
PY
