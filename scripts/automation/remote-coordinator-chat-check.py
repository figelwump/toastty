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
- a question with two options changes a finished task's sidebar badge to
  question; a page button answers it and restores the finished badge;
- a typed question reply reaches a waiting task that has no packet;
- answers and task-scoped threads survive an app relaunch in the same runtime.
- a question's native task menu opens its task space;
- a question with a fake mergeable pull request offers Merge, and Cancel
  leaves the task unmerged.
The fake agent records received lines. This proves delivery through Toastty's
page and terminal routes, not a real provider conversation.
Captures of the chat with the card collapsed and open, and of the report, go
to the artifacts directory; a capture that cannot be made is recorded, not
failed.
"""

from concurrent.futures import ThreadPoolExecutor
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
to_ship_check = _load('remote_sidebar_to_ship_check', 'remote-sidebar-to-ship-check.py')
require, wait_for, Instance = create_check.require, create_check.wait_for, create_check.Instance

PREFIX = 'remote-coordinator-chat'
KEY_RETURN, KEY_DOWN = 36, 125
REPLY = "Use banker's rounding"
OPTIONS = ['Staging only', 'Prepare prod, ask before applying']
QUESTION = 'Where should the totals bar change go?'
TYPED_REPLY = 'Keep the coupon row visible.'


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
    zdotdir = root / 'zdotdir'
    for directory in (runtime_home, user_home / '.toastty', fake_bin, work, zdotdir):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(session_check.FAKE_AGENT.replace(
        '  [ "$line" = quit ] && exit 0\n',
        '  printf \'%s\\n\' "$line" >> "$dir/$TOASTTY_SESSION_ID.input"\n'
        '  [ "$line" = quit ] && exit 0\n'))
    agent.chmod(0o755)
    # The Merge check only opens and cancels its confirmation. Every GitHub
    # read is answered by this fake executable in the disposable app's shell.
    (root / 'gh-state.json').write_text('{}')
    (fake_bin / 'state-path').write_text(str(root / 'gh-state.json'))
    (fake_bin / 'gh').write_text(to_ship_check.FAKE_GH.replace(
        'args = sys.argv[1:]',
        'args = sys.argv[1:]\nwith open(os.path.join(os.path.dirname(__file__), "gh-calls.jsonl"), "a") as log:\n'
        '    log.write(json.dumps(args) + "\\n")'))
    (fake_bin / 'gh').chmod(0o755)
    for name in ('.zshenv', '.zprofile'):
        (zdotdir / name).write_text(f'[ -f "$HOME/{name}" ] && source "$HOME/{name}"\n')
    (zdotdir / '.zshrc').write_text(f'[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"\nexport PATH="{fake_bin}:$PATH"\n')
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
        ZDOTDIR=str(zdotdir),
        PATH=f'{fake_bin}:{environment.get("PATH", "")}',
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

    def card(card_id):
        return next((item for item in chat_state()['items']
                     if item['type'] == 'card' and item['id'] == card_id), None)

    def page_action(action, element_id, text=None):
        payload = dict(action=action, elementID=element_id)
        if text is not None:
            payload['text'] = text
        response = instance.request('automation.coordinator_chat_action', payload)
        require(response.get('ok'), f'The page could not {action} {element_id}: {response}')
        return response

    def sidebar_row(title, reason):
        result = run_tool(driver, 'labels', pid, '*', check=False)
        if result.returncode != 0:
            return None
        return next((label for label in json.loads(result.stdout) if label.startswith(f'{title}, {reason}')), None)

    def received(session_id, text):
        path = fake_bin / 'sessions' / f'{session_id}.input'
        contents = path.read_text() if path.is_file() else ''
        return contents if text in contents else None

    def answered(card_id, answer):
        current = card(card_id)
        if current and current.get('answer') == answer and any(
                entry['text'] == answer and entry['role'] == 'user-task' for entry in current.get('thread', [])):
            return current
        return None

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

        # 6. A posted question takes precedence over the task's finished
        # badge. Choosing an option uses the same page reply route as typing.
        for kind in ('working', 'ready'):
            cli_result('session', 'status', '--session', task_session['sessionID'], '--kind', kind, '--summary', kind)
        wait_for('the packet task to finish its turn',
                 lambda: cli_result('task', 'get', task_id)['stage'].get('attention') == 'agentFinished')
        finished_row = wait_for('the finished sidebar row', lambda: sidebar_row(task['title'], 'finished'))
        cli_result('coordinator', 'post', 'question', '--task', task_id,
                   '--option', OPTIONS[0], '--option', OPTIONS[1], QUESTION)
        cli_result('coordinator', 'show', '--task', task_id)
        option_card = wait_for('the question with both options', lambda: next((item for item in chat_state()['items']
            if item['type'] == 'card' and item['kind'] == 'question' and item['taskID'] == task_id
            and item.get('options') == OPTIONS and item.get('isCurrent') is True), None))
        option_id = option_card['id']
        wait_for('the question card to open', lambda: option_id in chat_state()['expandedCardIDs'])
        require(option_card.get('answer') is None, f'The new question is already answered: {option_card}')
        require(option_card.get('defaultReplyTarget') == 'coordinator',
                f'A finished task should default to the coordinator: {option_card}')
        question_row = wait_for('the question sidebar row', lambda: sidebar_row(task['title'], 'question'))
        capture('coordinator-question-options')
        step('question replaced the finished sidebar badge', taskID=task_id,
             before=finished_row, question=question_row, options=option_card['options'],
             capture='coordinator-question-options.png', colorCheck='Compare the question badge with the amber prototype badge.')
        page_action('click', f'reply-to-task-{option_id}')
        capture('coordinator-question-options-enabled')
        page_action('click', f'option-{option_id}-0')
        option_answer = wait_for('the selected answer in the card thread', lambda: answered(option_id, OPTIONS[0]))
        input_text = wait_for('the option in the fake task input', lambda: received(task_session['sessionID'], OPTIONS[0]))
        restored_row = wait_for('the underlying finished sidebar badge', lambda: sidebar_row(task['title'], 'finished'))
        require(sidebar_row(task['title'], 'question') is None, 'The answered question still owns the sidebar badge')
        require(cli_result('task', 'get', task_id)['stage'].get('attention') == 'agentFinished',
                'Answering the question changed the underlying finished stage')
        coordinator_note = 'The totals bar change will stay on staging.'
        cli_result('coordinator', 'post', 'note', '--task', task_id, coordinator_note)
        option_answer = wait_for('the task-scoped coordinator note in the thread', lambda: (lambda item: item if item and any(
            entry['text'] == coordinator_note and entry['role'] == 'coordinator' for entry in item.get('thread', [])) else None)(card(option_id)))
        require(not any(item['type'] == 'message' and item.get('text') == coordinator_note for item in chat_state()['items']),
                'The task-scoped coordinator note was duplicated in the main transcript')
        require(not any(item['type'] == 'card' and item['kind'] == 'note' and item['taskID'] == task_id
                        for item in chat_state()['items']), 'The task-scoped coordinator note became a separate card')
        capture('coordinator-question-answered')
        step('option answered and restored the finished stage', cardID=option_id, answer=option_answer['answer'],
             thread=option_answer['thread'], sidebar=restored_row, fakeAgentReceived=input_text[-300:])

        # A native menu can hold the page action's callback until it closes.
        # One bounded future opens it while the main thread picks a safe item.
        bring_to_front()
        with ThreadPoolExecutor(max_workers=1) as menu_actions:
            opening = menu_actions.submit(page_action, 'click', f'menu-{option_id}')
            try:
                def menu_frames():
                    if opening.done():
                        opening.result()
                    result = run_tool(driver, 'menu-frames', pid, check=False)
                    return json.loads(result.stdout) if result.returncode == 0 else None

                menu = wait_for('the question card native menu', menu_frames, timeout=8, interval=0.3)
                evidence['questionMenu'] = menu
                (artifacts / f'{PREFIX}-question-menu.json').write_text(json.dumps(menu, indent=2))
                target = next((item for item in menu['items'] if item['enabled'] and item['title']), None)
                require(target and target['title'] == 'Open Task Space',
                        f'Open Task Space is not the first enabled native menu item: {menu}')
                # Use a native window capture here: the app socket may still
                # be completing the page action that opened NSMenu.
                menu_capture = artifacts / 'coordinator-question-native-menu.png'
                try:
                    captured_menu = subprocess.run([str(helper), 'capture', str(pid), str(menu_capture)],
                                                   capture_output=True, text=True, timeout=3)
                    if captured_menu.returncode == 0:
                        evidence['captures'].append(menu_capture.name)
                    else:
                        step('native menu capture unavailable', error=captured_menu.stderr.strip())
                except subprocess.TimeoutExpired:
                    step('native menu capture unavailable', error='Native capture exceeded three seconds.')
                x, y, width, height = target['frame']
                require(width > 0 and height > 0, f'The native menu item has no visible frame: {target}')
                # popUp(positioning: nil) starts with no selected item.
                # Arrow Down selects the proven safe first enabled item.
                run_tool(driver, 'key', KEY_DOWN)
                run_tool(driver, 'key', KEY_RETURN)
            finally:
                run_tool(driver, 'close-menu', pid, check=False)
            opening.result(timeout=20)
        task_workspace = task['setup']['taskSpaceWorkspaceID']
        wait_for('Open Task Space to select the task workspace', lambda: any(
            item['workspaceID'] == task_workspace and item['isSelected']
            for item in instance.query('workspace.list')['workspaces']))
        step('question native menu opened the task space', taskID=task_id, workspaceID=task_workspace,
             menu=menu, menuFile=f'{PREFIX}-question-menu.json')
        cli_result('coordinator', 'show', '--task', task_id)
        wait_for('the coordinator chat after the native menu', lambda: chat_state()['pages'] >= 1 and any(
            item['workspaceID'] == coordinator['workspaceID'] and item['isSelected']
            for item in instance.query('workspace.list')['workspaces']))

        # 7. A waiting task needs no review packet to take a typed answer.
        typed_task = cli_result('task', 'create', 'Keep the coupon visible', '--title', 'Coupon question without a packet',
                                '--workspace', workspace_id, '--wait', '--timeout', '90')
        typed_task_id = typed_task['taskID']
        typed_session_id = typed_task['setup']['sessionID']
        typed_session_path = fake_bin / 'sessions' / f'{typed_session_id}.json'
        wait_for('the second fake task to start', lambda: typed_session_path.is_file())
        cli_result('session', 'status', '--session', typed_session_id, '--kind', 'needs_approval', '--summary', 'Needs an answer')
        wait_for('the second task to wait for input',
                 lambda: cli_result('task', 'get', typed_task_id)['stage'].get('attention') == 'agentNeedsInput')
        cli_result('coordinator', 'post', 'question', '--task', typed_task_id, 'Should the coupon row stay visible?')
        cli_result('coordinator', 'show', '--task', typed_task_id)
        typed_card = wait_for('the question without a packet', lambda: next((item for item in chat_state()['items']
            if item['type'] == 'card' and item['kind'] == 'question' and item['taskID'] == typed_task_id
            and item.get('isCurrent') is True), None))
        typed_id = typed_card['id']
        require(typed_card['packetVersion'] is None, f'The second task unexpectedly has a packet: {typed_card}')
        require(typed_card.get('defaultReplyTarget') == 'task', f'A waiting task should default to the task: {typed_card}')
        wait_for('the second question to open', lambda: typed_id in chat_state()['expandedCardIDs'])
        page_action('type', f'reply-{typed_id}', TYPED_REPLY)
        typed_answer = wait_for('the typed answer in its card thread', lambda: answered(typed_id, TYPED_REPLY))
        typed_input = wait_for('the typed answer in the fake task input', lambda: received(typed_session_id, TYPED_REPLY))
        require('Review note on packet' not in typed_input, f'The no-packet reply used a review note: {typed_input}')
        capture('coordinator-question-typed-answer')
        step('typed answer reached a task without a packet', taskID=typed_task_id, cardID=typed_id,
             answer=typed_answer['answer'], thread=typed_answer['thread'], fakeAgentReceived=typed_input[-300:])

        # 8. A current question offers the same Merge confirmation as a
        # packet. Cancel it; the fake gh only permits read-only pr view calls.
        pull_request = f'https://github.com/{to_ship_check.SLUG}/pull/1'
        cli_result('action', 'run', 'workspace.set-annotation', '--workspace', task['setup']['taskSpaceWorkspaceID'],
                   'key=github-pr', 'text=PR #1', f'url={pull_request}')
        merge_card = wait_for('Merge on the current question', lambda: (lambda item: item if item and
            item.get('isCurrent') and item.get('canMerge') else None)(card(option_id)), timeout=45, interval=0.5)
        require(merge_card['kind'] == 'question', f'Merge was offered on another card: {merge_card}')
        cli_result('coordinator', 'show', '--task', task_id)
        if option_id not in chat_state()['expandedCardIDs']:
            page_action('click', f'expand-{option_id}')
        wait_for('the current question to open for Merge', lambda: option_id in chat_state()['expandedCardIDs'])
        page_action('click', f'merge-{option_id}')
        wait_for('the question Merge confirmation', lambda: 'Merge PR #1 as it is now?' in
                 run_tool(driver, 'texts', pid, '*').stdout, timeout=10, interval=0.3)
        capture('coordinator-question-merge-confirmation')
        run_tool(helper, 'press', pid, 'title:Cancel')
        wait_for('Cancel to close the question Merge confirmation', lambda: 'Merge PR #1 as it is now?' not in
                 run_tool(driver, 'texts', pid, '*').stdout, timeout=10, interval=0.3)
        unchanged = cli_result('task', 'get', task_id)
        require(not unchanged.get('mergeRequestedAt'), 'Cancel accepted the task merge')
        gh_calls = fake_bin / 'gh-calls.jsonl'
        fake_reads = wait_for('the disposable GitHub read', lambda: [json.loads(line) for line in gh_calls.read_text().splitlines()]
                             if gh_calls.is_file() else None, timeout=30, interval=0.5)
        require(fake_reads and all(args[:2] == ['pr', 'view'] for args in fake_reads),
                f'The disposable GitHub fixture did not record only read-only calls: {fake_reads}')
        step('question Merge confirmation canceled', taskID=task_id, cardID=option_id,
             mergeRequestedAt=unchanged.get('mergeRequestedAt'), fakeGitHubCalls=fake_reads)

        # 9. The event store, rather than page memory, owns answers and
        # threads. Restart this isolated app with exactly the same homes.
        persisted = {item['id']: dict(answer=item['answer'], thread=item['thread'])
                     for item in (option_answer, typed_answer)}
        instance.kill()
        instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-app.log')
        pid = instance.process.pid
        instance.wait_until_ready()
        wait_for('the coordinator after relaunch', lambda: instance.query('coordinator.status')['state'] == 'running',
                 timeout=90, interval=1)
        cli_result('coordinator', 'show', '--task', task_id)
        for card_id, expected_state in persisted.items():
            restored = wait_for('the saved answer and thread after relaunch', lambda: answered(card_id, expected_state['answer']))
            require(restored['thread'] == expected_state['thread'],
                    f'The thread changed after relaunch: before={expected_state}, after={restored}')
        capture('coordinator-question-after-relaunch')
        step('answers and threads survived relaunch', cards=persisted, runtimeHome=str(runtime_home), userHome=str(user_home))

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
