#!/usr/bin/env python3
"""Run the coordinator chat end to end with a real Claude coordinator.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-chat-e2e-check.py'. It reruns
itself from Terminal in the logged-in GUI session, where the Claude login is
readable, and uses the host's Claude subscription for a short run. It needs an
unlocked screen.

The check starts its own instance of the wrapper's build in automation mode,
with a throwaway runtime home, a throwaway git repository as the user home and
the only project, `merge = "direct"` for it, and Claude for the coordinator and
the task. It drives the chat page with automation.coordinator_chat_action and
captures the window with automation.capture_screenshot at each step:

1. the chat shows the running coordinator, and a request typed into its
   composer makes the coordinator create and start a task;
2. the task publishes packet v1 with screenshots, and its packet card opens,
   and Full report opens in the right panel;
3. a question asked from the card's **to coordinator** reply reaches the
   coordinator with the task named, and the chat shows only the typed text,
   in the task card's thread; then a reply to the task reaches its agent as
   `Review note on packet v1: …`, and the task leaves Needs you;
4. packet v2 adds a new card, and the v1 card collapses;
5. with a pull request link on the task, Open PR opens it in the right panel;
   Merge asks first, naming the direct merge policy, and Merge in the
   question merges at once: the task is done.

The project's origin is a local bare repository, and a fake `gh` from
remote-task-merge-check.py, first on the instance's login-shell PATH,
serves the pull request and merges by pushing to origin's main, so nothing on
GitHub changes.

Each step's outcome is recorded in the evidence file; the check fails at the
first step that does not happen in time.
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
import uuid
import zlib

HERE = Path(__file__).parent


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


create_check = _load('remote_task_create_check', 'remote-task-create-check.py')
queue_check = _load('remote_queue_steer_check', 'remote-queue-steer-check.py')
start_work_check = _load('remote_task_start_work_check', 'remote-task-start-work-check.py')
require, wait_for, Instance = create_check.require, create_check.wait_for, create_check.Instance
panel_ids = start_work_check.panel_ids

merge_check = _load('remote_task_merge_check', 'remote-task-merge-check.py')

PREFIX = 'remote-coordinator-chat-e2e'
SLUG = 'toastty-check/project'
# The fake gh answers for it; the repository does not exist on GitHub.
PULL_REQUEST = f'https://github.com/{SLUG}/pull/9'
ALLOWED_TOOLS = 'Bash,Edit,Write,Read,Glob,Grep,Skill'


def png(path, width, height, bands):
    rows = []
    for y in range(height):
        color = bands[min(len(bands) - 1, y * len(bands) // height)]
        rows.append(b'\x00' + bytes(color) * width)

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


def main():
    if '--in-gui-session' not in sys.argv[1:]:
        queue_check.run_in_gui_session(PREFIX, __file__, ['--in-gui-session'])
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary, cli = bundle / 'Contents/MacOS/Toastty', bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-chat-e2e-', dir='/tmp')).resolve()
    runtime_home, shots = root / 'runtime-home', root / 'shots'
    runtime_home.mkdir()
    shots.mkdir()
    # Claude trusts folders under the host home; the repository stays there.
    parent = Path.home() / 'toastty-queue-steer-checks' / f'chat-e2e-{uuid.uuid4().hex[:8]}'
    origin, repository = parent / 'origin.git', parent / 'project'
    parent.mkdir(parents=True)

    def git(*args, cwd=repository):
        return subprocess.run(['git', '-C', str(cwd), *args], check=True, capture_output=True, text=True).stdout.strip()

    subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(origin)], check=True)
    subprocess.run(['git', 'clone', '-q', str(origin), str(repository)], check=True, capture_output=True)
    git('config', 'user.name', 'Toastty Check')
    git('config', 'user.email', 'check@example.invalid')
    (repository / 'README.md').write_text('Hello world\n\nA throwaway project for a Toastty check.\n')
    (repository / '.git/info/exclude').write_text('.toastty/\n.claude\n')
    git('add', 'README.md')
    git('commit', '-q', '-m', 'Start')
    git('push', '-q', 'origin', 'main')
    # The fake gh, first on the PATH the instance's login shell reports.
    fake_bin, zdotdir = parent / 'bin', parent / 'zdotdir'
    fake_bin.mkdir()
    zdotdir.mkdir()
    gh_state = parent / 'gh-state.json'
    gh_state.write_text(json.dumps(dict(slug=SLUG, project=str(repository), prs={})))
    (fake_bin / 'gh').write_text(merge_check.FAKE_GH)
    (fake_bin / 'gh').chmod(0o755)
    (fake_bin / 'state-path').write_text(str(gh_state))
    for name in ('.zshenv', '.zprofile'):
        (zdotdir / name).write_text(f'[ -f "$HOME/{name}" ] && source "$HOME/{name}"\n')
    (zdotdir / '.zshrc').write_text(f'[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"\nexport PATH="{fake_bin}:$PATH"\n')
    toastty_dir = repository / '.toastty'
    toastty_dir.mkdir()
    if (Path.home() / '.claude').exists():
        (repository / '.claude').symlink_to(Path.home() / '.claude')
    light, dark = (232, 230, 225), (45, 107, 70)
    png(shots / 'before-390.png', 390, 640, [light, light, (214, 228, 239)])
    png(shots / 'after-390.png', 390, 640, [light, (207, 227, 212), dark])

    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    version, argv = start_work_check.provider_profile('claude', environment, repository)
    # --allowedTools takes any number of values; the flag after it ends
    # them, so the trailing task prompt stays the prompt.
    argv = [*argv, '--allowedTools', ALLOWED_TOOLS, '--verbose']
    (toastty_dir / 'agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps(argv)}\ninitialPromptPlacement = "trailing"\n')
    (toastty_dir / 'tasks.toml').write_text(
        '[defaults]\nagent = "claude"\n\n[coordinator]\nagent = "claude"\n\n'
        f'[workspace.{json.dumps(str(repository))}]\nmerge = "direct"\n')
    queue_check.set_directory_trust(repository, True)

    socket_path = str(root / 'socket.sock')
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL=PREFIX,
        TOASTTY_SOCKET_PATH=socket_path,
        TOASTTY_COORDINATOR_AUTOSTART='1',
        TOASTTY_AUTOMATION='1',
        TOASTTY_ARTIFACTS_DIR=str(artifacts),
        CFFIXED_USER_HOME=str(repository),
        ZDOTDIR=str(zdotdir),
        # The app uses its own PATH when the login shell's PATH probe takes
        # longer than its limit, as the GUI session's shell can.
        PATH=f'{fake_bin}:{environment.get("PATH", "/usr/bin:/bin")}',
        DISABLE_AUTOUPDATER='1',
    )
    cli_environment = {key: value for key, value in environment.items()
                       if key not in ('TOASTTY_COORDINATOR_AUTOSTART', 'TOASTTY_AUTOMATION')}
    evidence = dict(status='failed', claude=version, steps=[], captures=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[chat-e2e] {name} {json.dumps(facts, default=str)}', flush=True)

    def cli_result(*arguments):
        result = subprocess.run([str(cli), '--json', '--socket-path', socket_path, *arguments],
                                env=cli_environment, capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments[:3])} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-app.log')

    def chat_state():
        return instance.query('coordinator.chat.state')

    def page(action, element, text=None):
        args = dict(action=action, elementID=element)
        if text is not None:
            args['text'] = text
        return instance.request('automation.coordinator_chat_action', args).get('ok', False)

    def capture(name):
        time.sleep(1.0)
        response = instance.request('automation.capture_screenshot', dict(step=name))
        # The window captures are the evidence this check exists for.
        require(response.get('ok'), f'Could not capture {name}: {response.get("error")}')
        path = artifacts / f'{name}.png'
        shutil.copyfile(response['result']['path'], path)
        evidence['captures'].append(path.name)

    def report_action(panel_id, action, element, text=None):
        args = dict(panelID=panel_id, action=action, elementID=element)
        if text is not None:
            args['text'] = text
        return instance.request('automation.coordinator_report_action', args).get('ok', False)

    def report_panel(task_id, version):
        snapshot = instance.query('workspace.snapshot', workspaceID=coordinator['workspaceID'])
        return next((t['panelID'] for t in snapshot['rightPanel']['tabs']
                     if (t.get('url') or '').startswith(f'toastty://coordinator/report/{task_id}/{version}')), None)

    answered = set()

    def answer_dialogs():
        """Answers a first-run prompt in any agent terminal once, as a person would."""
        for workspace in instance.query('workspace.list')['workspaces']:
            for panel in panel_ids(instance.query('workspace.snapshot', workspaceID=workspace['workspaceID'])):
                try:
                    text = instance.query('terminal.visible-text', panelID=panel, tail=30).get('text', '')
                except AssertionError:
                    continue
                if 'Yes, proceed' in text and 'trust' in text.lower() and (panel, 'trust') not in answered:
                    answered.add((panel, 'trust'))
                    instance.request('app_control.run_action', dict(id='terminal.send-text', args=dict(panelID=panel, text='1', submit=True)))

    def waiting(probe):
        def wrapped():
            answer_dialogs()
            return probe()
        return wrapped

    def terminal_shows(workspace_id, text):
        for panel in panel_ids(instance.query('workspace.snapshot', workspaceID=workspace_id)):
            try:
                screen = instance.query('terminal.visible-text', panelID=panel, tail=200, includeScrollback=True).get('text', '')
            except AssertionError:
                continue
            if text in screen:
                return True
        return False

    def cards(kind=None):
        return [i for i in chat_state()['items'] if i['type'] == 'card' and (kind is None or i['kind'] == kind)]

    def thread_entry(task_id, role, text):
        current = next((c for c in cards() if c.get('taskID') == task_id and c.get('isCurrent')), None)
        return next((entry for entry in (current or {}).get('thread', [])
                     if entry['role'] == role and entry['text'] == text), None)

    def open_card(task_id, version):
        """The task's card for a packet version, opened. A card the
        coordinator posts replaces one the chat added, with a new ID, so the
        card is looked up again before each action."""
        def find():
            matching = [c for c in cards('packet') if c['taskID'] == task_id and c['packetVersion'] == version]
            return next((c for c in matching if not c['superseded']), None) or next(iter(matching), None)
        card = wait_for(f'the v{version} card', find, timeout=30, interval=1)
        if card['id'] not in chat_state()['expandedCardIDs']:
            require(page('click', f"expand-{card['id']}"), f'Could not open the v{version} card')
            wait_for(f'the v{version} card to open', lambda: card['id'] in chat_state()['expandedCardIDs'], timeout=15)
        return card

    try:
        workspace = instance.wait_until_ready()[0]
        workspace_id = workspace['workspaceID']
        coordinator = wait_for('the coordinator to run', waiting(lambda: (lambda s: s if s['state'] == 'running' else None)(
            instance.query('coordinator.status'))), timeout=120, interval=2)
        cli_result('coordinator', 'show')
        wait_for('the chat to accept a message', waiting(lambda: (lambda s: s['pages'] >= 1 and s['canSend'])(chat_state())),
                 timeout=300, interval=3)
        startup = wait_for('the projected coordinator launch prompt', lambda: (lambda s: s if any(
            i.get('role') == 'user' and i.get('text') == 'Use the toastty-coordinator skill.' for i in s['items']) else None)(chat_state()),
            timeout=30, interval=1)
        require(startup['hasUserRequests'] is False, 'The launch prompt hid the initial suggestions')
        require(page('visible', 'suggestions'), 'The Try row is not rendered at startup')
        capture('e2e-1-chat-ready')
        step('1a chat ready', coordinator=coordinator['sessionID'])

        request = (
            f'Please start one task in the project at {repository} (workspace {workspace_id}): change the first line '
            'of README.md from "Hello world" to "Hello coordinator" and commit it. Tell the task agent: when done, '
            'publish a review packet with the toastty-task-verify skill, and attach these two screenshots as a '
            f'before and after pair at width 390: {shots / "before-390.png"} and {shots / "after-390.png"}. '
            'Post the task-started card, and a packet card when its packet arrives.'
        )
        require(page('type', 'composer-input', f'@project {request}'), 'Could not type @project into the composer')
        task = wait_for('the coordinator to create a task', waiting(lambda: (cli_result('task', 'list')['tasks'] or [None])[0]),
                        timeout=600, interval=5)
        task_id = task['taskID']
        wait_for('the first real request to hide suggestions', lambda: chat_state()['hasUserRequests'], timeout=30, interval=1)
        wait_for('the rendered Try row to hide', lambda: not page('visible', 'suggestions'), timeout=30, interval=1)
        capture('e2e-1-task-created')
        step('1b coordinator created the task', taskID=task_id, title=task['title'])
        # The terminal can scroll past the envelope while the coordinator
        # creates the task. Its decoded transcript is the durable receipt:
        # only a valid project envelope renders as @<project title> here.
        project_user = wait_for('the decoded explicit project request', lambda: next(
            (i for i in chat_state()['items'] if i.get('role') == 'user'
             and i.get('text') == f"@{workspace['title']} {request}"), None), timeout=30, interval=1)
        routing_path = Path(coordinator['routingFile'])
        wait_for('the explicit project pick in routing.md',
                 lambda: str(repository) in routing_path.read_text().split('## Picks', 1)[-1], timeout=120, interval=2)
        shutil.copyfile(routing_path, artifacts / f'{PREFIX}-routing.md')
        step('1c explicit project pick recorded', projectRoot=str(repository), routingFile=str(routing_path), item=project_user)

        wait_for('a packet card for v1', waiting(lambda: next(
            (c for c in cards('packet') if c['taskID'] == task_id and c['packetVersion'] == 1), None)), timeout=900, interval=5)
        open_card(task_id, 1)
        capture('e2e-2-packet-open')
        packet = cli_result('task', 'packet', 'get', task_id)
        step('2a packet v1 card opened', screenshots=[s['name'] for s in packet['screenshots']], lookAt=packet['look_at'])
        require(page('click', f"report-{open_card(task_id, 1)['id']}"), 'Could not press Full report')
        wait_for('the report in the right panel', lambda: f'toastty://coordinator/report/{task_id}/1' in json.dumps(
            instance.query('workspace.snapshot', workspaceID=coordinator['workspaceID'])), timeout=20)
        capture('e2e-2-report')
        step('2b report opened', screenshots=len(packet['screenshots']))

        # A question to the coordinator from the card: the coordinator gets
        # it with the task named, and the chat shows only what was typed.
        question = 'In one short sentence, what does this task change? Do not act on it.'
        require(page('click', f"reply-to-coordinator-{open_card(task_id, 1)['id']}"), 'Could not switch the reply to the coordinator')
        require(page('type', f"reply-{open_card(task_id, 1)['id']}", question), 'Could not type the question')
        asked = wait_for('the coordinator question in the task thread',
                         waiting(lambda: thread_entry(task_id, 'user-coordinator', question)), timeout=600, interval=3)
        require(not any(i.get('aboutTaskID') == task_id and i.get('text') == question for i in chat_state()['items']),
                'The scoped question was duplicated outside its card thread')
        capture('e2e-3-asked')
        step('3a question to the coordinator appears in the task thread', item=asked)

        # An exact known slug in the composer uses the same strict ask envelope
        # and durable task thread as a card reply.
        addressed_question = 'What is left to verify? Answer briefly and do not change the task.'
        record = cli_result('task', 'get', task_id)
        wait_for('the composer to accept @task', waiting(lambda: chat_state()['canSend']), timeout=300, interval=2)
        require(page('type', 'composer-input', f"@{record['slug']} {addressed_question}"), 'Could not send @task')
        addressed = wait_for('the @task message in the task thread',
                             waiting(lambda: thread_entry(task_id, 'user-coordinator', addressed_question)), timeout=300, interval=2)
        require(not any(i.get('aboutTaskID') == task_id and i.get('text') == addressed_question for i in chat_state()['items']),
                'The @task message was duplicated outside its card thread')
        capture('e2e-3-addressed')
        step('3b @task uses the strict task envelope and thread', item=addressed, slug=record['slug'])

        reply = 'Please change it to "Hello coordinator!" with an exclamation mark, then publish packet v2 with the same screenshots.'
        # Drive report controls and their WebKit bridge, not task.send.
        require(page('click', f"report-{open_card(task_id, 1)['id']}"), 'Could not reopen the report')
        report_id = wait_for('the report panel', lambda: report_panel(task_id, 1), timeout=20)
        wait_for('the report controls', lambda: report_action(report_id, 'click', 'report-annotate'), timeout=20)
        require(report_action(report_id, 'click', 'shot-after-390'), 'Could not drop a pin')
        require(report_action(report_id, 'type', 'report-note-0', reply), 'Could not enter the mark note')
        capture('e2e-3-report-mark')
        require(report_action(report_id, 'click', 'report-send'), 'Could not send the marks')
        wait_for('the reply to be sent', lambda: (chat_state().get('notice') or {}).get('text', '').startswith('Sent to'), timeout=20)
        mark_text = f'1 marks on the screenshots:\n1. {reply} [after-390]'
        marked = wait_for('the report marks in the task thread',
                          lambda: thread_entry(task_id, 'user-task', mark_text), timeout=30, interval=1)
        current_thread = next(c for c in cards() if c.get('taskID') == task_id and c.get('isCurrent'))['thread']
        require(sum(e['text'] == mark_text and e['role'] == 'user-task' for e in current_thread) == 1,
                'The report marks were duplicated in the task thread')
        step('3c report marks entered the task thread once', item=marked)
        after = cli_result('task', 'get', task_id)
        require(after['readyForReviewAt'] is None, f'The task is still ready for review: {after}')
        task_space = after['setup']['taskSpaceWorkspaceID']
        wait_for('the review note in the task terminal', lambda: terminal_shows(task_space, 'Review note on packet v1'),
                 timeout=60, interval=2)
        wait_for('the marks message in the task terminal', lambda: terminal_shows(task_space, '1 marks on the screenshots:')
                 and terminal_shows(task_space, '[after-390]'), timeout=60, interval=2)
        # The agent's turn starts a moment after the note arrives.
        working = wait_for('the task to leave Needs you', lambda: (lambda r: r if not r['stage'].get('needsUser') else None)(
            cli_result('task', 'get', task_id)), timeout=120, interval=2)
        capture('e2e-3-replied')
        step('3c report marks sent to the task', stage=working.get('stage'),
             expectedMessage=f'Review note on packet v1: 1 marks on the screenshots:\n1. {reply} [after-390]')

        new_card = wait_for('a packet card for v2', waiting(lambda: next(
            (c for c in cards('packet') if c['taskID'] == task_id and c['packetVersion'] == 2), None)), timeout=900, interval=5)
        require(thread_entry(task_id, 'user-task', mark_text), 'The marks disappeared from the newer packet card thread')
        require(thread_entry(task_id, 'user-coordinator', addressed_question), 'The @task question disappeared from the newer packet card thread')
        # A card the coordinator posts for v1 replaces one the chat added, so
        # the v1 card is found by its version.
        olds = [c for c in cards('packet') if c['taskID'] == task_id and c['packetVersion'] == 1]
        require(olds and all(c['superseded'] for c in olds), f'No collapsed v1 card: {cards("packet")}')
        require(new_card['isNew'], f'v2 is not new: {new_card}')
        expanded = chat_state()['expandedCardIDs']
        require(not any(c['id'] in expanded for c in olds), 'The superseded v1 card stayed open')
        open_card(task_id, 2)
        capture('e2e-4-packet-v2')
        step('4 packet v2 card is new and v1 collapsed', newCard=new_card['id'])

        record = cli_result('task', 'get', task_id)
        checkout = (record.get('worktree') or {}).get('path') or str(repository)
        head = git('rev-parse', 'HEAD', cwd=checkout)
        branch = git('rev-parse', '--abbrev-ref', 'HEAD', cwd=checkout)
        state = json.loads(gh_state.read_text())
        state['prs']['9'] = dict(number=9, head=head, branch=branch, state='OPEN', pending=False)
        gh_state.write_text(json.dumps(state))
        cli_result('action', 'run', 'workspace.set-annotation', '--workspace', task_space,
                   'key=github-pr', 'text=PR #9', f'url={PULL_REQUEST}')
        wait_for('the card to show the pull request', lambda: open_card(task_id, 2)['pullRequestURL'] == PULL_REQUEST,
                 timeout=60, interval=2)
        card = open_card(task_id, 2)
        require(page('click', f"open-pr-{card['id']}"), 'Could not press Open PR')
        wait_for('the pull request in the right panel', lambda: PULL_REQUEST in json.dumps(
            instance.query('workspace.snapshot', workspaceID=coordinator['workspaceID'])), timeout=20)
        capture('e2e-5-open-pr')
        step('5a pull request opened in the right panel', canMerge=card['canMerge'], mergePolicy=card['mergePolicy'])
        require('merge = "direct"' in (card['mergePolicy'] or ''), f'The policy does not name the direct merge: {card}')
        require(card['canMerge'], f'The card offers no Merge: {card}')
        card = open_card(task_id, 2)
        require(page('click', f"merge-{card['id']}"), 'Could not press Merge')
        capture('e2e-5-merge-confirm')
        step('5b merge confirm shown', policy=card['mergePolicy'])
        require(page('click', f"merge-go-{card['id']}"), 'Could not press Merge in the question')
        merged = wait_for('the task to be done', lambda: (lambda r: r if r['stage']['group'] == 'done' else None)(
            cli_result('task', 'get', task_id)), timeout=300, interval=3)
        require(json.loads(gh_state.read_text())['prs']['9']['state'] == 'MERGED', 'The pull request did not merge')
        require(git('rev-parse', 'main', cwd=origin) == head, 'origin main is not the merged commit')
        capture('e2e-5-merged')
        step('5c merged and done', stage=merged['stage'], mergeCommit=merged.get('mergeCommit'), cleanup=merged.get('cleanup'))

        evidence['status'] = 'passed'
    except Exception:
        # Leave each agent terminal's last lines for diagnosis.
        try:
            screens = {}
            for workspace in instance.query('workspace.list')['workspaces']:
                for panel in panel_ids(instance.query('workspace.snapshot', workspaceID=workspace['workspaceID'])):
                    try:
                        screens[f"{workspace['title']}/{panel}"] = instance.query(
                            'terminal.visible-text', panelID=panel, tail=80, includeScrollback=True).get('text', '')
                    except AssertionError:
                        continue  # A right panel's browser or document.
            (artifacts / f'{PREFIX}-terminals.json').write_text(json.dumps(screens, indent=2))
            capture('e2e-failure')
        except Exception as error:
            step('could not record terminals', error=str(error))
        raise
    finally:
        if 'coordinator' in locals():
            routing_path = Path(coordinator['routingFile'])
            if routing_path.is_file():
                shutil.copyfile(routing_path, artifacts / f'{PREFIX}-routing.md')
        try:
            instance.kill()
        except Exception:
            pass
        queue_check.set_directory_trust(repository, False)
        shutil.rmtree(parent, ignore_errors=True)
        (artifacts / f'{PREFIX}-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[chat-e2e] passed', flush=True)


if __name__ == '__main__':
    main()
