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
  coordinator's folder as trusted, keeps every entry it had, and has what two
  other Claude sessions wrote while the app started; after the app is killed
  and relaunched, the coordinator is restored and nothing is asked;
- not-now: Not Now starts nothing; a relaunch does not ask again; Open
  Coordinator in the command palette and in the Agent menu each open it, and
  Restart Coordinator is offered only while it is open;
- notice: with a folder that Claude does not trust, the chat says that the
  agent may wait in the terminal and offers Show Terminal; after the answer in
  the terminal, the waiting message is typed and answered. The app cannot tell
  this profile's config file, so it writes no trust for it.

'--expect-notice no' checks the notice scenario against a build from before
the notice: the message waits and the chat says nothing about the terminal.

The check adds entries to ~/.claude.json only for its own temporary folders
and removes them at the end, under Claude Code's own lock. A copy of the file
from before the run stays beside it until the run ends; only key names,
counts and checksums go into the evidence.

Evidence goes to remote-coordinator-first-run-check.json, the app logs,
Claude's transcripts and, when the build can capture its window, PNG frames
under remote-coordinator-first-run-check-frames in the artifacts directory.
"""

import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
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


def remove_projects(folders):
    """Removes this run's project entries, and leaves the rest of the file alone."""
    with claude_config_lock():
        config = read_config()
        projects = config.get('projects', {})
        removed = [folder for folder in folders if projects.pop(folder, None) is not None]
        if removed:
            temporary = CLAUDE_CONFIG.with_name(CLAUDE_CONFIG.name + '.toastty-check')
            temporary.write_text(json.dumps(config, indent=2, ensure_ascii=False))
            shutil.copymode(CLAUDE_CONFIG, temporary)
            os.replace(temporary, CLAUDE_CONFIG)
    return removed


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
        self.environment = check.environment(name, self.runtime_home, self.user_home, real_home=True,
                                             TOASTTY_EVIDENCE_DIR=str(check.frames))
        self.run_cli, self.cli = check.cli_runner(self.environment)
        self.directory = self.runtime_home / 'coordinator'
        self.project = steer.claude_project_directory(self.directory)
        check.own_folders.append(str(self.directory))
        self.app_log = check.artifacts / f'{NAME}-{name}-app.log'
        self.instance = self.ui = None
        self.launch()

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

    def capture(self, step):
        self.check.frame_count += 1
        label = f'{self.check.frame_count:02d}-{self.name}-{step}'
        response = self.instance.request('automation.capture_screenshot', dict(step=label))
        self.check.evidence['captures'].append(dict(step=label, ok=response.get('ok'),
                                                    path=(response.get('result') or {}).get('path'),
                                                    error=None if response.get('ok') else response.get('error')))

    def finish(self):
        try:
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

        # Two other Claude sessions run while the app writes the trust: each
        # saves what it did under its own folder of Claude's config file.
        sides = []
        for index in (1, 2):
            folder = Path(tempfile.mkdtemp(prefix=f'side-{index}-', dir=check.root)).resolve()
            check.own_folders.append(str(folder))
            marker = f'SIDE-{index}'
            process = subprocess.Popen(
                [claude, '--setting-sources=', '--tools', 'Bash', '--strict-mcp-config', '-p',
                 f'Reply with exactly this one word and nothing else: {marker}'],
                cwd=folder, env=host_environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            sides.append(dict(folder=folder, marker=marker, process=process))

        # 2. Start Coordinator opens it, and Claude asks nothing about the folder.
        run.ui.run('click-label', START)
        wait_for('the question to go', lambda: not run.question(), timeout=30)
        opened = wait_for('the coordinator', lambda: (s := run.status())['exists'] and s, timeout=60)
        wait_for('the chat', lambda: run.ui.exists('coordinator.chat') and run.ui.exists('coordinator.chat.composer'), timeout=60)
        wait_for('the trust for the coordinator\'s folder', lambda: trusted(run.directory), timeout=60)
        prompt = run.wait_for_first_prompt_without_trust_question()
        if run.ui.has_label('Dismiss'):
            run.ui.run('click-label', 'Dismiss', check=False)
            time.sleep(0.5)
        require(not run.ui.exists('coordinator.chat.notice'), f'The chat shows a notice: {run.ui.texts()[-400:]}')
        run.capture('started')
        step('Start opened the coordinator and Claude asked nothing about the folder', opened=opened, prompt=prompt,
             terminal=run.screen()[-500:])

        # 3. The first message is answered.
        run.ui.send('Reply with exactly this one word and nothing else: FIRST-ONE')
        run.wait_for_reply('FIRST-ONE')
        run.capture('first-message')
        step('the first message was answered', chat=run.ui.texts()[-400:])

        # 4. The other sessions kept their writes, and the trust is still there.
        for side in sides:
            output, _ = side['process'].communicate(timeout=240)
            require(side['process'].returncode == 0 and side['marker'] in output,
                    f'The session beside the app failed: {output[-400:]}')
        config = read_config()
        saved = {str(side['folder']): sorted(config.get('projects', {}).get(str(side['folder']), {})) for side in sides}
        for folder, fields in saved.items():
            require('lastSessionId' in fields or 'lastCost' in fields,
                    f'Claude\'s config file lost what the session in {folder} saved: {fields}')
        require(trusted(run.directory), 'The trust for the coordinator\'s folder is gone after the other sessions saved')
        step('two other Claude sessions kept what they saved', saved=saved)

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
        run.wait_for_first_prompt_without_trust_question()
        run.capture('opened-from-menu')
        step('Open Coordinator in the Agent menu opened it', opened=from_menu)

        # 5. Restart Coordinator in the Agent menu.
        run.ui.run('menu', 'Agent', 'Restart Coordinator')
        restarted = wait_for('a new agent session',
                             lambda: (s := run.status()).get('sessionID') not in (None, from_menu.get('sessionID')) and s,
                             timeout=120)
        run.wait_for_first_prompt_without_trust_question()
        step('Restart Coordinator in the Agent menu started a new session', restarted=restarted)


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
            step('the message waited and the chat said nothing about the terminal', waiting=waiting,
                 chat=run.ui.texts()[-500:], terminal=run.screen()[-500:])
            return

        require(waiting.get('hold') == 'agentStarting', f'The message does not wait for the agent\'s start: {waiting}')
        require('waits for the agent to start' in run.ui.texts(), f'The chat does not say what the message waits for: {run.ui.texts()[-400:]}')
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
        # The terminal has the keyboard; a real Return takes the first
        # choice, "Yes, I trust this folder".
        run.instance.request('app_control.run_action', dict(id='workspace.focus-panel', args=dict(panelID=run.status()['panelID'])))
        time.sleep(0.5)
        run.ui.run('activate')
        run.ui.run('key', 'return')
        wait_for('Claude to go on', lambda: TRUST_QUESTION not in run.screen(), timeout=60)
        run.ui.run('click', 'coordinator.panel.mode-toggle')
        wait_for('the chat again', lambda: run.ui.exists('coordinator.chat'), timeout=30)
        run.wait_for_reply('NOTICE-ONE')
        wait_for('the queue to empty', lambda: run.status()['queuedCount'] == 0, timeout=60)
        wait_for('the notice to go', lambda: not run.ui.exists('coordinator.chat.notice'), timeout=60)
        run.capture('answered')
        step('after the answer in the terminal the message was typed and answered', chat=run.ui.texts()[-400:])


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


def run(check, scenarios, expect_notice):
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
    check.evidence.update(cliVersion=version, scenarios=list(scenarios), expectNotice=expect_notice)

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
    options = parser.parse_args()
    scenarios = options.scenario or list(SCENARIOS)
    if options.gui_session:
        arguments = [argument for name in scenarios for argument in ('--scenario', name)]
        chat.run_in_gui_session([*arguments, '--expect-notice', options.expect_notice], name=NAME, script=__file__)
    check = Check()
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
