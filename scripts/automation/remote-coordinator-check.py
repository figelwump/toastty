#!/usr/bin/env python3
"""Open, message, restart and restore the coordinator in a real app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-check.py'. Add
'--provider claude --gui-session' to run the message steps against the real,
authenticated Claude CLI; that run uses subscription usage.

The check starts its own instances of the wrapper's build, each with a
throwaway runtime home and user home. It never selects another app's window
or moves focus, and it does not touch the installed production app.

With the default fake agent, a shell script stands in for Claude Code: it
reports its start as Claude's SessionStart hook does, reports a turn for each
line it reads, and can hold a turn open. Through the real CLI the check then
proves that:
- `coordinator open` creates one workspace named Coordinator, with a
  terminal in <runtime home>/coordinator, and starts the agent
  with the model and effort from the [coordinator] table of tasks.toml; a
  second open starts nothing;
- `coordinator send` types at an open prompt, queues while a turn runs, and
  then types one entry for each prompt, in order;
- the coordinator is in no task list or workspace choice, and a task it
  creates has no parent task and waits for a workspace;
- `coordinator restart` ends a running agent and starts a fresh session in a
  new terminal of the same workspace;
- a message sent while no agent runs is typed after `coordinator open`
  starts one;
- after the app is killed and relaunched with another workspace selected,
  the coordinator's workspace is restored, its agent is resumed, and a
  message reaches it;
- closing the workspace removes the coordinator and keeps its folder.
A second instance in automation mode, which can render its own window over
SSH, captures the sidebar with the pinned row in the Projects and the Status
segment. A capture that cannot be made is recorded, not failed.

With '--provider claude', the check proves with the real CLI that pasted text
plus Return submits a turn, that a message sent during a turn is typed after
it, and that the resumed conversation takes a message after a relaunch.

Evidence goes to remote-coordinator-check-<provider>.json, the app logs and
the captures in the artifacts directory.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


base = load('task_create_check', 'remote-task-create-check.py')
require, wait_for, Instance = base.require, base.wait_for, base.Instance

MODEL = 'claude-opus-5-5'
EFFORT = 'high'

# Reads one message for each line. A turn lasts a second, or as long as the
# `hold` file exists. `/exit` ends the agent. The line that Toastty puts
# before the text of `coordinator send` belongs to the message after it.
FAKE_AGENT = r'''#!/bin/sh
case "$1" in
  --version) echo "2.1.288 (Claude Code)"; exit 0 ;;
  plugin|mcp|config) exit 0 ;;
esac
dir="$(dirname "$0")/coordinator"; mkdir -p "$dir"
native=""; previous=""
for argument in "$@"; do
  [ "$previous" = "--resume" ] && native="$argument"
  previous="$argument"
done
resumed=false
if [ -n "$native" ]; then resumed=true; else native="$(uuidgen | tr 'A-Z' 'a-z')"; fi
transcript="$dir/$native.jsonl"; touch "$transcript"
printf '%s\n' "$@" > "$dir/$TOASTTY_SESSION_ID.argv"
printf '{"sessionID":"%s","panelID":"%s","cwd":"%s","native":"%s","resumed":%s}\n' \
  "$TOASTTY_SESSION_ID" "$TOASTTY_PANEL_ID" "$PWD" "$native" "$resumed" > "$dir/$TOASTTY_SESSION_ID.json"
status() { "$TOASTTY_CLI_PATH" session status --session "$TOASTTY_SESSION_ID" --kind "$1" --summary "$2" >/dev/null 2>&1; }
printf '{"hook_event_name":"SessionStart","session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$native" "$transcript" "$PWD" \
  | "$TOASTTY_CLI_PATH" session ingest-agent-event --source claude-hooks --session "$TOASTTY_SESSION_ID" --panel "$TOASTTY_PANEL_ID" >/dev/null 2>&1
status idle Waiting
while IFS= read -r line; do
  [ "$line" = "/exit" ] && exit 0
  case "$line" in
    "[Toastty] From "*) printf '%s\n' "$line" >> "$dir/senders.log"; continue ;;
  esac
  status working Working
  printf '%s\t%s\n' "$TOASTTY_SESSION_ID" "$line" >> "$dir/received.log"
  while [ -f "$dir/hold" ]; do sleep 0.2; done
  sleep 1
  status idle Waiting
done
'''


class Check:
    def __init__(self, provider):
        self.provider = provider
        self.bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
        self.artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
        self.binary = self.bundle / 'Contents/MacOS/Toastty'
        self.cli = self.bundle / 'Contents/Helpers/toastty'
        require(self.binary.is_file() and self.cli.is_file(), f'No Toastty binary or CLI in {self.bundle}')
        self.prefix = f'remote-coordinator-check-{provider}'
        self.evidence = dict(status='failed', provider=provider, steps=[], captures=[])
        self.root = Path(tempfile.mkdtemp(prefix='toastty-coordinator-check-', dir='/tmp')).resolve()
        self.evidence['root'] = str(self.root)

    def step(self, name, **facts):
        self.evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[coordinator-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def home(self, name, agent_argv):
        """A throwaway runtime home and user home whose `claude` profile runs `agent_argv`."""
        runtime_home, user_home = self.root / name / 'runtime-home', self.root / name / 'user-home'
        for directory in (runtime_home, user_home / '.toastty'):
            directory.mkdir(parents=True)
        (user_home / '.toastty/agents.toml').write_text(
            f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps(agent_argv)}\n')
        (user_home / '.toastty/tasks.toml').write_text(
            f'[defaults]\nagent = "claude"\n\n[coordinator]\nmodel = "{MODEL}"\neffort = "{EFFORT}"\n')
        return runtime_home, user_home

    def environment(self, name, runtime_home, user_home, real_home=False, **extra):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith('TOASTTY_')
                       and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT')}
        environment.update(
            TOASTTY_RUNTIME_HOME=str(runtime_home),
            TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
            TOASTTY_RUNTIME_LABEL=f'{self.prefix}-{name}',
            TOASTTY_SOCKET_PATH=str(self.root / name / 'socket.sock'),
            CFFIXED_USER_HOME=str(user_home),
            DISABLE_AUTOUPDATER='1',
            **extra,
        )
        # Real Claude keeps the host login, which lives under the real home.
        if not real_home:
            environment['HOME'] = str(user_home)
        return environment

    def cli_runner(self, environment):
        def run(*arguments, session=None):
            env = dict(environment, TOASTTY_SESSION_ID=session) if session else environment
            return subprocess.run([str(self.cli), '--json', *arguments], env=env,
                                  capture_output=True, text=True, timeout=180)

        def result(*arguments, session=None):
            completed = run(*arguments, session=session)
            require(completed.returncode == 0,
                    f'toastty {" ".join(arguments)} failed: {completed.stdout} {completed.stderr}')
            return json.loads(completed.stdout).get('result') or {} if completed.stdout.strip() else {}

        return run, result

    def copy_instance_log(self, runtime_home, name):
        log = runtime_home / 'logs/toastty.log'
        if log.exists():
            shutil.copyfile(log, self.artifacts / f'{self.prefix}-{name}-instance.log')

    def finish(self):
        (self.artifacts / f'{self.prefix}.json').write_text(json.dumps(self.evidence, indent=2, default=str))
        shutil.rmtree(self.root, ignore_errors=True)


def coordinator_workspaces(instance):
    return [w for w in instance.query('workspace.list')['workspaces'] if w['title'] == 'Coordinator']


def wait_for_layout(runtime_home, *needles):
    """Waits until the saved layout names every needle, so a kill loses nothing."""
    layout = runtime_home / 'workspace-layout-profiles.json'

    def saved():
        text = layout.read_text().lower() if layout.is_file() else ''
        return all(needle.lower() in text for needle in needles)

    wait_for(f'the saved layout to hold {needles}', saved, timeout=30)


# MARK: - Fake agent


def run_fake(check):
    fake_bin = check.root / 'bin'
    fake_bin.mkdir()
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT)
    agent.chmod(0o755)
    records = fake_bin / 'coordinator'
    runtime_home, user_home = check.home('main', [str(agent)])
    environment = check.environment('main', runtime_home, user_home)
    run_cli, cli = check.cli_runner(environment)
    socket_path = environment['TOASTTY_SOCKET_PATH']
    app_log = check.artifacts / f'{check.prefix}-app.log'
    instance = Instance(check.binary, environment, socket_path, runtime_home, app_log)
    step = check.step

    def status():
        return cli('coordinator', 'status')

    def received():
        log = records / 'received.log'
        return [line.split('\t', 1)[1] for line in log.read_text().splitlines()] if log.is_file() else []

    def session_record(session_id):
        path = records / f'{session_id}.json'
        return json.loads(wait_for(f'the agent to record session {session_id}', lambda: path.is_file() and path.read_text()))

    def at_prompt():
        current = status()
        return current.get('status') == 'idle' and current.get('agentState') == 'running' and current

    def send(text):
        return cli('coordinator', 'send', text)

    def send_at_prompt(text):
        wait_for('the prompt to be open', at_prompt)
        # A turn that just ended holds the prompt for its settle time.
        time.sleep(1.5)
        answer = send(text)
        require(answer['delivery'] == 'sent', f'{text!r} was not typed at the open prompt: {answer} {status()}')
        wait_for(f'{text!r} to reach the agent', lambda: text in received())
        return answer

    try:
        workspaces = instance.wait_until_ready()
        project_id, window_id = workspaces[0]['workspaceID'], workspaces[0]['windowID']
        require(status() == dict(exists=False, queuedCount=0), f'A new instance has a coordinator: {status()}')
        actions = subprocess.run([str(check.cli), 'action', 'list'], env=environment, capture_output=True, text=True, timeout=60).stdout
        require(all(name in actions for name in ('coordinator.open', 'coordinator.restart', 'coordinator.send')),
                'The coordinator actions are not listed')
        step('booted', projectWorkspace=project_id)

        # 1. Open creates the workspace and starts the agent.
        opened = cli('coordinator', 'open')
        require(opened['createdWorkspace'] and opened['startedAgent'] and opened['agentState'] == 'running',
                f'Open did not start the coordinator: {opened}')
        workspace_id, panel_id, session_id = opened['workspaceID'], opened['panelID'], opened['sessionID']
        listed = coordinator_workspaces(instance)
        require(len(listed) == 1 and listed[0]['workspaceID'] == workspace_id,
                f'Expected one Coordinator workspace: {listed}')
        require(listed[0]['isSelected'], 'Open did not select the coordinator')
        record = session_record(session_id)
        directory = runtime_home / 'coordinator'
        require(os.path.realpath(record['cwd']) == str(directory), f'The agent did not start in {directory}: {record}')
        argv = (records / f'{session_id}.argv').read_text().split('\n')
        require(MODEL in argv and EFFORT in argv, f'The [coordinator] model and effort are not in the command: {argv}')
        step('open created the coordinator', opened=opened, cwd=record['cwd'], argv=argv)

        again = cli('coordinator', 'open', '--no-select')
        require(not again['createdWorkspace'] and not again['startedAgent'] and again['sessionID'] == session_id,
                f'A second open started something: {again}')
        require(len(coordinator_workspaces(instance)) == 1, 'A second open made a second workspace')
        step('a second open only selects', again=again)

        # 2. Send at an open prompt, then queue during a turn.
        send_at_prompt('wake one')
        # The check's shell names no session, and the first line says so.
        senders = (records / 'senders.log').read_text().splitlines()
        require(senders == ['[Toastty] From a terminal command: Toastty cannot tell who ran it.'],
                f'coordinator send did not name its sender: {senders}')
        step('sent at the open prompt', received=received(), senders=senders)
        (records / 'hold').write_text('')
        send_at_prompt('turn A')
        wait_for('the held turn to run', lambda: status().get('status') == 'working')
        first, second = send('queued 1'), send('queued 2')
        require(first['delivery'] == 'queued' and first['position'] == 1 and first['hold'] in ('busy', 'awaitingTurn'),
                f'A message during a turn was not queued: {first}')
        require(second['delivery'] == 'queued' and second['position'] == 2, f'Unexpected second answer: {second}')
        time.sleep(3)
        require(received() == ['wake one', 'turn A'], f'A queued message was typed during the turn: {received()}')
        held = status()
        require(held['queuedCount'] == 2 and held['hold'] == 'busy', f'Unexpected status during the turn: {held}')
        step('queued during a turn', answers=[first, second], status=held)
        (records / 'hold').unlink()
        wait_for('the first queued message', lambda: received() == ['wake one', 'turn A', 'queued 1'])
        between = status()
        wait_for('the second queued message', lambda: received() == ['wake one', 'turn A', 'queued 1', 'queued 2'])
        wait_for('the queue to empty', lambda: status()['queuedCount'] == 0 and at_prompt())
        step('one entry for each prompt, in order', received=received(), afterFirst=between)

        # 3. Not a task, and not a place for one.
        tasks = cli('task', 'list')['tasks']
        require(tasks == [], f'The coordinator is listed as a task: {tasks}')
        choices = cli('task', 'workspace-choices')
        require([w['workspaceID'] for w in choices['open']] == [project_id], f'Unexpected workspace choices: {choices}')
        created = cli('task', 'create', 'Tidy the changelog', session=session_id)
        require(created.get('parentTaskID') is None and created.get('workspaceID') is None
                and created['setup']['state'] == 'needsWorkspace', f'Unexpected task from the coordinator: {created}')
        refused = run_cli('task', 'create', 'x', '--workspace', workspace_id)
        require(refused.returncode != 0 and 'not a project' in refused.stdout + refused.stderr,
                f'A task was placed in the coordinator: {refused.stdout} {refused.stderr}')
        cli('task', 'delete', created['taskID'])
        step('not a task', taskFromCoordinator=created, choices=choices)

        # 4. Restart while the agent runs.
        restarted = cli('coordinator', 'restart')
        require(restarted['workspaceID'] == workspace_id and restarted['sessionID'] != session_id
                and restarted['panelID'] != panel_id and restarted['startedAgent'],
                f'Restart did not start a fresh session in a new terminal: {restarted}')
        require(session_record(restarted['sessionID'])['resumed'] is False, 'Restart resumed the old conversation')
        require(len(coordinator_workspaces(instance)) == 1, 'Restart made a second workspace')
        wait_for('the restarted agent at its prompt', at_prompt)
        send_at_prompt('after restart')
        step('restart started a fresh session', restarted=restarted, received=received())

        # 5. A message sent while no agent runs waits for Open.
        wait_for('the prompt to be open', at_prompt)
        instance.request('app_control.run_action', dict(id='terminal.send-text', args=dict(
            panelID=restarted['panelID'], text='/exit', submit=True)))
        wait_for('the agent to exit', lambda: status()['agentState'] == 'notRunning', timeout=30)
        waiting = send('while you were out')
        require(waiting['delivery'] == 'queued' and waiting['hold'] == 'noSession', f'Unexpected answer with no agent: {waiting}')
        reopened = cli('coordinator', 'open', '--no-select')
        require(reopened['startedAgent'] and not reopened['createdWorkspace'] and reopened['panelID'] == restarted['panelID'],
                f'Open did not start the agent again in the same terminal: {reopened}')
        wait_for('the waiting message', lambda: received()[-1] == 'while you were out')
        step('a message with no agent waits for Open', waiting=waiting, reopened=reopened, received=received())

        # 6. Kill and relaunch: the workspace is restored and the agent resumed.
        native = session_record(reopened['sessionID'])['native']
        (directory / 'policy.md').write_text('# Coordinator policy\n')
        wait_for('the prompt to be open', at_prompt)
        # The coordinator is in the background at the kill, so the relaunch
        # must resume its agent without showing its terminal.
        instance.request('app_control.run_action', dict(id='workspace.select', args=dict(workspaceID=project_id)))
        wait_for('the project to be selected', lambda: coordinator_workspaces(instance)[0]['isSelected'] is False)
        wait_for_layout(runtime_home, '"isCoordinator"', native)
        time.sleep(2)
        before = status()
        instance.kill()
        step('killed', status=before)
        instance = Instance(check.binary, environment, socket_path, runtime_home, app_log)
        instance.wait_until_ready()
        restored = status()
        require(restored['exists'] and restored['workspaceID'] == workspace_id and restored['panelID'] == before['panelID'],
                f'The coordinator was not restored: {restored}')
        listed = coordinator_workspaces(instance)
        require(len(listed) == 1 and listed[0]['workspaceID'] == workspace_id and listed[0]['isSelected'] is False,
                f'Expected the restored Coordinator workspace, in the background: {listed}')
        resumed = wait_for('the agent to be resumed', lambda: (s := status()).get('sessionID') and s, timeout=90)
        require(resumed['sessionID'] != before['sessionID'], 'The resumed agent should have a new session')
        resumed_record = session_record(resumed['sessionID'])
        require(resumed_record['resumed'] is True and resumed_record['native'] == native,
                f'The agent did not resume its conversation: {resumed_record}')
        send_at_prompt('after relaunch')
        require(cli('task', 'list')['tasks'] == [], 'The relaunch made the coordinator a task')
        step('relaunch restored the coordinator', restored=restored, resumed=resumed, record=resumed_record, received=received())

        # 7. Closing the workspace removes the coordinator; its folder stays.
        instance.request('app_control.run_action', dict(id='workspace.close', args=dict(workspaceID=workspace_id)))
        wait_for('the coordinator to be gone', lambda: status() == dict(exists=False, queuedCount=0))
        refused = run_cli('coordinator', 'send', 'anyone?')
        require(refused.returncode != 0 and 'no coordinator' in refused.stdout + refused.stderr,
                f'Send worked with no coordinator: {refused.stdout} {refused.stderr}')
        require((directory / 'policy.md').is_file(), 'Closing the workspace removed a file in its folder')
        fresh = cli('coordinator', 'open', '--no-select')
        require(fresh['createdWorkspace'] and fresh['workspaceID'] != workspace_id, f'Open did not make a new coordinator: {fresh}')
        step('closing removes the coordinator', fresh=fresh)
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        check.copy_instance_log(runtime_home, 'main')

    capture_sidebar(check, agent)


def capture_sidebar(check, agent):
    """Evidence only: the pinned row in a window that can render itself."""
    runtime_home, user_home = check.home('capture', [str(agent)])
    environment = check.environment(
        'capture', runtime_home, user_home,
        TOASTTY_AUTOMATION='1', TOASTTY_RUN_ID='coordinator', TOASTTY_ARTIFACTS_DIR=str(check.artifacts))
    _, cli = check.cli_runner(environment)
    instance = Instance(check.binary, environment, environment['TOASTTY_SOCKET_PATH'], runtime_home,
                        check.artifacts / f'{check.prefix}-capture-app.log')

    def capture(name):
        path = check.artifacts / f'{name}.png'
        time.sleep(1)
        response = instance.request('automation.capture_screenshot', dict(step=name, path=str(path)))
        if not response.get('ok'):
            check.step('capture unavailable', file=path.name, error=response.get('error'))
            return
        if Path(response['result']['path']) != path:
            shutil.copyfile(response['result']['path'], path)
        check.evidence['captures'].append(path.name)
        check.step('captured', file=path.name)

    try:
        workspaces = instance.wait_until_ready()
        window_id = workspaces[0]['windowID']
        opened = cli('coordinator', 'open', '--no-select')
        wait_for('the agent at its prompt', lambda: cli('coordinator', 'status').get('status') == 'idle')
        capture('coordinator-pinned-projects')
        (agent.parent / 'coordinator/hold').write_text('')
        time.sleep(1.5)
        cli('coordinator', 'send', 'hold this turn')
        wait_for('the turn to run', lambda: cli('coordinator', 'status').get('status') == 'working')
        capture('coordinator-pinned-working')
        cli('action', 'run', 'window.sidebar.set-segment', '--window', window_id, 'segment=status')
        capture('coordinator-pinned-status-segment')
        (agent.parent / 'coordinator/hold').unlink()
        cli('coordinator', 'open')
        wait_for('the turn to end', lambda: cli('coordinator', 'status').get('status') == 'idle')
        capture('coordinator-selected')
        instance.request('app_control.run_action', dict(id='terminal.send-text', args=dict(
            panelID=opened['panelID'], text='/exit', submit=True)))
        wait_for('the agent to exit', lambda: cli('coordinator', 'status')['agentState'] == 'notRunning', timeout=30)
        capture('coordinator-not-running')
    except Exception as error:  # noqa: BLE001 - captures are evidence, not the check
        check.step('capture run stopped', error=repr(error))
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        check.copy_instance_log(runtime_home, 'capture')


# MARK: - Real Claude


def run_claude(check):
    steer = load('queue_steer_check', 'remote-queue-steer-check.py')
    host_environment = {key: value for key, value in os.environ.items()
                        if not key.startswith('TOASTTY_')
                        and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT')}
    claude = shutil.which('claude') or str(Path.home() / '.local/bin/claude')
    require(Path(claude).is_file(), 'Claude CLI is not installed; install and authenticate it on the remote host')
    version = subprocess.check_output([claude, '--version'], text=True, timeout=30, env=host_environment).strip()
    auth = subprocess.run([claude, '--safe-mode', '--setting-sources', '', 'auth', 'status', '--json'],
                          capture_output=True, text=True, timeout=30, env=host_environment)
    require(auth.returncode == 0 and json.loads(auth.stdout).get('loggedIn'),
            'Claude CLI needs an interactive login on the remote host; add --gui-session over SSH')
    check.evidence['cliVersion'] = version

    # Only this disposable app sees the profile. It may run `sleep`, which
    # holds a turn open, and nothing else.
    argv = [claude, '--setting-sources=', '--allowedTools', 'Bash(sleep:*)', '--tools', 'Bash', '--strict-mcp-config']
    runtime_home, user_home = check.home('claude', argv)
    # The real model list is the user's; the check names none.
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')
    environment = check.environment('claude', runtime_home, user_home, real_home=True)
    run_cli, cli = check.cli_runner(environment)
    directory = runtime_home / 'coordinator'
    directory.mkdir(parents=True)
    # Typed text cannot answer the folder-trust dialog, so trust only this
    # run's folder for the run.
    steer.set_directory_trust(directory, True)
    app_log = check.artifacts / f'{check.prefix}-app.log'
    instance = Instance(check.binary, environment, environment['TOASTTY_SOCKET_PATH'], runtime_home, app_log)
    step = check.step

    def status():
        return cli('coordinator', 'status')

    def screen():
        panel = status().get('panelID')
        response = instance.request('app_control.run_query', dict(id='terminal.visible-text', args=dict(panelID=panel)))
        return (response.get('result') or {}).get('text', '') if response.get('ok') else ''

    def replied(marker):
        # The reply is the marker on a line of its own; the request shows it
        # inside a longer line.
        return any(line.strip(' ⏺●•').strip() == marker for line in screen().splitlines())

    def at_prompt():
        current = status()
        return current.get('agentState') == 'running' and current.get('status') in ('idle', 'ready') and current

    try:
        instance.wait_until_ready()
        opened = cli('coordinator', 'open')
        require(opened['startedAgent'] and opened['agentState'] == 'running', f'Open did not start Claude: {opened}')
        step('open started Claude', opened=opened, version=version)

        # 1. Paste plus Return at the first prompt submits a turn.
        # Before Claude reports its start, the message waits in the queue.
        answer = cli('coordinator', 'send', 'Reply with exactly this one word and nothing else: COORDINATOR-ONE')
        step('first message', answer=answer, status=status())
        wait_for('Claude to start the turn', lambda: status().get('status') == 'working' or replied('COORDINATOR-ONE'), timeout=120)
        wait_for('the reply to the first message', lambda: replied('COORDINATOR-ONE'), timeout=180)
        wait_for('the prompt to open again', at_prompt, timeout=120)
        step('paste plus Return submitted a turn', screen=screen()[-1500:])

        # 2. A message sent during a turn is typed after it.
        time.sleep(1.5)
        long_turn = cli('coordinator', 'send',
                        'Run the shell command `sleep 20` with the Bash tool, then reply with exactly: COORDINATOR-TWO')
        require(long_turn['delivery'] == 'sent', f'The message was not typed at the open prompt: {long_turn} {status()}')
        wait_for('the long turn to run', lambda: status().get('status') == 'working', timeout=60)
        queued = cli('coordinator', 'send', 'Reply with exactly this one word and nothing else: COORDINATOR-THREE')
        require(queued['delivery'] == 'queued' and queued['hold'] in ('busy', 'awaitingTurn'),
                f'A message during a turn was not queued: {queued}')
        time.sleep(5)
        require(not replied('COORDINATOR-THREE') and status()['queuedCount'] == 1,
                f'The queued message did not wait: {status()}')
        wait_for('the reply to the long turn', lambda: replied('COORDINATOR-TWO'), timeout=240)
        wait_for('the reply to the queued message', lambda: replied('COORDINATOR-THREE'), timeout=240)
        wait_for('the queue to empty', lambda: status()['queuedCount'] == 0 and at_prompt(), timeout=120)
        step('a message during a turn was typed after it', queued=queued, screen=screen()[-2500:])

        # 3. Kill and relaunch: the conversation is resumed and takes a message.
        before = status()
        wait_for_layout(runtime_home, '"isCoordinator"', '"resumeRecord"')
        instance.kill()
        instance = Instance(check.binary, environment, environment['TOASTTY_SOCKET_PATH'], runtime_home, app_log)
        instance.wait_until_ready()
        restored = status()
        require(restored['exists'] and restored['workspaceID'] == before['workspaceID'], f'Not restored: {restored}')
        resumed = wait_for('Claude to be resumed', lambda: (s := status()).get('sessionID') and s, timeout=120)
        require(resumed['sessionID'] != before['sessionID'], 'The resumed agent should have a new session')
        answer = cli('coordinator', 'send', 'Reply with exactly this one word and nothing else: COORDINATOR-FOUR')
        wait_for('the reply after the relaunch', lambda: replied('COORDINATOR-FOUR'), timeout=240)
        step('the resumed conversation took a message', resumed=resumed, answer=answer, screen=screen()[-1500:])
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        check.copy_instance_log(runtime_home, 'claude')
        steer.set_directory_trust(directory, False)
        project = steer.claude_project_directory(directory)
        if project.is_dir():
            capture = check.artifacts / f'{check.prefix}-transcripts'
            capture.mkdir(exist_ok=True)
            for path in project.glob('*.jsonl'):
                shutil.copyfile(path, capture / path.name)
            # Only the project for this run's unique temporary folder.
            shutil.rmtree(project, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--provider', choices=('fake', 'claude'), default='fake')
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    if options.gui_session:
        steer = load('queue_steer_check', 'remote-queue-steer-check.py')
        steer.run_in_gui_session(f'remote-coordinator-check-{options.provider}', __file__, ['--provider', options.provider])
    check = Check(options.provider)
    try:
        (run_claude if options.provider == 'claude' else run_fake)(check)
        check.evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - always keep the evidence
        check.evidence['failure'] = repr(error)
        raise
    finally:
        check.finish()
    print(f'[coordinator-check] passed ({options.provider})', flush=True)


if __name__ == '__main__':
    main()
