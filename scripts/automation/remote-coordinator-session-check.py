#!/usr/bin/env python3
"""Start the coordinator in a disposable app, end it, and restart the app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-session-check.py'.

The check starts its own second instance of the wrapper's build with a
throwaway runtime home and user home, and TOASTTY_COORDINATOR_AUTOSTART=1,
because a runtime-isolated run does not start the coordinator by default. Its
`agents.toml` maps `claude` to a fake agent script that records its first
message and exits when it reads a line `quit`. No real agent runs. The check
never selects a workspace or moves focus.

It checks that:
- Toastty starts the default agent at launch, once, in one hidden Coordinator
  workspace, in the user home, with `Use the toastty-coordinator skill.`, and
  creates routing.md;
- the visible workspace keeps its selection;
- `toastty coordinator post` from outside any agent session appends a card to
  events.jsonl, and a bad card is refused;
- when the agent exits, Toastty starts a fresh session in the same terminal;
- after the app is killed and relaunched, there is still exactly one
  coordinator workspace, and the coordinator runs again.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


create_check = _load('remote_task_create_check', 'remote-task-create-check.py')
require, wait_for, Instance = create_check.require, create_check.wait_for, create_check.Instance

PREFIX = 'remote-coordinator-session'
FIRST_MESSAGE = 'Use the toastty-coordinator skill.'

# Records the first message (the last argument) and the session, then waits
# for a line `quit`.
FAKE_AGENT = r'''#!/bin/sh
case "$1" in
  --version) echo "2.1.288 (Claude Code)"; exit 0 ;;
  plugin|mcp|config) exit 0 ;;
esac
for argument in "$@"; do message="$argument"; done
dir="$(dirname "$0")/sessions"; mkdir -p "$dir"
printf '%s' "$message" > "$dir/$TOASTTY_SESSION_ID.message"
printf '{"sessionID":"%s","panelID":"%s","cwd":"%s"}\n' "$TOASTTY_SESSION_ID" "$TOASTTY_PANEL_ID" "$PWD" > "$dir/$TOASTTY_SESSION_ID.json"
while IFS= read -r line; do
  [ "$line" = quit ] && exit 0
done
'''


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-coordinator-check-', dir='/tmp')).resolve()
    runtime_home, user_home, fake_bin = root / 'runtime-home', root / 'user-home', root / 'bin'
    for directory in (runtime_home, user_home / '.toastty', fake_bin):
        directory.mkdir(parents=True)
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT)
    agent.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    sessions_dir = fake_bin / 'sessions'

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL=PREFIX,
        TOASTTY_SOCKET_PATH=socket_path,
        TOASTTY_COORDINATOR_AUTOSTART='1',
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    cli_environment = {key: value for key, value in environment.items() if key != 'TOASTTY_COORDINATOR_AUTOSTART'}
    evidence = dict(status='failed', steps=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, **facts))
        print(f'[coordinator-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_cli(*arguments):
        result = subprocess.run([str(cli), '--json', '--socket-path', socket_path, *arguments],
                                env=cli_environment, capture_output=True, text=True, timeout=60)
        return result.returncode, result.stdout, result.stderr

    def coordinator_workspaces():
        return [w for w in instance.query('workspace.list')['workspaces'] if w['isCoordinator']]

    def running_status(excluding=()):
        status = instance.query('coordinator.status')
        if status['state'] == 'failed':
            raise AssertionError(f'The coordinator failed: {status}')
        if status['state'] == 'running' and status['sessionID'] not in excluding:
            return status
        return None

    def recorded_message(session_id):
        path = sessions_dir / f'{session_id}.message'
        return path.is_file() and path.read_text()

    app_log = artifacts / f'{PREFIX}-app.log'
    instance = Instance(binary, environment, socket_path, runtime_home, app_log)
    try:
        workspaces = instance.wait_until_ready()
        visible_id = workspaces[0]['workspaceID']

        # 1. The coordinator starts at launch in its own hidden workspace.
        first = wait_for('the coordinator to run', running_status)
        message = wait_for('the fake agent to record its first message', lambda: recorded_message(first['sessionID']))
        require(message == FIRST_MESSAGE, f'Unexpected first message: {message!r}')
        session = json.loads((sessions_dir / f"{first['sessionID']}.json").read_text())
        require(os.path.realpath(session['cwd']) == str(user_home), f'The coordinator did not start in the home: {session}')
        require(session['panelID'].lower() == first['panelID'].lower(), f'Wrong panel: {session} {first}')
        hidden = coordinator_workspaces()
        require([w['workspaceID'] for w in hidden] == [first['workspaceID']], f'Expected one coordinator workspace: {hidden}')
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        require(listed[visible_id]['isSelected'], 'The visible workspace lost selection')
        routing = Path(first['routingFile'])
        require(routing.is_file() and str(routing.resolve()).startswith(str(runtime_home)),
                f'routing.md missing or outside the runtime home: {routing}')
        # A running coordinator is left alone: no second launch follows.
        time.sleep(5)
        launched = sorted(path.stem for path in sessions_dir.glob('*.json'))
        require(launched == [first['sessionID']], f'Expected one launch, got {launched}')
        require(running_status() == first, f'The coordinator changed while it ran: {instance.query("coordinator.status")}')
        step('started', sessionID=first['sessionID'], workspaceID=first['workspaceID'], routing=str(routing))

        # 2. Cards from outside any agent session go to events.jsonl.
        code, out, err = run_cli('coordinator', 'post', 'note', 'Checking the coordinator.')
        require(code == 0, f'coordinator post failed ({code}): {out} {err}')
        code, out, err = run_cli('coordinator', 'post', 'packet')
        require(code != 0 and '--task' in (out + err), f'A packet card without a task was accepted: {out} {err}')
        lines = Path(first['eventsFile']).read_text().splitlines()
        require(len(lines) == 1 and json.loads(lines[0])['kind'] == 'note', f'Unexpected events: {lines}')
        step('posted a card', event=json.loads(lines[0]))

        # 3. When the agent exits, a fresh session starts in the same terminal.
        response = instance.request('app_control.run_action', dict(
            id='terminal.send-text', args=dict(panelID=first['panelID'], text='quit', submit=True)))
        require(response.get('ok'), f'Could not type into the coordinator terminal: {response}')
        second = wait_for('a fresh coordinator session', lambda: running_status(excluding=(first['sessionID'],)), timeout=90, interval=1)
        require(second['panelID'] == first['panelID'], f'The fresh session moved terminals: {first} {second}')
        message = wait_for('the fresh session to record its message', lambda: recorded_message(second['sessionID']))
        require(message == FIRST_MESSAGE, f'The fresh session did not get the skill line: {message!r}')
        step('restarted after exit', sessionID=second['sessionID'])

        # 4. Kill and relaunch: one coordinator workspace, running again.
        instance.kill()
        step('killed')
        instance = Instance(binary, environment, socket_path, runtime_home, app_log)
        instance.wait_until_ready()
        third = wait_for('the coordinator after relaunch', running_status, timeout=90, interval=1)
        hidden = coordinator_workspaces()
        require(len(hidden) == 1 and hidden[0]['workspaceID'] == third['workspaceID'],
                f'Relaunch did not keep one coordinator workspace: {hidden} {third}')
        step('relaunched', sessionID=third['sessionID'], workspaceID=third['workspaceID'],
             sameWorkspace=third['workspaceID'] == first['workspaceID'])

        evidence['status'] = 'passed'
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / f'{PREFIX}-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[coordinator-check] passed', flush=True)


if __name__ == '__main__':
    main()
