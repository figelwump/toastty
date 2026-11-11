#!/usr/bin/env python3
"""A user's first run with the coordinator, through the real UI and the real Claude CLI.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-first-run-check.py --gui-session'.
The run uses subscription usage. It needs the remote Mac's screen unlocked.

Each scenario starts its own instance of the wrapper's build, with a throwaway
runtime home and user home, and does not touch the installed production app.
The coordinator is the real, authenticated Claude CLI. No scenario marks the
coordinator's folder as trusted: that is the app's work, and what the check is
about. Every action a person makes goes through the real UI, as in
remote-coordinator-chat-check.py.

The scenarios prove from the UI's own text, the CLI, Claude's transcript and
Claude's config file that:
- start: a first launch asks once whether to start the coordinator; Start
  Coordinator opens it; Claude reaches its first prompt with no folder-trust
  question and answers the first message; Claude's config file names the
  coordinator's folder as trusted, keeps every entry it had, and has every
  write of three other Claude Code processes that saved to it while the app
  started; after the app is killed and relaunched, the coordinator is
  restored and nothing is asked;
- not-now: Not Now starts nothing; a relaunch does not ask again; Open
  Coordinator in the command palette and in the Agent menu each open it, and
  Restart Coordinator is offered only while it is open;
- notice: with a folder that Claude does not trust, the chat says that the
  agent may wait in the terminal and offers Show Terminal; after the answer in
  the terminal, the chat says that the user typed there and offers Send
  Anyway, and one click types the waiting message, which Claude answers. The
  app cannot tell this profile's config file, so it writes no trust for it.

'--expect-notice no' checks the notice scenario against a build from before
the notice: the message waits and the chat says nothing about the terminal.

The check adds entries to ~/.claude.json only for its own temporary folders
and removes them at the end, under Claude Code's own lock. A copy of the file
from before the run stays beside it until the run ends; only key names,
counts and checksums go into the evidence.

Evidence goes to remote-coordinator-first-run-check.json, the app logs and
Claude's transcripts in the artifacts directory. Under '--gui-session' the
check also keeps still pictures of the window's part of the screen, under
remote-coordinator-first-run-check-frames.
"""

import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).parent
NAME = 'remote-coordinator-first-run-check'
SCENARIOS = ('start', 'not-now', 'notice')


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


chat = load('coordinator_chat_check', 'remote-coordinator-chat-check.py')
coordinator_check, steer = chat.coordinator_check, chat.steer
require, wait_for = chat.require, chat.wait_for

QUESTION = 'Start the coordinator?'
# How many times each Claude Code process beside the app saves.
SIDE_WRITES = 12
START, NOT_NOW = 'Start Coordinator', 'Not Now'
TRUST_QUESTION = 'trust this folder'
CLAUDE_CONFIG = Path.home() / '.claude.json'


# MARK: - Claude's config file


@contextlib.contextmanager
def claude_config_lock(timeout=20):
    """Claude Code's own lock for its config file: a directory beside it."""
    lock = Path(str(CLAUDE_CONFIG) + '.lock')
    deadline = time.time() + timeout
    while True:
        try:
            lock.mkdir()
            break
        except FileExistsError:
            require(time.time() < deadline, f'{lock} stayed held')
            time.sleep(0.05)
    try:
        yield
    finally:
        lock.rmdir()


def read_config():
    return json.loads(CLAUDE_CONFIG.read_text())


def remove_projects(folders, quiet=4, timeout=60):
    """Removes this run's project entries, and leaves the rest of the file
    alone. A Claude session that the run ended saves once more as it exits,
    so the entries are removed until they stay away for `quiet` seconds."""
    removed, quiet_since, deadline = set(), None, time.time() + timeout
    while True:
        with claude_config_lock():
            config = read_config()
            projects = config.get('projects', {})
            gone = [folder for folder in folders if projects.pop(folder, None) is not None]
            if gone:
                temporary = CLAUDE_CONFIG.with_name(CLAUDE_CONFIG.name + '.toastty-check')
                temporary.write_text(json.dumps(config, indent=2, ensure_ascii=False))
                shutil.copymode(CLAUDE_CONFIG, temporary)
                os.replace(temporary, CLAUDE_CONFIG)
        removed.update(gone)
        if gone:
            quiet_since = None
        elif quiet_since is None:
            quiet_since = time.time()
        elif time.time() - quiet_since >= quiet or time.time() > deadline:
            return sorted(removed)
        time.sleep(1)


def summary(config):
    """What the evidence may say about the file: names, counts and checksums."""
    def digest(value):
        return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()[:16]

    return dict(keys={key: digest(value) for key, value in config.items() if key != 'projects'},
                projects={folder: digest(entry) for folder, entry in config.get('projects', {}).items()})


def compare(before, after, own_folders):
    """What the run did to the entries it does not own."""
    own = set(own_folders)
    return dict(
        missingKeys=sorted(set(before['keys']) - set(after['keys'])),
        changedKeys=sorted(key for key in before['keys'] if key in after['keys'] and after['keys'][key] != before['keys'][key]),
        addedKeys=sorted(set(after['keys']) - set(before['keys'])),
        missingProjects=sorted(set(before['projects']) - set(after['projects'])),
        changedProjects=sorted(folder for folder in before['projects']
                               if folder in after['projects'] and after['projects'][folder] != before['projects'][folder]),
        addedProjects=sorted(set(after['projects']) - set(before['projects']) - own),
        ownProjectsLeft=sorted(own & set(after['projects'])),
    )


# MARK: - One scenario's app


class Run:
    """One scenario: a runtime home, the app, and the UI driver."""

    def __init__(self, check, name, claude, profile_prefix=(), asks_start_offer=True):
        self.check, self.name, self.asks_start_offer = check, name, asks_start_offer
        # Only this disposable app sees the profile. The coordinator gets no
        # settings of the host and one tool it does not need.
        argv = [*profile_prefix, claude, '--setting-sources=', '--tools', 'Bash', '--strict-mcp-config']
        self.runtime_home, self.user_home = check.home(name, argv)
        (self.user_home / '.toastty/tasks.toml').write_text('[coordinator]\nagent = "claude"\n')
        subprocess.run(['git', 'init', '-q', str(self.user_home)], check=True)
        self.environment = check.environment(name, self.runtime_home, self.user_home, real_home=True)
        self.run_cli, self.cli = check.cli_runner(self.environment)
        self.directory = self.runtime_home / 'coordinator'
        self.project = steer.claude_project_directory(self.directory)
        check.own_folders.append(str(self.directory))
        self.app_log = check.artifacts / f'{NAME}-{name}-app.log'
        self.instance = self.ui = None

    def launch(self):
        self.instance = chat.ChatInstance(self.check.binary, self.environment, self.environment['TOASTTY_SOCKET_PATH'],
                                          self.runtime_home, self.app_log, asks_start_offer=self.asks_start_offer)
        self.instance.wait_until_ready()
        wait_for('instance.json', lambda: (self.runtime_home / 'instance.json').is_file())
        pid = json.loads((self.runtime_home / 'instance.json').read_text())['pid']
        self.ui = chat.UI(self.check.artifacts, pid)
        _, trust = self.ui.run('status')
        require('trusted=true' in trust and 'locked=false' in trust,
                f'The UI driver cannot act: {trust}. Unlock the screen, or run with --gui-session over SSH')
        if self.check.window_frame:
            placed = self.ui.run('window-set-frame', *self.check.window_frame)[1].split()
            require(placed == self.check.window_frame, f'The window is at {placed}, not at {self.check.window_frame}')

    def show_terminal_for_a_picture(self, step):
        """Switches the panel to the terminal, keeps a picture and its text, and switches back."""
        self.ui.run('click', 'coordinator.panel.mode-toggle')
        wait_for('the terminal in place of the chat', lambda: not self.ui.exists('coordinator.chat'), timeout=30)
        time.sleep(1)
        self.capture(step)
        text = self.screen()
        self.ui.run('click', 'coordinator.panel.mode-toggle')
        wait_for('the chat again', lambda: self.ui.exists('coordinator.chat'), timeout=30)
        return text

    def relaunch(self):
        # The answer and the layout are saved a moment after the change.
        time.sleep(3)
        self.instance.kill()
        self.launch()

    def status(self):
        return self.cli('coordinator', 'status')

    def at_prompt(self):
        current = self.status()
        return current.get('agentState') == 'running' and current.get('status') in ('idle', 'ready') and current

    def screen(self):
        panel = self.status().get('panelID')
        if not panel:
            return ''
        response = self.instance.request('app_control.run_query', dict(id='terminal.visible-text', args=dict(panelID=panel)))
        return (response.get('result') or {}).get('text', '') if response.get('ok') else ''

    def question(self):
        """The text of the question whether to start the coordinator, or '' when it does not show."""
        code, output = self.ui.run('sheet-texts', check=False)
        return output if code == 0 and QUESTION in output else ''

    def no_question_for(self, seconds):
        """The window has the keyboard and the question does not come."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.ui.run('activate')
            require(not self.question(), f'The question showed: {self.question()}')
            time.sleep(1)

    def menu_item(self, title):
        return self.ui.run('menu-enabled', 'Agent', title)[1]

    def transcript(self):
        entries = []
        for path in sorted(self.project.glob('*.jsonl'), key=lambda item: item.stat().st_mtime):
            for line in path.read_text().splitlines():
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get('type') not in ('user', 'assistant') or record.get('isSidechain'):
                    continue
                text = steer.claude_content_text((record.get('message') or {}).get('content'))
                if text:
                    entries.append(dict(role=record['type'], text=text))
        return entries

    def replied(self, marker):
        return any(entry['role'] == 'assistant' and marker in entry['text'] for entry in self.transcript())

    def wait_for_reply(self, marker, timeout=240):
        wait_for(f'the reply {marker}', lambda: self.replied(marker), timeout=timeout)
        wait_for(f'the chat to show {marker} twice', lambda: self.ui.texts().count(marker) >= 2, timeout=60)

    def wait_for_first_prompt_without_trust_question(self):
        """Claude reaches its first prompt, and its terminal never asks about the folder."""
        seen = []

        def ready():
            text = self.screen()
            if TRUST_QUESTION in text:
                seen.append(text)
            return self.at_prompt()

        current = wait_for('Claude at its first prompt', ready, timeout=180, interval=0.5)
        require(not seen and TRUST_QUESTION not in self.screen(),
                f'Claude asked whether to trust the coordinator\'s folder: {(seen or [self.screen()])[0][-600:]}')
        return current

    def window_rect(self):
        """The part of the window that is on the screen, as "x,y,width,height", or None."""
        code, output = self.ui.run('window-frame', check=False)
        if code != 0 or len(output.split()) != 4:
            return None
        x, y, width, height = map(int, output.split())
        left, top = max(x, 0), max(y, 0)
        return f'{left},{top},{x + width - left},{y + height - top}'

    def capture(self, step, whole_screen=False):
        """Keeps a still picture of the window's part of the screen, as it
        is. In a session that may not record the screen, the picture shows
        no windows. Never a recording: one from Terminal makes macOS show a
        consent prompt that stays until a person answers it."""
        self.check.frame_count += 1
        label = f'{self.check.frame_count:02d}-{self.name}-{step}'
        path = self.check.frames / f'{label}.png'
        rect = None if whole_screen else self.window_rect()
        done = subprocess.run(['screencapture', '-x', *(['-R', rect] if rect else []), str(path)],
                              capture_output=True, text=True, timeout=30)
        self.check.evidence['captures'].append(dict(step=label, at=time.time(), rect=rect, path=str(path),
                                                    ok=done.returncode == 0 and path.is_file(),
                                                    error=(done.stdout + done.stderr).strip() or None))

    def finish(self):
        try:
            if self.instance:
                self.instance.kill()
        except Exception:  # noqa: BLE001 - the evidence matters more
            pass
        self.check.copy_instance_log(self.runtime_home, self.name)
        if self.project.is_dir():
            saved = self.check.artifacts / f'{NAME}-{self.name}-transcripts'
            saved.mkdir(exist_ok=True)
            for path in self.project.glob('*.jsonl'):
                shutil.copyfile(path, saved / path.name)
            # Only the project for this run's unique temporary folder.
            shutil.rmtree(self.project, ignore_errors=True)


@contextlib.contextmanager
def scenario(check, name, claude, **options):
    run = Run(check, name, claude, **options)
    try:
        # Inside the `try`: a launch that fails must not leave its app.
        run.launch()
        yield run
    except Exception:
        try:
            run.capture('failure')
        except Exception:  # noqa: BLE001 - the first error matters
            pass
        raise
    finally:
        run.finish()


def trusted(folder):
    return read_config().get('projects', {}).get(str(folder), {}).get('hasTrustDialogAccepted') is True


# MARK: - The scenarios


def start(check, claude, host_environment):
    with scenario(check, 'start', claude) as run:
        step = check.step
        # 1. A first launch asks once.
        require(not run.directory.exists(), 'The coordinator\'s folder exists before the first launch')
        run.ui.run('activate')
        question = wait_for('the question at the first launch', run.question, timeout=30)
        require(START in question and NOT_NOW in question and 'follows your tasks' in question,
                f'The question does not say what the coordinator does: {question}')
        require(not run.status()['exists'], 'A coordinator exists before the answer')
        run.capture('question')
        # The window has the keyboard again: still one question.
        run.ui.run('activate')
        require(run.question() == question, 'The question changed when the window got the keyboard again')
        step('the first launch asked whether to start the coordinator', question=question)

        # Other Claude Code processes write the same config file while the
        # app writes the trust and Claude starts: each adds servers, one
        # after the other, under its own folder (`claude mcp add --scope
        # local` saves in projects[<folder>].mcpServers).
        sides = []
        for index in (1, 2, 3):
            folder = Path(tempfile.mkdtemp(prefix=f'side-{index}-', dir=check.root)).resolve()
            check.own_folders.append(str(folder))
            names = [f'side-{index}-{write}' for write in range(1, SIDE_WRITES + 1)]
            script = ' && '.join(f'{shlex.quote(claude)} mcp add --scope local {name} -- /bin/echo {name}' for name in names)
            process = subprocess.Popen(['/bin/sh', '-c', script], cwd=folder, env=host_environment,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            sides.append(dict(folder=folder, names=names, process=process, startedAt=time.time()))

        # 2. Start Coordinator opens it, and Claude asks nothing about the folder.
        run.ui.run('click-label', START)
        wait_for('the question to go', lambda: not run.question(), timeout=30)
        opened = wait_for('the coordinator', lambda: (s := run.status())['exists'] and s, timeout=60)
        wait_for('the chat', lambda: run.ui.exists('coordinator.chat') and run.ui.exists('coordinator.chat.composer'), timeout=60)
        run.capture('opened')
        wait_for('the trust for the coordinator\'s folder', lambda: trusted(run.directory), timeout=60, interval=0.1)
        trust_seen_at = time.time()
        prompt = run.wait_for_first_prompt_without_trust_question()
        if run.ui.has_label('Dismiss'):
            run.ui.run('click-label', 'Dismiss', check=False)
            time.sleep(0.5)
        require(not run.ui.exists('coordinator.chat.notice'), f'The chat shows a notice: {run.ui.texts()[-400:]}')
        run.capture('started')
        terminal = run.show_terminal_for_a_picture('terminal-at-first-prompt')
        require(TRUST_QUESTION not in terminal, f'Claude asked about the folder: {terminal[-400:]}')
        step('Start opened the coordinator and Claude asked nothing about the folder', opened=opened, prompt=prompt,
             terminal=terminal[-700:])

        # 3. The first message is answered.
        run.ui.send('Reply with exactly this one word and nothing else: FIRST-ONE')
        run.wait_for_reply('FIRST-ONE')
        run.capture('first-message')
        step('the first message was answered', chat=run.ui.texts()[-400:])

        # 4. The other processes kept every write, and the trust is still there.
        for side in sides:
            output, _ = side['process'].communicate(timeout=240)
            side['endedAt'] = time.time()
            require(side['process'].returncode == 0, f'A Claude Code process beside the app failed: {output[-400:]}')
        config = read_config()
        saved = {}
        for side in sides:
            servers = config.get('projects', {}).get(str(side['folder']), {}).get('mcpServers', {})
            require(sorted(servers) == sorted(side['names']),
                    f'Claude\'s config file lost writes of the process in {side["folder"]}: {sorted(servers)}')
            saved[str(side['folder'])] = dict(servers=len(servers), startedAt=side['startedAt'], endedAt=side['endedAt'])
        require(trusted(run.directory), 'The trust for the coordinator\'s folder is gone after the other processes saved')
        step('the Claude Code processes beside the app kept every write', saved=saved, trustWrittenBy=trust_seen_at)

        # 5. A relaunch restores the coordinator and asks nothing.
        before = run.status()
        coordinator_check.wait_for_layout(run.runtime_home, '"isCoordinator"', '"resumeRecord"')
        run.relaunch()
        run.ui.run('activate')
        restored = run.status()
        require(restored['exists'] and restored['workspaceID'] == before['workspaceID'], f'Not restored: {restored}')
        run.no_question_for(8)
        wait_for('the same conversation in the chat', lambda: 'FIRST-ONE' in run.ui.texts(), timeout=120)
        resumed = run.wait_for_first_prompt_without_trust_question()
        run.capture('relaunched')
        step('the relaunch restored the coordinator and asked nothing', restored=restored, resumed=resumed)


def not_now(check, claude, _host_environment):
    with scenario(check, 'not-now', claude) as run:
        step = check.step
        # 1. Not Now starts nothing.
        run.ui.run('activate')
        wait_for('the question at the first launch', run.question, timeout=30)
        run.capture('question')
        run.ui.run('click-label', NOT_NOW)
        wait_for('the question to go', lambda: not run.question(), timeout=30)
        time.sleep(2)
        require(not run.status()['exists'] and not run.directory.exists(), f'Not Now started something: {run.status()}')
        items = {title: run.menu_item(title) for title in ('Open Coordinator', 'Restart Coordinator')}
        require(items == {'Open Coordinator': 'enabled', 'Restart Coordinator': 'disabled'}, f'The Agent menu: {items}')
        run.ui.run('menu-open', 'Agent')
        run.capture('agent-menu', whole_screen=True)
        run.ui.run('key', 'escape')
        run.capture('not-now')
        step('Not Now started nothing', menu=items)

        # 2. The next launch does not ask again.
        run.relaunch()
        run.no_question_for(8)
        require(not run.status()['exists'], f'The relaunch started the coordinator: {run.status()}')
        run.capture('relaunched')
        step('the relaunch did not ask again')

        # 3. Open Coordinator in the command palette.
        run.ui.run('activate')
        run.ui.run('key', 'cmd-shift-p')
        wait_for('the command palette', lambda: run.ui.exists('command-palette.search'), timeout=30)
        time.sleep(0.5)
        run.ui.run('type', 'Open Coordinator')
        time.sleep(1)
        run.capture('palette')
        run.ui.run('key', 'return')
        from_palette = wait_for('the coordinator from the palette', lambda: (s := run.status())['exists'] and s, timeout=60)
        wait_for('the chat', lambda: run.ui.exists('coordinator.chat'), timeout=60)
        wait_for('the trust for the coordinator\'s folder', lambda: trusted(run.directory), timeout=60)
        run.wait_for_first_prompt_without_trust_question()
        require(run.menu_item('Restart Coordinator') == 'enabled', 'Restart Coordinator is not offered while it is open')
        run.capture('opened-from-palette')
        step('Open Coordinator in the command palette opened it', opened=from_palette)

        # 4. Open Coordinator in the Agent menu, after the user closed it.
        run.instance.request('app_control.run_action',
                             dict(id='workspace.close', args=dict(workspaceID=from_palette['workspaceID'])))
        wait_for('the coordinator to be gone', lambda: not run.status()['exists'], timeout=30)
        run.no_question_for(4)
        run.ui.run('menu', 'Agent', 'Open Coordinator')
        from_menu = wait_for('the coordinator from the menu', lambda: (s := run.status())['exists'] and s, timeout=60)
        require(from_menu['workspaceID'] != from_palette['workspaceID'], 'The menu did not open a new coordinator')
        wait_for('the chat', lambda: run.ui.exists('coordinator.chat'), timeout=60)
        running = run.wait_for_first_prompt_without_trust_question()
        run.capture('opened-from-menu')
        step('Open Coordinator in the Agent menu opened it', opened=from_menu, running=running)

        # 5. Restart Coordinator in the Agent menu.
        run.ui.run('menu', 'Agent', 'Restart Coordinator')
        restarted = wait_for('a new agent session',
                             lambda: (s := run.status()).get('sessionID') not in (None, running['sessionID']) and s,
                             timeout=120)
        run.wait_for_first_prompt_without_trust_question()
        step('Restart Coordinator in the Agent menu started a new session', before=running['sessionID'], restarted=restarted)


def notice(check, claude, _host_environment, expect_notice=True):
    # The profile changes the agent's environment in a way the app does not
    # read, so the app cannot tell which config file this Claude uses and
    # writes no trust. Claude then asks about the folder, as it does at any
    # question that comes before its first report.
    prefix = ('/usr/bin/env', '-u', 'TOASTTY_FIRST_RUN_CHECK_NO_SUCH_VARIABLE')
    with scenario(check, 'notice', claude, profile_prefix=prefix, asks_start_offer=False) as run:
        step = check.step
        opened = run.cli('coordinator', 'open')
        require(opened['startedAgent'], f'Open did not start Claude: {opened}')
        run.ui.run('activate')
        wait_for('the chat', lambda: run.ui.exists('coordinator.chat') and run.ui.exists('coordinator.chat.composer'), timeout=60)
        require(not run.question(), 'The question showed although the coordinator is open')
        wait_for('Claude\'s question about the folder', lambda: TRUST_QUESTION in run.screen(), timeout=120)
        require(not trusted(run.directory), 'The app wrote trust for a profile whose config file it cannot tell')
        if run.ui.has_label('Dismiss'):
            run.ui.run('click-label', 'Dismiss', check=False)
            time.sleep(0.5)

        # The user's message waits.
        run.ui.send('Reply with exactly this one word and nothing else: NOTICE-ONE')
        waiting = wait_for('the message to wait', lambda: (s := run.status())['queuedCount'] == 1 and s, timeout=30)
        wait_for('the chat to show it as Queued', lambda: 'queued 1' in run.ui.texts().lower(), timeout=30)
        run.capture('message-waits')

        if not expect_notice:
            # Before the notice: for as long as the user looks, the chat
            # says nothing about the terminal.
            deadline = time.time() + 20
            frame = 0
            while time.time() < deadline:
                require(not run.ui.exists('coordinator.chat.notice'), f'The chat shows a notice: {run.ui.texts()[-400:]}')
                frame += 1
                run.capture(f'no-notice-{frame}')
                time.sleep(2)
            require(TRUST_QUESTION in run.screen() and run.status()['queuedCount'] == 1, 'Claude went on by itself')
            chat_text = run.ui.texts()[-500:]
            terminal = run.show_terminal_for_a_picture('terminal-trust-question')
            require(TRUST_QUESTION in terminal, f'The terminal does not show Claude\'s question: {terminal[-400:]}')
            step('the message waited and the chat said nothing about the terminal', waiting=waiting,
                 chat=chat_text, terminal=terminal[-700:])
            return

        require(waiting.get('hold') == 'agentStarting', f'The message does not wait for the agent\'s start: {waiting}')
        require('waits for the agent to start' in run.ui.texts().lower(),
                f'The chat does not say what the message waits for: {run.ui.texts()[-400:]}')
        wait_for('the notice', lambda: run.ui.exists('coordinator.chat.notice'), timeout=30)
        first = run.ui.texts('coordinator.chat.notice')
        # After a few seconds the notice names the terminal.
        frame = 0

        def names_the_terminal():
            nonlocal frame
            frame += 1
            run.capture(f'notice-{frame}')
            return 'answer in the terminal' in run.ui.texts('coordinator.chat.notice')

        wait_for('the notice that names the terminal', names_the_terminal, timeout=40, interval=1)
        named = run.ui.texts('coordinator.chat.notice')
        require('Show Terminal' in named, f'The notice offers no way to the terminal: {named}')
        step('the chat said that the agent may wait in the terminal', waiting=waiting, first=first, notice=named)

        # Show Terminal shows the question, and the user answers it there.
        run.ui.run('click', 'coordinator.chat.notice.show-terminal')
        wait_for('the terminal in place of the chat', lambda: not run.ui.exists('coordinator.chat'), timeout=30)
        time.sleep(1)
        run.capture('terminal')
        require(TRUST_QUESTION in run.screen(), f'The terminal does not show Claude\'s question: {run.screen()[-400:]}')
        # The terminal has the keyboard. Real keys choose "Yes, I trust this
        # folder": which choice Claude selects first differs by version.
        run.instance.request('app_control.run_action', dict(id='workspace.focus-panel', args=dict(panelID=run.status()['panelID'])))
        time.sleep(0.5)
        run.ui.run('activate')
        choices = [line.strip() for line in run.screen().splitlines() if 'trust this folder' in line or 'No, exit' in line]
        selected = next((index for index, line in enumerate(choices) if line.startswith('\u276f')), None)
        yes = next((index for index, line in enumerate(choices) if TRUST_QUESTION in line), None)
        require(selected is not None and yes is not None, f'The check cannot read Claude\'s choices: {choices}')
        for _ in range(abs(yes - selected)):
            run.ui.run('key', 'down' if yes > selected else 'up')
            time.sleep(0.3)
        run.capture('terminal-yes-selected')
        run.ui.run('key', 'return')
        wait_for('Claude to go on', lambda: TRUST_QUESTION not in run.screen(), timeout=60)
        started = wait_for('Claude at its first prompt', run.at_prompt, timeout=120)
        run.capture('terminal-claude-started')
        run.ui.run('click', 'coordinator.panel.mode-toggle')
        wait_for('the chat again', lambda: run.ui.exists('coordinator.chat'), timeout=30)

        # The agent reported its start. Toastty cannot tell the keys that
        # answered the question from a draft in Claude's prompt, so nothing
        # is typed: the chat says so and offers Send Anyway.
        wait_for('the notice about the keys in the terminal',
                 lambda: 'Send Anyway' in run.ui.texts('coordinator.chat.notice'), timeout=30)
        draft_notice = run.ui.texts('coordinator.chat.notice')
        require('answered a question' in draft_notice and 'has not started' not in draft_notice,
                f'The notice after the answer: {draft_notice}')
        time.sleep(3)
        held = run.status()
        require(held['queuedCount'] == 1 and held.get('hold') == 'userDraft' and not run.replied('NOTICE-ONE'),
                f'The message did not wait for the user\'s release: {held}')
        run.capture('send-anyway-notice')
        step('after the answer in the terminal the chat offered Send Anyway', started=started, held=held,
             notice=draft_notice)

        # One click types the waiting message, and Claude answers it.
        run.ui.run('click', 'coordinator.chat.notice.send-anyway')
        run.wait_for_reply('NOTICE-ONE')
        wait_for('the queue to empty', lambda: run.status()['queuedCount'] == 0, timeout=60)
        wait_for('the notice to go', lambda: not run.ui.exists('coordinator.chat.notice'), timeout=60)
        run.capture('answered')
        step('Send Anyway typed the waiting message and Claude answered it', chat=run.ui.texts()[-400:])


# MARK: - The check


class Check(coordinator_check.Check):
    def __init__(self):
        super().__init__('claude')
        self.prefix = NAME
        self.own_folders = []
        self.frame_count = 0
        self.frames = self.artifacts / f'{NAME}-frames'
        shutil.rmtree(self.frames, ignore_errors=True)
        self.frames.mkdir(parents=True)
        self.claude = self.window_frame = None


def run(check, scenarios, expect_notice):
    host_environment = {key: value for key, value in os.environ.items()
                        if not key.startswith('TOASTTY_')
                        and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT')}
    # A Claude CLI beside the host's own must not update the host's.
    host_environment['DISABLE_AUTOUPDATER'] = '1'
    claude = check.claude or shutil.which('claude') or str(Path.home() / '.local/bin/claude')
    require(Path(claude).is_file(), 'Claude CLI is not installed; install and authenticate it on the remote host')
    version = subprocess.check_output([claude, '--version'], text=True, timeout=30, env=host_environment).strip()
    auth = subprocess.run([claude, '--safe-mode', '--setting-sources', '', 'auth', 'status', '--json'],
                          capture_output=True, text=True, timeout=30, env=host_environment)
    require(auth.returncode == 0 and json.loads(auth.stdout).get('loggedIn'),
            'Claude CLI needs an interactive login on the remote host; add --gui-session over SSH')
    check.evidence.update(cliVersion=version, cliPath=claude, scenarios=list(scenarios), expectNotice=expect_notice)

    # The file as it was, kept beside it for the run. It holds the account's
    # details, so it does not go to the artifacts.
    backup = CLAUDE_CONFIG.with_name(f'{CLAUDE_CONFIG.name}.toastty-first-run-check-{os.getpid()}')
    shutil.copy2(CLAUDE_CONFIG, backup)
    before = summary(read_config())
    try:
        for name in scenarios:
            if name == 'start':
                start(check, claude, host_environment)
            elif name == 'not-now':
                not_now(check, claude, host_environment)
            else:
                notice(check, claude, host_environment, expect_notice=expect_notice)
    finally:
        try:
            during = compare(before, summary(read_config()), check.own_folders)
            removed = remove_projects(check.own_folders)
            after = compare(before, summary(read_config()), check.own_folders)
            check.evidence['claudeConfig'] = dict(path=str(CLAUDE_CONFIG), entriesBefore=len(before['projects']),
                                                  ownFolders=check.own_folders, removedAtTheEnd=removed,
                                                  beforeTheCleanup=during, afterTheCleanup=after)
            # Every entry the file had is still there, and none of this
            # run's is left.
            intact = not (after['missingKeys'] or after['missingProjects'] or after['ownProjectsLeft'])
            check.evidence['claudeConfig']['intact'] = intact
            if intact:
                backup.unlink()
            else:
                check.evidence['claudeConfig']['backup'] = str(backup)
        except Exception as error:  # noqa: BLE001 - the copy stays for a person to look at
            check.evidence['claudeConfig'] = dict(failure=repr(error), backup=str(backup))
            raise
    require(check.evidence['claudeConfig']['intact'],
            f'Claude\'s config file lost entries: {check.evidence["claudeConfig"]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    parser.add_argument('--scenario', action='append', choices=SCENARIOS,
                        help='run only this scenario; repeat for more (default: all)')
    parser.add_argument('--expect-notice', choices=('yes', 'no'), default='yes',
                        help="'no' checks the notice scenario against a build from before the notice")
    parser.add_argument('--claude', help='the Claude CLI to run as the coordinator (default: `claude` on the PATH)')
    parser.add_argument('--window-frame', metavar='X,Y,WIDTH,HEIGHT',
                        help='where to put the app\'s window, to keep it clear of something else on the screen; '
                             'write a frame that starts with a minus sign as --window-frame=-100,40,980,1000')
    options = parser.parse_args()
    scenarios = options.scenario or list(SCENARIOS)
    if options.gui_session:
        arguments = [argument for name in scenarios for argument in ('--scenario', name)]
        arguments += ['--expect-notice', options.expect_notice]
        # One word each: a frame can start with a minus sign.
        for flag, value in (('--claude', options.claude), ('--window-frame', options.window_frame)):
            arguments += [f'{flag}={value}'] if value else []
        chat.run_in_gui_session(arguments, name=NAME, script=__file__)
    check = Check()
    check.claude = options.claude
    check.window_frame = options.window_frame.split(',') if options.window_frame else None
    try:
        run(check, scenarios, options.expect_notice == 'yes')
        check.evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - always keep the evidence
        check.evidence['failure'] = repr(error)
        raise
    finally:
        check.finish()
    print(f'[{NAME}] passed', flush=True)


if __name__ == '__main__':
    main()
