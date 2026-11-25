#!/usr/bin/env bash
# End-to-end check of tasks and the coordinator in toastty-linux, on a private
# GDK Broadway display (never the live session), with a fake agent:
#   1. `toastty task create` makes a task in a git workspace, its task space
#      opens and the fake agent starts with the start skill and task text;
#   2. `toastty task list` / `task get` read it back;
#   3. `toastty task workspace-choices` lists the open workspace;
#   4. `toastty coordinator open` makes the Coordinator workspace with its
#      agent, and `coordinator status` reports it;
#   5. the task survives a quit and restart;
#   6. the Tasks view (Broadway, smoke script): open, rows, mark widths,
#      selection with the arrows, Esc, the Show Tasks toggle, and the right
#      panel, plus Merge and Complete Task directly in the workspace header.
# Build first: scripts/linux/build.sh --product toastty-linux --product toastty
# Usage: scripts/linux/e2e-tasks.sh   (exit status 0 when every check passes)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$REPO/artifacts/manual/linux-tasks"
B=${TOASTTY_LINUX_E2E_BIN:-$REPO/linux/.build/debug}
[ -x $B/toastty-linux ] || B=$(dirname $(find $REPO/linux/.build -name toastty-linux -type f -perm -u+x | head -1))
APP=$B/toastty-linux; CLI=$B/toastty
WORK=$(mktemp -d "${XDG_RUNTIME_DIR}/tttasks.XXXX")
HOMEDIR=$WORK/home; RT=$WORK/rt; mkdir -p $HOMEDIR/.toastty $RT; chmod 700 $RT
SOCK=$WORK/s.sock
DISPLAYNUM=$((90 + RANDOM % 20))
# The project: a git repository, as a task's workspace needs.
PROJECT=$WORK/project; mkdir -p $PROJECT
git -C $PROJECT init -q -b main && git -C $PROJECT -c user.email=e2e@example.com -c user.name=e2e commit -q --allow-empty -m init
mkdir -p $WORK/bin
# Named `claude`, so Toastty passes the task text as its first message.
cat > $WORK/bin/claude <<'AGENT'
#!/bin/bash
# A fake managed agent: record its arguments and environment, report a
# submitted prompt through the Toastty hook CLI, then idle.
out="$(dirname "$0")/../agent-$TOASTTY_SESSION_ID.log"
{ echo "args: $*"; echo "cwd=$PWD"; } > "$out"
printf '{"hook_event_name":"UserPromptSubmit","prompt":"e2e","session_id":"native-%s"}' "$TOASTTY_SESSION_ID" \
  | "$TOASTTY_CLI_PATH" session ingest-agent-event --source claude-hooks >> "$out" 2>&1
# As the coordinator: a Claude transcript with markdown, a tool call and an
# answer, bound through the SessionStart hook, as Claude Code reports it.
case "$PWD" in
*/coordinator)
  sid="11111111-2222-3333-4444-$(printf '%012d' $$)"
  dir="$HOME/.claude/projects/coordinator"; mkdir -p "$dir"; t="$dir/$sid.jsonl"
  ts() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
  {
    printf '{"type":"user","sessionId":"%s","uuid":"u-1","parentUuid":null,"isSidechain":false,"timestamp":"%s","message":{"role":"user","content":"What needs me?"}}\n' "$sid" "$(ts)"
    printf '{"type":"assistant","sessionId":"%s","uuid":"a-1","parentUuid":"u-1","isSidechain":false,"timestamp":"%s","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"toastty task list --json"}}]}}\n' "$sid" "$(ts)"
    printf '{"type":"user","sessionId":"%s","uuid":"u-2","parentUuid":"a-1","isSidechain":false,"timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"[]"}]}}\n' "$sid" "$(ts)"
    # The rest: an 11-line message with links and a list, the user's reply
    # that quotes it, and the answer (written by the e2e script below).
    sed -e "s/@SID@/$sid/g" -e "s/@TS@/$(ts)/g" "$(dirname "$0")/../coordinator-tail.jsonl"
  } > "$t"
  printf '{"hook_event_name":"SessionStart","session_id":"%s","transcript_path":"%s","cwd":"%s","source":"startup"}' "$sid" "$t" "$PWD" \
    | "$TOASTTY_CLI_PATH" session ingest-agent-event --source claude-hooks >> "$out" 2>&1
  printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":"%s"}' "$sid" "$t" \
    | "$TOASTTY_CLI_PATH" session ingest-agent-event --source claude-hooks >> "$out" 2>&1
  ;;
esac
echo "fake agent up"
if [[ "$*" == *"Second task"* ]]; then
  while [[ ! -f "$(dirname "$0")/../finish-second" ]]; do sleep 0.1; done
  printf '{"hook_event_name":"Stop","session_id":"native-%s"}' "$TOASTTY_SESSION_ID" \
    | "$TOASTTY_CLI_PATH" session ingest-agent-event --source claude-hooks >> "$out" 2>&1
fi
sleep 600
AGENT
chmod +x $WORK/bin/claude
# The coordinator's long message and a reply that quotes it. A reply's quote
# once set the chat's width, as one line of up to 2,000 characters.
python3 - "$WORK/coordinator-tail.jsonl" <<'PY'
import json, sys
long_message = "\n".join([
    "## Three tasks need you",
    "**All clear** on the build. [Fix the sidebar width](https://example.com/tasks/sidebar-width) is ready for review, and its pull request passed every check on the first run.",
    "",
    "- [Linux tasks UI flows](https://example.com/tasks/linux-tasks-ui) waits for your answer on the dock shortcut and the names of the two new menu items",
    "- [Coordinator chat reply layout](https://example.com/tasks/reply-layout) reproduced the wide chat offscreen and is testing a fix now",
    "- the `build` task",
    "- [docs](https://example.com)",
    "",
    "| Task | Stage |",
    "|---|---|",
    "| Build | Running |",
])
quote = long_message.split("\n")
reply = "\n".join(
    ["[Toastty] Reply from the user | quotes your message of 06:40, %d lines" % len(quote)]
    + [">" if line == "" else "> " + line for line in quote]
    + ["Merge the sidebar fix first."]
)
def row(kind, uuid, parent, content, **extra):
    message = {"role": kind, "content": content}
    if kind == "assistant":
        message.update(model="claude-opus-5", stop_reason="end_turn")
    return json.dumps({"type": kind, "sessionId": "@SID@", "uuid": uuid, "parentUuid": parent,
                       "isSidechain": False, "timestamp": "@TS@", "message": message})
with open(sys.argv[1], "w") as out:
    out.write(row("assistant", "a-2", "u-2", [{"type": "text", "text": long_message}]) + "\n")
    out.write(row("user", "u-3", "a-2", reply) + "\n")
    # Force the fresh chat's first layout to overflow the viewport.
    report = "\n\n".join(f"Checked task {i}." for i in range(1, 41))
    out.write(row("assistant", "a-3", "u-3", [{"type": "text", "text": report + "\n\nMerging it now."}]) + "\n")
PY
cat > $HOMEDIR/.toastty/agents.toml <<TOML
[claude]
displayName = "Fake Claude"
argv = ["$WORK/bin/claude"]
TOML
envs=(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=$HOMEDIR CFFIXED_USER_HOME=$HOMEDIR
  XDG_RUNTIME_DIR=$RT XDG_CONFIG_HOME=$HOMEDIR/.config XDG_STATE_HOME=$HOMEDIR/.local/state
  XDG_DATA_HOME=$HOMEDIR/.local/share XDG_CACHE_HOME=$HOMEDIR/.cache SHELL=/bin/bash TERM=xterm-256color
  LANG=C.UTF-8 GDK_BACKEND=broadway BROADWAY_DISPLAY=:$DISPLAYNUM GTK_A11Y=none NO_AT_BRIDGE=1
  GDK_DEBUG=no-portals GSETTINGS_BACKEND=memory TOASTTY_LINUX_NON_UNIQUE=1 TOASTTY_SOCKET_PATH=$SOCK
  LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-})
"${envs[@]}" gtk4-broadwayd :$DISPLAYNUM > $WORK/broadwayd.log 2>&1 &
BPID=$!; sleep 0.5
start_app() { (cd $PROJECT && "${envs[@]}" $APP > $WORK/app-$1.log 2>&1) & APID=$!; for i in $(seq 1 100); do [ -S $SOCK ] && $CLI --socket-path $SOCK query list >/dev/null 2>&1 && return 0; sleep 0.1; done; echo "app did not start"; return 1; }
stop_app() { kill -TERM $APID 2>/dev/null; for i in $(seq 1 50); do kill -0 $APID 2>/dev/null || break; sleep 0.1; done; kill -9 $APID 2>/dev/null; pkill -f "$WORK/bin/claude" 2>/dev/null; rm -f $SOCK; }
cli() { "${envs[@]}" $CLI --json --socket-path $SOCK "$@"; }
json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); r=d.get('result',d); print(eval(sys.argv[2]))" "$@"; }
fail=0; check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
stop_viewer() {
  if [[ -n "${VIEWER_PID:-}" ]]; then
    kill "$VIEWER_PID" 2>/dev/null
    wait "$VIEWER_PID" 2>/dev/null
    VIEWER_PID=""
  fi
}
cleanup() { stop_viewer; stop_app; { kill -9 $BPID; wait $BPID; } 2>/dev/null; }
trap cleanup EXIT

start_app 1 || { tail -30 $WORK/app-1.log; exit 1; }
WIN=$(cli query run workspace.list | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result",d); print(r["windows"][0]["id"] if "windows" in r else r["workspaces"][0]["windowID"])')
cli action run workspace.create --window "$WIN" title=Project > $WORK/ws.json
WSID=$(json $WORK/ws.json 'r["workspaceID"]')
PANEL=$(cli query run terminal.state --workspace "$WSID" | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r.get("panelID") or r.get("panel",{}).get("id",""))')
sleep 1
cli action run terminal.send-text --panel "$PANEL" text="cd $PROJECT" submit=true > /dev/null
# The workspace's folder comes from the shell's working directory.
for i in $(seq 1 50); do cli task workspace-choices > $WORK/choices.json 2>&1; sed 's|\\/|/|g' $WORK/choices.json | grep -q "$PROJECT" && break; sleep 0.2; done
check "task workspace-choices lists the project" "sed 's|\\\\/|/|g' $WORK/choices.json | grep -q '$PROJECT'"

cli task create "E2E task: add a README" --workspace "$WSID" --agent claude > $WORK/create.json 2>&1
TASK=$(json $WORK/create.json 'r.get("task",r).get("id") or r.get("taskID")' 2>/dev/null)
check "task create returns a task" "[ -n '$TASK' ] && [ '$TASK' != None ]"
[ -n "$TASK" ] || cat $WORK/create.json
for i in $(seq 1 100); do grep -l "add a README" $WORK/agent-*.log >/dev/null 2>&1 && break; sleep 0.2; done
AGENTLOG=$(grep -l "add a README" $WORK/agent-*.log 2>/dev/null | head -1)
check "the task's agent starts with the start skill and the task text" "[ -n '$AGENTLOG' ] && grep -q 'toastty-task-start' '$AGENTLOG'"
check "the task's agent runs in the project" "grep -q 'cwd=$PROJECT\$' '$AGENTLOG'"
cli task get "$TASK" > $WORK/get.json 2>&1
check "task get reads the task" "grep -q 'E2E task: add a README' $WORK/get.json"
cli task list > $WORK/list.json 2>&1
check "task list includes the task" "grep -q '$TASK' $WORK/list.json"
cli query run workspace.list > $WORK/wslist.json
check "the task space opened" "grep -q 'e2e-task-add-a-readme' $WORK/wslist.json"

cli coordinator open --window "$WIN" > $WORK/coord-open.json 2>&1
for i in $(seq 1 100); do cli coordinator status > $WORK/coord.json 2>&1; grep -q '"workspaceID"' $WORK/coord.json && break; sleep 0.2; done
check "coordinator open makes the Coordinator workspace" "grep -q '\"workspaceID\"' $WORK/coord.json"
check "the Coordinator workspace shows in the window" "cli query run workspace.list | grep -q 'Coordinator'"

stop_app
start_app 2 || { tail -30 $WORK/app-2.log; exit 1; }
cli task get "$TASK" > $WORK/get2.json 2>&1
check "the task survives a restart" "grep -q 'E2E task: add a README' $WORK/get2.json"
stop_app

# Phase B: the Tasks view, driven by a smoke script while the CLI makes tasks.
# A local fixture answers PR lookups. The PR task's fake agent stays in
# its turn, so the header's Merge action queues the merge skill.
cat > "$WORK/bin/gh" <<'GH'
#!/bin/bash
[[ "$1 $2 $3" == "pr view https://github.com/fixture/toastty/pull/42" ]] || exit 1
if [[ -f "$(dirname "$0")/../pending-pr" ]]; then
  echo '{"state":"OPEN","isDraft":false,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"status":"IN_PROGRESS"}]}'
else
  echo '{"state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN"}'
fi
GH
chmod +x "$WORK/bin/gh"
printf 'export PATH="%s:$PATH"\n' "$WORK/bin" > "$HOMEDIR/.profile"
# Keep a viewer attached for the scripted UI phases. Broadway only runs GTK
# layout frames with a viewer; the forced-layout fallback can't test scrolling.
if VIEWER=$(command -v google-chrome || command -v chromium); then
  "${envs[@]}" "$VIEWER" --headless=new --disable-gpu --no-first-run \
    --disable-background-timer-throttling --disable-renderer-backgrounding \
    --disable-backgrounding-occluded-windows --window-size=1280,800 \
    --user-data-dir="$WORK/chrome" "http://127.0.0.1:$((8080 + DISPLAYNUM))/" > "$WORK/chrome.log" 2>&1 &
  VIEWER_PID=$!
fi
cat > $WORK/ui.script <<SCRIPT
wait-file $WORK/go
wait 500
perform browser.create
wait 300
expect rightPanel=true rightPanelTabs=1 rightPanelMapped=true
action window.toggle-tasks-view
wait 300
expect tasksView=shown tasksRows=2 rightPanel=true rightPanelTabs=1 rightPanelMapped=false
tasks wait-idle
# Each mark keeps its 12-wide slot, however short the row's text.
expect tasksMarkWidths=12,12
screenshot $WORK/tasks-view.png
tasks select 1
wait 200
expect tasksDetail=E2E_task:_add_a_README tasksSelected=E2E_task:_add_a_README
tasks key up
wait 200
expect tasksSelected=Second_task tasksDetail=Second_task
tasks key down
wait 200
expect tasksSelected=E2E_task:_add_a_README
tasks key escape
wait 300
expect tasksView=hidden rightPanel=true rightPanelTabs=1 rightPanelMapped=true
screenshot $WORK/tasks-right-panel-restored.png
# The first card render already rebuilt the sidebar. Opening a task-space
# menu must still map a native popup.
tasks sidebar-menu open
expect sidebarContextMenu=shown
tasks sidebar-menu close
expect sidebarContextMenu=hidden
action window.toggle-right-panel
wait 300
expect rightPanel=false rightPanelTabs=1 rightPanelMapped=false
action window.toggle-tasks-view
wait 200
expect tasksView=shown rightPanel=false rightPanelMapped=false
action window.toggle-tasks-view
wait 200
expect tasksView=hidden rightPanel=false rightPanelTabs=1 rightPanelMapped=false
expect sidebarTaskRows=2 sidebarSegment=all sidebarMarkWidths=12,12
screenshot $WORK/sidebar.png
action workspace.select-1
action window.toggle-tasks-view
expect workspaceIndex=0 tasksView=shown sidebarVisibleRows=2
click sidebar.card.1.disclosure
wait 300
expect workspaceIndex=0 tasksView=shown sidebarVisibleRows=0
click sidebar.card.1.disclosure
wait 300
expect workspaceIndex=0 tasksView=shown sidebarVisibleRows=2
action window.toggle-tasks-view
action workspace.select-2
click sidebar.segment.needsYou
wait 300
expect sidebarSegment=needsYou
click sidebar.segment.all
wait 300
expect sidebarSegment=all
# Changing segments rebuilt the cards again.
tasks sidebar-menu open
expect sidebarContextMenu=shown
tasks sidebar-menu close
expect sidebarContextMenu=hidden
action window.toggle-right-panel
expect rightPanel=true rightPanelTabs=1 rightPanelMapped=true
action window.toggle-tasks-view
expect tasksView=shown tabs=1 rightPanel=true rightPanelMapped=false
action workspace.tab.create
expect tasksView=hidden tabs=2 rightPanel=false rightPanelTabs=0 rightPanelMapped=false
action window.toggle-tasks-view
action workspace.tab.select-1
expect tasksView=hidden tabs=2 tabIndex=0 rightPanel=true rightPanelTabs=1 rightPanelMapped=true
action window.toggle-tasks-view
click sidebar.segment.needsYou
wait 300
expect sidebarSegment=needsYou
action workspace.create
expect tasksView=hidden sidebarSegment=all tabs=1
state $WORK/ui-state.json
expect workspaceTaskControl=none
file-write $WORK/test-complete go
wait-file $WORK/complete-selected
expect tasksView=hidden workspaceTaskControl=Archive_Task…
file-write $WORK/finish-second go
wait-file $WORK/review-ready
expect tasksView=hidden workspaceTaskControl=Complete_Task
screenshot $WORK/workspace-complete.png
click workspace.task-control.primary
wait 400
expect dialog=AdwAlertDialog
screenshot $WORK/workspace-complete-confirm.png
dialog-respond cancel
wait 400
expect tasksView=hidden workspaceTaskControl=Complete_Task
click workspace.task-control.primary
wait 400
dialog-respond confirm
wait 400
file-write $WORK/complete-clicked go
wait-file $WORK/merge-selected
expect tasksView=hidden workspaceTaskControl=Merge_PR
screenshot $WORK/workspace-merge.png
click workspace.task-control.primary
wait 400
expect workspaceTaskControl=progress
file-write $WORK/merge-clicked go
wait-file $WORK/test-pending
# Opening Tasks triggers a pull request refresh without waiting for the
# board's periodic poll. Verify the result back in the workspace.
action window.toggle-tasks-view
expect workspaceTaskControl=none
action window.toggle-tasks-view
terminal-wait-state 10000 workspaceTaskControl=Open_PR
expect tasksView=hidden
screenshot $WORK/workspace-open-pr.png
action workspace.merge
expect tasksView=hidden workspaceTaskControl=progress
quit
SCRIPT
(cd $PROJECT && exec "${envs[@]}" PATH="$WORK/bin:/usr/local/bin:/usr/bin:/bin" TOASTTY_LINUX_SMOKE_SCRIPT=$WORK/ui.script $APP > $WORK/app-ui.log 2>&1) & APID=$!
for i in $(seq 1 100); do [ -S $SOCK ] && $CLI --socket-path $SOCK query list >/dev/null 2>&1 && break; sleep 0.1; done
# A smoke-script run starts from a fresh layout and task store: make the
# project workspace and two tasks in it.
WIN=$(cli query run workspace.list | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result",d); print(r["windows"][0]["id"] if "windows" in r else r["workspaces"][0]["windowID"])')
cli action run workspace.create --window "$WIN" title=Project > $WORK/ws2.json
WSID=$(json $WORK/ws2.json 'r["workspaceID"]')
PANEL=$(cli query run terminal.state --workspace "$WSID" | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r.get("panelID") or r.get("panel",{}).get("id",""))')
sleep 1
cli action run terminal.send-text --panel "$PANEL" text="cd $PROJECT" submit=true > /dev/null
for i in $(seq 1 50); do cli task workspace-choices > $WORK/choices2.json 2>&1; sed 's|\\/|/|g' $WORK/choices2.json | grep -q "$PROJECT" && break; sleep 0.2; done
cli task create "E2E task: add a README" --workspace "$WSID" --agent claude > $WORK/create1b.json 2>&1
cli task create "Second task" --workspace "$WSID" --agent claude > $WORK/create2.json 2>&1
check "two tasks are created for the UI phase" "grep -q '\"ok\" : true' $WORK/create1b.json && grep -q '\"ok\" : true' $WORK/create2.json"
wait_for_file() {
  for _ in $(seq 1 "${2:-300}"); do
    [[ -f "$1" ]] && return 0
    kill -0 "$APID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}
TASK1=$(json "$WORK/create1b.json" 'r["taskID"]')
TASK2=$(json "$WORK/create2.json" 'r["taskID"]')
sleep 1; touch $WORK/go
# The task-list checks above wait for GTK frames before starting the header checks.
if wait_for_file "$WORK/test-complete" 900; then
  cli task get "$TASK1" > "$WORK/task1.json"
  cli task get "$TASK2" > "$WORK/task2.json"
  SPACE1=$(json "$WORK/task1.json" 'r["setup"]["taskSpaceWorkspaceID"]')
  SPACE2=$(json "$WORK/task2.json" 'r["setup"]["taskSpaceWorkspaceID"]')
  cli action run workspace.select --workspace "$SPACE2" > "$WORK/select2.json"
  touch "$WORK/complete-selected"
  wait_for_file "$WORK/finish-second"
  cli task ready-for-review "$TASK2" > "$WORK/review.json"
  for _ in $(seq 1 50); do
    cli task get "$TASK2" > "$WORK/review-get.json"
    grep -q '"attention" : "readyForReview"' "$WORK/review-get.json" && break
    sleep 0.1
  done
  touch "$WORK/review-ready"
fi
if wait_for_file "$WORK/complete-clicked"; then
  cli task get "$TASK2" > "$WORK/completed.json"
  cli query run workspace.list > "$WORK/after-complete.json"
  DONE_AT=$(json "$WORK/completed.json" 'r.get("doneAt")')
  check "Complete Task marks the task done and closes its workspace" \
    "[ -n '$DONE_AT' ] && [ '$DONE_AT' != None ] && ! grep -qi '$SPACE2' '$WORK/after-complete.json'"
  cli action run workspace.set-annotation --workspace "$SPACE1" key=github-pr text="PR #42" \
    url=https://github.com/fixture/toastty/pull/42 > "$WORK/pr.json"
  cli action run workspace.select --workspace "$SPACE1" > "$WORK/select1.json"
  touch "$WORK/merge-selected"
fi
if wait_for_file "$WORK/merge-clicked"; then
  cli task get "$TASK1" > "$WORK/merge.json"
  MERGE_REQUESTED_AT=$(json "$WORK/merge.json" 'r.get("mergeRequestedAt")')
  check "Merge from the header requests the task’s merge flow" \
    "[ -n '$MERGE_REQUESTED_AT' ] && [ '$MERGE_REQUESTED_AT' != None ]"
  cli task cancel-merge "$TASK1" > "$WORK/cancel-merge.json"
  touch "$WORK/pending-pr" "$WORK/test-pending"
fi
for i in $(seq 1 300); do kill -0 $APID 2>/dev/null || break; sleep 0.1; done
kill -9 $APID 2>/dev/null
wait $APID; UIRC=$?
check "the Tasks view and workspace header script passes" "[ $UIRC = 0 ] && ! grep -q '^.*FAIL' $WORK/app-ui.log"
grep 'FAIL' $WORK/app-ui.log | head -5
check "the Tasks view screenshot is written" "[ -s $WORK/tasks-view.png ]"
for shot in tasks-view tasks-right-panel-restored sidebar workspace-complete workspace-complete-confirm workspace-merge workspace-open-pr; do
  [ -s $WORK/$shot.png ] && mkdir -p $REPO/artifacts/manual/linux-tasks && cp $WORK/$shot.png $REPO/artifacts/manual/linux-tasks/$shot.png
done
pkill -f "$WORK/bin/claude" 2>/dev/null; rm -f $SOCK

# Phase C: the coordinator's chat over its terminal and the dock.
SCROLL_CHECKS=""
DOCK_SCROLL_CHECK=""
if [[ -n "${VIEWER_PID:-}" ]]; then
  SCROLL_CHECKS=$(cat <<'SCROLL'
expect coordinatorLatestVisible=true
coordinator scroll-top
wait 250
expect coordinatorLatestVisible=false
coordinator jump
wait 400
expect coordinatorLatestVisible=true
SCROLL
)
  DOCK_SCROLL_CHECK="expect coordinatorLatestVisible=true"
else
  echo "SKIP coordinator scroll assertions (no Chrome or Chromium Broadway viewer)"
fi
cat > $WORK/coordinator.script <<SCRIPT
wait 500
perform coordinator.open
wait 3000
expect coordinatorRunning=true coordinatorCover=chat
$SCROLL_CHECKS
screenshot $WORK/coordinator-full.png
expect coordinatorChatFits=true
coordinator reply
wait 300
expect coordinatorReplying=true coordinatorChatFits=true coordinatorReplyBar=Replying_to_the_coordinator_· coordinatorReplyBarTimeOK=true
screenshot $WORK/coordinator-replying.png
coordinator type Hello_Toasty
wait 200
expect coordinatorComposer=Hello_Toasty
coordinator send
wait 800
expect coordinatorComposerEmpty=true coordinatorReplying=false coordinatorChatFits=true
screenshot $WORK/coordinator-reply-sent.png
state $WORK/coordinator-chat-state.json
click coordinator.panel.mode
wait 300
expect coordinatorCover=terminal
click coordinator.panel.mode
wait 300
expect coordinatorCover=chat
perform coordinator.dock.toggle
wait 800
expect coordinatorDock=shown
$DOCK_SCROLL_CHECK
screenshot $WORK/coordinator-dock.png
perform coordinator.dock.toggle
wait 500
expect coordinatorDock=hidden
state $WORK/coordinator-state.json
quit
SCRIPT
(cd $PROJECT && "${envs[@]}" TOASTTY_LINUX_SMOKE_SCRIPT=$WORK/coordinator.script $APP > $WORK/app-coordinator.log 2>&1) & APID=$!
for i in $(seq 1 400); do kill -0 $APID 2>/dev/null || break; sleep 0.1; done
kill -9 $APID 2>/dev/null; wait $APID; CRC=$?
check "the coordinator script passes (chat cover, scrolling with a viewer, reply, send, Terminal/Chat, dock)" "[ $CRC = 0 ] && ! grep -q 'FAIL' $WORK/app-coordinator.log"
grep 'FAIL' $WORK/app-coordinator.log | head -8
echo "coordinator chat minimum width after the reply: $(json $WORK/coordinator-chat-state.json 'r.get("coordinatorChatMinWidth")' 2>/dev/null) px"
for shot in coordinator-full coordinator-replying coordinator-reply-sent coordinator-dock; do
  [ -s $WORK/$shot.png ] && mkdir -p $REPO/artifacts/manual/linux-tasks && cp $WORK/$shot.png $REPO/artifacts/manual/linux-tasks/$shot.png
done
pkill -f "$WORK/bin/claude" 2>/dev/null; rm -f $SOCK

# Phase D: quick entry creates a task (no coordinator in this run).
cat > $WORK/quick-entry.script <<SCRIPT
wait 500
expect taskCount=0 quickEntry=closed
click sidebar.segment.needsYou
wait 300
expect sidebarSegment=needsYou
click sidebar.needsYou.showAll
wait 300
expect sidebarSegment=all
click sidebar.tasks.new
wait 500
expect quickEntry=open quickEntrySendsToCoordinator=false quickEntryCanSubmit=false
quick-entry type Write_the_release_notes
wait 200
quick-entry picker workspace
wait 300
expect quickEntryPicker=workspace
quick-entry screenshot $WORK/quick-entry-picker.png
quick-entry choose 0
wait 300
expect quickEntryPicker=none quickEntryCanSubmit=true
quick-entry screenshot $WORK/quick-entry.png
quick-entry submit
wait 1500
expect quickEntry=closed taskCount=1
quit
SCRIPT
(cd $PROJECT && "${envs[@]}" TOASTTY_LINUX_SMOKE_SCRIPT=$WORK/quick-entry.script $APP > $WORK/app-quick-entry.log 2>&1) & APID=$!
for i in $(seq 1 300); do kill -0 $APID 2>/dev/null || break; sleep 0.1; done
kill -9 $APID 2>/dev/null; wait $APID; QRC=$?
check "empty Needs you can return to All, and sidebar New Task opens quick entry (type, Workspace picker, submit)" "[ $QRC = 0 ] && ! grep -q 'FAIL' $WORK/app-quick-entry.log"
grep 'FAIL' $WORK/app-quick-entry.log | head -8
for shot in quick-entry quick-entry-picker; do
  [ -s $WORK/$shot.png ] && cp $WORK/$shot.png $REPO/artifacts/manual/linux-tasks/$shot.png
done
pkill -f "$WORK/bin/claude" 2>/dev/null; rm -f $SOCK

# Phase E: a first launch asks What's new; Start Coordinator starts it.
FRESH=$WORK/fresh-home; mkdir -p $FRESH/.toastty; cp $HOMEDIR/.toastty/agents.toml $FRESH/.toastty/
cat > $WORK/whats-new.script <<SCRIPT
wait 1500
screenshot $WORK/whats-new.png
click whats-new.start
wait 3000
expect coordinatorRunning=true
quit
SCRIPT
(cd $PROJECT && "${envs[@]}" HOME=$FRESH CFFIXED_USER_HOME=$FRESH XDG_CONFIG_HOME=$FRESH/.config TOASTTY_LINUX_TEST_START_OFFER=1 TOASTTY_LINUX_SMOKE_SCRIPT=$WORK/whats-new.script $APP > $WORK/app-whats-new.log 2>&1) & APID=$!
for i in $(seq 1 300); do kill -0 $APID 2>/dev/null || break; sleep 0.1; done
kill -9 $APID 2>/dev/null; wait $APID; WRC=$?
check "a first launch asks What's new, and Start Coordinator starts it" "[ $WRC = 0 ] && ! grep -q 'FAIL' $WORK/app-whats-new.log"
grep 'FAIL' $WORK/app-whats-new.log | head -5
[ -s $WORK/whats-new.png ] && cp $WORK/whats-new.png $REPO/artifacts/manual/linux-tasks/whats-new.png
pkill -f "$WORK/bin/claude" 2>/dev/null; rm -f $SOCK
[ $fail = 0 ] && echo "e2e-tasks: all checks passed" || { echo "e2e-tasks: FAILED (work dir $WORK)"; trap - EXIT; cleanup; exit 1; }
rm -rf $WORK
