#!/usr/bin/env python3
"""Run the whole coordinator flow end to end with real Claude agents.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-final-e2e-check.py'. It needs
an unlocked screen, and uses the host's Claude subscription.

The check reruns itself from Terminal in the logged-in GUI session, where the
Claude login is readable. Terminal there has no Accessibility access, so the
first process stays in the SSH session and presses keys and sidebar rows for
it: the GUI-session check writes each request to a folder that this process
watches.

The app runs in automation mode with a throwaway runtime home. There are two
projects: `project`, with `merge = "direct"`, and `docs-site`. Both have a
local bare origin, and a fake `gh` from remote-task-merge-check.py serves
their pull requests, so nothing on GitHub changes. In the real app, the check
covers:
1. the sidebar's Coordinator row opens the chat;
2. a request typed in the composer makes the coordinator create and start a
   task, A;
3. A's packet puts it in the sidebar's Needs you list with its action and ▾
   menu, and the row opens the packet card in the chat;
4. Full report opens in the right panel; a reply to A takes it out of Needs
   you; packet v2 updates the only task card and keeps v1 in report history;
5. with a pull request link, Open PR opens it in the right panel, and Merge
   from A's sidebar row, after its question, merges it: A is Done;
6. a second task, B, merges from its card in the chat;
7. Cmd+Shift+T opens the chat from another workspace;
8. Option+Cmd+T shows All tasks with the tasks in their groups; the project
   filter shows one project; the arrow keys move the selection, and Return
   opens the selected task;
9. no Tasks view: the window has no Tasks view element, and
   `window.tasks.show` opens the chat;
10. after the app is killed and relaunched, the chat shows the same cards;
11. routing.md opens in the right panel.
A capture of the window goes to the artifacts directory at each step.
"""

import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).parent


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


create_check = _load('remote_task_create_check', 'remote-task-create-check.py')
queue_check = _load('remote_queue_steer_check', 'remote-queue-steer-check.py')
start_work_check = _load('remote_task_start_work_check', 'remote-task-start-work-check.py')
merge_check = _load('remote_task_merge_check', 'remote-task-merge-check.py')
e2e_check = _load('remote_coordinator_chat_e2e_check', 'remote-coordinator-chat-e2e-check.py')
require, wait_for, Instance = create_check.require, create_check.wait_for, create_check.Instance
panel_ids = start_work_check.panel_ids

PREFIX = 'remote-coordinator-final-e2e'
SLUG = 'toastty-check/project'
ALLOWED_TOOLS = 'Bash,Edit,Write,Read,Glob,Grep,Skill'
KEY_RETURN, KEY_ESCAPE, KEY_DOWN, KEY_T = 36, 53, 125, 17
MODIFIERS = {'cmd': 'command down', 'shift': 'shift down', 'opt': 'option down', 'ctrl': 'control down'}
# The whole run, both agents' turns included.
GUI_TIMEOUT = 3600

# Prints the View menu's items, whether each is enabled, and its key, for
# a failure report.
VIEW_MENU = r'''
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
func v(_ e: AXUIElement, _ n: String) -> AnyObject? { var r: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &r) == .success ? r : nil }
guard let bar = v(app, kAXMenuBarAttribute) else { print("no menu bar"); exit(0) }
for top in (v(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
    let title = v(top, kAXTitleAttribute) as? String ?? ""
    guard title == "View" else { continue }
    for menu in (v(top, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        for item in (v(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            let t = v(item, kAXTitleAttribute) as? String ?? ""
            let enabled = (v(item, kAXEnabledAttribute) as? Bool) ?? false
            let key = v(item, "AXMenuItemCmdChar") as? String ?? ""
            if !t.isEmpty { print("\(t)\t\(enabled)\t\(key)") }
        }
    }
}
'''


class _Process:
    """What `Instance` uses of a child process, for an app LaunchServices
    started."""

    def __init__(self, pid):
        self.pid = pid

    def poll(self):
        try:
            os.kill(self.pid, 0)
            return None
        except ProcessLookupError:
            return 0

    def send_signal(self, number):
        try:
            os.kill(self.pid, number)
        except ProcessLookupError:
            pass

    def wait(self, timeout=None):
        wait_for('the app to exit', lambda: self.poll() is not None, timeout=timeout or 30, interval=0.2)


class LaunchedInstance(Instance):
    """The app started through LaunchServices, as Finder starts it, rather
    than as a child of the GUI session's Terminal."""

    def __init__(self, bundle, environment, socket_path, runtime_home, log_path):
        self.socket_path, self.runtime_home = socket_path, runtime_home
        self.log = open(log_path, 'a')
        binary = str(Path(bundle) / 'Contents/MacOS/Toastty')
        before = set(_pids(binary))
        arguments = ['open', '-n', '-g', '-o', str(log_path), '--stderr', str(log_path)]
        for key, value in environment.items():
            arguments += ['--env', f'{key}={value}']
        subprocess.run([*arguments, '-a', str(bundle)], check=True, timeout=60)
        pid = wait_for('the app to start', lambda: next(iter(set(_pids(binary)) - before), None), timeout=60, interval=0.2)
        self.process = _Process(pid)


def _pids(binary):
    result = subprocess.run(['pgrep', '-f', '-x', binary], capture_output=True, text=True)
    return [int(line) for line in result.stdout.split()]


def serve_gui_session():
    """Starts the check in the GUI session and runs its Accessibility
    requests here until it ends: `<n>.json` holds a request, `<n>.out` the
    answer."""
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR']).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    requests = Path(tempfile.mkdtemp(prefix='toastty-final-e2e-ax-', dir='/tmp'))
    tools = {}
    (requests / 'view-menu.swift').write_text(VIEW_MENU)
    for name, source in (('driver', HERE / 'quick-entry-ui-driver.swift'), ('helper', HERE / 'task-stages-ui-helper.swift'),
                         ('menu', requests / 'view-menu.swift')):
        tools[name] = requests / name
        subprocess.run(['swiftc', '-O', str(source), '-o', str(tools[name])], check=True)
    locked = subprocess.run([str(tools['driver']), 'locked'], capture_output=True, text=True).stdout.strip()
    require(locked == '0', 'The remote screen is locked; unlock it to press keys')

    done, output = artifacts / f'{PREFIX}-gui.exit', artifacts / f'{PREFIX}-gui.log'
    done.unlink(missing_ok=True)
    command = ' '.join([
        'cd', shlex.quote(os.getcwd()), '&&',
        f"TOASTTY_APP_BUNDLE={shlex.quote(os.environ['TOASTTY_APP_BUNDLE'])}",
        f'TOASTTY_ARTIFACTS_DIR={shlex.quote(str(artifacts))}',
        f'TOASTTY_FINAL_E2E_REQUESTS={shlex.quote(str(requests))}',
        'python3', shlex.quote(str(Path(__file__).resolve())), '--in-gui-session',
        '>', shlex.quote(str(output)), '2>&1;',
        'echo $? >', shlex.quote(str(done)), '; exit',
    ])
    subprocess.run(['osascript', '-e', f'tell application "Terminal" to do script {json.dumps(command)}'],
                   check=True, capture_output=True, timeout=30)
    deadline = time.time() + GUI_TIMEOUT
    while not done.exists():
        require(time.time() < deadline, 'The GUI-session check did not finish in time')
        for request in sorted(requests.glob('*.json')):
            arguments = json.loads(request.read_text())
            executable = ['osascript', '-e'] if arguments[0] == 'osascript' else [str(tools[arguments[0]])]
            result = subprocess.run([*executable, *map(str, arguments[1:])], capture_output=True, text=True, timeout=60)
            answer = request.with_suffix('.out')
            answer.with_suffix('.tmp').write_text(json.dumps(dict(code=result.returncode, stdout=result.stdout, stderr=result.stderr)))
            os.replace(answer.with_suffix('.tmp'), answer)
            request.unlink()
        time.sleep(0.2)
    shutil.rmtree(requests, ignore_errors=True)
    print(output.read_text())
    raise SystemExit(int(done.read_text().strip() or 1))


def main():
    if '--in-gui-session' not in sys.argv[1:]:
        serve_gui_session()
    requests = Path(os.environ['TOASTTY_FINAL_E2E_REQUESTS'])
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary, cli = bundle / 'Contents/MacOS/Toastty', bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    request_count = [0]
    # This check runs in a Terminal window, which must not hold the keys
    # meant for the app. Terminal scripts its own windows without
    # Accessibility.
    subprocess.run(['osascript', '-e', 'tell application "Terminal" to set miniaturized of every window to true'],
                   capture_output=True, timeout=30)

    def ax(tool, *arguments, check=True):
        """Runs a helper in the SSH session, which may press keys."""
        request_count[0] += 1
        request = requests / f'{request_count[0]:04d}.json'
        request.with_suffix('.tmp').write_text(json.dumps([tool, *map(str, arguments)]))
        os.replace(request.with_suffix('.tmp'), request)
        answer = request.with_suffix('.out')
        wait_for(f'{tool} {arguments[0]}', answer.exists, timeout=90, interval=0.1)
        result = json.loads(answer.read_text())
        answer.unlink()
        if check:
            require(result['code'] == 0, f'{tool} {arguments[0]} failed: {result["stderr"].strip()}')
        return result

    root = Path(tempfile.mkdtemp(prefix='toastty-final-e2e-', dir='/tmp')).resolve()
    runtime_home, shots = root / 'runtime-home', root / 'shots'
    runtime_home.mkdir()
    shots.mkdir()
    # Claude trusts folders under the host home; the repositories stay there.
    parent = Path.home() / 'toastty-queue-steer-checks' / f'final-e2e-{uuid.uuid4().hex[:8]}'
    parent.mkdir(parents=True)
    repository, docs = parent / 'project', parent / 'docs-site'

    def git(*args, cwd=repository):
        return subprocess.run(['git', '-C', str(cwd), *args], check=True, capture_output=True, text=True).stdout.strip()

    for checkout in (repository, docs):
        origin = parent / f'{checkout.name}-origin.git'
        subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(origin)], check=True)
        subprocess.run(['git', 'clone', '-q', str(origin), str(checkout)], check=True, capture_output=True)
        git('config', 'user.name', 'Toastty Check', cwd=checkout)
        git('config', 'user.email', 'check@example.invalid', cwd=checkout)
        (checkout / 'README.md').write_text('Hello world\n\nA throwaway project for a Toastty check.\n')
        (checkout / '.git/info/exclude').write_text('.toastty/\n.claude\n')
        git('add', 'README.md', cwd=checkout)
        git('commit', '-q', '-m', 'Start', cwd=checkout)
        git('push', '-q', 'origin', 'main', cwd=checkout)
        if (Path.home() / '.claude').exists():
            (checkout / '.claude').symlink_to(Path.home() / '.claude')
        queue_check.set_directory_trust(checkout, True)

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
    light, dark = (232, 230, 225), (45, 107, 70)
    e2e_check.png(shots / 'before-390.png', 390, 640, [light, light, (214, 228, 239)])
    e2e_check.png(shots / 'after-390.png', 390, 640, [light, (207, 227, 212), dark])

    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    version, argv = start_work_check.provider_profile('claude', environment, repository)
    # --allowedTools takes any number of values; the flag after it ends them.
    argv = [*argv, '--allowedTools', ALLOWED_TOOLS, '--verbose']
    (toastty_dir / 'agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps(argv)}\ninitialPromptPlacement = "trailing"\n')
    (toastty_dir / 'tasks.toml').write_text(
        '[defaults]\nagent = "claude"\n\n[coordinator]\nagent = "claude"\n\n'
        f'[workspace.{json.dumps(str(repository))}]\nmerge = "direct"\n\n'
        f'[workspace.{json.dumps(str(docs))}]\nmerge = "direct"\n')

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
        # The app uses its own PATH when the login shell's PATH probe is slow.
        PATH=f'{fake_bin}:{environment.get("PATH", "/usr/bin:/bin")}',
        DISABLE_AUTOUPDATER='1',
    )
    cli_environment = {key: value for key, value in environment.items()
                       if key not in ('TOASTTY_COORDINATOR_AUTOSTART', 'TOASTTY_AUTOMATION')}
    evidence = dict(status='failed', claude=version, steps=[], captures=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[final-e2e] {name} {json.dumps(facts, default=str)}', flush=True)

    def cli_result(*arguments):
        result = subprocess.run([str(cli), '--json', '--socket-path', socket_path, *arguments],
                                env=cli_environment, capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments[:3])} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    app = dict(instance=LaunchedInstance(bundle, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-app.log'))

    def instance():
        return app['instance']

    def pid():
        return instance().process.pid

    def chat_state():
        return instance().query('coordinator.chat.state')

    def page(action, element, text=None):
        args = dict(action=action, elementID=element)
        if text is not None:
            args['text'] = text
        response = instance().request('automation.coordinator_chat_action', args)
        require(response.get('ok'), f'Could not {action} {element}: {response}')

    def capture(name):
        ax('helper', 'activate', pid(), check=False)
        time.sleep(1.0)
        response = instance().request('automation.capture_screenshot', dict(step=name))
        require(response.get('ok'), f'Could not capture {name}: {response.get("error")}')
        path = artifacts / f'{name}.png'
        shutil.copyfile(response['result']['path'], path)
        evidence['captures'].append(path.name)

    def key(code, modifiers=None):
        """Presses a key in the app, once it is frontmost: a key goes to the
        frontmost app, and the Terminal running this check can be. It runs in
        the SSH session, which may send keys."""
        def frontmost():
            ax('helper', 'activate', pid(), check=False)
            time.sleep(0.3)
            return ax('helper', 'frontmost-pid', check=False)['stdout'].strip() == str(pid())
        wait_for('the app to be frontmost', frontmost, timeout=20, interval=0.5)
        # System Events presses the modifier keys too, as a keyboard does.
        using = ', '.join(MODIFIERS[name] for name in (modifiers or '').split(',') if name)
        ax('osascript', f'tell application "System Events" to key code {code}' + (f' using {{{using}}}' if using else ''))
        time.sleep(0.8)

    def exists(identifier):
        return ax('helper', 'exists', pid(), identifier, check=False)['code'] == 0

    def press(identifier):
        wait_for(f'{identifier} on screen', lambda: exists(identifier), timeout=30, interval=0.5)
        ax('helper', 'press', pid(), identifier)

    answered = set()

    def answer_dialogs():
        """Answers a first-run prompt in any agent terminal once, as a person would."""
        for workspace in instance().query('workspace.list')['workspaces']:
            for panel in panel_ids(instance().query('workspace.snapshot', workspaceID=workspace['workspaceID'])):
                try:
                    text = instance().query('terminal.visible-text', panelID=panel, tail=30).get('text', '')
                except AssertionError:
                    continue
                if 'Yes, proceed' in text and 'trust' in text.lower() and (panel, 'trust') not in answered:
                    answered.add((panel, 'trust'))
                    instance().request('app_control.run_action', dict(id='terminal.send-text', args=dict(panelID=panel, text='1', submit=True)))

    def waiting(probe):
        def wrapped():
            answer_dialogs()
            return probe()
        return wrapped

    def cards(kind=None):
        return [i for i in chat_state()['items'] if i['type'] == 'card' and (kind is None or i['kind'] == kind)]

    def open_card(task_id, version):
        """The task's card for a packet version, opened; see the chat e2e check."""
        def find():
            matching = [c for c in cards('packet') if c['taskID'] == task_id and c['packetVersion'] == version]
            return next((c for c in matching if not c['superseded']), None) or next(iter(matching), None)
        card = wait_for(f'the v{version} card', find, timeout=30, interval=1)
        if card['id'] not in chat_state()['expandedCardIDs']:
            page('click', f"expand-{card['id']}")
            wait_for(f'the v{version} card to open', lambda: card['id'] in chat_state()['expandedCardIDs'], timeout=15)
        return card

    def task(task_id):
        return cli_result('task', 'get', task_id)

    def open_pull_request(task_id, number):
        """Links a pull request that the fake gh serves at the task's commit."""
        record = task(task_id)
        checkout = (record.get('worktree') or {}).get('path') or str(repository)
        head = git('rev-parse', 'HEAD', cwd=checkout)
        state = json.loads(gh_state.read_text())
        state['project'] = checkout
        state['prs'][str(number)] = dict(number=number, head=head, branch=git('rev-parse', '--abbrev-ref', 'HEAD', cwd=checkout),
                                         state='OPEN', pending=False)
        gh_state.write_text(json.dumps(state))
        cli_result('action', 'run', 'workspace.set-annotation', '--workspace', record['setup']['taskSpaceWorkspaceID'],
                   'key=github-pr', f'text=PR #{number}', f'url=https://github.com/{SLUG}/pull/{number}')
        return head

    def merged_and_done(task_id, number):
        record = wait_for(f'{task_id} to be done', lambda: (lambda r: r if r['stage']['group'] == 'done' else None)(task(task_id)),
                          timeout=300, interval=3)
        require(json.loads(gh_state.read_text())['prs'][str(number)]['state'] == 'MERGED', f'PR #{number} did not merge')
        return record

    def cmd_shift_t(when):
        """From the project workspace, Cmd+Shift+T selects the coordinator
        with its chat. A failure records what held the keys."""
        cli_result('action', 'run', 'workspace.select', '--workspace', workspace_id)
        time.sleep(1)
        key(KEY_T, 'cmd,shift')

        def chat_shows():
            selected = [w['workspaceID'] for w in instance().query('workspace.list')['workspaces'] if w['isSelected']]
            return selected == [coordinator['workspaceID']] and chat_state()['view'] == 'chat'
        try:
            wait_for(f'Cmd+Shift+T to open the chat {when}', chat_shows, timeout=15, interval=0.5)
        except AssertionError:
            evidence['shortcutFailure'] = dict(
                when=when,
                frontmost=ax('helper', 'frontmost-pid', check=False)['stdout'].strip(), pid=pid(),
                viewMenu=ax('menu', pid(), check=False)['stdout'],
                windows=ax('helper', 'dump', pid(), check=False)['stdout'][-6000:],
            )
            raise
        step(f'cmd+shift+t opens the chat {when}')

    workspace_id = None
    try:
        workspace_id = instance().wait_until_ready()[0]['workspaceID']
        coordinator = wait_for('the coordinator to run', waiting(lambda: (lambda s: s if s['state'] == 'running' else None)(
            instance().query('coordinator.status'))), timeout=120, interval=2)

        # 1. The sidebar's Coordinator row opens the chat.
        press('sidebar.coordinator.open')
        wait_for('the chat to accept a message', waiting(lambda: (lambda s: s['pages'] >= 1 and s['canSend'])(chat_state())),
                 timeout=300, interval=3)
        selected = [w['workspaceID'] for w in instance().query('workspace.list')['workspaces'] if w['isSelected']]
        require(selected == [coordinator['workspaceID']], f'The Coordinator row did not open the chat: {selected}')
        capture('01-sidebar-opens-chat')
        step('1 coordinator row opens the chat')
        cmd_shift_t('before any task')

        # 2. A request in the composer creates and starts task A.
        request = (
            f'Please start one task in the project at {repository} (workspace {workspace_id}): change the first line '
            'of README.md from "Hello world" to "Hello coordinator" and commit it. Tell the task agent: when done, '
            'publish a review packet with the toastty-task-verify skill, and attach these two screenshots as a '
            f'before and after pair at width 390: {shots / "before-390.png"} and {shots / "after-390.png"}. '
            'Post the task-started card, and a packet card when its packet arrives.'
        )
        wait_for('the chat to accept a message', waiting(lambda: chat_state()['canSend']), timeout=300, interval=2)
        page('type', 'composer-input', request)
        a = wait_for('the coordinator to create a task', waiting(lambda: (cli_result('task', 'list')['tasks'] or [None])[0]),
                     timeout=600, interval=5)
        a_id = a['taskID']
        capture('02-coordinator-creates-task')
        step('2 composer request created a task', taskID=a_id, title=a['title'])

        # 3. The packet puts A in the sidebar's Needs you list; its row opens
        # the packet card.
        wait_for('packet v1', waiting(lambda: task(a_id).get('packetVersion') == 1), timeout=900, interval=5)
        row = f'sidebar.needsYou.task.{a_id}'
        wait_for('A in Needs you', lambda: exists(f'{row}.primary') and exists(f'{row}.menu'), timeout=60, interval=1)
        cli_result('action', 'run', 'workspace.select', '--workspace', workspace_id)
        capture('03-sidebar-needs-you')
        ax('helper', 'press', pid(), f'{row}.menu', check=False)
        capture('03-sidebar-row-menu')
        key(KEY_ESCAPE)
        # The row's text opens the packet in the chat.
        title_prefix = a['title'][:20]
        ax('driver', 'press-label', pid(), title_prefix)
        wait_for('the packet card to open from the sidebar', lambda: chat_state()['currentTaskID'] == a_id
                 and chat_state()['view'] == 'chat', timeout=20, interval=0.5)
        capture('03-sidebar-opens-packet')
        step('3 needs you row opened the packet')

        # 4. Full report, a reply, and packet v2.
        page('click', f"report-{open_card(a_id, 1)['id']}")
        wait_for('the report in the right panel', lambda: f'toastty://coordinator/report/{a_id}/1' in json.dumps(
            instance().query('workspace.snapshot', workspaceID=coordinator['workspaceID'])), timeout=20)
        capture('04-full-report')
        reply = 'Please change it to "Hello coordinator!" with an exclamation mark, then publish packet v2 with the same screenshots.'
        page('type', f"reply-{open_card(a_id, 1)['id']}", reply)
        wait_for('A to leave Needs you', lambda: not task(a_id)['stage'].get('needsUser'), timeout=120, interval=2)
        capture('04-reply-leaves-needs-you')
        wait_for('a packet card for v2', waiting(lambda: next(
            (c for c in cards('packet') if c['taskID'] == a_id and c['packetVersion'] == 2), None)), timeout=900, interval=5)
        task_cards = [c for c in cards() if c['taskID'] == a_id]
        require(len(task_cards) == 1 and task_cards[0].get('packetVersions') == [1, 2]
                and not task_cards[0]['superseded'], f'Packet v2 duplicated the card or lost history: {task_cards}')
        open_card(a_id, 2)
        capture('04-packet-v2')
        step('4 report, reply and v2')

        # 5. Open PR, then Merge from A's sidebar row.
        a_head = open_pull_request(a_id, 9)
        wait_for('the card to show the pull request', lambda: open_card(a_id, 2)['pullRequestURL'], timeout=60, interval=2)
        page('click', f"open-pr-{open_card(a_id, 2)['id']}")
        wait_for('the pull request in the right panel', lambda: f'https://github.com/{SLUG}/pull/9' in json.dumps(
            instance().query('workspace.snapshot', workspaceID=coordinator['workspaceID'])), timeout=20)
        capture('05-open-pr')
        wait_for('A to wait for review', lambda: task(a_id)['stage'].get('attention') == 'review', timeout=120, interval=2)
        press(f'{row}.primary')
        wait_for('the merge question', lambda: exists(f'{row}.confirmMerge'), timeout=20, interval=0.5)
        capture('05-sidebar-merge-question')
        press(f'{row}.confirmMerge')
        merged_a = merged_and_done(a_id, 9)
        require(merged_a.get('mergeCommit') == a_head, f'A did not merge at its commit: {merged_a}')
        capture('05-sidebar-merged')
        step('5 open PR and merge from the sidebar', mergeCommit=merged_a.get('mergeCommit'))

        # 6. Task B merges from its card.
        b = cli_result('task', 'create', 'This is an automated Toastty check. Reply with exactly READY-B and do nothing else.',
                       '--title', 'Add a docs link', '--workspace', workspace_id, '--start-work',
                       '--branch-prefix', 'check', '--wait', '--timeout', '300')
        b_id = b['taskID']
        b_worktree = wait_for('B in its worktree', lambda: (task(b_id).get('worktree') or {}).get('path'), timeout=300, interval=2)
        (Path(b_worktree) / 'DOCS.md').write_text('See README.md.\n')
        git('add', 'DOCS.md', cwd=b_worktree)
        git('commit', '-q', '-m', 'Add a docs link', cwd=b_worktree)
        (root / 'packet-b.json').write_text(json.dumps({
            'summary': 'Adds DOCS.md, which points at README.md.', 'look_at': 'DOCS.md',
            'checks': [{'name': 'git show --stat', 'ok': True}], 'not_verified': [], 'screenshots': [],
        }))
        cli_result('task', 'packet', 'publish', b_id, '--file', str(root / 'packet-b.json'))
        cli_result('coordinator', 'post', 'packet', '--task', b_id)
        open_pull_request(b_id, 10)
        cli_result('coordinator', 'show', '--task', b_id)
        card = wait_for('B\'s card to offer Merge', lambda: (lambda c: c if c['canMerge'] else None)(open_card(b_id, 1)),
                        timeout=60, interval=2)
        page('click', f"merge-{card['id']}")
        capture('06-card-merge-question')
        page('click', f"merge-go-{open_card(b_id, 1)['id']}")
        merged_and_done(b_id, 10)
        capture('06-card-merged')
        step('6 merge from a card')

        # 7. Cmd+Shift+T opens the chat from another workspace.
        cmd_shift_t('after the merges')
        capture('07-cmd-shift-t')
        step('7 cmd+shift+t opens the chat')

        # 8. Option+Cmd+T: All tasks, the filter, the arrow keys and Return.
        # A task placed in a project directory opens it as a second project.
        c = cli_result('task', 'create', 'This is an automated Toastty check. Reply with exactly READY-C and do nothing else.',
                       '--title', 'Update the API guide')
        cli_result('task', 'set-workspace', c['taskID'], '--root', str(docs))
        wait_for('C to start in docs-site', waiting(lambda: (task(c['taskID']).get('setup') or {}).get('state') == 'started'),
                 timeout=300, interval=2)
        key(KEY_T, 'cmd,opt')
        wait_for('Option+Cmd+T to show All tasks', lambda: chat_state()['view'] == 'tasks', timeout=15, interval=0.5)
        rows = {r['taskID']: r for r in chat_state()['tasks']}
        require(rows[a_id]['group'] == 'done' and rows[b_id]['group'] == 'done', f'A and B are not Done: {rows}')
        require(rows[c['taskID']]['group'] in ('running', 'needsYou'), f'C is not running: {rows[c["taskID"]]}')
        capture('08-all-tasks')
        page('click', 'group-done')
        capture('08-all-tasks-done-open')
        # The chat header's project filter also filters the right panel.
        # Projects sort by name: docs-site comes before Workspace 1. The
        # selection moves to the only row the filter leaves.
        page('click', 'project-filter-0')
        wait_for('the docs-site filter', lambda: chat_state()['selectedRowID'] == rows[c['taskID']]['id'], timeout=10, interval=0.3)
        capture('08-all-tasks-filtered')
        page('click', 'project-filter-all')
        # C comes first, in Needs you or Running; Down moves past it.
        page('click', f"task-row-{rows[c['taskID']]['id']}")
        wait_for('C selected', lambda: chat_state()['selectedRowID'] == rows[c['taskID']]['id'], timeout=10, interval=0.3)
        key(KEY_DOWN)
        wait_for('Down Arrow to move the selection', lambda: chat_state()['selectedRowID'] not in (None, rows[c['taskID']]['id']),
                 timeout=10, interval=0.3)
        capture('08-all-tasks-selection')
        page('click', f"task-row-{rows[a_id]['id']}")
        key(KEY_RETURN)
        wait_for('Return to open A\'s card', lambda: chat_state()['view'] == 'chat' and chat_state()['currentTaskID'] == a_id,
                 timeout=15, interval=0.3)
        capture('08-return-opens-card')
        step('8 all tasks, filter, arrow keys and return')

        # 9. No Tasks view.
        dump = ax('helper', 'dump', pid())['stdout']
        require('tasks.view' not in dump, 'The window still has a Tasks view element')
        cli_result('action', 'run', 'window.tasks.show')
        wait_for('window.tasks.show to open the chat', lambda: chat_state()['view'] == 'chat', timeout=10, interval=0.3)
        step('9 no tasks view')

        # 10. Kill and relaunch: the chat keeps its cards.
        before = sorted((c['taskID'], c['kind'], c['packetVersion']) for c in cards())
        instance().kill()
        app['instance'] = LaunchedInstance(bundle, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-app.log')
        instance().wait_until_ready()
        # The coordinator's workspace may come back with a new ID.
        coordinator = wait_for('the coordinator after relaunch', waiting(lambda: (lambda c: c if c['state'] == 'running' else None)(
            instance().query('coordinator.status'))), timeout=180, interval=2)
        cli_result('coordinator', 'show')
        after = wait_for('the chat after relaunch', lambda: (lambda c: c if c == before else None)(
            sorted((c['taskID'], c['kind'], c['packetVersion']) for c in cards())), timeout=60, interval=1)
        capture('10-relaunch-keeps-cards')
        step('10 relaunch keeps the cards', cards=len(after))

        # 11. routing.md in the right panel.
        page('click', 'open-routing')
        wait_for('routing.md in the right panel', lambda: 'routing.md' in json.dumps(
            instance().query('workspace.snapshot', workspaceID=coordinator['workspaceID'])), timeout=20)
        capture('11-routing')
        step('11 routing.md')

        evidence['status'] = 'passed'
    except Exception:
        try:
            evidence['chatState'] = chat_state()
            capture('failure')
        except Exception as error:
            evidence['diagnosticsError'] = repr(error)
        raise
    finally:
        try:
            instance().kill()
        except Exception:
            pass
        for checkout in (repository, docs):
            queue_check.set_directory_trust(checkout, False)
        shutil.rmtree(parent, ignore_errors=True)
        (artifacts / f'{PREFIX}-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[final-e2e] passed', flush=True)


if __name__ == '__main__':
    main()
