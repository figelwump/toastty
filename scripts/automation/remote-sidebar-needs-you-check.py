#!/usr/bin/env python3
"""Check the sidebar's Coordinator row and Needs you list in a real app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-sidebar-needs-you-check.py'. It needs an
unlocked screen: it presses sidebar buttons in its own app instance through
Accessibility and captures its window.

The check starts its own instance of the wrapper's build, as
remote-coordinator-chat-check.py does, with TOASTTY_COORDINATOR_AUTOSTART=1,
the fake agent from remote-coordinator-session-check.py for the coordinator
and the task, and a fake `gh` that reports each pull request open. Automation
mode lets the app capture its own window. The task publishes a packet and gets
a pull request link, so it waits for review. Through the UI and the CLI it
checks that:
- the Coordinator row counts the task, and the Projects | Status switcher is
  gone;
- the task's Needs you row shows the review reason and the packet's look_at,
  and offers Merge;
- the Coordinator row opens the chat, and the row opens the task's packet
  card in it;
- Merge asks in the row first: Cancel leaves the task unmerged;
- Merge, then the row's Merge, accepts the merge (`mergeRequestedAt`).
Captures of each step and remote-sidebar-needs-you-check.json go to the
artifacts directory; a capture that cannot be made is recorded, not failed.
"""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).parent
_spec = importlib.util.spec_from_file_location('remote_task_create_check', HERE / 'remote-task-create-check.py')
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)
require, wait_for, Instance = base.require, base.wait_for, base.Instance

def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


to_ship = _load('remote_sidebar_to_ship_check', 'remote-sidebar-to-ship-check.py')
chat_check = _load('remote_coordinator_chat_check', 'remote-coordinator-chat-check.py')
session_check = _load('remote_coordinator_session_check', 'remote-coordinator-session-check.py')
queue_check = _load('remote_queue_steer_check', 'remote-queue-steer-check.py')
LOOK_AT = 'The pinned totals bar at 390 px.'

PREFIX = 'remote-sidebar-needs-you'
SLUG = 'toastty-check/project'
TITLE = 'Unread dot stays on'


def main():
    if '--gui-session' in sys.argv[1:]:
        queue_check.run_in_gui_session(PREFIX, __file__)
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-needs-you-check-', dir='/tmp')).resolve()
    driver, helper = root / 'quick-entry-ui-driver', root / 'task-stages-ui-helper'
    for source, output in ((HERE / 'quick-entry-ui-driver.swift', driver), (HERE / 'task-stages-ui-helper.swift', helper)):
        subprocess.run(['swiftc', '-O', str(source), '-o', str(output)], check=True)

    def run_tool(tool, *arguments, check=True):
        result = subprocess.run([str(tool), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        if check:
            require(result.returncode == 0, f'{tool.name} {arguments[0]} failed: {result.stderr.strip()}')
        return result

    require(run_tool(driver, 'locked').stdout.strip() == '0', 'The remote screen is locked; unlock it to press rows')

    runtime_home, user_home, fake_bin, zdotdir = root / 'runtime-home', root / 'user-home', root / 'bin', root / 'zdotdir'
    work = root / 'work'
    for directory in (runtime_home, user_home / '.toastty', fake_bin, zdotdir, work):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    chat_check.png(work / 'after-390.png', 390, 700, [(220, 218, 213), (207, 227, 212), (45, 107, 70)])
    (work / 'packet.json').write_text(json.dumps({
        'summary': 'Pins the totals bar on narrow screens.',
        'look_at': LOOK_AT,
        'checks': [{'name': 'unit tests', 'ok': True}],
        'not_verified': [],
        'screenshots': [{'name': 'after-390', 'width': 390}],
    }))
    agent = fake_bin / 'claude'
    agent.write_text(session_check.FAKE_AGENT)
    agent.chmod(0o755)
    gh_state = root / 'gh-state.json'
    gh_state.write_text('{}')
    (fake_bin / 'gh').write_text(to_ship.FAKE_GH)
    (fake_bin / 'gh').chmod(0o755)
    (fake_bin / 'state-path').write_text(str(gh_state))
    for name in ('.zshenv', '.zprofile'):
        (zdotdir / name).write_text(f'[ -f "$HOME/{name}" ] && source "$HOME/{name}"\n')
    (zdotdir / '.zshrc').write_text(f'[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"\nexport PATH="{fake_bin}:$PATH"\n')
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL=PREFIX,
        TOASTTY_SOCKET_PATH=socket_path,
        TOASTTY_COORDINATOR_AUTOSTART='1',
        TOASTTY_AUTOMATION='1',
        TOASTTY_ARTIFACTS_DIR=str(artifacts),
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        ZDOTDIR=str(zdotdir),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], captures=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[sidebar-needs-you-check] {name} {json.dumps(facts, default=str, ensure_ascii=False)}', flush=True)

    cli_environment = {key: value for key, value in environment.items()
                       if key not in ('TOASTTY_COORDINATOR_AUTOSTART', 'TOASTTY_AUTOMATION')}

    def cli_json(*arguments, session=None):
        env = dict(cli_environment)
        if session:
            env.update(TOASTTY_SESSION_ID=session['sessionID'], TOASTTY_PANEL_ID=session['panelID'])
        result = subprocess.run([str(cli), '--json', '--socket-path', socket_path, *arguments], env=env, cwd=work,
                                capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-check-app.log')
    pid = instance.process.pid

    def capture(name):
        """Evidence only: a capture that cannot be made is recorded, not failed."""
        path = artifacts / f'{name}.png'
        run_tool(helper, 'activate', pid, check=False)
        time.sleep(1.0)
        response = instance.request('automation.capture_screenshot', dict(step=name))
        if response.get('ok'):
            if Path(response['result']['path']).resolve() != path.resolve():
                shutil.copyfile(response['result']['path'], path)
        else:
            result = run_tool(helper, 'capture', pid, path, check=False)
            if result.returncode != 0:
                step('capture unavailable', file=path.name, app=response.get('error'), window=result.stderr.strip())
                return
        evidence['captures'].append(path.name)
        step('captured', file=path.name)

    def labels():
        result = run_tool(driver, 'labels', pid, '*', check=False)
        return json.loads(result.stdout) if result.returncode == 0 else []

    def label_starting(prefix):
        return next((label for label in labels() if label.startswith(prefix)), None)

    def exists(identifier):
        return run_tool(helper, 'exists', pid, identifier, check=False).returncode == 0

    def chat_state():
        return instance.query('coordinator.chat.state')

    try:
        workspaces = instance.wait_until_ready()
        workspace_id = workspaces[0]['workspaceID']
        coordinator_status = wait_for('the coordinator to run', lambda: (lambda s: s if s['state'] == 'running' else None)(
            instance.query('coordinator.status')), timeout=90, interval=1)
        wait_for('the first terminal in the user home', lambda: str(user_home) in [
            os.path.realpath(cwd) for w in instance.query('workspace.list')['workspaces']
            if w['workspaceID'] == workspace_id for cwd in w['terminalCwds']], interval=1)

        task = cli_json('task', 'create', TITLE, '--title', TITLE, '--workspace', workspace_id, '--wait', '--timeout', '90')
        task_id = task['taskID']
        session_file = fake_bin / 'sessions' / f"{task['setup']['sessionID']}.json"
        task_session = json.loads(wait_for('the task agent to record its session',
                                           lambda: session_file.is_file() and session_file.read_text()))
        published = cli_json('task', 'packet', 'publish', '--file', 'packet.json', '--screenshot', 'after-390.png',
                             session=task_session)
        require(published['packetVersion'] == 1, f'Packet not published: {published}')
        cli_json('coordinator', 'post', 'packet', '--task', task_id)
        cli_json('action', 'run', 'workspace.set-annotation', '--workspace', task['setup']['taskSpaceWorkspaceID'],
                 'key=github-pr', 'text=PR #1', f'url=https://github.com/{SLUG}/pull/1')
        wait_for('the task to wait for review', lambda: cli_json('task', 'get', task_id)['stage'].get('attention') == 'review',
                 interval=1)
        step('task waits for review', taskID=task_id)

        # 1. The Coordinator row counts it; the switcher is gone.
        coordinator = wait_for('the Coordinator row', lambda: label_starting('Coordinator, 1 needs you'))
        require(label_starting('Group the sidebar by') is None, f'The Projects | Status switcher is still there: {labels()}')
        # The look_at line comes from the packet, read after the first draw.
        row = wait_for('the Needs you row with the look_at line',
                       lambda: (lambda label: label if label and label.endswith(LOOK_AT) else None)(label_starting(f'{TITLE}, review')))
        require(label_starting('Needs you, 1'), f'No Needs you header: {labels()}')
        require(exists(f'sidebar.needsYou.task.{task_id}.primary'), 'The row has no primary action')
        step('needs you row', coordinator=coordinator, row=row)
        capture('needs-you-review')

        # 2. The Coordinator row opens the chat; the row opens its packet.
        run_tool(helper, 'press', pid, 'sidebar.coordinator.open')
        wait_for('the chat', lambda: chat_state()['pages'] >= 1, timeout=20, interval=0.5)
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        require(listed[coordinator_status['workspaceID']]['isSelected'], 'The Coordinator row did not select the coordinator')
        packet_card = next(i for i in chat_state()['items'] if i['type'] == 'card' and i['kind'] == 'packet')
        run_tool(driver, 'press-label', pid, f'{TITLE}, review')
        wait_for('the packet card to open', lambda: packet_card['id'] in chat_state()['expandedCardIDs'], timeout=20, interval=0.3)
        step('row opened its packet', card=packet_card['id'])
        capture('needs-you-opens-packet')

        # 3. Merge asks in the row; Cancel leaves the task alone.
        run_tool(helper, 'press', pid, f'sidebar.needsYou.task.{task_id}.primary')
        wait_for('the merge question', lambda: exists(f'sidebar.needsYou.task.{task_id}.confirmMerge'))
        require('Merge PR #1?' in run_tool(driver, 'texts', pid, '*').stdout, 'The row does not ask before it merges')
        capture('needs-you-merge-question')
        run_tool(helper, 'press', pid, f'sidebar.needsYou.task.{task_id}.cancelMerge')
        wait_for('the question to close', lambda: exists(f'sidebar.needsYou.task.{task_id}.confirmMerge') is False)
        time.sleep(1)
        require(not cli_json('task', 'get', task_id).get('mergeRequestedAt'), 'Cancel accepted the merge')
        step('cancel kept the task')

        # 4. Merge, then Merge in the row, accepts the merge.
        run_tool(helper, 'press', pid, f'sidebar.needsYou.task.{task_id}.primary')
        wait_for('the merge question', lambda: exists(f'sidebar.needsYou.task.{task_id}.confirmMerge'))
        run_tool(helper, 'press', pid, f'sidebar.needsYou.task.{task_id}.confirmMerge')
        accepted = wait_for('the merge to be accepted', lambda: cli_json('task', 'get', task_id).get('mergeRequestedAt'),
                            interval=1)
        step('merge accepted', mergeRequestedAt=accepted)
        capture('needs-you-merge-accepted')

        evidence['status'] = 'passed'
    except Exception:
        dump = subprocess.run([str(helper), 'dump', str(pid)], capture_output=True, text=True, timeout=60)
        (artifacts / f'{PREFIX}-check-ax.txt').write_text(dump.stdout)
        raise
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / f'{PREFIX}-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[sidebar-needs-you-check] passed', flush=True)


if __name__ == '__main__':
    main()
