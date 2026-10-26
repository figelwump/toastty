#!/usr/bin/env python3
"""Open the coordinator chat in a disposable app, and act on a packet card.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-chat-check.py [--gui-session]'.
It needs an unlocked screen: it clicks and types into its own app instance,
and captures its window. Add --gui-session to rerun it from Terminal in the
logged-in GUI session, where window captures can work.

The check starts its own instance of the wrapper's build with a throwaway
runtime home and a user home that is a git repository, with
TOASTTY_COORDINATOR_AUTOSTART=1 and the fake agent from
remote-coordinator-session-check.py for both the coordinator and the task. No
real agent runs. Through the real CLI and the page itself it checks that:
- `coordinator show` covers the coordinator's terminal with the chat, which
  shows the task-started and packet cards the coordinator posted;
- `coordinator show --task` opens and scrolls to the task's packet card;
- a reply typed into the open card reaches the task's agent as
  `Review note on packet v1: …`, and the task leaves Needs you;
- Full report opens toastty://coordinator/report/<task>/1 in the right panel;
- the blocked composer's Open terminal button shows the raw terminal again.
Captures of the chat with the card collapsed and open, and of the report, go
to the artifacts directory; a capture that cannot be made is recorded, not
failed.
"""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

HERE = Path(__file__).parent


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


create_check = _load('remote_task_create_check', 'remote-task-create-check.py')
queue_check = _load('remote_queue_steer_check', 'remote-queue-steer-check.py')
session_check = _load('remote_coordinator_session_check', 'remote-coordinator-session-check.py')
require, wait_for, Instance = create_check.require, create_check.wait_for, create_check.Instance

PREFIX = 'remote-coordinator-chat'
KEY_RETURN = 36
REPLY = "Use banker's rounding"


def png(path, width, height, bands):
    """Writes a PNG of horizontal color bands, so screenshots look like pages."""
    rows = []
    for y in range(height):
        color = bands[min(len(bands) - 1, y * len(bands) // height)]
        rows.append(b'\x00' + bytes(color) * width)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


def main():
    if '--gui-session' in sys.argv[1:]:
        # Window captures need Screen Recording, which Terminal in the GUI
        # session can have when an SSH session does not.
        queue_check.run_in_gui_session(PREFIX, __file__)
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary, cli = bundle / 'Contents/MacOS/Toastty', bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-coordinator-chat-check-', dir='/tmp')).resolve()
    runtime_home, user_home, fake_bin, work = root / 'runtime-home', root / 'user-home', root / 'bin', root / 'work'
    for directory in (runtime_home, user_home / '.toastty', fake_bin, work):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(session_check.FAKE_AGENT)
    agent.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')
    paper, header, summary, payment, bar = (246, 246, 244), (220, 218, 213), (207, 227, 212), (214, 228, 239), (45, 107, 70)
    png(work / 'before-390.png', 390, 700, [header, payment, payment, summary, header])
    png(work / 'after-390.png', 390, 700, [header, summary, payment, payment, bar])
    png(work / 'after-1280.png', 1280, 800, [header, payment, summary, paper])
    (work / 'packet.json').write_text(json.dumps({
        'summary': 'Moves the order summary above payment and pins the totals bar on narrow screens.',
        'look_at': 'The pinned totals bar at 390 px, and whether the coupon row is still reachable under it.',
        'checks': [{'name': 'unit tests', 'ok': True, 'log': '/tmp/unit.log'},
                   {'name': 'e2e checkout with coupon', 'ok': False, 'log': '/tmp/e2e.log'}],
        'not_verified': ['Safari sticky footer'],
        'screenshots': [{'name': 'before-390', 'pair': 'before', 'width': 390},
                        {'name': 'after-390', 'pair': 'after', 'width': 390},
                        {'name': 'after-1280', 'pair': 'after', 'width': 1280}],
    }))

    helper, driver = root / 'task-stages-ui-helper', root / 'quick-entry-ui-driver'
    for source, output in ((HERE / 'task-stages-ui-helper.swift', helper), (HERE / 'quick-entry-ui-driver.swift', driver)):
        subprocess.run(['swiftc', '-O', str(source), '-o', str(output)], check=True)

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL=PREFIX,
        TOASTTY_SOCKET_PATH=socket_path,
        TOASTTY_COORDINATOR_AUTOSTART='1',
        # Automation mode lets the app capture its own window, web content
        # included, where the host gives no Screen Recording grant.
        TOASTTY_AUTOMATION='1',
        TOASTTY_ARTIFACTS_DIR=str(artifacts),
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    cli_environment = {key: value for key, value in environment.items()
                       if key not in ('TOASTTY_COORDINATOR_AUTOSTART', 'TOASTTY_AUTOMATION')}
    cli_environment['PWD'] = str(work)
    evidence = dict(status='failed', steps=[], captures=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[chat-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_tool(tool, *arguments, check=True):
        result = subprocess.run([str(tool), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        require(check is False or result.returncode == 0, f'{tool.name} {arguments} failed: {result.stderr}')
        return result

    def cli_result(*arguments, session=None):
        env = dict(cli_environment)
        if session:
            env.update(TOASTTY_SESSION_ID=session['sessionID'], TOASTTY_PANEL_ID=session['panelID'])
        result = subprocess.run([str(cli), '--json', '--socket-path', socket_path, *arguments], env=env, cwd=work,
                                capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments[:3])} failed ({result.returncode}): {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-app.log')
    pid = instance.process.pid

    def chat_state():
        return instance.query('coordinator.chat.state')

    def capture(name):
        path = artifacts / f'{name}.png'
        time.sleep(1.0)
        response = instance.request('automation.capture_screenshot', dict(step=name))
        if response.get('ok'):
            if Path(response['result']['path']).resolve() != path.resolve():
                shutil.copyfile(response['result']['path'], path)
        else:
            result = run_tool(helper, 'capture', pid, path, check=False)
            if result.returncode != 0:
                step('capture unavailable', file=path.name, window=result.stderr.strip(), app=response.get('error'))
                return
        evidence['captures'].append(path.name)
        step('captured', file=path.name)

    def bring_to_front():
        run_tool(helper, 'activate', pid)
        wait_for('the instance in front', lambda: run_tool(helper, 'frontmost-pid').stdout.strip() == str(pid), timeout=15)

    try:
        workspace_id = instance.wait_until_ready()[0]['workspaceID']
        coordinator = wait_for('the coordinator to run', lambda: (lambda s: s if s['state'] == 'running' else None)(
            instance.query('coordinator.status')), timeout=90, interval=1)
        listed = instance.query('workspace.list')['workspaces']
        window_frame = next((w.get('windowFrame') for w in listed if w['workspaceID'] == workspace_id), None)
        locked = run_tool(driver, 'locked', check=False).stdout.strip()
        step('coordinator running', sessionID=coordinator['sessionID'], window=window_frame, screenLocked=locked)

        def terminal_in_home():
            listed = instance.query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == workspace_id)['terminalCwds']
            return str(user_home) in [os.path.realpath(cwd) for cwd in cwds]

        wait_for('the first terminal in the user home', terminal_in_home, interval=1)
        task = cli_result('task', 'create', 'Fix the totals bar', '--title', 'Checkout totals bar',
                          '--workspace', workspace_id, '--wait', '--timeout', '90')
        task_id = task['taskID']
        session_file = fake_bin / 'sessions' / f"{task['setup']['sessionID']}.json"
        task_session = json.loads(wait_for('the task agent to record its session',
                                           lambda: session_file.is_file() and session_file.read_text()))
        cli_result('coordinator', 'post', 'task-started', '--task', task_id)
        published = cli_result('task', 'packet', 'publish', '--file', 'packet.json', '--screenshot', 'before-390.png',
                               '--screenshot', 'after-390.png', '--screenshot', 'after-1280.png', session=task_session)
        require(published['packetVersion'] == 1, f'Packet not published: {published}')
        cli_result('coordinator', 'post', 'packet', '--task', task_id)
        cli_result('coordinator', 'post', 'note', 'One task is ready for your review.')
        step('task and cards ready', taskID=task_id)

        # 1. The chat covers the coordinator's terminal and shows the cards.
        cli_result('coordinator', 'show')
        state = wait_for('the chat page to show the cards', lambda: (lambda s: s if s['pages'] >= 1 and
                         [i['kind'] for i in s['items'] if i['type'] == 'card'] == ['task-started', 'packet', 'note'] else None)(
                         chat_state()), timeout=30, interval=0.5)
        packet_card = next(i for i in state['items'] if i['type'] == 'card' and i['kind'] == 'packet')
        require(packet_card['taskID'] == task_id and packet_card['packetVersion'] == 1, f'Packet card: {packet_card}')
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        require(listed[coordinator['workspaceID']]['isSelected'], 'The coordinator workspace is not selected')
        bring_to_front()
        capture('coordinator-chat-collapsed')

        # 2. show --task opens the task's packet card.
        cli_result('coordinator', 'show', '--task', task_id)
        wait_for('the packet card to open', lambda: packet_card['id'] in chat_state()['expandedCardIDs'], timeout=15, interval=0.3)
        capture('coordinator-chat-expanded')

        # 3. A reply typed into the card reaches the task as a review note.
        bring_to_front()
        reply_field = f"title:Review note for {task['slug']}"
        # WebKit builds the page's Accessibility tree lazily, so the first
        # lookups after a render can miss.
        focused = False
        for _ in range(20):
            if run_tool(helper, 'focus', pid, reply_field, check=False).returncode == 0:
                focused = True
                break
            time.sleep(0.5)
        if not focused:
            # Leave the tree for diagnosis: web content shows as AXWebArea.
            (artifacts / f'{PREFIX}-ax.txt').write_text(run_tool(helper, 'dump', pid, check=False).stdout)
            raise AssertionError(f'No {reply_field} in the Accessibility tree; see {PREFIX}-ax.txt')
        time.sleep(0.3)
        run_tool(driver, 'type', REPLY)
        run_tool(driver, 'key', KEY_RETURN)
        expected = f'Review note on packet v1: {REPLY}'

        sent_notice = f"Sent to {task['slug']}."
        notice = wait_for('the chat to report the reply sent', lambda: (lambda n: n if n and n['text'] == sent_notice else None)(
            chat_state().get('notice')), timeout=20, interval=0.5)
        # The task's terminal is in a workspace that is not selected, so its
        # screen text may not be drawn; record it as evidence.
        task_text = instance.query('terminal.visible-text', panelID=task_session['panelID'], tail=40, includeScrollback=True).get('text', '')
        after = cli_result('task', 'get', task_id)
        require(after['readyForReviewAt'] is None, f'The task is still ready for review: {after}')
        step('reply reached the task', notice=notice, stage=after.get('stage'),
             noteInTaskTerminal=expected in task_text.replace('\n', ''), taskTerminal=task_text[-300:])

        # 4. Full report opens in the coordinator workspace's right panel.
        wait_for('Full report to press', lambda: run_tool(helper, 'press', pid, 'title:Full report', check=False).returncode == 0,
                 timeout=10, interval=0.5)
        report_url = f'toastty://coordinator/report/{task_id}/1'

        def report_tab():
            snapshot = instance.query('workspace.snapshot', workspaceID=coordinator['workspaceID'])
            return report_url in json.dumps(snapshot)
        wait_for('the report in the right panel', report_tab, timeout=20, interval=0.5)
        time.sleep(1.5)
        capture('coordinator-report')
        step('report opened', url=report_url)

        # 5. This fake agent emits no ready/turn events, as at first-load
        # setup. The blocked composer must offer a way to its terminal.
        require(chat_state()['canSend'] is False, 'The fake agent unexpectedly accepts chat input')
        opened = instance.request('automation.coordinator_chat_action',
                                  dict(action='click', elementID='composer-open-terminal'))
        require(opened.get('ok'), f'The blocked composer did not offer Open terminal: {opened}')
        wait_for('the chat to uncover the terminal', lambda: chat_state()['pages'] == 0, timeout=15, interval=0.3)
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        require(listed[coordinator['workspaceID']]['isSelected'], 'Open terminal did not keep the coordinator workspace')
        step('blocked composer opened the raw terminal without sending a message')

        # Keep the CLI route covered as well.
        cli_result('coordinator', 'show')
        wait_for('the chat to reopen', lambda: chat_state()['pages'] >= 1, timeout=15, interval=0.3)
        cli_result('coordinator', 'show-terminal')
        wait_for('the CLI to uncover the terminal', lambda: chat_state()['pages'] == 0, timeout=15, interval=0.3)
        step('CLI showed the raw terminal')

        evidence['status'] = 'passed'
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / f'{PREFIX}-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[chat-check] passed', flush=True)


if __name__ == '__main__':
    main()
