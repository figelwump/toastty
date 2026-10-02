#!/usr/bin/env bash
# Captures real Toastty screenshots for the README from a made-up "lumen" demo.
#
# It launches an isolated Debug build (its own runtime home, home folder for both
# the shell and Foundation, temporary directory, socket, settings, and Ghostty
# config), builds the demo through the toastty CLI, and captures the window with
# `screencapture -l`, which does not focus or click anything. Sessions are fake: each pane prints a canned transcript and then
# sleeps, and the CLI reports names and statuses for it. Nothing touches your
# normal Toastty data.
#
# Requirements: macOS with a GUI session, Screen Recording permission for the
# terminal running this script, and a Ghostty-enabled Debug build (run
# ./scripts/dev/bootstrap-worktree.sh first, or pass --build).
#
# Usage: scripts/website/capture-demo-screenshots.sh [--build] [--app PATH] [--out DIR] [--keep]
#   --build   build the Debug app into artifacts/website-capture/Derived first
#   --app     Toastty.app to launch (default: that Derived build)
#   --out     new or empty output directory (default: artifacts/website-capture/run-<timestamp>)
#   --keep    leave the demo app running after capturing
#
# Writes window.png (the full window), sidebar.png (the sidebar down to the last
# workspace card), right-panel.png (the right panel's top), and social-crop.txt
# (the sidebar.png region for render-hero-video.mjs --social-crop) to --out.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED="$ROOT/artifacts/website-capture/Derived"
APP="$DERIVED/Build/Products/Debug/Toastty.app"
OUT="$ROOT/artifacts/website-capture/run-$(date +%Y%m%d-%H%M%S)"
BUILD=0
KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=1 ;;
    --app) APP="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --keep) KEEP=1 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# Absolute paths: the app is launched from the demo home, and the runtime home's
# path also names its settings domain.
abspath() { python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"; }
OUT="$(abspath "$OUT")"
APP="$(abspath "$APP")"
if [[ -e "$OUT" && -n "$(ls -A "$OUT")" ]]; then
  echo "$OUT is not empty; pass a new --out directory" >&2
  exit 2
fi
mkdir -p "$OUT"

if [[ "$BUILD" == 1 ]]; then
  mkdir -p "$ROOT/artifacts/website-capture"
  xcodebuild -workspace "$ROOT/toastty.xcworkspace" -scheme ToasttyApp -configuration Debug \
    -destination "platform=macOS,arch=arm64" -derivedDataPath "$DERIVED" build >"$ROOT/artifacts/website-capture/build.log"
fi
[[ -x "$APP/Contents/MacOS/Toastty" ]] || { echo "Toastty.app not found at $APP (pass --build or --app)" >&2; exit 1; }
CLI="$APP/Contents/Helpers/toastty"

DEMO_HOME="$OUT/home"
RUNTIME="$OUT/runtime"
DEMO="$DEMO_HOME/.demo"
mkdir -p "$DEMO" "$RUNTIME" "$DEMO_HOME/.config/ghostty"
for repo in lumen lumen-checkout-redesign lumen-search-filters lumen-sidebar-icons docs-site infra; do
  mkdir -p "$DEMO_HOME/code/$repo"
done

# ---------------------------------------------------------------- demo files

cat >"$DEMO_HOME/.config/ghostty/config" <<'EOF'
font-size = 13
background = #141416
foreground = #d9d5cd
window-padding-x = 14
window-padding-y = 10
EOF
# The login shell keeps HOME at the real home but honors ZDOTDIR.
cat >"$DEMO_HOME/.zshrc" <<'EOF'
PROMPT='%F{244}%1~%f %F{214}❯%f '
EOF

# transcript NAME TITLE: writes $DEMO/NAME.txt from stdin, which uses \e escapes,
# preceded by an OSC 2 sequence so the pane title reads TITLE.
transcript() {
  { printf '\033]2;%s\007' "$2"; printf '%b' "$(cat)"; } >"$DEMO/$1.txt"
}
B='\e[1m'; D='\e[2m'; Y='\e[33m'; G='\e[32m'; R='\e[31m'; X='\e[0m'

transcript plan "Claude Code" <<EOF
${B}●${X} Published Scratchpad ${Y}"Checkout mockup"${X} (rev 3).
  ${D}Summary card moves above payment; totals stay${X}
  ${D}pinned while scrolling on mobile.${X}

${B}●${X} Plan agreed. Ready to build when you are.

${D}› hand this off to a worktree and verify it visually${X}

${B}●${X} ${B}Skill${X}(worktree-create)
  ${D}⎿ Wrote WORKTREE_HANDOFF.md${X}
  ${D}⎿ Created worktree on ${X}${Y}feat/checkout-redesign${X}
  ${D}⎿ Forked this session into a new subspace${X}
  ${D}⎿ Copied the checkout mockup to its right panel${X}

${B}●${X} Handed off. The subspace owns the build and the PR.

EOF
transcript tests "Claude Code" <<EOF
${B}●${X} ${B}Bash${X}(npm test -- auth)
  ${D}⎿${X} ${R}FAIL${X} src/auth/expiry.test.ts
     token expiry › refreshes 30s before expiry
     Expected ${G}"refreshed"${X}, received ${R}"expired"${X}

${B}●${X} The refresh timer reads the server clock, which drifts
  from the client. Switching it to the token's ${Y}exp${X} claim.

${B}●${X} ${B}Edit${X} src/auth/refresh.ts ${G}+7${X} ${R}−4${X}
${B}●${X} ${B}Bash${X}(npm test -- auth --runInBand)
EOF
transcript redesign "Claude Code" <<EOF
${B}●${X} ${B}Read${X} WORKTREE_HANDOFF.md
  ${D}⎿ Goal, 4 decisions, 3 checks, mockup rev 3${X}

${B}●${X} ${B}Edit${X} src/checkout/SummaryCard.tsx ${G}+86${X} ${R}−41${X}
${B}●${X} ${B}Edit${X} src/checkout/CheckoutPage.tsx ${G}+12${X} ${R}−30${X}

${B}●${X} ${B}Bash${X}(npm test)
  ${D}⎿${X} ${G}✓ 214 passing${X} ${D}(38s)${X}

${B}●${X} Published verification report: ${G}3/3 checks passed${X}
${B}●${X} Opened PR ${Y}#128${X} feat/checkout-redesign → main
${B}●${X} Ready for your review.

EOF
transcript filters "Claude Code" <<EOF
${B}●${X} ${B}Edit${X} src/search/FilterBar.tsx ${G}+52${X} ${R}−9${X}
${B}●${X} ${B}Bash${X}(npm test -- search)
EOF
transcript icons "Claude Code" <<EOF
${B}●${X} Merged PR ${Y}#121${X}. Nothing left to do here.

EOF
transcript docs "Codex" <<EOF
${B}●${X} ${B}Bash${X}(npm run dev)
  ${D}⎿ Docs preview at localhost:3000${X}

${B}●${X} The reference pages build cleanly. Three endpoints
  still describe the v1 webhook payload. Want me to update them?

EOF
transcript infra "Claude Code" <<EOF
${B}●${X} ${B}Bash${X}(terraform plan -out staging.plan)
  ${D}⎿ Plan: 2 to add, 1 to change, 0 to destroy.${X}

${B}●${X} Applying will rotate the staging API keys.
  ${Y}Allow terraform apply staging.plan?${X}

EOF

cat >"$DEMO/WORKTREE_HANDOFF.md" <<'EOF'
# Checkout redesign: handoff

`feat/checkout-redesign` · base `main` · draft PR

## Goal

Move the order summary above payment and keep totals visible on small screens, matching mockup rev 3.

## Decisions

- Summary card is a sticky header on mobile only
- Keep the existing Pay button and payment form
- No new dependencies

## Checks

- [x] Summary above payment at 390px
- [x] Totals pinned while scrolling
- [x] `npm test` passes
EOF

cat >"$DEMO/checkout-mockup.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;background:#fbf7ef;color:#2a241b;font:14px/1.5 -apple-system,system-ui,sans-serif;padding:24px}
h1{font-size:20px;margin:0 0 4px}.m{color:#8a7f6f;font-size:12px;margin-bottom:18px}
.row{display:flex;gap:18px;align-items:flex-start}.phone{width:170px;border:6px solid #1c1c1f;border-radius:22px;background:#fff;padding:12px 10px}
.desk{flex:1;border:1px solid #d8cdb9;border-radius:8px;background:#fff;padding:12px}
.sum{border:1px dashed #d8cdb9;border-radius:8px;padding:8px;margin-bottom:10px;background:#fdfaf4;font-size:11px}
.sum div{display:flex;justify-content:space-between}.sum b{font-size:12.5px}
.it{display:flex;gap:8px;align-items:center;margin-bottom:8px}.it i{width:24px;height:24px;border-radius:5px;background:#eadfcb}.it span{height:7px;border-radius:4px;background:#e6ded0;flex:1}
.pay{background:#c9b79b;color:#fff;text-align:center;border-radius:6px;padding:7px 0;font-weight:700;font-size:12px}
ol{color:#5d5346;font-size:13px;padding-left:20px;margin-top:18px}
</style></head><body>
<h1>Checkout mockup</h1><div class="m">rev 3 · mobile and desktop</div>
<div class="row"><div class="phone"><div class="sum"><div><span>Subtotal</span><span>$76.00</span></div><div><span>Shipping</span><span>$8.00</span></div><div><b>Total</b><b>$84.00</b></div></div>
<div class="it"><i></i><span></span></div><div class="it"><i></i><span></span></div><div class="it"><i></i><span></span></div><div class="pay">Pay</div></div>
<div class="desk"><div class="it"><i></i><span></span></div><div class="it"><i></i><span></span></div><div class="sum"><div><span>Subtotal</span><span>$76</span></div><div><b>Total</b><b>$84</b></div></div><div class="pay">Pay</div></div></div>
<ol><li>Summary card first on mobile</li><li>Totals stay pinned while scrolling</li><li>One primary action</li></ol>
</body></html>
EOF

# ---------------------------------------------------------------- launch

# Toastty keeps a runtime-isolated instance's settings in a defaults domain
# named for an FNV-1a hash of its runtime home (ToasttyRuntimePaths). Marking an
# agent as launched before startup gives the sidebar its full 280pt width.
# CFFIXED_USER_HOME points Foundation's home directory, and with it every
# ~/.toastty or ~/.codex path the app resolves, at the demo home. Preferences
# still go through the user's cfprefsd, so this run-specific domain is written
# there and deleted on exit.
DEFAULTS_SUITE="$(python3 -c "
import sys
h = 0xcbf29ce484222325
for b in sys.argv[1].encode():
    h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
print('com.GiantThings.toastty.runtime.%016x' % h)" "$RUNTIME")"
defaults write "$DEFAULTS_SUITE" toastty.hasEverLaunchedAgent -bool true

# A private, short temporary directory: the app writes its socket and the shared
# socket discovery record (toastty-<uid>/current-socket.json) under TMPDIR, so
# the user's TMPDIR would redirect their CLI to the demo. Unix socket paths are
# limited to 104 bytes, which rules out a directory inside --out.
DEMO_TMP="$(mktemp -d /tmp/toastty-demo.XXXXXX)"

APP_PID=""
cleanup() {
  if [[ "$KEEP" == 0 ]]; then
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
      kill "$APP_PID" 2>/dev/null || true
      wait "$APP_PID" 2>/dev/null || true
    fi
    rm -rf "$DEMO_TMP"
    defaults delete "$DEFAULTS_SUITE" >/dev/null 2>&1 || true
    # cfprefsd leaves an empty plist behind after the domain is deleted.
    rm -f "$HOME/Library/Preferences/$DEFAULTS_SUITE.plist"
  fi
}
trap cleanup EXIT

# env -i keeps this instance from inheriting TOASTTY_* variables and attaching
# to the Toastty that may be running this script. exec makes $! the app itself.
(cd "$DEMO_HOME" && exec env -i HOME="$DEMO_HOME" CFFIXED_USER_HOME="$DEMO_HOME" ZDOTDIR="$DEMO_HOME" \
  USER="$USER" LOGNAME="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/zsh TMPDIR="$DEMO_TMP/" \
  LANG=en_US.UTF-8 TOASTTY_RUNTIME_HOME="$RUNTIME" \
  TOASTTY_GHOSTTY_CONFIG_PATH="$DEMO_HOME/.config/ghostty/config" \
  "$APP/Contents/MacOS/Toastty" </dev/null >"$OUT/app.log" 2>&1) &
APP_PID=$!

json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
for _ in $(seq 1 60); do
  [[ -f "$RUNTIME/instance.json" ]] && [[ "$(json "d['pid']" <"$RUNTIME/instance.json")" == "$APP_PID" ]] && break
  kill -0 "$APP_PID" 2>/dev/null || { echo "demo app exited during startup; see $OUT/app.log" >&2; exit 1; }
  sleep 0.5
done
[[ "$(json "d['pid']" <"$RUNTIME/instance.json" 2>/dev/null)" == "$APP_PID" ]] \
  || { echo "demo app did not report pid $APP_PID in instance.json" >&2; exit 1; }
SOCK="$(json "d['socketPath']" <"$RUNTIME/instance.json")"
[[ "$SOCK" == "$DEMO_TMP"* ]] || { echo "unexpected socket path $SOCK" >&2; exit 1; }
for _ in $(seq 1 60); do [[ -S "$SOCK" ]] && break; sleep 0.5; done
lsof -a -p "$APP_PID" -U 2>/dev/null | grep -qF "$SOCK" || { echo "socket $SOCK is not owned by pid $APP_PID" >&2; exit 1; }

# AS_SESSION, when set, makes the call on behalf of that fake session.
t() {
  env -i HOME="$DEMO_HOME" CFFIXED_USER_HOME="$DEMO_HOME" TMPDIR="$DEMO_TMP/" PATH=/usr/bin:/bin \
    ${AS_SESSION:+TOASTTY_SESSION_ID=$AS_SESSION} \
    "$CLI" --socket-path "$SOCK" --json "$@"
}
# ok: fail loudly when a CLI response is not ok.
ok() {
  local out
  # The CLI exits nonzero on errors; keep its JSON so the error is reported.
  out="$(t "$@")" || true
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('ok', True) else 1)" "$out" \
    || { echo "toastty $* failed: $out" >&2; exit 1; }
  printf '%s' "$out"
}
snapshot() { ok query run workspace.snapshot --workspace "$1"; }
focused_panel() { snapshot "$1" | json "d['result']['focusedPanelID']"; }

# run_in WORKSPACE PANEL TRANSCRIPT DIR: shows a transcript in a pane and keeps
# its shell busy so the fake session is not ended for sitting at a prompt. A new
# pane's terminal surface takes a moment to start, so send-text is retried
# until the surface accepts input.
run_in() {
  local panel="$2" out
  for _ in $(seq 1 60); do
    out="$(t action run terminal.send-text --panel "$panel" \
      text="cd $(printf %q "$DEMO_HOME/code/$4") && clear && cat $(printf %q "$DEMO/$3.txt") && sleep 86400" \
      submit=true)" || true
    grep -q '"ok" : true' <<<"$out" && return 0
    sleep 0.5
  done
  echo "pane $panel never accepted input: $out" >&2
  exit 1
}

# session PANEL ID NAME DIR [AGENT]: starts a fake session and names it through
# a Claude-style transcript title record, the same source Toastty reads for a
# real Claude Code session.
session() {
  local panel="$1" id="$2" name="$3" dir="$4" agent="${5:-claude}"
  local native
  native="$(uuidgen | tr 'A-Z' 'a-z')"
  printf '{"type":"ai-title","aiTitle":"%s","sessionId":"%s"}\n' "$name" "$native" >"$DEMO/$id.jsonl"
  ok session start --agent claude --panel "$panel" --session "$id" --cwd "$DEMO_HOME/code/$dir" >/dev/null
  printf '{"hook_event_name":"SessionStart","session_id":"%s","transcript_path":"%s","cwd":"%s","source":"startup"}' \
    "$native" "$DEMO/$id.jsonl" "$DEMO_HOME/code/$dir" \
    | t session ingest-agent-event --source claude-hooks --session "$id" --panel "$panel" >/dev/null
  ok session status --session "$id" --panel "$panel" --kind working --summary "Thinking" >/dev/null
}
# status ID PANEL KIND TEXT: session rows show the detail line; subspace rows
# fall back to the summary, so both carry the same text.
status() { ok session status --session "$1" --panel "$2" --kind "$3" --summary "$4" --detail "$4" >/dev/null; }

# ---------------------------------------------------------------- demo state

WIN="$(ok query run workspace.list | json "d['result']['workspaces'][0]['windowID']")"
LUMEN="$(ok query run workspace.list | json "d['result']['workspaces'][0]['workspaceID']")"
ok action run workspace.rename --workspace "$LUMEN" title=lumen >/dev/null
ok action run workspace.set-annotation --workspace "$LUMEN" key=git-branch text=main >/dev/null

PLAN_PANEL="$(focused_panel "$LUMEN")"
run_in "$LUMEN" "$PLAN_PANEL" plan lumen
session "$PLAN_PANEL" demo-plan "Plan checkout redesign" lumen
ok action run workspace.split.down --workspace "$LUMEN" >/dev/null
TESTS_PANEL="$(focused_panel "$LUMEN")"
run_in "$LUMEN" "$TESTS_PANEL" tests lumen
session "$TESTS_PANEL" demo-tests "Fix flaky auth test" lumen
ok action run panel.scratchpad.set-content sessionID=demo-plan title="Checkout mockup" \
  filePath="$DEMO/checkout-mockup.html" >/dev/null

# new_workspace TITLE [PARENT]: prints the new workspace ID. A parent makes it a
# subspace, with demo-plan recorded as the session that spawned it. Without one,
# the call is not made as a session, which would also nest it.
new_workspace() {
  local args=(action run workspace.create --window "$WIN" title="$1" activate=false)
  if [[ -n "${2:-}" ]]; then
    AS_SESSION=demo-plan ok "${args[@]}" parent="$2" | json "d['result']['workspaceID']"
  else
    ok "${args[@]}" | json "d['result']['workspaceID']"
  fi
}

REDESIGN="$(new_workspace checkout-redesign "$LUMEN")"
P="$(focused_panel "$REDESIGN")"; run_in "$REDESIGN" "$P" redesign lumen-checkout-redesign
session "$P" demo-redesign "Redesign checkout summary" lumen-checkout-redesign
ok action run workspace.set-annotation --workspace "$REDESIGN" key=github-pr text="PR #128" \
  url=https://github.com/lumen-app/lumen/pull/128 primary=true >/dev/null
ok action run panel.create.local-document --workspace "$REDESIGN" \
  filePath="$DEMO/WORKTREE_HANDOFF.md" placement=rightPanel >/dev/null
REDESIGN_PANEL="$P"

FILTERS="$(new_workspace search-filters "$LUMEN")"
P="$(focused_panel "$FILTERS")"; run_in "$FILTERS" "$P" filters lumen-search-filters
session "$P" demo-filters "Add search filters" lumen-search-filters
status demo-filters "$P" working "Editing FilterBar.tsx"

ICONS="$(new_workspace sidebar-icons "$LUMEN")"
P="$(focused_panel "$ICONS")"; run_in "$ICONS" "$P" icons lumen-sidebar-icons
session "$P" demo-icons "Refresh sidebar icons" lumen-sidebar-icons
ok action run workspace.set-annotation --workspace "$ICONS" key=github-pr text="PR #121" \
  url=https://github.com/lumen-app/lumen/pull/121 primary=true >/dev/null
status demo-icons "$P" idle "Merged"
ok action run workspace.set-done --workspace "$ICONS" >/dev/null

DOCS="$(new_workspace docs-site)"
P="$(focused_panel "$DOCS")"; run_in "$DOCS" "$P" docs docs-site
session "$P" demo-docs "Update API reference" docs-site
DOCS_PANEL="$P"

INFRA="$(new_workspace infra)"
P="$(focused_panel "$INFRA")"; run_in "$INFRA" "$P" infra infra
session "$P" demo-infra "Rotate staging keys" infra
status demo-infra "$P" needs_approval "Allow terraform apply staging.plan?"

status demo-tests "$TESTS_PANEL" working "Running auth tests…"
status demo-plan "$PLAN_PANEL" idle "Handed off to checkout-redesign"
# Visiting the background workspaces clears their "New" badges; the subspace
# with the ready result is left unvisited so its row stays unread.
for ws in "$DOCS" "$INFRA" "$LUMEN"; do
  ok action run workspace.select --workspace "$ws" >/dev/null
  sleep 0.5
done
# Results that arrive while lumen is selected stay unread, so their rows are tinted.
status demo-redesign "$REDESIGN_PANEL" ready "Ready for review"
status demo-docs "$DOCS_PANEL" ready "Three endpoints still use the v1 payload. Update them?"
ok action run workspace.focus-panel --workspace "$LUMEN" panelID="$PLAN_PANEL" >/dev/null

# ---------------------------------------------------------------- capture

sleep 3
WINDOW_ID="$(swift - "$APP_PID" <<'EOF'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let windows = list.filter { ($0["kCGWindowOwnerPID"] as? Int) == pid && ($0["kCGWindowLayer"] as? Int) == 0 }
print(windows.first?["kCGWindowNumber"] as? Int ?? 0)
EOF
)"
[[ "$WINDOW_ID" != 0 ]] || { echo "no on-screen window for pid $APP_PID" >&2; exit 1; }
screencapture -x -o -l "$WINDOW_ID" "$OUT/window.png"

# Crops. The sidebar is 280pt wide (WindowState.defaultSidebarWidthAfterAgentLaunch)
# and the demo's last workspace card ends above 560pt. The right panel's left
# edge is found as the last 1pt divider line (#292929) across a row of pixels,
# ignoring the window's border.
swift - "$OUT" <<'EOF'
import AppKit
let out = CommandLine.arguments[1]
let rep = NSImage(contentsOfFile: out + "/window.png")!.representations.first as! NSBitmapImageRep
let scale = rep.pixelsWide / 1280 > 1 ? 2 : 1
func save(_ name: String, _ rect: CGRect) {
  let cg = rep.cgImage!.cropping(to: rect)!
  try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: out + "/" + name))
}
func isDivider(_ x: Int, _ y: Int) -> Bool {
  let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
  return [c.redComponent, c.greenComponent, c.blueComponent].allSatisfy { abs($0 * 255 - 41) < 4 }
}
let row = rep.pixelsHigh * 3 / 4
var dividers: [Int] = []
for x in 1..<rep.pixelsWide - 1 where isDivider(x, row) && !isDivider(x - 1, row) { dividers.append(x) }
// The window's own border shares the divider color, so skip the outer edges.
guard let rightPanelX = dividers.last(where: { $0 > 300 * scale && $0 < rep.pixelsWide - 40 * scale }) else {
  fatalError("right panel divider not found")
}
save("sidebar.png", CGRect(x: 0, y: 0, width: 280 * scale, height: 560 * scale))
let panelLeft = rightPanelX + scale
save("right-panel.png", CGRect(x: panelLeft, y: 0, width: rep.pixelsWide - panelLeft - scale, height: 560 * scale))
// The social card's close-up: the lumen card down to the ready subspace row.
try! "0,0,\(280 * scale),\(262 * scale)\n".write(toFile: out + "/social-crop.txt", atomically: true, encoding: .utf8)
EOF
echo "wrote window.png, sidebar.png, right-panel.png, and social-crop.txt to $OUT"
