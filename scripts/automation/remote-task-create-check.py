#!/usr/bin/env python3
"""Create tasks through the real CLI in a disposable app, then restart it.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-create-check.py'.

The check starts its own second instance of the wrapper's build, with a
throwaway runtime home and a throwaway user home. The user home is a git
repository, so the first terminal starts in it and it becomes the workspace's
project root. Its `agents.toml` maps `claude` to a fake agent script that
records its first message, and its `tasks.toml` makes that profile the
default. The check never selects a workspace or moves focus.

It checks that `toastty task create --wait`:
- makes a task space nested under the workspace, linked to the task, and starts
  the agent there with the text as written and Toastty's copy of the file;
- returns the first task for a repeated request ID;
- fails at once for an unknown agent, saving nothing;
and that after the app is killed and relaunched, the record, the task space
and its task link are still there, with no second record rebuilt.
"""

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import uuid

TIMEOUT = 60
TASK_TEXT = 'Fix the unread dot\nIt stays on after reading.'

# Records the first message (the last argument) and the session, then waits.
FAKE_AGENT = r'''#!/bin/sh
case "$1" in
  --version) echo "2.1.288 (Claude Code)"; exit 0 ;;
  plugin|mcp|config) exit 0 ;;
esac
for argument in "$@"; do message="$argument"; done
dir="$(dirname "$0")/sessions"; mkdir -p "$dir"
printf '%s' "$message" > "$dir/$TOASTTY_SESSION_ID.message"
printf '{"sessionID":"%s","panelID":"%s","cwd":"%s"}\n' "$TOASTTY_SESSION_ID" "$TOASTTY_PANEL_ID" "$PWD" > "$dir/$TOASTTY_SESSION_ID.json"
while IFS= read -r line; do :; done
'''


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def wait_for(description, probe, timeout=TIMEOUT, interval=0.2):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = probe()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError(f'Timed out waiting for {description}; last value: {last!r}')


class Instance:
    """One running app on a private socket and runtime home."""

    def __init__(self, binary, environment, socket_path, runtime_home, log_path):
        self.socket_path, self.runtime_home = socket_path, runtime_home
        self.log = open(log_path, 'a')
        self.process = subprocess.Popen([str(binary)], env=environment, stdout=self.log, stderr=subprocess.STDOUT)

    def request(self, command, payload):
        envelope = dict(protocolVersion='1.0', kind='request', requestID=str(uuid.uuid4()),
                        command=command, payload=payload)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(15)
            connection.connect(self.socket_path)
            connection.sendall(json.dumps(envelope).encode() + b'\n')
            data = b''
            while b'\n' not in data:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                data += chunk
        return json.loads(data)

    def query(self, query_id, **args):
        response = self.request('app_control.run_query', dict(id=query_id, args=args))
        require(response.get('ok'), f'{query_id} failed: {response}')
        return response['result']

    def wait_until_ready(self):
        def socket_answers():
            require(self.process.poll() is None, 'The check instance exited during startup')
            if not os.path.exists(self.socket_path):
                return None
            try:
                return self.query('workspace.list')['workspaces']
            except (OSError, AssertionError, json.JSONDecodeError):
                return None

        return wait_for('the automation socket', socket_answers)

    def kill(self):
        self.process.send_signal(signal.SIGKILL)
        self.process.wait(timeout=30)
        self.log.close()


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-task-check-', dir='/tmp')).resolve()
    runtime_home, user_home, fake_bin = root / 'runtime-home', root / 'user-home', root / 'bin'
    for directory in (runtime_home, user_home / '.toastty', fake_bin):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT)
    agent.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')
    screenshot = root / 'repro shot.png'
    screenshot.write_bytes(b'png')

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-task-create-check',
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    cli_environment = dict(environment)
    evidence = dict(status='failed', steps=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, **facts))
        print(f'[task-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_cli(*arguments):
        result = subprocess.run([str(cli), '--json', *arguments], env=cli_environment,
                                capture_output=True, text=True, timeout=180)
        return result.returncode, result.stdout, result.stderr

    app_log = artifacts / 'remote-task-create-check-app.log'
    instance = Instance(binary, environment, socket_path, runtime_home, app_log)
    try:
        workspaces = instance.wait_until_ready()
        workspace_id = workspaces[0]['workspaceID']

        def terminal_in_home():
            listed = instance.query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == workspace_id)['terminalCwds']
            if str(user_home) in [os.path.realpath(cwd) for cwd in cwds]:
                return cwds
            step('waiting for the terminal directory', cwds=cwds)
            return None

        wait_for('the first terminal in the user home', terminal_in_home, interval=1)
        step('booted', workspaceID=workspace_id)

        # 1. Create and wait for the agent to start.
        code, out, err = run_cli('task', 'create', TASK_TEXT, '--file', str(screenshot),
                                 '--workspace', workspace_id, '--request-id', 'live-1', '--wait', '--timeout', '90')
        require(code == 0, f'task create --wait failed ({code}): {out} {err}')
        task = json.loads(out)['result']
        task_id = task['taskID']
        task_space_id = task['setup']['taskSpaceWorkspaceID']
        require(task['setup']['state'] == 'started', f'Task did not start: {task}')
        require(task['agent'] == 'claude', f'Default agent not used: {task}')
        require(os.path.realpath(task['projectRoot']) == str(user_home), f'Project root is not the repo: {task}')
        step('created', taskID=task_id, taskSpace=task_space_id, sessionID=task['setup']['sessionID'])

        # The agent ran in the task space, in the repo, with the text and file.
        session_file = fake_bin / 'sessions' / f"{task['setup']['sessionID']}.json"
        session = json.loads(wait_for('the fake agent to record its session', lambda: session_file.is_file() and session_file.read_text()))
        message = (fake_bin / 'sessions' / f"{task['setup']['sessionID']}.message").read_text()
        require(TASK_TEXT in message, f'Task text not delivered as written: {message!r}')
        attachment = task['files'][0]
        require(attachment.startswith(str(runtime_home / 'task-attachments' / task_id)), f'Attachment not copied: {attachment}')
        require(attachment in message, f'Attachment path not in the prompt: {message!r}')
        require(os.path.realpath(session['cwd']) == str(user_home), f'Agent did not start in the project root: {session}')
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        require(task_space_id in listed, 'Task space is not listed')
        require(listed[workspace_id]['isSelected'], 'The original workspace lost selection')
        require(listed[task_space_id]['activeSessions'], f'No agent session in the task space: {listed[task_space_id]}')
        step('agent started in task space', message=message, cwd=session['cwd'])

        # 2. A repeat with the same request ID returns the first task.
        code, out, err = run_cli('task', 'create', 'ignored', '--workspace', workspace_id, '--request-id', 'live-1')
        require(code == 0 and json.loads(out)['result']['taskID'] == task_id, f'Repeat made a new task: {out} {err}')
        step('repeat returned the first task')

        # 3. A bad agent fails at once and saves nothing.
        code, out, err = run_cli('task', 'create', 'x', '--workspace', workspace_id, '--agent', 'gemini')
        require(code != 0 and 'available: claude' in (out + err), f'Bad agent was accepted: {code} {out} {err}')
        code, out, _ = run_cli('task', 'list')
        tasks = json.loads(out)['result']['tasks']
        require(len(tasks) == 1, f'Expected one task, got {tasks}')
        step('bad agent refused', listed=len(tasks))

        # 4. Kill the app at once: setup saved the layout when it made the
        # task space, so the task link must already be on disk. Then relaunch.
        layout_file = runtime_home / 'workspace-layout-profiles.json'
        require(layout_file.is_file() and task_id.lower() in layout_file.read_text().lower(),
                'The layout file did not hold the task link when setup finished')
        instance.kill()
        step('killed')
        instance = Instance(binary, environment, socket_path, runtime_home, app_log)
        instance.wait_until_ready()
        code, out, err = run_cli('task', 'get', task_id)
        require(code == 0, f'task get after relaunch failed: {out} {err}')
        restored = json.loads(out)['result']
        require(restored['setup']['state'] == 'started', f'Record not kept: {restored}')
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        require(task_space_id in listed, 'Task space not restored after relaunch')
        code, out, _ = run_cli('task', 'list')
        require(len(json.loads(out)['result']['tasks']) == 1, f'Relaunch added records: {out}')
        layout = json.loads(layout_file.read_text())
        require(task_id.lower() in json.dumps(layout).lower(), 'Restored layout lost the task link')
        step('relaunched', taskSpaceRestored=True)

        evidence['status'] = 'passed'
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / 'remote-task-create-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[task-check] passed', flush=True)


if __name__ == '__main__':
    main()
