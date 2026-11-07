#!/usr/bin/env bash
# Install and launch built Linux packages, then check what a user does first:
# the window comes up, a terminal runs commands, and Claude Code and Codex
# start as managed agents and answer a one-word prompt. Saves screenshots,
# terminal transcripts and a report as proof.
#
# Usage: scripts/linux/test-package.sh [--release-dir DIR] [--deb FILE] [--appimage FILE]
#          [--installed-deb] [--real-window] [--agents claude,codex|none] [--no-prompt]
#          [--out DIR]
#
#   --release-dir DIR  test the .deb and AppImage listed in DIR/package-metadata.env
#                      (default: the newest artifacts/release/linux/*/)
#   --deb FILE         test this .deb
#   --appimage FILE    test this AppImage
#   --installed-deb    the .deb is installed (sudo apt install ./FILE): test
#                      /usr/lib/toastty and check dpkg's installed version.
#                      Without it the .deb is checked with apt-get --simulate
#                      and installed into a scratch root with dpkg-deb -x.
#   --real-window      launch on the current display instead of a private
#                      Broadway display (OpenGL check; a window opens).
#   --agents LIST      agents to launch (default: claude,codex); `none` skips them
#   --no-prompt        launch the agents without sending them a prompt
#   --out DIR          output (default: artifacts/package-tests/<timestamp>/)
#
# Each instance is isolated: its own TOASTTY_RUNTIME_HOME, socket and
# artifacts, launched non-unique, so it never hands off to or touches an
# installed, running Toastty. HOME is the real one so the agents find their
# logins and the user's agent profiles (~/.toastty/agents.toml, which must
# define `claude` and `codex`); agent CLIs and managed hooks behave as in the
# user's own Toastty. An agent's update offer is skipped with Esc, never
# accepted.
# The agents run in the repository root (a folder they already trust).
#
# Output: report.md, results.json, and per package: screenshots/*.png,
# transcripts/*.txt, app.log. Exit 0 when every check passes, 1 otherwise.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
release_dir=""
debs=()
appimages=()
installed_deb=0
real_window=0
agents="claude,codex"
prompt=1
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-dir) release_dir="$2"; shift ;;
    --deb) debs+=("$2"); shift ;;
    --appimage) appimages+=("$2"); shift ;;
    --installed-deb) installed_deb=1 ;;
    --real-window) real_window=1 ;;
    --agents) agents="$2"; shift ;;
    --no-prompt) prompt=0 ;;
    --out) out="$2"; shift ;;
    -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "test-package.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done
[[ "$agents" == "none" ]] && agents=""

if [[ ${#debs[@]} -eq 0 && ${#appimages[@]} -eq 0 ]]; then
  if [[ -z "$release_dir" ]]; then
    release_dir="$(ls -td "$repo_root"/artifacts/release/linux/*/ 2>/dev/null | head -n1)"
  fi
  [[ -n "$release_dir" && -f "$release_dir/package-metadata.env" ]] \
    || { echo "test-package.sh: no package-metadata.env; pass --release-dir, --deb or --appimage" >&2; exit 64; }
  # shellcheck source=/dev/null
  source "$release_dir/package-metadata.env"
  [[ -n "${TOASTTY_LINUX_DEB:-}" ]] && debs+=("$repo_root/$TOASTTY_LINUX_DEB")
  [[ -n "${TOASTTY_LINUX_APPIMAGE:-}" ]] && appimages+=("$repo_root/$TOASTTY_LINUX_APPIMAGE")
fi
for f in "${debs[@]}" "${appimages[@]}"; do
  [[ -f "$f" ]] || { echo "test-package.sh: missing package $f" >&2; exit 64; }
done

out="${out:-$repo_root/artifacts/package-tests/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
results="$out/results.jsonl"
: > "$results"
report="$out/report.md"
failures=0

# shellcheck source=/dev/null
source "$repo_root/scripts/automation/smoke-platform.sh"
log() { printf '[test-package] %s\n' "$*"; }

# check NAME DETAIL COMMAND...: record a result line and a report row.
current=""
check() {
  local name="$1" detail="$2"; shift 2
  local status=pass
  if ! "$@" >/dev/null 2>&1; then status=fail; failures=$((failures + 1)); fi
  python3 -c 'import json,sys; print(json.dumps({"package": sys.argv[1], "check": sys.argv[2], "status": sys.argv[3], "detail": sys.argv[4]}))' \
    "$current" "$name" "$status" "$detail" >> "$results"
  printf '| %s | %s | %s |\n' "$( [[ $status == pass ]] && echo PASS || echo '**FAIL**')" "$name" "${detail//|/\\|}" >> "$report.$current"
  log "$current: $status: $name"
  [[ "$status" == pass ]]
}

json_get() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=d[int(k)] if isinstance(d,list) else d[k]
print(d)' "$1" 2>/dev/null; }

# --- One package -------------------------------------------------------------

# test_instance NAME LAUNCHER CLI [launcher args...]
test_instance() {
  current="$1"; local launcher="$2" cli_bin="$3"; shift 3
  local dir="$out/$current"
  mkdir -p "$dir/screenshots" "$dir/transcripts" "$dir/runtime-home" "$dir/artifacts"
  local sock="$dir/toastty.sock" app_log="$dir/app.log"

  if [[ "$real_window" == "0" ]]; then
    toastty_smoke_start_display "$dir/broadwayd.log" || { check "Broadway display starts" "gtk4-broadwayd" false; return; }
  fi
  # Drop the launching agent's and Toastty's own context (an agent running this
  # script sits in a Toastty terminal): TOASTTY_APP_RESOURCES_PATH and the like
  # would point the package at another install.
  local -a clean_env=(env)
  local name
  for name in $(compgen -e); do
    [[ "$name" =~ ^(TOASTTY_|CLAUDE|CODEX_|OPENAI_|ANTHROPIC_) ]] && clean_env+=(-u "$name")
  done
  "${clean_env[@]}" TOASTTY_RUNTIME_HOME="$dir/runtime-home" TOASTTY_SOCKET_PATH="$sock" \
    "$launcher" "$@" --automation --run-id "package-$current" --artifacts-dir "$dir/artifacts" \
    >"$app_log" 2>&1 &
  local app_pid=$!
  cli() { "${clean_env[@]}" "$cli_bin" --json --socket-path "$sock" "$@"; }
  sock_req() { python3 "$repo_root/scripts/linux/socket-request.py" "$sock" "$@"; }
  shot() {
    sleep "${2:-1.5}"
    local path; path="$(sock_req automation.capture_screenshot "{\"step\": \"$1\"}" | json_get result.path)"
    [[ -s "$path" ]] && cp "$path" "$dir/screenshots/$1.png" && echo "$dir/screenshots/$1.png"
  }
  local up=1 i
  for i in $(seq 1 150); do
    [[ -S "$sock" ]] && cli query list >/dev/null 2>&1 && { up=0; break; }
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.2
  done
  check "app launches and its socket answers" "pid $app_pid, $(ps -o args= -p "$app_pid" 2>/dev/null | cut -c1-120)" test "$up" = 0 \
    || { tail -n 30 "$app_log" > "$dir/transcripts/launch-failure.txt"; kill -9 "$app_pid" 2>/dev/null; toastty_smoke_stop_display; return; }
  ps -o pid=,args= -p "$app_pid" > "$dir/transcripts/process.txt"
  local launched; launched="$(shot launched 2)"
  check "window screenshot after launch" "screenshots/launched.png" test -s "$launched"

  # A terminal in a new workspace runs a command.
  local win ws panel marker
  win="$(cli query run workspace.list | json_get result.workspaces.0.windowID)"
  ws="$(cli action run workspace.create --window "$win" title=Package-Test | json_get result.workspaceID)"
  panel="$(cli query run terminal.state --workspace "$ws" | json_get result.panelID)"
  marker="package-test-$RANDOM"
  sleep 1.5
  cli action run terminal.send-text --panel "$panel" "text=echo $marker; echo \"Toastty CLI: \$TOASTTY_CLI_PATH\"; uname -sr; cd '$repo_root'" submit=true >/dev/null
  local seen=1
  for i in $(seq 1 50); do
    cli query run terminal.visible-text --panel "$panel" > "$dir/transcripts/terminal.json"
    [[ "$(grep -o "$marker" "$dir/transcripts/terminal.json" | wc -l)" -ge 2 ]] && { seen=0; break; }
    sleep 0.2
  done
  json_get result.text < "$dir/transcripts/terminal.json" > "$dir/transcripts/terminal.txt"
  check "a terminal opens and runs a command" "echo $marker round-trip; transcripts/terminal.txt" test "$seen" = 0
  shot terminal >/dev/null

  # Managed agents.
  local agent
  for agent in ${agents//,/ }; do
    command -v "$agent" >/dev/null || { check "$agent launches" "$agent is not on PATH" false; continue; }
    local tab apanel
    tab="$(cli action run workspace.tab.create --workspace "$ws" | json_get result.tabID)"
    apanel="$(cli query run terminal.state --workspace "$ws" | json_get result.panelID)"
    sleep 1.5
    cli action run terminal.send-text --panel "$apanel" "text=cd '$repo_root'" submit=true >/dev/null
    sleep 0.5
    cli action run agent.launch --panel "$apanel" "profileID=$agent" > "$dir/transcripts/$agent-launch.json"
    local session
    session="$(json_get result.sessionID < "$dir/transcripts/$agent-launch.json")"
    # The TUI is up once its banner is drawn. If Codex still offers an update,
    # Esc skips it; never Enter, which accepts "Update now".
    local ready=1 banner
    case "$agent" in
      claude) banner='Claude Code v[0-9]' ;;
      codex) banner='OpenAI Codex \(v[0-9]' ;;
      *) banner="$agent" ;;
    esac
    for i in $(seq 1 100); do
      cli query run terminal.visible-text --panel "$apanel" > "$dir/transcripts/$agent.json"
      if grep -q 'Update available' "$dir/transcripts/$agent.json" && grep -q 'Skip' "$dir/transcripts/$agent.json"; then
        shot "$agent-update-offer" 0.5 >/dev/null
        cli action run terminal.send-text --panel "$apanel" "text=$(printf '\033')" submit=false >/dev/null
        sleep 1
        continue
      fi
      if grep -qE "$banner" "$dir/transcripts/$agent.json"; then ready=0; break; fi
      sleep 0.4
    done
    sleep 2
    check "$agent launches as a managed agent" "session ${session:-none}; transcripts/$agent-launch.json" test -n "$session"
    check "$agent draws its interface in the terminal" "transcripts/$agent.txt" test "$ready" = 0
    shot "$agent-launched" >/dev/null
    if [[ "$prompt" == "1" && "$ready" == "0" ]]; then
      # The session status the sidebar shows, from the automation state dump:
      # "<kind>|<detail>" for this agent's session.
      session_status() {
        local dump
        dump="$(sock_req automation.dump_state '{"includeRuntime": true}' | json_get result.path)"
        [[ -s "$dump" ]] || return 0
        python3 -c 'import json,sys
s=json.load(open(sys.argv[1]))["sessionRegistry"]["sessionsByID"].get(sys.argv[2]) or {}
st=s.get("status") or {}
print("%s|%s" % (st.get("kind",""), st.get("detail","")))' "$dump" "$session" 2>/dev/null
        rm -f "$dump"
      }
      local word="PONG$RANDOM" answered=1 saw_working=1 status="" history=""
      cli action run terminal.send-text --panel "$apanel" "text=Reply with only the word $word and nothing else. Do not run any tools." submit=false >/dev/null
      sleep 0.5
      cli action run terminal.send-text --panel "$apanel" "text=" submit=true >/dev/null
      for i in $(seq 1 150); do
        status="$(session_status)"
        [[ "$history" == *"${status%%|*}"* ]] || history+="${status%%|*} "
        [[ "$status" == working* ]] && saw_working=0
        cli query run terminal.visible-text --panel "$apanel" > "$dir/transcripts/$agent.json"
        [[ "$(grep -o "$word" "$dir/transcripts/$agent.json" | wc -l)" -ge 2 ]] && { answered=0; break; }
        sleep 0.4
      done
      check "$agent answers a prompt" "asked for $word; transcripts/$agent.txt" test "$answered" = 0
      # The agent's hooks report the turn: working while it answers, then
      # idle or ready with the reply as the detail.
      local reported=1
      for i in $(seq 1 60); do
        status="$(session_status)"
        [[ "$history" == *"${status%%|*}"* ]] || history+="${status%%|*} "
        [[ "$status" == working* ]] && saw_working=0
        if [[ "$status" =~ ^(idle|ready)\| && "$status" == *"$word"* ]]; then reported=0; break; fi
        sleep 0.5
      done
      echo "$status" > "$dir/transcripts/$agent-status.txt"
      local hook_note=""
      if [[ "$reported" != 0 && "$agent" == codex ]]; then
        # Codex can run hooks in its app-server daemon, which keeps the
        # TOASTTY_* environment of the managed session that started it.
        local daemon_pid daemon_socket
        for daemon_pid in $(pgrep -u "$(id -u)" -f 'codex app-server'); do
          daemon_socket="$(tr '\0' '\n' < "/proc/$daemon_pid/environ" 2>/dev/null | sed -n 's/^TOASTTY_SOCKET_PATH=//p')"
          [[ -n "$daemon_socket" && "$daemon_socket" != "$sock" ]] \
            && hook_note="; Codex daemon pid $daemon_pid reports to $daemon_socket"
        done
      fi
      check "$agent session shows working while it answers" "statuses seen: ${history% }$hook_note" test "$saw_working" = 0
      check "$agent hooks report the reply to Toastty" "final status: ${status:-none}$hook_note" test "$reported" = 0
      shot "$agent-answered" >/dev/null
    fi
    json_get result.text < "$dir/transcripts/$agent.json" > "$dir/transcripts/$agent.txt"
  done

  # Quit cleanly. An AppImage runs the app from a FUSE mount whose helper
  # process must unmount and exit after the app quits.
  local mount_dir=""
  mount_dir="$(readlink "/proc/$app_pid/exe" 2>/dev/null)"
  [[ "$mount_dir" == /tmp/.mount_* ]] && mount_dir="${mount_dir%%/usr/lib/toastty/*}" || mount_dir=""
  kill -TERM "$app_pid" 2>/dev/null
  local quit=1
  for i in $(seq 1 50); do kill -0 "$app_pid" 2>/dev/null || { quit=0; break; }; sleep 0.2; done
  [[ "$quit" == 0 ]] || kill -9 "$app_pid" 2>/dev/null
  check "app quits on SIGTERM" "within 10 s" test "$quit" = 0
  if [[ -n "$mount_dir" ]]; then
    local unmounted=1
    for i in $(seq 1 50); do mountpoint -q "$mount_dir" || { unmounted=0; break; }; sleep 0.2; done
    check "AppImage unmounts after the app quits" "$mount_dir" test "$unmounted" = 0 \
      || { fusermount3 -u -z "$mount_dir" 2>/dev/null || fusermount -u -z "$mount_dir" 2>/dev/null; }
  fi
  check "log has no crash or GL/WebKit renderer errors" "app.log" \
    bash -c "! grep -iE 'fatal error|segmentation|backtrace|failed to create.*(gl|egl)|GLib-CRITICAL|WebKit.*(crash|error)' '$app_log'"
  toastty_smoke_stop_display
}

# --- .deb --------------------------------------------------------------------

for deb in "${debs[@]}"; do
  current="deb"
  printf '| Result | Check | Detail |\n|---|---|---|\n' > "$report.$current"
  version="$(dpkg-deb -f "$deb" Version)"
  if [[ "$installed_deb" == "1" ]]; then
    installed="$(dpkg-query -W -f='${Version}' toastty 2>/dev/null)"
    check "package is installed (dpkg)" "toastty $installed, built $version" test "$installed" = "$version" || continue
    check "desktop entry installed" "/usr/share/applications/com.GiantThings.toastty.desktop" \
      desktop-file-validate /usr/share/applications/com.GiantThings.toastty.desktop
    bin=/usr/lib/toastty/bin
  else
    apt-get install --simulate "$deb" > "$out/deb-apt-simulate.txt" 2>&1
    check "dependencies resolve (apt-get install --simulate)" "deb-apt-simulate.txt" \
      grep -q "^Inst toastty" "$out/deb-apt-simulate.txt"
    root="$out/deb/root"
    rm -rf "$root"; mkdir -p "$root"
    dpkg-deb -x "$deb" "$root"
    check "package extracts" "dpkg-deb -x into deb/root" test -x "$root/usr/lib/toastty/bin/toastty-linux"
    check "desktop entry validates" "usr/share/applications/com.GiantThings.toastty.desktop" \
      desktop-file-validate "$root/usr/share/applications/com.GiantThings.toastty.desktop"
    bin="$root/usr/lib/toastty/bin"
  fi
  test_instance deb "$bin/toastty-linux" "$bin/toastty"
done

# --- AppImage ----------------------------------------------------------------

for image in "${appimages[@]}"; do
  current="appimage"
  printf '| Result | Check | Detail |\n|---|---|---|\n' > "$report.$current"
  # "Install" the way users do: copy it somewhere and make it executable.
  apps="$out/appimage/Applications"
  mkdir -p "$apps"
  installed_image="$apps/$(basename "$image")"
  cp "$image" "$installed_image"
  chmod +x "$installed_image"
  update_info="$("$installed_image" --appimage-updateinformation 2>/dev/null)"
  check "update information points at GitHub Releases" "$update_info" grep -q '^gh-releases-zsync|' <<<"$update_info"
  check "zsync file sits next to the AppImage" "$(basename "$image").zsync" test -s "$image.zsync"
  mkdir -p "$out/appimage/extract"
  (cd "$out/appimage/extract" && "$installed_image" --appimage-extract >/dev/null 2>&1)
  cli_bin="$out/appimage/extract/squashfs-root/usr/lib/toastty/bin/toastty"
  # Launch the AppImage file itself (FUSE mount), as a user would.
  test_instance appimage "$installed_image" "$cli_bin"
done

# --- Report ------------------------------------------------------------------

{
  echo "# Linux package test"
  echo
  echo "- Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Host: $(. /etc/os-release && echo "$PRETTY_NAME"), glibc $(ldd --version | head -n1 | awk '{print $NF}')"
  echo "- Display: $([[ $real_window == 1 ]] && echo "real window (${XDG_SESSION_TYPE:-unknown})" || echo "private Broadway display")"
  echo "- Agents: ${agents:-none}$([[ $prompt == 1 ]] && echo ", with a one-word prompt")"
  for f in "${debs[@]}" "${appimages[@]}"; do echo "- Package: ${f#"$repo_root/"}"; done
  for name in deb appimage; do
    [[ -f "$report.$name" ]] || continue
    echo; echo "## $name"; echo
    cat "$report.$name"
    rm -f "$report.$name"
  done
} > "$report"
python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in open(sys.argv[1])], indent=2))' "$results" > "$out/results.json"
rm -f "$results"
log "report: ${out#"$repo_root/"}/report.md ($failures failed)"
[[ "$failures" == 0 ]]
