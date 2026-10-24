#!/usr/bin/env python3
"""Publish a task's review packet through the real CLI in a disposable app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-packet-check.py'.

The check starts its own second instance of the wrapper's build, with a
throwaway runtime home and a throwaway user home that is a git repository, as
remote-task-create-check.py does. A fake agent records its session, and the
check runs the CLI with that session's TOASTTY_SESSION_ID, as the task's own
agent would. It never selects a workspace or moves focus.

It checks that:
- `task packet publish` refuses a packet without look_at and one whose
  screenshot has no file, and stores nothing;
- a packet with a screenshot, published without a task ID, becomes v1 of the
  agent's own task, with the screenshot copied under the runtime home's
  task-packets folder, and the task moves to Needs you, ready for review;
- `task get` reports packetVersion and verifySkill, and `task packet get`
  returns the packet as written, with the stored screenshot's path;
- a second publish is v2, `--version 1` still reads v1, and both survive a
  relaunch.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


create_check = _load('remote_task_create_check', 'remote-task-create-check.py')
require, wait_for, Instance = create_check.require, create_check.wait_for, create_check.Instance

PREFIX = 'remote-task-packet-check'
PACKET = {
    'summary': 'Moves the totals above payment on narrow screens.',
    'look_at': 'The pinned totals bar at 390 px.',
    'checks': [{'name': 'unit tests', 'ok': True, 'log': '/tmp/unit.log'}],
    'not_verified': ['Safari sticky footer'],
    'screenshots': [{'name': 'after-390', 'pair': 'after', 'width': 390}],
}


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary, cli = bundle / 'Contents/MacOS/Toastty', bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-packet-check-', dir='/tmp')).resolve()
    runtime_home, user_home, fake_bin, work = root / 'runtime-home', root / 'user-home', root / 'bin', root / 'work'
    for directory in (runtime_home, user_home / '.toastty', fake_bin, work):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(create_check.FAKE_AGENT)
    agent.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')
    screenshot = work / 'after-390.png'
    screenshot.write_bytes(b'\x89PNG packet check')

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL=PREFIX,
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, **facts))
        print(f'[packet-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_cli(*arguments, session=None):
        # The CLI resolves relative paths against PWD, which cwd= does not set.
        cli_environment = dict(environment, PWD=str(work))
        if session:
            cli_environment.update(TOASTTY_SESSION_ID=session['sessionID'], TOASTTY_PANEL_ID=session['panelID'])
        result = subprocess.run([str(cli), '--json', *arguments], env=cli_environment, cwd=work,
                                capture_output=True, text=True, timeout=180)
        return result.returncode, result.stdout, result.stderr

    def cli_result(*arguments, session=None):
        code, out, err = run_cli(*arguments, session=session)
        require(code == 0, f'{" ".join(arguments[:3])} failed ({code}): {out} {err}')
        return json.loads(out)['result']

    def write_packet(name, packet):
        (work / name).write_text(json.dumps(packet))
        return name

    app_log = artifacts / f'{PREFIX}-app.log'
    instance = Instance(binary, environment, socket_path, runtime_home, app_log)
    try:
        workspace_id = instance.wait_until_ready()[0]['workspaceID']

        def terminal_in_home():
            listed = instance.query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == workspace_id)['terminalCwds']
            return str(user_home) in [os.path.realpath(cwd) for cwd in cwds]

        wait_for('the first terminal in the user home', terminal_in_home, interval=1)
        task = cli_result('task', 'create', 'Fix the totals bar', '--workspace', workspace_id, '--wait', '--timeout', '90')
        task_id = task['taskID']
        session_file = fake_bin / 'sessions' / f"{task['setup']['sessionID']}.json"
        session = json.loads(wait_for('the fake agent to record its session',
                                      lambda: session_file.is_file() and session_file.read_text()))
        step('created', taskID=task_id, session=session)

        # 1. Incomplete packets are refused, and nothing is stored.
        incomplete = dict(PACKET)
        del incomplete['look_at']
        code, out, err = run_cli('task', 'packet', 'publish', '--file', write_packet('incomplete.json', incomplete),
                                 '--screenshot', 'after-390.png', session=session)
        require(code != 0 and 'look_at' in (out + err), f'A packet without look_at was accepted: {code} {out} {err}')
        code, out, err = run_cli('task', 'packet', 'publish', '--file', write_packet('packet.json', PACKET), session=session)
        require(code != 0 and 'after-390' in (out + err), f'A packet without its screenshot was accepted: {code} {out} {err}')
        require(cli_result('task', 'get', task_id)['packetVersion'] is None, 'A refused packet left a version')
        step('incomplete packets refused')

        # 2. The task's agent publishes v1 for its own task.
        published = cli_result('task', 'packet', 'publish', '--file', 'packet.json', '--screenshot', 'after-390.png',
                               session=session)
        require(published['taskID'] == task_id and published['packetVersion'] == 1, f'Not v1 of the task: {published}')
        stored_shot = published['packet']['screenshots'][0]['path']
        require(os.path.realpath(stored_shot).startswith(str(runtime_home / 'task-packets' / task_id / 'v1')),
                f'Screenshot not stored under the runtime home: {stored_shot}')
        require(Path(stored_shot).read_bytes() == screenshot.read_bytes(), 'The stored screenshot differs')
        got = wait_for('the task in Needs you', lambda: (lambda t: t if t.get('stage', {}).get('attention') == 'readyForReview'
                       else None)(cli_result('task', 'get', task_id)), timeout=30, interval=0.5)
        require(got['packetVersion'] == 1 and got['verifySkill'] == 'toastty-task-verify', f'task get: {got}')
        step('published v1', stage=got['stage'], screenshot=stored_shot)

        packet = cli_result('task', 'packet', 'get', task_id)
        for key in ('summary', 'look_at', 'checks', 'not_verified'):
            require(packet[key] == PACKET[key], f'{key} changed: {packet[key]!r}')
        require(packet['version'] == 1 and packet['latestVersion'] == 1 and packet['stale'] is False, f'packet get: {packet}')
        step('read v1', packet=packet)

        # 3. A second version, then a relaunch keeps both.
        revised = dict(PACKET, summary='Addresses the review notes.', screenshots=[], not_verified=[])
        second = cli_result('task', 'packet', 'publish', '--file', write_packet('revised.json', revised), session=session)
        require(second['packetVersion'] == 2, f'Second publish is not v2: {second}')
        instance.kill()
        instance = Instance(binary, environment, socket_path, runtime_home, app_log)
        instance.wait_until_ready()
        latest = cli_result('task', 'packet', 'get', task_id)
        first = cli_result('task', 'packet', 'get', task_id, '--version', '1')
        require(latest['version'] == 2 and latest['summary'] == revised['summary'], f'Latest after relaunch: {latest}')
        require(first['summary'] == PACKET['summary'] and Path(first['screenshots'][0]['path']).is_file(),
                f'v1 after relaunch: {first}')
        step('relaunched', latest=latest['version'], first=first['version'])

        evidence['status'] = 'passed'
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / f'{PREFIX}.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[packet-check] passed', flush=True)


if __name__ == '__main__':
    main()
