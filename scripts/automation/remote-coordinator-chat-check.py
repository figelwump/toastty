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
- `coordinator show` covers the coordinator's terminal with the chat;
- packet v1, packet v2 and a question share one task card at its newest
  activity, with both reports reachable from that card;
- `coordinator show --task` opens and scrolls to the task's packet card;
- a reply typed into the open card reaches the task's agent as
  `Review note on packet v1: …`, and the task leaves Needs you;
- Full report opens toastty://coordinator/report/<task>/1 in the right panel;
- report marks and an addressed composer message remain in the task thread;
- the project filter keeps one current task card, and Today and All tasks
  open that same card beside the chat;
- Try chips fill the composer without sending, then hide after a user request;
- the blocked composer's Open terminal button shows the raw terminal again.
- a question with two options changes a finished task's sidebar badge to
  question; a page button answers it and restores the finished badge;
- a typed question reply reaches a waiting task that has no packet;
- answers and task-scoped threads survive an app relaunch in the same runtime.
- a question's native task menu opens its task space;
- a question with a fake mergeable pull request offers Merge, and Cancel
  leaves the task unmerged.
- a taskless project question sends an exact route envelope to the fake
  coordinator, saves its delivery state, accepts a synthetic transcript echo
  without duplicating the reply, and persists;
- a stuck task shows its failure, opens its task space and offers the native
  Archive confirmation, which is canceled without deleting files.
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
import shlex
import struct
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
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
    route_context = None

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[chat-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_tool(tool, *arguments, check=True):
        result = subprocess.run([str(tool), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        require(check is False or result.returncode == 0, f'{tool.name} {arguments} failed: {result.stderr}')
        return result

    def cli_result(*arguments, session=None, stdin=None):
        env = dict(cli_environment)
        if session:
            env.update(TOASTTY_SESSION_ID=session['sessionID'], TOASTTY_PANEL_ID=session['panelID'])
        result = subprocess.run([str(cli), '--json', '--socket-path', socket_path, *arguments], env=env, cwd=work,
                                input=stdin, capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments[:3])} failed ({result.returncode}): {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-app.log')
    pid = instance.process.pid

    def chat_state():
        return instance.query('coordinator.chat.state')

    def card(card_id):
        return next((item for item in chat_state()['items']
                     if item['type'] == 'card' and item['id'] == card_id), None)

    def task_cards(task_id):
        return [item for item in chat_state()['items'] if item['type'] == 'card' and item['taskID'] == task_id]

    def single_task_card(task_id, kind, versions):
        items = task_cards(task_id)
        if len(items) == 1 and items[0]['kind'] == kind and items[0].get('packetVersions') == versions:
            require(items[0]['isCurrent'] and not items[0]['superseded'], f'The task card is not current: {items}')
            return items[0]
        return None

    def thread_entry(task_id, role, text):
        items = task_cards(task_id)
        return next((entry for item in items for entry in item.get('thread', [])
                     if entry['role'] == role and entry['text'] == text), None)

    def rendered(view):
        response = instance.request('automation.coordinator_page_state', {})
        require(response.get('ok'), f'Could not inspect coordinator pages: {response}')
        return next((page for page in response['result']['pages'] if page['view'] == view), None)

    def prepare_wide_chat(label):
        # Match the incoming dashboard scenario's wide layout. The window
        # also contains the sidebar and right panel, so its width alone does
        # not prove the center exceeds the filter's 720 px breakpoint.
        actual_size = json.loads(run_tool(helper, 'resize', pid, 1600, 1000).stdout)
        step('wide window requested', scenario=label, requestedPoints=dict(width=1600, height=1000),
             actualWindowPoints=actual_size)
        center = wait_for('a chat viewport wider than 720 px', lambda: (page := rendered('chat'))
                          and page['viewportWidth'] > 720 and page, timeout=15, interval=0.3)
        step('wide chat layout established', scenario=label, requestedPoints=dict(width=1600, height=1000),
             actualWindowPoints=actual_size, viewportWidth=center['viewportWidth'])
        return center

    def dashboard(view):
        state, center = rendered(view), rendered('chat')
        if not state or not center:
            return None
        right = instance.query('workspace.snapshot', workspaceID=coordinator['workspaceID'])['rightPanel']
        summary_tabs = [tab for tab in right['tabs'] if (tab.get('url') or '').rstrip('/') in
                        ('toastty://coordinator/today', 'toastty://coordinator/tasks')]
        if right['isVisible'] and len(summary_tabs) == 1 and summary_tabs[0]['panelID'] == right['activePanelID']:
            return state
        return None

    def report_action(panel_id, action, element_id, text=None):
        payload = dict(panelID=panel_id, action=action, elementID=element_id)
        if text is not None:
            payload['text'] = text
        return instance.request('automation.coordinator_report_action', payload).get('ok', False)

    def page_action(action, element_id, text=None):
        payload = dict(action=action, elementID=element_id)
        if text is not None:
            payload['text'] = text
        response = instance.request('automation.coordinator_chat_action', payload)
        require(response.get('ok'), f'The page could not {action} {element_id}: {response}')
        return response

    def wait_for_page_element(element_id):
        def visible():
            response = instance.request('automation.coordinator_chat_action',
                                        dict(action='visible', elementID=element_id))
            if not response.get('ok'):
                error = response.get('error') or {}
                require(error.get('code') == 'INVALID_PAYLOAD'
                        and error.get('message', '').startswith('no open chat page has'),
                        f'The page visibility probe failed: {response}')
                return False
            return True
        wait_for(f'the rendered page element {element_id}', visible)

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

    def route_diagnostics(error):
        diagnostics = dict(error=str(error), context=route_context)

        def tail(path, limit):
            try:
                with path.open('rb') as stream:
                    size = stream.seek(0, os.SEEK_END)
                    stream.seek(max(0, size - limit))
                    contents = stream.read(limit).decode('utf-8', errors='replace')
                if size > limit:
                    contents = contents.partition('\n')[2]
                return dict(path=str(path), exists=True, truncated=size > limit, text=contents)
            except FileNotFoundError:
                return dict(path=str(path), exists=False, text='')
            except OSError as read_error:
                return dict(path=str(path), error=str(read_error), text='')

        try:
            diagnostics['chatState'] = chat_state()  # Instance socket reads have a 15-second timeout.
            diagnostics['nativeNotice'] = diagnostics['chatState'].get('notice')
        except Exception as query_error:
            diagnostics['chatStateError'] = str(query_error)
        stored = tail(runtime_home / 'coordinator/events.jsonl', 256 * 1024)
        diagnostics['persistedEventLog'] = stored
        route_replies = []
        for line in stored['text'].splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get('questionID') == route_context.get('questionID') and event.get('kind') == 'reply':
                route_replies.append(event)
        diagnostics['persistedRouteReplies'] = route_replies
        diagnostics['fakeSessionInput'] = tail(fake_bin / 'sessions' / f"{route_context['sessionID']}.input", 64 * 1024)
        path = artifacts / f'{PREFIX}-route-diagnostics.json'
        path.write_text(json.dumps(diagnostics, indent=2))
        step('route check failed', diagnosticsFile=path.name, nativeNotice=diagnostics.get('nativeNotice'),
             inputState=diagnostics.get('chatState', {}).get('inputState'),
             persistedReplies=len(route_replies), fakeInputExists=diagnostics['fakeSessionInput'].get('exists'))

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
        wait_for('the rendered center chat', lambda: rendered('chat'))
        state = wait_for('the chat page to show the cards', lambda: (lambda s: s if
                         [i['kind'] for i in s['items'] if i['type'] == 'card'] == ['packet', 'note'] else None)(
                         chat_state()), timeout=30, interval=0.5)
        packet_card = next(i for i in state['items'] if i['type'] == 'card' and i['kind'] == 'packet')
        require(packet_card['taskID'] == task_id and packet_card['packetVersion'] == 1, f'Packet card: {packet_card}')
        require(single_task_card(task_id, 'packet', [1]), 'Task-started was not combined with packet v1')
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        require(listed[coordinator['workspaceID']]['isSelected'], 'The coordinator workspace is not selected')
        bring_to_front()
        startup = wait_for('the Try chips before a user request', lambda: (page := rendered('chat'))
                           and page['suggestionsVisible'] and 'status' in page['suggestionLabels'] and page)
        step('Try chips shown before a user request', labels=startup['suggestionLabels'])
        capture('coordinator-chat-collapsed')

        # 2. show --task opens the task's packet card.
        cli_result('coordinator', 'show', '--task', task_id)
        wait_for('the packet card to open', lambda: packet_card['id'] in chat_state()['expandedCardIDs'], timeout=15, interval=0.3)
        capture('coordinator-chat-expanded')

        # 3. A reply typed into the card reaches the task as a review note.
        bring_to_front()
        wait_for_page_element(f"reply-{packet_card['id']}")
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
        focused_input = json.loads(run_tool(driver, 'focused', pid).stdout)
        step('keyboard reply entered', focusedInput=focused_input,
             frontmostPID=run_tool(helper, 'frontmost-pid').stdout.strip())
        require(focused_input.get('value') == REPLY,
                f'The keyboard reply did not reach the focused field: {focused_input}')
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

        def wait_for_report(version, label):
            expected_url = f'toastty://coordinator/report/{task_id}/{version}'
            diagnostics = dict(expectedURL=expected_url, label=label)

            def loaded():
                snapshot = instance.query('workspace.snapshot', workspaceID=coordinator['workspaceID'])
                diagnostics['workspaceSnapshot'] = snapshot
                right_panel = snapshot['rightPanel']
                browser_states = {}
                for tab in right_panel['tabs']:
                    if tab.get('webDefinition') != 'browser':
                        continue
                    response = instance.request('app_control.run_query',
                                                dict(id='panel.browser.state', args=dict(panelID=tab['panelID'])))
                    browser_states[tab['panelID']] = response.get('result') if response.get('ok') else response
                diagnostics['browserStates'] = browser_states
                active = next((tab for tab in right_panel['tabs']
                               if tab['panelID'] == right_panel.get('activePanelID')
                               and tab.get('url') == expected_url), None)
                if not right_panel['isVisible'] or not active:
                    return None
                browser = browser_states.get(active['panelID']) or {}
                # A model URL alone can race with a live WKWebView that still
                # displays the prior report and republishes its URL.
                if (browser.get('stateRestorableURL') == expected_url and browser.get('observedURL') == expected_url
                        and browser.get('navigationState') == 'finished' and browser.get('isLoading') is False
                        and browser.get('navigationError') is None):
                    return browser
                return None

            try:
                browser = wait_for(label, loaded, timeout=20, interval=0.5)
            except Exception as error:
                diagnostics['error'] = str(error)
                path = artifacts / f'{PREFIX}-report-{label}.json'
                path.write_text(json.dumps(diagnostics, indent=2))
                step('report navigation failed', expectedURL=expected_url, diagnosticsFile=path.name)
                raise
            evidence.setdefault('reportNavigations', []).append(dict(label=label, browserState=browser))
            return browser

        report_state = wait_for_report(1, 'initial-v1')
        time.sleep(1.5)
        capture('coordinator-report')
        step('report opened', url=report_url)

        # Report marks use their own real WebKit controls and native send
        # route. They must survive the later packet and question updates.
        report_id = report_state['panelID']
        wait_for('the report annotation controls', lambda: report_action(report_id, 'click', 'report-annotate'))
        require(report_action(report_id, 'click', 'shot-after-390'), 'Could not place a report mark')
        mark_note = 'Keep the coupon row above the pinned totals bar.'
        require(report_action(report_id, 'type', 'report-note-0', mark_note), 'Could not enter the report mark note')
        capture('coordinator-report-mark')
        require(report_action(report_id, 'click', 'report-send'), 'Could not send the report mark')
        mark_text = f'1 marks on the screenshots:\n1. {mark_note} [after-390]'
        mark_entry = wait_for('the report mark in the task thread', lambda: thread_entry(task_id, 'user-task', mark_text))
        mark_input = wait_for('the report mark in fake task input', lambda: received(task_session['sessionID'], mark_note))
        require(sum(entry['role'] == 'user-task' and entry['text'] == mark_text
                    for item in task_cards(task_id) for entry in item.get('thread', [])) == 1,
                'The report mark was duplicated in the task thread')
        step('report mark reached the task and its thread once', taskID=task_id, entry=mark_entry,
             fakeAgentReceived=mark_input[-400:])

        # 5. This fake agent emits no ready/turn events, as at first-load
        # setup. The blocked composer must offer a way to its terminal.
        require(chat_state()['canSend'] is False, 'The fake agent unexpectedly accepts chat input')
        opened = instance.request('automation.coordinator_chat_action',
                                  dict(action='click', elementID='composer-open-terminal'))
        require(opened.get('ok'), f'The blocked composer did not offer Open terminal: {opened}')
        wait_for('the chat to uncover the terminal', lambda: rendered('chat') is None, timeout=15, interval=0.3)
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        require(listed[coordinator['workspaceID']]['isSelected'], 'Open terminal did not keep the coordinator workspace')
        step('blocked composer opened the raw terminal without sending a message')

        # Keep the CLI route covered as well.
        cli_result('coordinator', 'show')
        wait_for('the chat to reopen', lambda: rendered('chat'), timeout=15, interval=0.3)
        cli_result('coordinator', 'show-terminal')
        wait_for('the CLI to uncover the terminal', lambda: rendered('chat') is None, timeout=15, interval=0.3)
        step('CLI showed the raw terminal')

        # 6. A posted question takes precedence over the task's finished
        # badge. Choosing an option uses the same page reply route as typing.
        revised_packet = json.loads((work / 'packet.json').read_text())
        revised_packet['summary'] = 'Keeps the coupon visible above the pinned totals bar.'
        (work / 'packet-v2.json').write_text(json.dumps(revised_packet))
        published = cli_result('task', 'packet', 'publish', '--file', 'packet-v2.json',
                               '--screenshot', 'before-390.png', '--screenshot', 'after-390.png',
                               '--screenshot', 'after-1280.png', session=task_session)
        require(published['packetVersion'] == 2, f'Packet v2 not published: {published}')
        cli_result('coordinator', 'post', 'packet', '--task', task_id)
        second_packet = wait_for('one task card with both packet versions',
                                 lambda: single_task_card(task_id, 'packet', [1, 2]))
        require(chat_state()['items'][-1]['id'] == second_packet['id'], 'Packet v2 did not move the task card to the end')
        cli_result('coordinator', 'show', '--task', task_id)
        wait_for('the v2 packet card to open', lambda: second_packet['id'] in chat_state()['expandedCardIDs'])
        page_action('click', f"reply-to-task-{second_packet['id']}")
        page_action('type', f"reply-{second_packet['id']}", 'Confirm the v2 coupon placement.')
        wait_for('the v2 review note in the fake task input',
                 lambda: received(task_session['sessionID'], 'Review note on packet v2:'))
        wait_for('the v2 review to leave Needs you', lambda: cli_result('task', 'get', task_id)['readyForReviewAt'] is None)
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
        require(single_task_card(task_id, 'question', [1, 2]), 'The question duplicated the packet card or lost its reports')
        require(thread_entry(task_id, 'user-task', mark_text), 'Packet v2 or the question lost the report mark')
        require(chat_state()['items'][-1]['id'] == option_id, 'The question did not place the task card at newest activity')
        wait_for('the question card to open', lambda: option_id in chat_state()['expandedCardIDs'])
        page_action('click', f'report-{option_id}')
        wait_for_report(2, 'question-v2')
        page_action('click', f'report-{option_id}-1')
        wait_for_report(1, 'history-v1')
        step('one task card retained both packet versions and opened v1', cardID=option_id,
             packetVersions=option_card['packetVersions'], reportURL=report_url)
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

        # One unrelated project makes filtering observable. Use the existing
        # shell-readiness gate before changing that disposable terminal's cwd.
        other_root = root / 'other-project'
        other_root.mkdir()
        subprocess.run(['git', 'init', '-q', str(other_root)], check=True)
        window_id = next(item['windowID'] for item in instance.query('workspace.list')['workspaces']
                         if item['workspaceID'] == workspace_id)
        other_workspace = cli_result('action', 'run', 'workspace.create', '--window', window_id,
                                     'title=Other project', 'parent=none', 'activate=true')['workspaceID']
        other_panel = instance.query('workspace.snapshot', workspaceID=other_workspace)['slotPanelIDs'][0]
        wait_for('the other project shell to accept input', lambda: cli_result(
            'action', 'run', 'terminal.send-text', '--panel', other_panel,
            'text=', 'submit=false', 'allowUnavailable=true').get('available') is True,
            timeout=30, interval=0.5)
        cli_result('action', 'run', 'terminal.send-text', '--panel', other_panel,
                   f'text=cd {shlex.quote(str(other_root))}', 'submit=true')
        wait_for('the other project terminal cwd', lambda: os.path.realpath(
            instance.query('terminal.state', panelID=other_panel)['cwd']) == str(other_root))
        other_task = cli_result('task', 'create', 'Keep the other project separate', '--title', 'Other project task',
                                '--workspace', other_workspace, '--wait', '--timeout', '90')
        cli_result('coordinator', 'post', 'task-started', '--task', other_task['taskID'])
        cli_result('coordinator', 'tasks')
        wait_for('All tasks beside the center chat', lambda: dashboard('tasks'))
        bring_to_front()
        prepare_wide_chat('project filter and dashboards')
        rows = {row['taskID']: row for row in chat_state()['tasks']}
        project_id, other_project_id = rows[task_id]['projectID'], rows[other_task['taskID']]['projectID']
        require(project_id != other_project_id, 'The project fixtures did not create distinct project IDs')
        project_index = next(index for index, project in enumerate(chat_state()['projects']) if project['id'] == project_id)
        wait_for('the wide chat project filter', lambda: (page := rendered('chat')) and page['projectFilterVisible'])
        page_action('click', f'project-filter-{project_index}')
        wait_for('the native project filter', lambda: chat_state()['projectFilter'] == project_id)
        other_card = wait_for('the other project card', lambda: next(iter(task_cards(other_task['taskID'])), None))
        global_note = next(item['id'] for item in chat_state()['items']
                           if item['type'] == 'card' and item['kind'] == 'note' and item['taskID'] is None)

        def filtered_center():
            page = rendered('chat')
            return page if page and page['viewportWidth'] > 720 and page['projectFilterVisible'] \
                and page['projectFilter'] == project_id and page['visibleItemIDs'].count(option_id) == 1 \
                and other_card['id'] not in page['visibleItemIDs'] and global_note in page['visibleItemIDs'] else None

        wait_for('the project filter to retain one current card and the global note', filtered_center)
        require(single_task_card(task_id, 'question', [1, 2]), 'Filtering changed the single current task card')
        filtered_tasks = wait_for('All tasks to use the same project filter', lambda: (page := dashboard('tasks'))
                                 and page['projectFilter'] == project_id and task_id in page['visibleTaskRowIDs']
                                 and other_task['taskID'] not in page['visibleTaskRowIDs'] and page)
        cli_result('coordinator', 'show', '--task', task_id)
        wait_for_page_element(f'collapse-{option_id}')
        page_action('click', f'collapse-{option_id}')
        wait_for('the current card to close before Today opens it', lambda: option_id not in chat_state()['expandedCardIDs'])
        page_action('click', 'dashboard-tab-today')
        today = wait_for('Today to retain the shared project filter', lambda: (page := dashboard('today'))
                         and page['projectFilter'] == project_id and task_id in page['todaySections']['needsYou']
                         and other_task['taskID'] not in page['visibleTaskRowIDs'] and page)
        page_action('click', f"today-row-{rows[task_id]['id']}")
        wait_for('Today to open the same task card', lambda: chat_state()['currentTaskID'] == task_id
                 and option_id in chat_state()['expandedCardIDs'])
        require(dashboard('today'), 'Opening the task card removed Today or the center chat')
        capture('coordinator-filtered-today-card')
        wait_for_page_element(f'collapse-{option_id}')
        page_action('click', f'collapse-{option_id}')
        page_action('click', 'dashboard-tab-tasks')
        wait_for('All tasks to reopen beside the center chat', lambda: dashboard('tasks'))
        page_action('click', f"task-row-{rows[task_id]['id']}")
        page_action('focus', 'dashboard')
        wait_for('All tasks to own keyboard focus', lambda: (page := dashboard('tasks'))
                 and page['documentHasFocus'] and page['focusedElementID'] == 'dashboard')
        run_tool(driver, 'key', KEY_RETURN)
        wait_for('All tasks Return to open the same task card', lambda: chat_state()['currentTaskID'] == task_id
                 and option_id in chat_state()['expandedCardIDs'])
        require(dashboard('tasks') and filtered_center(), 'Opening the task lost the shared project filter or dashboard')
        capture('coordinator-filtered-all-tasks-card')
        step('project filter and both dashboards retain one task card', taskID=task_id, cardID=option_id,
             projectID=project_id, hiddenTaskID=other_task['taskID'], today=today,
             allTasks=filtered_tasks, packetVersions=[1, 2])
        page_action('click', 'project-filter-all')
        wait_for('all project cards to return', lambda: chat_state()['projectFilter'] is None
                 and other_card['id'] in (rendered('chat') or {}).get('visibleItemIDs', []))

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
        wait_for('the coordinator chat after the native menu', lambda: rendered('chat') and any(
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

        # 9. A failed agent offers recovery on the card. Cancel the real
        # native archive dialog; the sentinel makes accidental deletion fail.
        sentinel = user_home / 'keep-after-archive-cancel.txt'
        sentinel.write_text('Archive cancellation must preserve this file.\n')
        failure = 'The fixture build stopped because its required package is missing.'
        cli_result('session', 'status', '--session', typed_session_id, '--kind', 'error',
                   '--summary', failure, '--detail', failure)
        cli_result('coordinator', 'show', '--task', typed_task_id)
        stuck = wait_for('the stuck task card with its failure and Archive action', lambda: (lambda items:
            items[0] if len(items) == 1 and items[0].get('stage') == 'stuck'
            and items[0].get('failureText') == failure and items[0].get('canArchive') else None)(task_cards(typed_task_id)))
        stuck_id = stuck['id']
        wait_for('the stuck card to open', lambda: stuck_id in chat_state()['expandedCardIDs'])
        wait_for('the visible failure summary', lambda: failure in run_tool(driver, 'texts', pid, '*').stdout)
        capture('coordinator-stuck-card')
        page_action('click', f'open-stuck-{stuck_id}')
        wait_for('the stuck task space to open', lambda: any(
            item['workspaceID'] == typed_task['setup']['taskSpaceWorkspaceID'] and item['isSelected']
            for item in instance.query('workspace.list')['workspaces']))
        cli_result('coordinator', 'show', '--task', typed_task_id)
        wait_for('the stuck card after opening its space', lambda: stuck_id in chat_state()['expandedCardIDs'])
        bring_to_front()

        # Native expansion state survives workspace navigation. It can be
        # current before the replacement web page has received its payload.
        wait_for_page_element(f'archive-{stuck_id}')

        def archive_probe(tool, *arguments):
            try:
                result = subprocess.run([str(tool), *map(str, arguments)], capture_output=True, text=True, timeout=3)
                probe = dict(returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)
                try:
                    probe['value'] = json.loads(result.stdout)
                except ValueError:
                    pass
                return probe
            except subprocess.TimeoutExpired:
                return dict(error='The probe exceeded three seconds.', arguments=list(map(str, arguments)))

        def archive_diagnostics(error, opening):
            probes = {name: archive_probe(driver, name, pid, *arguments)
                      for name, arguments in [('texts', ['*']), ('labels', ['*']), ('windows', []), ('dialog', [])]}
            probes['frontmostPID'] = archive_probe(helper, 'frontmost-pid')
            probes['helperDump'] = archive_probe(helper, 'dump', pid)
            probes['expectedConfirmation'] = confirmation
            probes['pageActionCompleted'] = opening.done()
            if opening.done():
                try:
                    probes['pageActionResult'] = opening.result()
                except Exception as action_error:
                    probes['pageActionError'] = str(action_error)
            probes['error'] = str(error)
            path = artifacts / f'{PREFIX}-archive-diagnostics.json'
            path.write_text(json.dumps(probes, indent=2))
            (artifacts / f'{PREFIX}-archive-ax.txt').write_text(probes['helperDump'].get('stdout', ''))
            dialog = probes['dialog'].get('value') or {}
            texts = probes['texts'].get('value') or []
            step('Archive confirmation failed', diagnosticsFile=path.name,
                 observedDialog=dialog, observedFailureText=[text for text in texts if 'Unable to Archive' in text],
                 pageActionError=probes.get('pageActionError'), expectedConfirmation=confirmation)

        # NSAlert runs a modal loop. Keep one bounded page action in flight
        # while the main thread cancels it through Accessibility.
        with ThreadPoolExecutor(max_workers=1) as archive_actions:
            opening = archive_actions.submit(page_action, 'click', f'archive-{stuck_id}')
            confirmation = f"Archive {typed_task['title']}?"
            try:
                def archive_confirmation():
                    if opening.done():
                        opening.result()  # Surface a rejected page action without waiting for the dialog deadline.
                    probe = archive_probe(driver, 'dialog', pid)
                    require(probe.get('returncode') == 0, f'The native dialog probe failed: {probe}')
                    dialog = probe.get('value') or {}
                    texts = dialog.get('texts', [])
                    if any(text.startswith('Unable to Archive') for text in texts):
                        raise AssertionError(f'Archive was refused: {json.dumps(dialog, ensure_ascii=False)}')
                    return dialog if confirmation in texts and 'Cancel' in dialog.get('buttons', []) else None

                dialog = wait_for('the native Archive confirmation', archive_confirmation, timeout=10, interval=0.3)
                step('native Archive confirmation observed', dialog=dialog)
                # Match Cancel inside the native dialog, never a page button
                # or the destructive Archive action.
                canceled = archive_probe(driver, 'dialog-press', pid, 'Cancel')
                require(canceled.get('returncode') == 0, f'Could not cancel the native Archive dialog: {canceled}')
                opening.result(timeout=20)
            except Exception as error:
                archive_diagnostics(error, opening)
                raise
            finally:
                remaining_dialog = archive_probe(driver, 'dialog', pid).get('value') or {}
                if 'Cancel' in remaining_dialog.get('buttons', []):
                    archive_probe(driver, 'dialog-press', pid, 'Cancel')
        require(sentinel.read_text() == 'Archive cancellation must preserve this file.\n', 'Archive removed the sentinel')
        archive_record = cli_result('task', 'get', typed_task_id)
        require(not archive_record.get('archivedAt'), 'Cancel archived the stuck task')
        require(any(item['workspaceID'] == typed_task['setup']['taskSpaceWorkspaceID']
                    for item in instance.query('workspace.list')['workspaces']), 'Cancel removed the task space')
        step('stuck task opened its space and canceled native Archive', taskID=typed_task_id,
             failure=failure, archivedAt=archive_record.get('archivedAt'), preservedFile=str(sentinel))

        # 10. Use the public Claude hook ingestion route to bind a synthetic
        # transcript and open a prompt. A transcript's end_turn alone cannot
        # authorize input. No real provider or new automation API is involved.
        coordinator_session_path = fake_bin / 'sessions' / f"{coordinator['sessionID']}.json"
        coordinator_session = json.loads(coordinator_session_path.read_text())
        route_context = dict(sessionID=coordinator['sessionID'], questionID=None)
        native_id = str(uuid.uuid4())
        transcript = root / f'{native_id}.jsonl'

        def transcript_message(role, text, record_id):
            message = dict(role=role, content=text if role == 'user' else [dict(type='text', text=text)])
            if role == 'assistant':
                message['stop_reason'] = 'end_turn'
            row = dict(type=role, sessionId=native_id, uuid=record_id, isSidechain=False,
                       timestamp=datetime.now(timezone.utc).isoformat(), message=message)
            with transcript.open('a') as stream:
                stream.write(json.dumps(row) + '\n')

        def hook(name, **fields):
            cli_result('session', 'ingest-agent-event', '--source', 'claude-hooks',
                       session=coordinator_session, stdin=json.dumps(dict(hook_event_name=name,
                       session_id=native_id, transcript_path=str(transcript), cwd=coordinator_session['cwd'], **fields)))

        transcript.touch()
        hook('SessionStart')
        transcript_message('user', session_check.FIRST_MESSAGE, 'fixture-initial-user')
        transcript_message('assistant', 'Ready for the project choice.', 'fixture-initial-answer')
        wait_for('the synthetic transcript to bind', lambda: any(
            item.get('text') == 'Ready for the project choice.' for item in chat_state()['items']))
        hook('UserPromptSubmit', turn_id='fixture-initial-turn', prompt='Synthetic coordinator ready check')
        wait_for('the submitted coordinator turn to become working',
                 lambda: chat_state().get('inputState') == 'working', timeout=30, interval=0.3)
        hook('Stop', turn_id='fixture-initial-turn', last_assistant_message='Ready for the project choice.')

        def route_input_ready():
            state = chat_state()
            return state if state.get('inputState') == 'openPrompt' and state['canSend'] else None

        wait_for('the coordinator input prompt after Stop', route_input_ready, timeout=30, interval=0.3)

        # A Try chip fills a draft. It must not send until the user submits.
        prepare_wide_chat('Try chips and addressed composer')
        suggestions = wait_for('Try chips after the launch prompt', lambda: (page := rendered('chat'))
                               and page['suggestionsVisible'] and 'one it has to ask about' in page['suggestionLabels'] and page)
        coordinator_input = fake_bin / 'sessions' / f"{coordinator['sessionID']}.input"
        input_before_suggestion = coordinator_input.read_text() if coordinator_input.exists() else ''
        bring_to_front()
        wait_for('the Try chip to press', lambda: run_tool(helper, 'press', pid,
                 'title:one it has to ask about', check=False).returncode == 0, timeout=15, interval=0.3)
        suggestion_draft = wait_for('the Try chip draft in the focused composer', lambda: (focused := json.loads(
            run_tool(driver, 'focused', pid).stdout)) and focused.get('value') == 'Add a dark mode toggle' and focused)
        require((coordinator_input.read_text() if coordinator_input.exists() else '') == input_before_suggestion,
                'The Try chip sent a request instead of preparing a draft')
        capture('coordinator-try-chip-draft')
        step('Try chip prepared a composer draft without sending', labels=suggestions['suggestionLabels'],
             focusedInput=suggestion_draft)

        addressed_text = 'Keep the report marks and the question together in this task.'
        require(route_input_ready(), 'The coordinator cannot receive the addressed composer request')
        page_action('type', 'composer-input', f"@{task['slug']} {addressed_text}")
        addressed_entry = wait_for('the addressed composer request in the task thread',
                                  lambda: thread_entry(task_id, 'user-coordinator', addressed_text))
        addressed_input = wait_for('the addressed request in fake coordinator input',
                                   lambda: received(coordinator['sessionID'], addressed_text))
        addressed_line = next((line for line in addressed_input.splitlines()
                               if addressed_text in line and task_id in line and line.startswith('About task ')), None)
        require(addressed_line, f'The addressed request did not carry its task identity: {addressed_input}')
        transcript_message('user', addressed_line, 'fixture-addressed-echo')
        addressed_marker = 'The synthetic coordinator recorded the addressed task request.'
        transcript_message('assistant', addressed_marker, 'fixture-addressed-echo-read')
        wait_for('the addressed transcript receipt', lambda: any(
            item.get('text') == addressed_marker for item in chat_state()['items']))
        wait_for('Try chips to hide after the real user request', lambda: chat_state()['hasUserRequests']
                 and (page := rendered('chat')) and not page['suggestionsVisible'])
        require(single_task_card(task_id, 'question', [1, 2]), 'The addressed request duplicated or replaced the task card')
        require(thread_entry(task_id, 'user-task', mark_text), 'The addressed request lost the report mark')
        require(sum(entry['role'] == 'user-coordinator' and entry['text'] == addressed_text
                    for item in task_cards(task_id) for entry in item.get('thread', [])) == 1,
                'The addressed request transcript echo duplicated its thread entry')
        require(not any(item['type'] == 'message' and item.get('text') == addressed_text
                        for item in chat_state()['items']), 'The addressed request leaked into the main transcript')
        cli_result('coordinator', 'show', '--task', task_id)
        wait_for('the addressed thread to render in the current card', lambda: (page := rendered('chat'))
                 and addressed_entry['id'] in page['visibleThreadItemIDs'] and mark_entry['id'] in page['visibleThreadItemIDs'])
        capture('coordinator-addressed-current-card')
        step('addressed composer request and report mark retained in one card', taskID=task_id,
             cardID=option_id, addressedEntry=addressed_entry, markEntry=mark_entry,
             fakeAgentReceived=addressed_line)

        # Reopen the synthetic provider prompt in order before testing the
        # independent project-route answer. Do not infer readiness from text.
        hook('UserPromptSubmit', turn_id='fixture-addressed-turn', prompt=addressed_line)
        wait_for('the addressed coordinator turn to become working',
                 lambda: chat_state().get('inputState') == 'working', timeout=30, interval=0.3)
        hook('Stop', turn_id='fixture-addressed-turn', last_assistant_message=addressed_marker)
        wait_for('the coordinator prompt after the addressed request', route_input_ready, timeout=30, interval=0.3)
        route_question = """Which project is “Add a dark mode toggle” for?
Both projects have settings."""
        route_options = [str(user_home), str(work)]
        cli_result('coordinator', 'post', 'question', '--option', route_options[0],
                   '--option', route_options[1], route_question)
        cli_result('coordinator', 'show')
        route_card = wait_for('the taskless route question', lambda: next((item for item in chat_state()['items']
            if item['type'] == 'card' and item['kind'] == 'question' and item.get('taskID') is None
            and item.get('options') == route_options), None))
        route_id = route_card['id']
        route_context['questionID'] = route_id
        events_file = runtime_home / 'coordinator/events.jsonl'

        def route_events():
            return [event for line in events_file.read_text().splitlines()
                    if (event := json.loads(line)).get('kind') == 'reply' and event.get('questionID') == route_id]

        wait_for('the route input prompt after showing the question', route_input_ready, timeout=30, interval=0.3)
        capture('coordinator-route-question')
        require(route_input_ready(), 'The coordinator input prompt changed before the route click')
        page_action('click', f'option-{route_id}-0')
        received_route = wait_for('the strict route envelope in fake coordinator input',
                                 lambda: received(coordinator['sessionID'], 'Coordinator route answer: '))
        envelopes = [line for line in received_route.splitlines() if line.startswith('Coordinator route answer: ')]
        require(len(envelopes) == 1, f'Expected one route send: {envelopes}')
        envelope = json.loads(envelopes[0].removeprefix('Coordinator route answer: '))
        require(set(envelope) == {'questionID', 'replyID', 'question', 'answer'} and
                envelope['questionID'] == route_id and envelope['question'] == route_question and
                envelope['answer'] == route_options[0], f'Wrong route envelope: {envelope}')
        uuid.UUID(envelope['replyID'])
        pending = wait_for('the saved pending route reply', lambda: next(
            (event for event in route_events() if event.get('delivery') == 'pending'), None))
        require(pending['id'] == envelope['replyID'], 'The pending route reply changed identity')

        def route_delivery_outcome():
            if any(event.get('delivery') == 'accepted' for event in route_events()):
                return 'accepted'
            if (chat_state().get('notice') or {}).get('text') == \
                    'The message may not have reached the coordinator. Check its terminal.':
                return 'uncertain'
            return None

        outcome = wait_for('the observed route delivery outcome', route_delivery_outcome, timeout=20, interval=0.3)
        if outcome == 'accepted':
            wait_for('the answer after accepted route delivery', lambda: (item := card(route_id))
                     and item.get('answer') == route_options[0] and not item.get('answerPending'))
        else:
            require(card(route_id)['answer'] is None and card(route_id)['answerPending'],
                    'An unconfirmed route answer was presented as delivered')
            capture('coordinator-route-pending')
        transcript_message('user', envelopes[0], 'fixture-route-echo')
        # The answer may already be visible. A later transcript marker proves
        # the echo was consumed before checking durable reply deduplication.
        echo_marker = 'The synthetic coordinator recorded the project choice.'
        transcript_message('assistant', echo_marker, 'fixture-route-echo-read')
        wait_for('the transcript echo to be consumed', lambda: any(
            item.get('text') == echo_marker for item in chat_state()['items']))
        wait_for('the route answer after its exact transcript echo', lambda: (item := card(route_id))
                 and item.get('answer') == route_options[0] and not item.get('answerPending') and item)
        accepted = wait_for('the accepted route reply on disk', lambda: (events := route_events())
                            and events[-1].get('delivery') == 'accepted' and events)
        require({event['id'] for event in accepted} == {envelope['replyID']}, 'Confirmation duplicated the route reply')
        accepted_rows = [event for event in accepted if event.get('delivery') == 'accepted']
        require(len(accepted_rows) == 1 and accepted_rows[0].get('sourceID') == f"route-accepted:{envelope['replyID']}",
                f'The transcript echo duplicated the accepted route source: {accepted_rows}')
        capture('coordinator-route-answered')
        step('taskless route answer delivered and transcript echo deduplicated', cardID=route_id, envelope=envelope,
             deliveryOutcome=outcome, uncertainOutcomeObserved=outcome == 'uncertain',
             deliveries=[event.get('delivery') for event in accepted],
             providerEvidence='Synthetic Claude hook input and transcript echo; real provider behavior is not covered.')

        # 11. The event store, rather than page memory, owns answers and
        # threads. Restart this isolated app with exactly the same homes.
        persisted = {item['id']: dict(answer=item['answer'], thread=item['thread'])
                     for item in (card(option_id), card(typed_id))}
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
        restored_route = wait_for('the saved route answer after relaunch', lambda: (item := card(route_id))
                                 and item.get('answer') == route_options[0] and item)
        require(not restored_route['answerPending'], 'The confirmed route answer became pending after relaunch')
        capture('coordinator-question-after-relaunch')
        step('answers and threads survived relaunch', cards=persisted, runtimeHome=str(runtime_home), userHome=str(user_home))

        evidence['status'] = 'passed'
    except Exception as error:
        diagnostics = dict(error=str(error))
        for name, read in [('chatState', chat_state),
                           ('focusedInput', lambda: json.loads(run_tool(driver, 'focused', pid).stdout)),
                           ('frontmostPID', lambda: run_tool(helper, 'frontmost-pid').stdout.strip()),
                           ('accessibilityTree', lambda: run_tool(helper, 'dump', pid).stdout)]:
            try:
                diagnostics[name] = read()
            except Exception as probe_error:
                diagnostics[name] = dict(error=str(probe_error))
        (artifacts / f'{PREFIX}-failure-diagnostics.json').write_text(json.dumps(diagnostics, indent=2))
        try:
            capture('coordinator-failed')
        except Exception:
            pass
        if route_context is not None:
            route_diagnostics(error)
        raise
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / f'{PREFIX}-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[chat-check] passed', flush=True)


if __name__ == '__main__':
    main()
