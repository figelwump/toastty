#!/usr/bin/env python3
"""Failures that Toastty finds at launch, as a new user meets them, through the real UI.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-launch-failure-check.py --gui-session'.
It needs the remote Mac's screen unlocked. No agent takes a turn, so the run
uses no subscription usage.

Each scenario starts its own instances of the wrapper's build, with a
throwaway runtime home and user home, and does not touch the installed
production app or the host's Claude or Codex settings. Every action a person
makes goes through the real UI, as in remote-coordinator-first-run-check.py.

- no-claude: a Mac with Codex but no `claude` on the PATH, as a user who has
  only Codex. The first launch asks whether to start the coordinator; Start
  shows an alert that names `claude` and `[coordinator] agent` and offers
  Start with Codex; Cancel leaves no Coordinator workspace and no folder, and
  the question does not come back in that launch; the next launch asks again;
  Start with Codex then starts the coordinator with Codex.
- bad-shortcut: tasks.toml sets a quick entry shortcut that is not valid.
  The first window shows the message as a sheet, and once it is closed, the
  question whether to start the coordinator still comes. (Another app that
  holds the shortcut does not make Toastty's registration fail: Carbon
  refuses a hot key only when both apps ask for it exclusively.)

Evidence goes to remote-launch-failure-check.json and the app logs in the
artifacts directory. Under '--gui-session' the check also keeps still
pictures of the window, the alert and the sheet, under
remote-launch-failure-check-frames.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

HERE = Path(__file__).parent
NAME = 'remote-launch-failure-check'
SCENARIOS = ('no-claude', 'bad-shortcut')


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


chat = load('coordinator_chat_check', 'remote-coordinator-chat-check.py')
coordinator_check = chat.coordinator_check
require, wait_for = chat.require, chat.wait_for

QUESTION = 'Start the coordinator?'
START = 'Start Coordinator'
AGENT_ALERT = 'coordinator.agent-not-installed'
# Homebrew's folder holds `codex` and the `node` it runs on; `claude` is in
# the host user's ~/.local/bin, which this PATH and the throwaway home leave
# out. The app's login-shell probe adds only /etc/paths and /etc/paths.d.
PATH_WITHOUT_CLAUDE = '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'
# Not a key that the shortcut parser knows.
BAD_SHORTCUT = 'opt+shift+banana'


class App:
    """One instance of the app with its own runtime home and user home."""

    def __init__(self, check, name, tasks_toml, path=None, asks_start_offer=True):
        self.check, self.name, self.asks_start_offer = check, name, asks_start_offer
        self.runtime_home, self.user_home = check.root / name / 'runtime-home', check.root / name / 'user-home'
        for directory in (self.runtime_home, self.user_home / '.toastty'):
            directory.mkdir(parents=True)
        (self.user_home / '.toastty/tasks.toml').write_text(tasks_toml)
        # No agents.toml: the built-in claude and codex profiles, as on a new Mac.
        self.environment = check.environment(name, self.runtime_home, self.user_home,
                                             CODEX_HOME=str(self.user_home / '.codex'))
        if path:
            self.environment['PATH'] = path
        self.run_cli, self.cli = check.cli_runner(self.environment)
        self.directory = self.runtime_home / 'coordinator'
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
            self.ui.run('window-set-frame', *self.check.window_frame)

    def relaunch(self):
        # Saved settings and the layout are written a moment after a change.
        time.sleep(3)
        self.instance.kill()
        self.launch()

    def status(self):
        return self.cli('coordinator', 'status')

    def profile(self, profile_id):
        return self.cli('query', 'run', 'agent.profile.state', f'profileID={profile_id}')

    def sheet(self):
        code, output = self.ui.run('sheet-texts', check=False)
        return output if code == 0 else ''

    def question(self):
        text = self.sheet()
        return text if QUESTION in text else ''

    def agent_alert(self):
        return self.ui.texts(AGENT_ALERT)

    def no_question_for(self, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.ui.run('activate')
            require(not self.question(), f'The question showed: {self.question()}')
            time.sleep(1)

    def log_contains(self, text):
        log = self.runtime_home / 'logs/toastty.log'
        return log.is_file() and text in log.read_text(errors='replace')

    def rect(self, command, *arguments):
        code, output = self.ui.run(command, *arguments, check=False)
        if code != 0 or len(output.split()) != 4:
            return None
        x, y, width, height = map(int, output.split())
        left, top = max(x, 0), max(y, 0)
        return f'{left},{top},{x + width - left},{y + height - top}'

    def capture(self, step, element=None):
        """A still picture of the window, or of the element with that
        accessibility identifier. Never a recording: one from Terminal makes
        macOS show a consent prompt that stays until a person answers it."""
        self.check.frame_count += 1
        label = f'{self.check.frame_count:02d}-{self.name}-{step}'
        path = self.check.frames / f'{label}.png'
        rect = self.rect('frame', element) if element else self.rect('window-frame')
        done = subprocess.run(['screencapture', '-x', *(['-R', rect] if rect else []), str(path)],
                              capture_output=True, text=True, timeout=30)
        self.check.evidence['captures'].append(dict(step=label, rect=rect, path=str(path),
                                                    ok=done.returncode == 0 and path.is_file()))

    def finish(self):
        try:
            if self.instance:
                self.instance.kill()
        except Exception:  # noqa: BLE001 - the evidence matters more
            pass
        self.check.copy_instance_log(self.runtime_home, self.name)


def no_claude(check):
    step = check.step
    app = App(check, 'no-claude', '[quick_entry]\nshortcut = "none"\n', path=PATH_WITHOUT_CLAUDE)
    try:
        app.launch()
        claude, codex = app.profile('claude'), app.profile('codex')
        require(claude.get('executablePath') is None and claude.get('failure') == 'command_not_found',
                f'claude is installed for this app: {claude}')
        require(codex.get('executablePath'), f'codex is not installed for this app: {codex}')
        step('only Codex is installed for this app', claude=claude, codex=codex)

        # 1. The first launch asks, and Start shows the alert.
        app.ui.run('activate')
        wait_for('the question at the first launch', app.question, timeout=30)
        app.capture('question')
        app.ui.run('click-label', START)
        alert = wait_for('the alert', app.agent_alert, timeout=30)
        for text in ('Unable to Start the Coordinator',
                     "The coordinator's agent claude is not installed: Toastty did not find the claude command.",
                     'set agent under [coordinator] in ~/.toastty/tasks.toml', 'such as codex',
                     'a later start tries claude again', 'Start with Codex', 'Cancel'):
            require(text in alert, f'The alert does not say "{text}": {alert}')
        app.capture('alert', element=AGENT_ALERT)
        app.capture('alert-over-window')
        status = app.status()
        require(not status['exists'] and not app.directory.exists(), f'The start made a coordinator: {status}')
        step('Start showed the alert, and nothing was made', alert=alert)

        # 2. Cancel: nothing is left, and the question waits for the next launch.
        app.ui.run('key', 'escape')
        wait_for('the alert to go', lambda: not app.agent_alert(), timeout=30)
        time.sleep(2)
        status = app.status()
        require(not status['exists'] and not app.directory.exists(), f'Cancel left a coordinator: {status}')
        app.no_question_for(6)
        app.capture('after-cancel')
        step('Cancel left no Coordinator workspace or folder, and the question did not come back', status=status)

        # 3. The next launch asks again.
        app.relaunch()
        app.ui.run('activate')
        question = wait_for('the question at the next launch', app.question, timeout=30)
        app.capture('question-again')
        step('the next launch asked again', question=question)

        # 4. Start with Codex starts the coordinator with Codex.
        app.ui.run('click-label', START)
        wait_for('the alert', app.agent_alert, timeout=30)
        app.ui.run('click-label', 'Start with Codex')
        opened = wait_for('the coordinator with Codex',
                          lambda: (s := app.status())['exists'] and s.get('agent') == 'codex' and s, timeout=90)
        wait_for('the coordinator\'s chat', lambda: app.ui.exists('coordinator.chat'), timeout=60)
        time.sleep(2)
        app.capture('started-with-codex')
        step('Start with Codex started the coordinator with Codex', status=opened)
    finally:
        app.finish()


def bad_shortcut(check):
    step = check.step
    app = App(check, 'bad-shortcut', f'[quick_entry]\nshortcut = "{BAD_SHORTCUT}"\n')
    try:
        app.launch()
        app.ui.run('activate')
        sheet = wait_for('the message at launch', lambda: (t := app.sheet()) and 'banana' in t and t, timeout=30)
        for text in ('Configuration Warnings', 'line 2: [quick_entry] the shortcut "opt+shift+banana"',
                     'unknown key "banana"', 'The quick entry shortcut is ⌥⇧T until the file is fixed.'):
            require(text in sheet, f'The message does not say "{text}": {sheet}')
        require(QUESTION not in sheet, 'The question showed in place of the message')
        app.capture('launch-message')
        step('the first window showed the message', sheet=sheet)

        app.ui.run('key', 'return')
        wait_for('the message to go', lambda: 'banana' not in app.sheet(), timeout=30)
        # The question comes when the window has the keyboard again.
        question = wait_for('the question after the message', lambda: app.ui.run('activate') and app.question(),
                            timeout=30)
        app.capture('question-after-message')
        step('the question whether to start the coordinator came after the message', question=question)
    finally:
        app.finish()


class Check(coordinator_check.Check):
    def __init__(self):
        super().__init__('none')
        self.prefix = NAME
        self.frame_count = 0
        self.frames = self.artifacts / f'{NAME}-frames'
        shutil.rmtree(self.frames, ignore_errors=True)
        self.frames.mkdir(parents=True)
        self.window_frame = None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where still pictures show windows')
    parser.add_argument('--scenario', action='append', choices=SCENARIOS,
                        help='run only this scenario; repeat for more (default: all)')
    parser.add_argument('--window-frame', metavar='X,Y,WIDTH,HEIGHT',
                        help='where to put the app\'s window; write a frame that starts with a minus sign '
                             'as --window-frame=-100,40,980,1000')
    options = parser.parse_args()
    scenarios = options.scenario or list(SCENARIOS)
    if options.gui_session:
        arguments = [argument for name in scenarios for argument in ('--scenario', name)]
        arguments += [f'--window-frame={options.window_frame}'] if options.window_frame else []
        chat.run_in_gui_session(arguments, name=NAME, script=__file__)
    check = Check()
    check.window_frame = options.window_frame.split(',') if options.window_frame else None
    check.evidence['scenarios'] = scenarios
    try:
        for name in scenarios:
            no_claude(check) if name == 'no-claude' else bad_shortcut(check)
        check.evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - always keep the evidence
        check.evidence['failure'] = repr(error)
        raise
    finally:
        check.finish()
    print(f'[{NAME}] passed', flush=True)


if __name__ == '__main__':
    main()
