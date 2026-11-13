#!/usr/bin/env python3
"""Use the coordinator's chat through its real UI, with the real Claude CLI.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-chat-check.py --gui-session'.
The run uses subscription usage. It needs the remote Mac's screen unlocked.

The check starts its own instance of the wrapper's build, with a throwaway
runtime home and user home. It does not touch the installed production app.
The coordinator is the real, authenticated Claude CLI in a folder of this
run. Tasks get a fake agent, so a task space exists for a chip to open.

Every action a person makes goes through the real UI: `ax-drive.swift` finds
a control by its accessibility identifier, clicks it with a mouse event and
types with key events. Under '--gui-session' the check itself runs in
Terminal in the GUI session, where the Claude login is readable, and the
process that started it over SSH makes the clicks and keys.

The check proves from Claude's transcript, the chat's own text and the CLI
that:
- Open Coordinator shows the chat, and Return in the composer sends;
- a message queued with Command-Return while the coordinator works waits
  as Queued and is typed after the turn, in its own turn (Return steers the
  turn; remote-coordinator-steer-check.py covers that);
- Stop ends the turn and sets the waiting message aside; Send next types it;
- a digest that Toastty typed shows as one folded line, and a click opens it;
- a task link shows as a chip with the task's own title; a click in the
  full view opens the task's space with the chat beside it in the dock; a
  link to no task and another Toastty link are plain text that a click does
  not open;
- the dock: a message sent there gets its reply there, and output it shows
  is read; Open Full View and the full view's Dock button move the chat
  between the dock and the full view; the toolbar button and Cmd+Shift+K
  hide and show it, Cmd+Shift+K with the keyboard in its field, where
  Cmd+= changes the chat's text size and Cmd+W closes nothing; a drag on
  its edge sets its width up to 480 points; with the sidebar hidden it is
  at the window's left edge; while it is hidden, a reply leaves the
  coordinator's row unread, and showing the dock reads it; after the
  relaunch it shows again at its width;
- the header's switch shows the terminal and the chat again;
- after the app is killed and relaunched, the chat shows the same
  conversation and takes a message;
- with Remote Access on, a message from a paired device shows in the chat,
  and a message that the device queued is typed before one from the Mac;
- after Restart Coordinator, the chat follows the new agent.

Evidence goes to remote-coordinator-chat-check.json, the app log, Claude's
transcripts and, when the build can capture its window, PNG frames under
remote-coordinator-chat-check-frames in the artifacts directory.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).parent
NAME = 'remote-coordinator-chat-check'


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coordinator_check = load('coordinator_check', 'remote-coordinator-check.py')
steer = load('queue_steer_check', 'remote-queue-steer-check.py')
require, wait_for, Instance = coordinator_check.require, coordinator_check.wait_for, coordinator_check.Instance

# Records its session and waits. A task needs an agent for its task space;
# this one reports a finished first turn and then reads its terminal.
HELPER_AGENT = r'''#!/bin/sh
status() { "$TOASTTY_CLI_PATH" session status --session "$TOASTTY_SESSION_ID" --kind "$1" --summary "$2" >/dev/null 2>&1; }
status working Working
sleep 1
status ready Ready
while IFS= read -r line; do :; done
'''

NO_BREAK_SPACE = '\u00a0'
HOLD_COMMAND = './hold-turn.sh'
# The labels of the coordinator's sidebar row.
ROW_READ = 'Coordinator'
ROW_UNREAD = 'Coordinator, unread'


def long_turn(seconds, marker):
    """A message whose turn lasts `seconds`."""
    return (f'Run the shell command `{HOLD_COMMAND} {seconds}` with the Bash tool, in the foreground and with a '
            f'timeout of {seconds + 30} seconds. Do not run it in the background. '
            f'When it ends, reply with exactly: {marker}')


# MARK: - The real UI


class UI:
    """Clicks and keys in the app's real window, through ax-drive."""

    def __init__(self, artifacts, pid):
        self.artifacts, self.pid = artifacts, pid
        self.broker = os.environ.get('TOASTTY_AX_BROKER')
        self.binary = Path(self.broker or artifacts) / 'ax-drive'
        self.count = 0
        if not self.broker:
            compile_ax_drive(self.binary)

    def run(self, *arguments, check=True):
        arguments = [str(self.pid), *arguments]
        # ax-drive refuses a click that another app's window covers (exit
        # 5). A notification banner passes in a few seconds: wait for it.
        deadline = time.monotonic() + 20
        while True:
            if self.broker:
                code, output = broker_request(Path(self.broker), arguments)
            else:
                completed = subprocess.run([str(self.binary), *arguments], capture_output=True, text=True, timeout=60)
                code, output = completed.returncode, completed.stdout + completed.stderr
            if code != 5 or 'COVERED' not in output or time.monotonic() > deadline:
                break
            time.sleep(1)
        if check:
            require(code == 0, f'ax-drive {" ".join(arguments[1:])} failed ({code}): {output}')
        return code, output.strip()

    def exists(self, identifier):
        return self.run('frame', identifier, check=False)[0] == 0

    def has_label(self, label):
        return self.run('label-frame', label, check=False)[0] == 0

    def texts(self, identifier='coordinator.chat'):
        code, output = self.run('texts', identifier, check=False)
        return output if code == 0 else ''

    def send(self, text, key='return'):
        """Types into the chat's composer and presses Return. While a turn
        runs, Return steers it; `key='cmd-return'` queues instead."""
        self.run('focus', 'coordinator.chat.composer')
        time.sleep(0.3)
        self.run('type', text)
        time.sleep(0.3)
        self.run('key', key)

    def queue(self, text):
        """Types into the chat's composer and presses Command-Return, so the
        message waits for the running turn's end."""
        self.send(text, key='cmd-return')


def compile_ax_drive(binary):
    subprocess.run(['swiftc', '-O', str(HERE / 'ax-drive.swift'), '-o', str(binary)], check=True, timeout=300)


def broker_request(directory, arguments):
    """Asks the process that started the GUI-session run to make a click."""
    request = directory / f'{uuid.uuid4().hex}.request'
    answer = request.with_suffix('.answer')
    temporary = request.with_suffix('.writing')
    temporary.write_text(json.dumps(arguments))
    os.replace(temporary, request)
    wait_for('the UI driver', answer.exists, timeout=90, interval=0.05)
    result = json.loads(answer.read_text())
    answer.unlink()
    return result['code'], result['output']


def run_in_gui_session(arguments, name=NAME, script=__file__):
    """Reruns the check `script` from Terminal in the GUI session, and serves
    its clicks and keys from this process, which Accessibility trusts."""
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR']).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    broker = artifacts / f'{name}-ui'
    shutil.rmtree(broker, ignore_errors=True)
    broker.mkdir()
    binary = broker / 'ax-drive'
    compile_ax_drive(binary)
    done, output = artifacts / f'{name}-gui.exit', artifacts / f'{name}-gui.log'
    done.unlink(missing_ok=True)
    command = ' '.join([
        'cd', shlex.quote(os.getcwd()), '&&',
        f"TOASTTY_APP_BUNDLE={shlex.quote(os.environ['TOASTTY_APP_BUNDLE'])}",
        f'TOASTTY_ARTIFACTS_DIR={shlex.quote(str(artifacts))}',
        f'TOASTTY_AX_BROKER={shlex.quote(str(broker))}',
        *(f'{key}={shlex.quote(os.environ[key])}' for key in ('TOASTTY_EVIDENCE_CAPTURE',) if key in os.environ),
        'python3', shlex.quote(str(Path(script).resolve())), *map(shlex.quote, arguments),
        '>', shlex.quote(str(output)), '2>&1;',
        'echo $? >', shlex.quote(str(done)), '; exit',
    ])
    # Terminal types the command into a new shell. A terminal keeps at most
    # 1024 characters for a shell that does not read yet, and drops the rest
    # with the Return key, so the shell then waits for good. The long command
    # goes into a file, and Terminal types a short one.
    launcher = artifacts / f'{name}-gui.command'
    launcher.write_text(command.removesuffix('; exit') + '\n')
    do_script = f'tell application "Terminal" to do script {json.dumps(f"/bin/zsh {shlex.quote(str(launcher))}; exit")}'
    subprocess.run(['osascript', '-e', do_script], check=True, capture_output=True, timeout=30)
    deadline = time.time() + 2400
    while not done.exists():
        require(time.time() < deadline, 'The GUI-session check did not finish')
        for request in sorted(broker.glob('*.request')):
            arguments = json.loads(request.read_text())
            completed = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=60)
            temporary = request.with_suffix('.answering')
            temporary.write_text(json.dumps(dict(code=completed.returncode, output=completed.stdout + completed.stderr)))
            request.unlink()
            os.replace(temporary, request.with_suffix('.answer'))
        time.sleep(0.05)
    print(output.read_text())
    shutil.rmtree(broker, ignore_errors=True)
    raise SystemExit(int(done.read_text().strip() or 1))


# MARK: - The check


class ChatInstance(Instance):
    """The check's app, with Remote Access on a loopback port when asked.
    With `asks_start_offer`, a first launch asks whether to start the
    coordinator, as it does for a user."""

    def __init__(self, binary, environment, socket_path, runtime_home, log_path, gateway_port=None,
                 asks_start_offer=False):
        self.socket_path, self.runtime_home = socket_path, runtime_home
        self.log = open(log_path, 'a')
        arguments = [str(binary), *(() if asks_start_offer else coordinator_check.base.START_OFFER_ANSWERED)]
        if gateway_port:
            arguments += ['-toastty.remoteAccess.enabled', 'YES', '-toastty.remoteAccess.port', str(gateway_port)]
        self.process = subprocess.Popen(arguments, env=environment, stdout=self.log, stderr=subprocess.STDOUT)


def run(check):
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

    # Only this disposable app sees the profiles. The coordinator may run
    # the run's own wait script, which holds a turn open, and nothing else.
    # Claude Code refuses a plain `sleep` in the foreground.
    argv = [claude, '--setting-sources=', '--allowedTools', f'Bash({HOLD_COMMAND}:*)', '--tools', 'Bash',
            '--strict-mcp-config']
    runtime_home, user_home = check.home('chat', argv)
    helper = check.root / 'bin/helper-agent'
    helper.parent.mkdir()
    helper.write_text(HELPER_AGENT)
    helper.chmod(0o755)
    with open(user_home / '.toastty/agents.toml', 'a') as agents:
        agents.write(f'\n[helper]\ndisplayName = "Helper"\nargv = {json.dumps([str(helper)])}\n'
                     'initialPromptPlacement = "trailing"\n')
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "helper"\n\n[coordinator]\nagent = "claude"\n')
    # The first terminal starts in the user home, which is the tasks' project.
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    # A paired device for the Remote Access steps, as the queue check seeds it.
    device = dict(id=str(uuid.uuid4()).upper(), name='Check phone', scopes=['read', 'send'],
                  authKind='native', tailscaleLogin=steer.IDENTITY, createdAt=0)
    credential = dict(credentialHash=hashlib.sha256(steer.TOKEN.encode()).hexdigest(), deviceID=device['id'], issuedAt=0)
    (runtime_home / 'remote-access').mkdir(parents=True)
    (runtime_home / 'remote-access/devices.json').write_text(json.dumps(dict(
        devices=[device], credentials=[credential], nativePairingFailures=[])))

    frames = check.artifacts / f'{NAME}-frames'
    shutil.rmtree(frames, ignore_errors=True)
    frames.mkdir()
    environment = check.environment('chat', runtime_home, user_home, real_home=True, TOASTTY_EVIDENCE_DIR=str(frames))
    run_cli, cli = check.cli_runner(environment)
    directory = runtime_home / 'coordinator'
    directory.mkdir(parents=True)
    hold = directory / 'hold-turn.sh'
    hold.write_text('#!/bin/sh\nsleep "$1"\necho waited "$1" seconds\n')
    hold.chmod(0o755)
    # Typed text cannot answer the folder-trust dialog, so trust only this
    # run's folder for the run.
    steer.set_directory_trust(directory, True)
    project = steer.claude_project_directory(directory)
    app_log = check.artifacts / f'{check.prefix}-app.log'
    socket_path = environment['TOASTTY_SOCKET_PATH']
    instance = ChatInstance(check.binary, environment, socket_path, runtime_home, app_log)
    step = check.step
    frame_count = 0

    def status():
        return cli('coordinator', 'status')

    def at_prompt():
        current = status()
        return current.get('agentState') == 'running' and current.get('status') in ('idle', 'ready') and current

    def transcript():
        """Every message of the coordinator's conversations, oldest first."""
        entries = []
        for path in sorted(project.glob('*.jsonl'), key=lambda item: item.stat().st_mtime):
            for line in path.read_text().splitlines():
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get('type') not in ('user', 'assistant') or record.get('isSidechain'):
                    continue
                text = steer.claude_content_text((record.get('message') or {}).get('content'))
                if text:
                    entries.append(dict(role=record['type'], text=text, file=path.name))
        return entries

    def index_of(role, fragment, after=-1):
        return next((index for index, entry in enumerate(transcript())
                     if index > after and entry['role'] == role and fragment in entry['text']), None)

    def replied(marker):
        return index_of('assistant', marker) is not None

    def wait_for_reply(marker, timeout=240):
        wait_for(f'the reply {marker}', lambda: replied(marker), timeout=timeout)
        # The chat shows what Claude wrote: the request and the reply.
        wait_for(f'the chat to show {marker} twice', lambda: ui.texts().count(marker) >= 2, timeout=60)

    def capture(name):
        nonlocal frame_count
        frame_count += 1
        label = f'{frame_count:02d}-{name}'
        response = instance.request('automation.capture_screenshot', dict(step=label))
        check.evidence['captures'].append(dict(step=label, ok=response.get('ok'),
                                               path=(response.get('result') or {}).get('path'),
                                               error=None if response.get('ok') else response.get('error')))

    def selected_workspace():
        return next((w['workspaceID'] for w in instance.query('workspace.list')['workspaces'] if w['isSelected']), None)

    def pid():
        return json.loads((runtime_home / 'instance.json').read_text())['pid']

    try:
        workspaces = instance.wait_until_ready()
        project_id = workspaces[0]['workspaceID']

        def terminal_in_home():
            listed = instance.query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == project_id)['terminalCwds']
            return str(user_home) in [os.path.realpath(cwd) for cwd in cwds]

        wait_for('the first terminal in the user home', terminal_in_home, interval=1)
        wait_for('instance.json', lambda: (runtime_home / 'instance.json').is_file())
        ui = UI(check.artifacts, pid())
        _, trust = ui.run('status')
        require('trusted=true' in trust and 'locked=false' in trust,
                f'The UI driver cannot act: {trust}. Unlock the screen, or run with --gui-session over SSH')

        # A task with an open task space, for a chip.
        created = cli('task', 'create', 'Restore split ratios', '--workspace', project_id, '--wait', '--timeout', '90')
        require(created['setup']['state'] == 'started', f'The task did not start: {created}')
        task_id, task_space = created['taskID'], created['setup']['taskSpaceWorkspaceID']

        # 1. Open Coordinator shows the chat.
        opened = cli('coordinator', 'open')
        require(opened['startedAgent'] and opened['agentState'] == 'running', f'Open did not start Claude: {opened}')
        coordinator_id = opened['workspaceID']
        ui.run('activate')
        wait_for('the chat', lambda: ui.exists('coordinator.chat') and ui.exists('coordinator.chat.composer'))
        require(ui.exists('coordinator.panel.mode-toggle'), 'The panel header has no Chat and Terminal switch')
        wait_for('Claude at its first prompt', at_prompt, timeout=180)
        # A new runtime home shows a notice about skills over the top of
        # the window. It is not part of the chat.
        if ui.has_label('Dismiss'):
            ui.run('click-label', 'Dismiss', check=False)
            time.sleep(0.5)
        capture('chat-open')
        step('open shows the chat', opened=opened, version=version)

        # 2. Return in the composer sends.
        first = 'Reply with exactly this one word and nothing else: CHAT-ONE'
        ui.send(first)
        wait_for_reply('CHAT-ONE')
        sent = index_of('user', first)
        require(sent is not None and transcript()[sent]['text'] == first,
                f'Claude did not get the composer text as typed: {transcript()[-4:]}')
        require('sent remotely' not in ui.texts(), f'The chat marks the Mac\'s own message as remote: {ui.texts()}')
        wait_for('the prompt to open again', at_prompt, timeout=120)
        capture('composer-send')
        step('Return in the composer sent a message', chat=ui.texts()[-600:])

        # 3. A message sent during a turn waits as Queued, then gets its own turn.
        ui.send(long_turn(25, 'CHAT-TWO'))
        wait_for('the long turn to run', lambda: status().get('status') == 'working', timeout=60)
        ui.queue('Reply with exactly this one word and nothing else: CHAT-THREE')
        queued = wait_for('the message to wait', lambda: (s := status())['queuedCount'] == 1 and s)
        require(queued.get('hold') in ('busy', 'awaitingTurn'), f'Unexpected hold: {queued}')
        wait_for('the chat to show it as Queued', lambda: 'queued 1' in ui.texts().lower())
        capture('queued-while-busy')
        time.sleep(5)
        require(index_of('user', 'CHAT-THREE') is None and status()['queuedCount'] == 1,
                f'The queued message did not wait: {status()}')
        wait_for_reply('CHAT-TWO')
        wait_for_reply('CHAT-THREE')
        require(index_of('user', 'CHAT-THREE') > index_of('assistant', 'CHAT-TWO'),
                f'The queued message was typed during the turn: {transcript()[-6:]}')
        wait_for('the queue to empty', lambda: status()['queuedCount'] == 0 and at_prompt(), timeout=120)
        require('queued 1' not in ui.texts().lower(), 'The chat still shows the typed message as Queued')
        capture('queued-typed')
        step('a message during a turn waited and was typed after it', queued=queued)

        # 4. Stop ends the turn and sets the waiting message aside.
        ui.send(long_turn(90, 'CHAT-FOUR'))
        wait_for('the long turn to run', lambda: status().get('status') == 'working', timeout=60)
        ui.queue('Reply with exactly this one word and nothing else: CHAT-FIVE')
        wait_for('the message to wait', lambda: status()['queuedCount'] == 1)
        wait_for('the Stop button', lambda: ui.exists('coordinator.chat.stop'), timeout=30)
        time.sleep(3)
        ui.run('click', 'coordinator.chat.stop')
        stopped_at = time.time()
        wait_for('Claude to record the stop',
                 lambda: index_of('user', '[Request interrupted by user') is not None, timeout=60)
        wait_for('the turn to end', at_prompt, timeout=60)
        require(time.time() - stopped_at < 60, 'Stop did not end the turn in time')
        wait_for('the chat to show the message as Paused', lambda: 'paused' in ui.texts().lower())
        time.sleep(8)
        require(index_of('user', 'CHAT-FIVE') is None and not replied('CHAT-FOUR') and status()['queuedCount'] == 1,
                f'A message started a turn right after the stop: {transcript()[-4:]} {status()}')
        capture('stopped-and-paused')
        ui.run('click-prefix', 'toastty-mobile-queued-resume-')
        wait_for_reply('CHAT-FIVE')
        wait_for('the queue to empty', lambda: status()['queuedCount'] == 0 and at_prompt(), timeout=120)
        capture('send-next')
        step('Stop ended the turn, and Send next typed what waited')

        # 5. A digest is one folded line; a click opens it.
        timer = cli('coordinator', 'wake', '--in', '60s')['wake']
        digest_at = wait_for('the digest in Claude\'s transcript',
                             lambda: index_of('user', '[Toastty] Wake'), timeout=150)
        wait_for('the folded line', lambda: 'Toastty · 1 update' in ui.texts(), timeout=60)
        require('[Toastty] Wake' not in ui.texts(), f'The digest is not folded: {ui.texts()[-800:]}')
        capture('digest-folded')
        ui.run('click-label', 'Toastty · 1 update')
        wait_for('the open digest', lambda: 'Scheduled check' in ui.texts(), timeout=30)
        capture('digest-open')
        ui.run('click-label', 'Toastty · 1 update')
        wait_for('Claude to end the digest\'s turn', at_prompt, timeout=240)
        step('a digest showed folded and opened', timer=timer, digest=transcript()[digest_at]['text'])

        # 6. A task link is a chip; in the full view, a click opens the task
        # with the chat in the dock.
        missing = str(uuid.uuid4()).upper()
        ui.send('Reply with exactly this text and nothing else: '
                f'[some old words](toastty://task/{task_id}) is ready. '
                f'[not-a-task](toastty://task/{missing}) and [not-a-link](toastty://action/open-settings) are plain.')
        wait_for('the reply with the links', lambda: index_of('assistant', f'toastty://task/{task_id}') is not None, timeout=240)
        chip_title = 'Restore split ratios'.replace(' ', NO_BREAK_SPACE)
        wait_for('the chip with the task\'s title', lambda: chip_title in ui.texts(), timeout=60)
        wait_for('the prompt to open again', at_prompt, timeout=120)
        capture('task-chip')
        ui.run('click-text', 'not-a-task')
        ui.run('click-text', 'not-a-link')
        time.sleep(1.5)
        require(selected_workspace() == coordinator_id, 'A link to no task opened something')
        require(not ui.exists('coordinator.dock'), 'The dock shows beside the full view')
        ui.run('click-text', chip_title)
        wait_for('the task\'s space', lambda: selected_workspace() == task_space, timeout=30)
        wait_for('the chat in the dock', lambda: ui.exists('coordinator.dock') and chip_title in ui.texts(), timeout=30)
        require(not ui.exists('coordinator.panel.mode-toggle'), 'The full view still shows beside the dock')
        # The header's tab strip moves for 0.18 s after a workspace switch.
        time.sleep(0.6)
        capture('task-space-with-dock')
        step('a chip in the full view opened the task with the chat in the dock', taskID=task_id,
             dock=ui.run('frame', 'coordinator.dock')[1])

        # 7. The dock is the same chat: a message sent there gets its reply
        # there, and the output it shows is read.
        ui.send('Reply with exactly this one word and nothing else: CHAT-DOCK')
        wait_for_reply('CHAT-DOCK')
        require(selected_workspace() == task_space, 'Sending from the dock left the task')
        wait_for('the reply to count as read', lambda: ui.has_label(ROW_READ) and not ui.has_label(ROW_UNREAD), timeout=10)
        capture('dock-reply')
        step('the dock sent and showed the reply, which is read', chat=ui.texts()[-300:])

        # 8. Open Full View and the full view's Dock button move the chat.
        ui.run('click', 'coordinator.dock.open-full-view')
        wait_for('the full view', lambda: selected_workspace() == coordinator_id and not ui.exists('coordinator.dock')
                 and ui.exists('coordinator.chat'), timeout=30)
        time.sleep(0.6)
        capture('full-view')
        ui.run('click', 'coordinator.panel.dock')
        wait_for('the task with the dock again', lambda: selected_workspace() == task_space
                 and ui.exists('coordinator.dock'), timeout=30)
        step('Open Full View and Dock moved the chat between the full view and the dock')

        # 9. The toolbar button hides the dock; Cmd+Shift+K shows it with the
        # keyboard in its field, where Cmd+= changes the chat's text size.
        ui.run('click', 'titlebar.toggle.coordinator-dock')
        wait_for('the dock to hide', lambda: not ui.exists('coordinator.dock'), timeout=30)
        ui.run('key', 'cmd-shift-k')
        wait_for('the dock to show', lambda: ui.exists('coordinator.dock'), timeout=30)
        time.sleep(0.6)
        composer_height = lambda: int(ui.run('frame', 'coordinator.chat.composer')[1].split()[3])
        before_scale = composer_height()
        ui.run('key', 'cmd-equal')
        wait_for('a larger text size in the dock', lambda: composer_height() > before_scale, timeout=10)
        ui.run('key', 'cmd-0')
        wait_for('the text size again', lambda: composer_height() == before_scale, timeout=10)
        require(selected_workspace() == task_space, 'The shortcut left the task')
        # Cmd+W in the dock's field closes neither the task's panel nor the window.
        task_terminals = lambda: [w for w in instance.query('workspace.list')['workspaces']
                                  if w['workspaceID'] == task_space][0]['terminalCwds']
        terminals_before = task_terminals()
        ui.run('focus', 'coordinator.chat.composer')
        ui.run('key', 'cmd-w')
        time.sleep(1.5)
        require(task_terminals() == terminals_before and ui.exists('coordinator.dock'),
                'Cmd+W in the dock\'s field closed something')
        step('the toolbar button and Cmd+Shift+K hid and showed the dock; Cmd+= sized its chat; Cmd+W closed nothing',
             composerHeight=before_scale)

        # A drag on the dock's edge sets its width, up to 480 points.
        dock_frame = lambda: [int(value) for value in ui.run('frame', 'coordinator.dock')[1].split()]
        x, y, width, height = dock_frame()
        ui.run('drag', str(x + width), str(y + height // 2), str(x + width + 60), str(y + height // 2))
        wait_for('a wider dock', lambda: dock_frame()[2] >= width + 50, timeout=10)
        x, y, wider, height = dock_frame()
        ui.run('drag', str(x + wider), str(y + height // 2), str(x + wider + 400), str(y + height // 2))
        wait_for('the widest dock', lambda: dock_frame()[2] == 480, timeout=10)
        capture('dock-widest')
        step('a drag on the dock\'s edge set its width', default=width, wider=wider, widest=dock_frame()[2])

        # 10. With the sidebar hidden, the dock is at the window's left edge.
        ui.run('key', 'cmd-b')
        wait_for('the dock at the window\'s left edge',
                 lambda: int(ui.run('frame', 'coordinator.dock')[1].split()[0])
                 == int(ui.run('window-frame')[1].split()[0]), timeout=10)
        time.sleep(0.6)
        capture('sidebar-hidden-dock')
        ui.run('key', 'cmd-b')
        wait_for('the sidebar again', lambda: ui.exists('sidebar.coordinator'), timeout=10)
        step('with the sidebar hidden, the dock was at the window\'s left edge')

        # 11. While the dock is hidden, a reply is unread on the row and the
        # toolbar button. Showing the dock reads it.
        ui.run('click', 'titlebar.toggle.coordinator-dock')
        wait_for('the dock to hide', lambda: not ui.exists('coordinator.dock'), timeout=30)
        # A note from `coordinator send` is not the user's, so the
        # coordinator answers it without following it. Any answer will do.
        cli('coordinator', 'send', 'For your information only: CHAT-HIDDEN. No action is needed.')
        wait_for('the note in the conversation', lambda: index_of('user', 'CHAT-HIDDEN') is not None, timeout=120)
        note_at = index_of('user', 'CHAT-HIDDEN')
        wait_for('the coordinator\'s answer to the note',
                 lambda: any(entry['role'] == 'assistant' for entry in transcript()[note_at + 1:]), timeout=240)
        wait_for('the unread row', lambda: ui.has_label(ROW_UNREAD), timeout=60)
        require(selected_workspace() == task_space, 'The reply took the user out of the task')
        capture('dock-hidden-unread')
        ui.run('click', 'titlebar.toggle.coordinator-dock')
        wait_for('the dock', lambda: ui.exists('coordinator.dock'), timeout=30)
        wait_for('the answer to count as read', lambda: not ui.has_label(ROW_UNREAD), timeout=10)
        capture('dock-shown-read')
        step('a reply while the dock was hidden was unread until the dock showed it')

        instance.request('app_control.run_action', dict(id='workspace.select', args=dict(workspaceID=coordinator_id)))
        wait_for('the coordinator again', lambda: selected_workspace() == coordinator_id
                 and ui.exists('coordinator.chat') and not ui.exists('coordinator.dock'), timeout=30)

        # 12. The header's switch shows the terminal, then the chat.
        ui.run('click', 'coordinator.panel.mode-toggle')
        wait_for('the terminal in place of the chat', lambda: not ui.exists('coordinator.chat'), timeout=30)
        panel = status()['panelID']
        screen = instance.request('app_control.run_query', dict(id='terminal.visible-text', args=dict(panelID=panel)))
        capture('terminal')
        ui.run('click', 'coordinator.panel.mode-toggle')
        wait_for('the chat again', lambda: ui.exists('coordinator.chat') and 'CHAT-ONE' in ui.texts(), timeout=30)
        capture('chat-after-terminal')
        step('the switch showed the terminal and the chat', terminal=((screen.get('result') or {}).get('text') or '')[-600:])

        # 13. Kill and relaunch with the chat open, now with Remote Access on.
        before = status()
        coordinator_check.wait_for_layout(runtime_home, '"isCoordinator"', '"resumeRecord"',
                                          '"coordinatorDockWidthPointsOverride"')
        instance.kill()
        port = steer.free_port()
        gateway = steer.Gateway(port)
        instance = ChatInstance(check.binary, environment, socket_path, runtime_home, app_log, gateway_port=port)
        instance.wait_until_ready()
        ui = UI(check.artifacts, pid())
        ui.run('activate')
        restored = status()
        require(restored['exists'] and restored['workspaceID'] == before['workspaceID'], f'Not restored: {restored}')
        require(selected_workspace() == coordinator_id, 'The relaunch did not show the coordinator')
        resumed = wait_for('Claude to be resumed', lambda: (s := status()).get('sessionID') and s, timeout=120)
        wait_for('the same conversation in the chat',
                 lambda: all(marker in ui.texts() for marker in ('CHAT-ONE', 'CHAT-FIVE', chip_title)), timeout=120)
        wait_for('the resumed prompt', at_prompt, timeout=180)
        capture('relaunched')
        # The dock comes back beside the task, at its width.
        instance.request('app_control.run_action', dict(id='workspace.select', args=dict(workspaceID=task_space)))
        wait_for('the dock after the relaunch', lambda: ui.exists('coordinator.dock')
                 and int(ui.run('frame', 'coordinator.dock')[1].split()[2]) == 480, timeout=30)
        capture('relaunched-dock')
        instance.request('app_control.run_action', dict(id='workspace.select', args=dict(workspaceID=coordinator_id)))
        wait_for('the coordinator again', lambda: selected_workspace() == coordinator_id
                 and not ui.exists('coordinator.dock'), timeout=30)
        ui.send('Reply with exactly this one word and nothing else: CHAT-SIX')
        wait_for_reply('CHAT-SIX')
        wait_for('the prompt to open again', at_prompt, timeout=120)
        capture('after-relaunch-send')
        step('the relaunch showed the same conversation and took a message', resumed=resumed)

        # 14. With Remote Access on, a paired device sends to the same panel.
        def conversation():
            _, body = gateway.call('GET', '/api/sessions')
            return next((c for c in (body or {}).get('snapshot', {}).get('conversations', [])
                         if c['placement'].get('panelID') == status()['panelID']), None)

        def phone_send(request_id, text, mode='prompt', epoch=None):
            current = conversation()
            body = dict(conversationID=current['conversationID'], clientRequestID=request_id, deliveryMode=mode,
                        expectedInputEpoch=epoch or current['inputAvailability']['epoch'], text=text)
            code, result = gateway.call('POST', '/api/conversation.message.send', body)
            require(code == 200 and result.get('status') == ('queued' if mode == 'queue' else 'accepted'),
                    f'The device\'s send failed: {code} {result}')
            return result

        wait_for('the gateway and the coordinator\'s conversation',
                 lambda: (c := conversation()) and c['inputAvailability'].get('kind') == 'open_prompt', timeout=120)
        phone_send('phone-1', 'Reply with exactly this one word and nothing else: PHONE-ONE')
        wait_for_reply('PHONE-ONE')
        wait_for('the chat to mark the device\'s message', lambda: 'sent remotely' in ui.texts(), timeout=30)
        wait_for('the prompt to open again', at_prompt, timeout=120)
        capture('message-from-a-paired-device')
        # While the coordinator works: the Mac queues first, the device second.
        ui.send(long_turn(25, 'CHAT-SEVEN'))
        busy = wait_for('the turn the device can queue into',
                        lambda: (c := conversation()) and (c.get('inputControl') or {}).get('turnEpoch') and c, timeout=60)
        ui.queue('Reply with exactly this one word and nothing else: CHAT-EIGHT')
        wait_for('the Mac\'s message to wait', lambda: status()['queuedCount'] == 1)
        phone_send('phone-2', 'Reply with exactly this one word and nothing else: PHONE-TWO', 'queue',
                   busy['inputControl']['turnEpoch'])
        wait_for('the chat to list both', lambda: 'PHONE-TWO' in ui.texts() and 'queued 2' in ui.texts().lower(), timeout=30)
        capture('device-and-mac-queued')
        wait_for_reply('CHAT-SEVEN')
        wait_for_reply('PHONE-TWO')
        wait_for_reply('CHAT-EIGHT')
        order = [index_of('assistant', 'CHAT-SEVEN'), index_of('user', 'PHONE-TWO'), index_of('assistant', 'PHONE-TWO'),
                 index_of('user', 'CHAT-EIGHT'), index_of('assistant', 'CHAT-EIGHT')]
        require(order == sorted(order), f'The device\'s and the Mac\'s messages did not each get a turn in order: {order}')
        wait_for('the queue to empty', lambda: status()['queuedCount'] == 0 and at_prompt(), timeout=120)
        capture('device-then-mac')
        step('a paired device and the Mac shared the prompt in order', order=order)

        # 15. Restart Coordinator while the chat shows.
        old_session = status()['sessionID']
        restarted = cli('coordinator', 'restart')
        require(restarted['startedAgent'] and restarted['sessionID'] != old_session, f'Restart did not start an agent: {restarted}')
        wait_for('the chat over the new terminal', lambda: ui.exists('coordinator.chat') and ui.exists('coordinator.chat.composer'), timeout=60)
        wait_for('the new agent at its prompt', at_prompt, timeout=180)
        wait_for('the chat to leave the old conversation', lambda: 'CHAT-ONE' not in ui.texts(), timeout=60)
        capture('after-restart')
        ui.run('activate')
        ui.send('Reply with exactly this one word and nothing else: CHAT-NINE')
        wait_for_reply('CHAT-NINE')
        newest = transcript()[index_of('assistant', 'CHAT-NINE')]['file']
        require(newest != transcript()[index_of('assistant', 'CHAT-ONE')]['file'],
                'The message after the restart went to the old conversation')
        capture('after-restart-send')
        step('the chat followed the restarted agent', restarted=restarted)
    except Exception:
        # What the window showed when the check stopped.
        try:
            capture('failure')
        except Exception:  # noqa: BLE001 - the first error matters
            pass
        raise
    finally:
        try:
            instance.kill()
        except Exception:  # noqa: BLE001 - the evidence below matters more
            pass
        check.copy_instance_log(runtime_home, 'chat')
        steer.set_directory_trust(directory, False)
        if project.is_dir():
            saved = check.artifacts / f'{check.prefix}-transcripts'
            saved.mkdir(exist_ok=True)
            for path in project.glob('*.jsonl'):
                shutil.copyfile(path, saved / path.name)
            # Only the project for this run's unique temporary folder.
            shutil.rmtree(project, ignore_errors=True)


class Check(coordinator_check.Check):
    def __init__(self):
        super().__init__('claude')
        self.prefix = NAME


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    if options.gui_session:
        run_in_gui_session([])
    check = Check()
    try:
        run(check)
        check.evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - always keep the evidence
        check.evidence['failure'] = repr(error)
        raise
    finally:
        check.finish()
    print(f'[{NAME}] passed', flush=True)


if __name__ == '__main__':
    main()
