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
#   6. the Tasks view (Broadway, smoke script): open, rows, selection with
#      the arrows, Esc, the Show Tasks toggle.
# Build first: scripts/linux/build.sh --product toastty-linux --product toastty
# Usage: scripts/linux/e2e-tasks.sh   (exit status 0 when every check passes)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
    printf '{"type":"assistant","sessionId":"%s","uuid":"a-2","parentUuid":"u-2","isSidechain":false,"timestamp":"%s","message":{"role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"## Nothing needs you\\n\\n**All clear.** Next check:\\n\\n- the `build` task\\n- [docs](https://example.com)\\n\\n| Task | Stage |\\n|---|---|\\n| Build | Running |"}]}}\n' "$sid" "$(ts)"
  } > "$t"
  printf '{"hook_event_name":"SessionStart","session_id":"%s","transcript_path":"%s","cwd":"%s","source":"startup"}' "$sid" "$t" "$PWD" \
    | "$TOASTTY_CLI_PATH" session ingest-agent-event --source claude-hooks >> "$out" 2>&1
  printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":"%s"}' "$sid" "$t" \
    | "$TOASTTY_CLI_PATH" session ingest-agent-event --source claude-hooks >> "$out" 2>&1
  ;;
esac
echo "fake agent up"
sleep 600
AGENT
chmod +x $WORK/bin/claude
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
cleanup() { stop_app; { kill -9 $BPID; wait $BPID; } 2>/dev/null; }
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
cat > $WORK/ui.script <<SCRIPT
wait-file $WORK/go
wait 500
action window.toggle-tasks-view
wait 300
expect tasksView=shown tasksRows=2
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
expect tasksView=hidden
action window.toggle-tasks-view
wait 200
expect tasksView=shown
action window.toggle-tasks-view
wait 200
expect tasksView=hidden
state $WORK/ui-state.json
quit
SCRIPT
(cd $PROJECT && "${envs[@]}" TOASTTY_LINUX_SMOKE_SCRIPT=$WORK/ui.script $APP > $WORK/app-ui.log 2>&1) & APID=$!
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
sleep 1; touch $WORK/go
for i in $(seq 1 300); do kill -0 $APID 2>/dev/null || break; sleep 0.1; done
wait $APID; UIRC=$?
check "the Tasks view script passes (open, rows, select, arrows, Esc, toggle)" "[ $UIRC = 0 ] && ! grep -q '^.*FAIL' $WORK/app-ui.log"
grep 'FAIL' $WORK/app-ui.log | head -5
check "the Tasks view screenshot is written" "[ -s $WORK/tasks-view.png ]"
[ -s $WORK/tasks-view.png ] && mkdir -p $REPO/artifacts/manual/linux-tasks && cp $WORK/tasks-view.png $REPO/artifacts/manual/linux-tasks/tasks-view.png
pkill -f "$WORK/bin/claude" 2>/dev/null; rm -f $SOCK

# Phase C: the coordinator's chat over its terminal and the dock.
cat > $WORK/coordinator.script <<SCRIPT
wait 500
perform coordinator.open
wait 3000
expect coordinatorRunning=true coordinatorCover=chat
screenshot $WORK/coordinator-full.png
coordinator type Hello_Toasty
wait 200
expect coordinatorComposer=Hello_Toasty
coordinator send
wait 800
expect coordinatorComposerEmpty=true
click coordinator.panel.mode
wait 300
expect coordinatorCover=terminal
click coordinator.panel.mode
wait 300
expect coordinatorCover=chat
perform coordinator.dock.toggle
wait 800
expect coordinatorDock=shown
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
check "the coordinator script passes (chat cover, send, Terminal/Chat, dock)" "[ $CRC = 0 ] && ! grep -q 'FAIL' $WORK/app-coordinator.log"
grep 'FAIL' $WORK/app-coordinator.log | head -8
for shot in coordinator-full coordinator-dock; do
  [ -s $WORK/$shot.png ] && mkdir -p $REPO/artifacts/manual/linux-tasks && cp $WORK/$shot.png $REPO/artifacts/manual/linux-tasks/$shot.png
done
pkill -f "$WORK/bin/claude" 2>/dev/null; rm -f $SOCK
[ $fail = 0 ] && echo "e2e-tasks: all checks passed" || { echo "e2e-tasks: FAILED (work dir $WORK)"; trap - EXIT; cleanup; exit 1; }
rm -rf $WORK
