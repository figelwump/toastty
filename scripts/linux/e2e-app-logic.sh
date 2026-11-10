#!/usr/bin/env bash
# End-to-end check of toastty-linux with the app-logic layer on a private
# GDK Broadway display (never the live session):
#   1. the automation socket + `toastty` CLI create a workspace;
#   2. terminal.send-text / terminal.visible-text round-trip through Ghostty;
#   3. agent.launch runs a fake managed agent whose
#      `toastty session ingest-agent-event` hook makes its session "working"
#      (read back with automation.dump_state in automation mode);
#   4. the workspace layout persists across a SIGTERM quit and restart;
#   5. automation.capture_screenshot writes a PNG of the window;
#   6. the `scratchpad.create` window command (scripted UI run) reaches
#      LinuxAppLogic.performAppCommand and opens a Scratchpad panel;
#   7. the Remote Access dialog pairs against a fake Tailscale Serve;
#   8. window size and sidebar / right panel widths persist across restart;
#   9. agent profiles: header buttons, palette entries, Ctrl+Alt+key, launch.
# Build first: scripts/linux/build.sh --product toastty-linux --product toastty
# Usage: scripts/linux/e2e-app-logic.sh   (exit status 0 when every check passes)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# TOASTTY_LINUX_E2E_BIN runs the checks against another build, e.g. an
# install (scripts/linux/e2e-install.sh).
B=${TOASTTY_LINUX_E2E_BIN:-$REPO/linux/.build/debug}
[ -x $B/toastty-linux ] || B=$(dirname $(find $REPO/linux/.build -name toastty-linux -type f -perm -u+x | head -1))
APP=$B/toastty-linux; CLI=$B/toastty
WORK=$(mktemp -d "${XDG_RUNTIME_DIR}/tte2e.XXXX")
HOMEDIR=$WORK/home; RT=$WORK/rt; mkdir -p $HOMEDIR/.toastty $RT; chmod 700 $RT
SOCK=$WORK/s.sock
DISPLAYNUM=$((70 + RANDOM % 20))
cat > $WORK/fake-agent.sh <<'AGENT'
#!/bin/bash
# A fake managed agent: report a submitted prompt through the Toastty hook CLI, then idle.
echo "fake agent session=$TOASTTY_SESSION_ID panel=$TOASTTY_PANEL_ID"
# What an agent's `toastty setup guide` sees through the launch environment.
"$TOASTTY_CLI_PATH" setup guide --topic workflows --format md > "$(dirname "$0")/workflows.md" 2>&1
printf '{"hook_event_name":"UserPromptSubmit","prompt":"e2e prompt","session_id":"native-e2e"}' \
  | "$TOASTTY_CLI_PATH" session ingest-agent-event --source claude-hooks > "$(dirname "$0")/ingest.log" 2>&1
echo "fake agent reported working rc=$?"
sleep 600
AGENT
chmod +x $WORK/fake-agent.sh
cat > $HOMEDIR/.toastty/agents.toml <<TOML
[claude]
displayName = "Fake Claude"
argv = ["$WORK/fake-agent.sh"]
TOML
envs=(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=$HOMEDIR CFFIXED_USER_HOME=$HOMEDIR
  XDG_RUNTIME_DIR=$RT XDG_CONFIG_HOME=$HOMEDIR/.config XDG_STATE_HOME=$HOMEDIR/.local/state
  XDG_DATA_HOME=$HOMEDIR/.local/share XDG_CACHE_HOME=$HOMEDIR/.cache SHELL=/bin/bash TERM=xterm-256color
  LANG=C.UTF-8 GDK_BACKEND=broadway BROADWAY_DISPLAY=:$DISPLAYNUM GTK_A11Y=none NO_AT_BRIDGE=1
  GDK_DEBUG=no-portals GSETTINGS_BACKEND=memory TOASTTY_LINUX_NON_UNIQUE=1 TOASTTY_SOCKET_PATH=$SOCK
  LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-})
"${envs[@]}" gtk4-broadwayd :$DISPLAYNUM > $WORK/broadwayd.log 2>&1 &
BPID=$!; sleep 0.5
start_app() { "${envs[@]}" $APP > $WORK/app-$1.log 2>&1 & APID=$!; for i in $(seq 1 100); do [ -S $SOCK ] && $CLI --socket-path $SOCK query list >/dev/null 2>&1 && return 0; sleep 0.1; done; echo "app did not start"; return 1; }
cli() { "${envs[@]}" $CLI --json --socket-path $SOCK "$@"; }
fail=0; check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
start_app 1 || { tail -30 $WORK/app-1.log; exit 1; }
WS=$(cli query run workspace.list); WIN=$(echo "$WS" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result",d); print(r["windows"][0]["id"] if "windows" in r else r["workspaces"][0]["windowID"])' 2>/dev/null)
echo "window=$WIN"
cli action run workspace.create --window "$WIN" title=E2E-Workspace > $WORK/create.json; check "CLI creates a workspace" "cli query run workspace.list | grep -q E2E-Workspace"
WSID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["workspaceID"])' $WORK/create.json)
cli query run terminal.state --workspace "$WSID" > $WORK/tstate.json
PANEL=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["result"]; print(r.get("panelID") or r.get("panel",{}).get("id",""))' $WORK/tstate.json)
echo "panel=$PANEL"
sleep 2
TOKEN="e2e-token-$RANDOM"
cli action run terminal.send-text --panel "$PANEL" text="echo $TOKEN" submit=true > $WORK/send.json
for i in $(seq 1 50); do cli query run terminal.visible-text --panel "$PANEL" > $WORK/visible.json; grep -q "$TOKEN" $WORK/visible.json && [ $(grep -o "$TOKEN" $WORK/visible.json | wc -l) -ge 2 ] && break; sleep 0.2; done
check "terminal send-text/visible-text round-trip through Ghostty" "[ \$(grep -o $TOKEN $WORK/visible.json | wc -l) -ge 2 ]"
cli action run agent.launch --panel "$PANEL" profileID=claude > $WORK/launch.json
sleep 3
cli query run terminal.visible-text --panel "$PANEL" > $WORK/visible2.json
check "fake agent ran in the terminal" "grep -q 'fake agent reported working' $WORK/visible2.json"
# Quit cleanly (SIGTERM → GApplication quit path) and restart; persistence must restore the workspace.
kill -TERM $APID; for i in $(seq 1 50); do kill -0 $APID 2>/dev/null || break; sleep 0.1; done; kill -9 $APID 2>/dev/null
rm -f $SOCK
start_app 2 || { tail -30 $WORK/app-2.log; exit 1; }
check "workspace persists across restart" "cli query run workspace.list | grep -q E2E-Workspace"
kill -TERM $APID; sleep 1; kill -9 $APID 2>/dev/null; { kill -9 $BPID; wait $BPID; } 2>/dev/null
# Phase B: automation mode (dump_state with the session registry) to read the
# session status the sidebar renders.
SOCK=$WORK/b.sock; envs+=(TOASTTY_AUTOMATION=1 TOASTTY_ARTIFACTS_DIR=$WORK/artifacts TOASTTY_SOCKET_PATH=$SOCK TOASTTY_RUN_ID=e2e)
"${envs[@]}" gtk4-broadwayd :$DISPLAYNUM > $WORK/broadwayd2.log 2>&1 & BPID=$!; sleep 0.5
start_app 3 || { tail -30 $WORK/app-3.log; exit 1; }
WIN=$(cli query run workspace.list | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["workspaces"][0]["windowID"])')
WSID=$(cli action run workspace.create --window "$WIN" title=Agent-E2E | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["workspaceID"])')
PANEL=$(cli query run terminal.state --workspace "$WSID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["panelID"])')
sleep 2
cli action run agent.launch --panel "$PANEL" profileID=claude > $WORK/launch2.json
for i in $(seq 1 50); do python3 "$(dirname "$0")/socket-request.py" $SOCK automation.dump_state '{"includeRuntime": true}' > $WORK/dump.json; P=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["path"])' $WORK/dump.json 2>/dev/null); [ -n "$P" ] && python3 -c 'import json,sys; s=json.dumps(json.load(open(sys.argv[1]))["sessionRegistry"]); sys.exit(0 if "working" in s else 1)' "$P" && break; sleep 0.2; done
check "managed agent + session ingest-agent-event sets its session to working" "python3 -c 'import json,sys; s=json.dumps(json.load(open(sys.argv[1]))[\"sessionRegistry\"]); sys.exit(0 if \"working\" in s else 1)' \"$P\""
# The Claude launch staged the shipped Toastty skills from this build's
# bundle (the checkout's plugins/toastty, or an install's copy of it).
STAGED=$(find $WORK -path '*/claude/*/toastty/skills/toastty-read-terminal/SKILL.md' 2>/dev/null | head -1)
check "Claude launch stages the five shipped Toastty skills" "[ -n \"$STAGED\" ] && [ \$(ls \"\$(dirname \"\$(dirname \"$STAGED\")\")\" | grep -c '^toastty-') -eq 5 ] && grep -q 'Alt+Shift+3 on Linux' \"$STAGED\""
EXAMPLES=$(grep -m1 -o '/[^ `]*WorkflowExamples/skills\|/[^ `]*examples/skills' $WORK/workflows.md 2>/dev/null)
check "setup guide --topic workflows points agents at the workflow example skills" "[ -n \"$EXAMPLES\" ] && [ -f \"$EXAMPLES/worktree-create/SKILL.md\" ]"
python3 "$(dirname "$0")/socket-request.py" $SOCK automation.capture_screenshot '{"step": "e2e"}' > $WORK/shot.json
SHOT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["path"])' $WORK/shot.json 2>/dev/null)
check "automation.capture_screenshot writes a PNG of the window" "[ -s \"$SHOT\" ] && head -c 8 \"$SHOT\" | grep -q PNG"
kill -TERM $APID; sleep 1; kill -9 $APID 2>/dev/null; { kill -9 $BPID; wait $BPID; } 2>/dev/null
# Phase C: a scripted UI session. The `scratchpad.create` window action goes
# GAction -> AppLogicStoreBinding -> LinuxAppLogic.performAppCommand.
cat > $WORK/scratchpad.script <<'SCRIPT'
wait 600
action scratchpad.create
wait 600
web-wait ready
expect webKind=scratchpad rightPanelTabs=1
quit
SCRIPT
"${envs[@]}" gtk4-broadwayd :$DISPLAYNUM > $WORK/broadwayd3.log 2>&1 & BPID=$!; sleep 0.5
"${envs[@]}" TOASTTY_LINUX_SMOKE_SCRIPT=$WORK/scratchpad.script TOASTTY_SOCKET_PATH=$WORK/c.sock timeout 120 $APP > $WORK/app-4.log 2>&1
check "scratchpad.create through the GTK command handler opens a Scratchpad panel" "[ $? -eq 0 ]"
{ kill -9 $BPID; wait $BPID; } 2>/dev/null
# Phase D: Remote Access pairing UI against a fake Tailscale Serve on a
# loopback port (never the real tailnet): enable, issue a pairing offer, and
# the dialog's QR code and fallback code exist.
cat > $WORK/remote.script <<SCRIPT
wait 600
action app.remote-access.open
wait 400
remote-access enable
remote-access pair
wait 800
expect remoteAccess=ready remotePairing=true remoteQRCode=true
screenshot $WORK/artifacts/remote-pairing.png
quit
SCRIPT
RPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
"${envs[@]}" gtk4-broadwayd :$DISPLAYNUM > $WORK/broadwayd4.log 2>&1 & BPID=$!; sleep 0.5
"${envs[@]}" TOASTTY_LINUX_SMOKE_SCRIPT=$WORK/remote.script TOASTTY_SOCKET_PATH=$WORK/d.sock \
  TOASTTY_LINUX_FAKE_TAILNET_ORIGIN=https://toastty-e2e.example.ts.net TOASTTY_LINUX_FAKE_TAILNET_PORT=$RPORT \
  timeout 120 $APP > $WORK/app-5.log 2>&1
check "Remote Access dialog pairs against a fake Tailscale Serve (QR + fallback code)" "[ $? -eq 0 ]"
{ kill -9 $BPID; wait $BPID; } 2>/dev/null
# Phase E: window size, sidebar width and right panel width persist across a
# restart (persistence on: TOASTTY_AUTOMATION=0 with a fixed runtime home).
# sidebar-width/right-panel-width take the resize handles' path.
cat > $WORK/size1.script <<'SCRIPT'
wait 600
resize 1000 700
wait 800
sidebar-width 260
action window.toggle-right-panel
wait 300
right-panel-width 300
wait 400
expect windowFrame=1000x700 sidebarWidth=260 rightPanelWidth=300
quit
SCRIPT
cat > $WORK/size2.script <<'SCRIPT'
wait 800
expect windowFrame=1000x700 sidebarWidth=260 rightPanelWidth=300
quit
SCRIPT
mkdir -p $WORK/size-home
"${envs[@]}" gtk4-broadwayd :$DISPLAYNUM > $WORK/broadwayd5.log 2>&1 & BPID=$!; sleep 0.5
size_ok=0
for n in 1 2; do
  "${envs[@]}" TOASTTY_AUTOMATION=0 TOASTTY_RUNTIME_HOME=$WORK/size-home TOASTTY_LINUX_SMOKE_SCRIPT=$WORK/size$n.script \
    TOASTTY_SOCKET_PATH=$WORK/e.sock timeout 60 $APP > $WORK/app-size$n.log 2>&1 || size_ok=1
done
check "window size, sidebar width and right panel width persist across restart" "[ $size_ok -eq 0 ]"
{ kill -9 $BPID; wait $BPID; } 2>/dev/null
# Phase F: agent launching from the UI. agents.toml (written above) has one
# profile with shortcutKey "c": its header button, its "Run Agent" palette
# entry with Ctrl+Alt+C, and running agent.run.claude (the button/shortcut
# path through AgentLaunchUI) until its hook marks the session working.
# Then, without agents.toml, the header offers "Get Started…".
sed -i 's/^displayName = "Fake Claude"$/displayName = "Fake Claude"\nshortcutKey = "c"/' $HOMEDIR/.toastty/agents.toml
cat > $WORK/agents.script <<'SCRIPT'
wait 1500
expect agentButtons=Fake_Claude agentShortcuts=<Control><Alt>c
palette run agent
wait 300
expect paletteResults=1 paletteTop=agent.run.claude
close-dialog
perform agent.run.claude
wait 3000
expect sessions=working
quit
SCRIPT
cat > $WORK/no-agents.script <<'SCRIPT'
wait 800
expect agentButtons=Get_Started…
quit
SCRIPT
"${envs[@]}" gtk4-broadwayd :$DISPLAYNUM > $WORK/broadwayd6.log 2>&1 & BPID=$!; sleep 0.5
"${envs[@]}" TOASTTY_LINUX_SMOKE_SCRIPT=$WORK/agents.script TOASTTY_SOCKET_PATH=$WORK/f.sock timeout 90 $APP > $WORK/app-agents.log 2>&1
check "agent header button, palette entry and launch mark the session working" "[ $? -eq 0 ]"
mv $HOMEDIR/.toastty/agents.toml $WORK/agents.toml.off
"${envs[@]}" TOASTTY_LINUX_SMOKE_SCRIPT=$WORK/no-agents.script TOASTTY_SOCKET_PATH=$WORK/g.sock timeout 60 $APP > $WORK/app-no-agents.log 2>&1
check "without agent profiles the header offers Get Started" "[ $? -eq 0 ]"
{ kill -9 $BPID; wait $BPID; } 2>/dev/null
# Phase H: the app icon (rendered from macOS's AppIcon) resolves through the
# icon theme from this build's data, is the default window icon, and the About
# dialog shows it.
cat > $WORK/icon.script <<SCRIPT
wait 600
expect appIcon=toastty windowIcon=com.GiantThings.toastty
action app.about
wait 600
screenshot $WORK/about.png
quit
SCRIPT
"${envs[@]}" gtk4-broadwayd :$DISPLAYNUM > $WORK/broadwayd8.log 2>&1 & BPID=$!; sleep 0.5
"${envs[@]}" TOASTTY_LINUX_SMOKE_SCRIPT=$WORK/icon.script TOASTTY_SOCKET_PATH=$WORK/i.sock timeout 60 $APP > $WORK/app-icon.log 2>&1
check "the Toastty icon resolves from this build and is the window icon" "[ $? -eq 0 ]"
check "the Linux icons are current with the macOS AppIcon (render-app-icon.py --check)" "python3 $REPO/scripts/linux/render-app-icon.py --check"
{ kill -9 $BPID; wait $BPID; } 2>/dev/null
# Phase G: background browser loading. After a restart, browser panels in a
# workspace that is not selected have no widget; panel.browser.state and
# panel.browser.reload must load them off screen (macOS keeps a WKWebView per
# runtime) and report WebKit's navigation result, not a guess.
cat > $WORK/page.html <<'HTML'
<!doctype html><html><head><title>E2E Page</title></head><body><p>background page</p></body></html>
HTML
PAGE_URL=file://$WORK/page.html; MISSING_URL=file://$WORK/missing.html
SOCK=$WORK/h.sock; envs+=(TOASTTY_AUTOMATION=0 TOASTTY_RUNTIME_HOME=$WORK/browser-home TOASTTY_SOCKET_PATH=$SOCK)
mkdir -p $WORK/browser-home
"${envs[@]}" gtk4-broadwayd :$DISPLAYNUM > $WORK/broadwayd7.log 2>&1 & BPID=$!; sleep 0.5
start_app browser1 || { tail -30 $WORK/app-browser1.log; exit 1; }
WIN=$(cli query run workspace.list | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["workspaces"][0]["windowID"])')
HIDDEN=$(cli action run workspace.create --window "$WIN" title=Browser-Hidden | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["workspaceID"])')
cli action run panel.create.browser --workspace "$HIDDEN" url="$PAGE_URL" > /dev/null
cli action run panel.create.browser --workspace "$HIDDEN" url="$MISSING_URL" > /dev/null
cli action run workspace.create --window "$WIN" title=Browser-Front > /dev/null
sleep 1
kill -TERM $APID; for i in $(seq 1 50); do kill -0 $APID 2>/dev/null || break; sleep 0.1; done; kill -9 $APID 2>/dev/null
rm -f $SOCK
start_app browser2 || { tail -30 $WORK/app-browser2.log; exit 1; }
cli query run workspace.snapshot --workspace "$HIDDEN" > $WORK/hidden.json
panel_for() { python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["result"]["rightPanel"]["tabs"]; print(next(x["panelID"] for x in t if (x.get("url") or "").endswith(sys.argv[2])))' $WORK/hidden.json "$1" 2>/dev/null; }
PAGE_PANEL=$(panel_for page.html); MISSING_PANEL=$(panel_for missing.html)
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["result"].get(sys.argv[2]); print("" if v is None else (json.dumps(v) if isinstance(v, dict) else v))' "$1" "$2" 2>/dev/null; }
# Poll panel.browser.state until WebKit settles (finished or failed).
settle() {
  for i in $(seq 1 100); do
    cli query run panel.browser.state --panel "$1" > "$2"
    case "$(field "$2" navigationState)" in finished|failed) return 0 ;; esac
    sleep 0.2
  done
  return 1
}
cli query run panel.browser.state --panel "$PAGE_PANEL" > $WORK/page-first.json
settle "$PAGE_PANEL" $WORK/page-state.json
cli query run panel.browser.state --panel "$PAGE_PANEL" > $WORK/page-again.json
check "panel.browser.state loads a never-shown browser in the background (detached, finished, WebKit URL and title)" \
  "[ -n \"$PAGE_PANEL\" ] && [ \"\$(field $WORK/page-first.json hostLifecycleState)\" = detached ] && [ \"\$(field $WORK/page-state.json navigationState)\" = finished ] && [ \"\$(field $WORK/page-state.json title)\" = 'E2E Page' ] && field $WORK/page-state.json observedURL | grep -q 'page.html\$' && [ -z \"\$(field $WORK/page-state.json navigationError)\" ] && [ \"\$(field $WORK/page-again.json navigationState)\" = finished ]"
settle "$MISSING_PANEL" $WORK/missing-state.json
check "a browser load that fails reports navigationState failed with a navigationError" \
  "[ -n \"$MISSING_PANEL\" ] && [ \"\$(field $WORK/missing-state.json navigationState)\" = failed ] && [ -n \"\$(field $WORK/missing-state.json navigationError)\" ]"
sed -i 's/E2E Page/E2E Page Reloaded/' $WORK/page.html
cli action run panel.browser.reload --panel "$PAGE_PANEL" > $WORK/reload.json
settle "$PAGE_PANEL" $WORK/page-reloaded.json
check "panel.browser.reload starts a new navigation that finishes with the updated page" \
  "grep -q '\"ok\" *: *true' $WORK/reload.json && [ \"\$(field $WORK/page-reloaded.json navigationState)\" = finished ] && [ \"\$(field $WORK/page-reloaded.json title)\" = 'E2E Page Reloaded' ]"
kill -TERM $APID; sleep 1; kill -9 $APID 2>/dev/null; { kill -9 $BPID; wait $BPID; } 2>/dev/null
if [ "${TOASTTY_LINUX_TEST_KEEP:-0}" = 1 ]; then echo "kept $WORK"; else rm -rf "$WORK"; fi
exit $fail
