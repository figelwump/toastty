#!/usr/bin/env python3
"""Use one release candidate as an updating user does, with the real Claude CLI.

`scripts/release/candidate-check.py` runs this script on the validation Mac
after its own clean first launch. It is not a check to run alone before a
release: the receipt comes from `scripts/release/verify-candidate.sh`.

The app under test is the candidate from the release DMG
(`TOASTTY_APP_BUNDLE`). `--previous` is the app of the last published
version. Each stage has its own throwaway runtime home and user home. The
installed production app is not touched. The run uses subscription usage of
the Claude account of the Mac that runs it, and needs its screen unlocked.

The stages, in the order they run:

- `update`: the previous version saves a layout with two workspaces, and
  nobody answers its question about the coordinator. The candidate replaces
  the app at the same path. Its What's New sheet shows over the restored
  layout, Start Coordinator opens the coordinator, and the first message
  gets its answer.
- `sessions`: the previous version saves a coordinator's conversation and
  two tasks' agents, and quits from its menu. The candidate replaces the
  app. Each new shell takes three seconds to its first prompt, as a user's
  shell with a long startup file does. The candidate asks nothing, the
  coordinator answers in the conversation from before the update, and each
  task's agent starts once, with its saved conversation.
- `restart`: in the same app, the coordinator's agent ends and a message
  from the chat waits. Restart Coordinator in the chat's notice starts a
  new agent, and that agent gets the message once.
- `compact`: Claude Code's real "We recommend compacting earlier" offer, as
  `scripts/automation/remote-coordinator-compact-offer-check.py` runs it:
  Show Terminal, arrow keys, the wheel, Escape, and the waiting message.

The coordinator is the real, authenticated Claude CLI. A task's agent is a
script that reports its start as Claude Code's hooks do and records each
start: the check counts the starts, so a launch command typed twice or cut
short shows.

A stage that fails does not stop the stages that do not depend on it, so one
run shows every fault. Evidence goes to candidate-use-check.json, the app
logs, Claude's transcripts and PNG frames in the artifacts directory.
"""

import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
# Beside this script on the validation Mac, beside its folder in the repository.
AUTOMATION = next(path for path in (HERE / 'automation', HERE.parent / 'automation') if path.is_dir())
NAME = 'candidate-use-check'
STAGES = ('update', 'sessions', 'restart', 'compact')
SECOND_WORKSPACE = 'Second project'
SLOW_SHELL_SECONDS = 3
# One-word answers: a small model keeps the stages short and cheap.
COORDINATOR_MODEL = 'claude-sonnet-5-5'


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, AUTOMATION / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


compact = load('coordinator_compact_offer_check', 'remote-coordinator-compact-offer-check.py')
skill = load('coordinator_skill_check', 'remote-coordinator-skill-check.py')
first = compact.first
chat = first.chat
require, wait_for = first.require, first.wait_for

# The `claude` profile: real Claude Code in the coordinator's folder, the
# recording agent in a task's folder.
DISPATCHER = r'''#!/bin/sh
case "$1" in
  --version|plugin|mcp|config) exec "__CLAUDE__" "$@" ;;
esac
if [ "$(pwd -P)" = "__COORDINATOR__" ]; then
  exec "__CLAUDE__" --setting-sources= --tools Bash --strict-mcp-config "$@"
fi
exec "__PYTHON__" "__BIN__/fake-agent.py" "$@"
'''


def one_word(marker):
    return f'Reply with exactly this one word and nothing else: {marker}'


class Check(first.Check):
    def __init__(self, work_root, candidate):
        super().__init__()
        self.prefix = NAME
        # The caller removes this folder and ends what still runs from it.
        shutil.rmtree(self.root, ignore_errors=True)
        self.root = work_root
        self.candidate = candidate
        self.evidence.update(root=str(work_root), stages={name: 'not run' for name in STAGES}, failures={})

    def environment(self, *arguments, **extra):
        # A signed build outside automation mode starts its updater. This
        # keeps the updater off, and lets Quit end the app without a question.
        return super().environment(*arguments, TOASTTY_SKIP_QUIT_CONFIRMATION='1', **extra)

    def use(self, bundle):
        """The app that the next launch starts, and whose CLI the check calls."""
        self.binary, self.cli = bundle / 'Contents/MacOS/Toastty', bundle / 'Contents/Helpers/toastty'
        require(self.binary.is_file() and self.cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    @contextlib.contextmanager
    def stage(self, name):
        self.evidence['stages'][name] = 'fail'
        self.step(f'stage {name} starts')
        started = time.time()
        try:
            yield
        except Exception as error:
            self.evidence['failures'][name] = repr(error)
            raise
        self.evidence['stages'][name] = 'pass'
        self.step(f'stage {name} passed', seconds=round(time.time() - started))


class State(first.Run):
    """One user's saved state. The previous version writes it, and the
    candidate takes it over at the same path, as an update does."""

    def __init__(self, check, name, claude):
        super().__init__(check, name, claude)
        home = self.runtime_home.parent
        self.bin, zdotdir, self.app = home / 'bin', home / 'zdotdir', home / 'Applications/Toastty.app'
        self.bin.mkdir()
        zdotdir.mkdir()
        (self.bin / 'fake-agent.py').write_text(skill.FAKE_AGENT.replace('__PYTHON__', sys.executable))
        dispatcher = self.bin / 'claude'
        dispatcher.write_text(DISPATCHER.replace('__CLAUDE__', claude).replace('__PYTHON__', sys.executable)
                              .replace('__COORDINATOR__', str(self.directory)).replace('__BIN__', str(self.bin)))
        dispatcher.chmod(0o755)
        (self.user_home / '.toastty/agents.toml').write_text(
            f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(dispatcher)])}\n')
        (self.user_home / '.toastty/tasks.toml').write_text(f'[defaults]\nagent = "claude"\n\n[coordinator]\nagent = "claude"\nmodel = "{COORDINATOR_MODEL}"\n')
        # The app's shells read these files only. While the file `slow-shell`
        # exists, a new shell waits that many seconds before its first prompt.
        self.slow_shell = self.bin / 'slow-shell'
        for file in ('.zshenv', '.zprofile'):
            (zdotdir / file).write_text('')
        flag = shlex.quote(str(self.slow_shell))
        (zdotdir / '.zshrc').write_text(f'[ -f {flag} ] && sleep "$(cat {flag})"\n')
        self.environment['ZDOTDIR'] = str(zdotdir)
        self.tasks_project = home / 'project'
        self.tasks_project.mkdir()
        for arguments in (('init', '-q', '-b', 'main'), ('commit', '-q', '--allow-empty', '-m', 'base')):
            subprocess.run(['git', '-C', str(self.tasks_project), '-c', 'user.name=Candidate Check',
                            '-c', 'user.email=candidate-check@example.invalid', *arguments], check=True)

    def install(self, bundle):
        """Puts `bundle` where this user's Toastty is."""
        shutil.rmtree(self.app, ignore_errors=True)
        self.app.parent.mkdir(exist_ok=True)
        subprocess.run(['/usr/bin/ditto', str(bundle), str(self.app)], check=True, timeout=180)
        self.check.use(self.app)

    def quit(self):
        """Quits the app from its menu, as a person or an update does."""
        process = self.instance.process
        self.ui.run('menu', 'Toastty', 'Quit Toastty')
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            raise AssertionError('The app did not quit from its menu') from None
        self.instance.log.close()
        self.instance = None

    def layout(self):
        path = self.runtime_home / 'workspace-layout-profiles.json'
        return path.read_text() if path.is_file() else ''

    def workspaces(self):
        return self.instance.query('workspace.list')['workspaces']

    def agent_starts(self):
        """Each start of a task's agent, oldest first."""
        log = self.bin / 'agent/events.jsonl'
        events = [json.loads(line) for line in log.read_text().splitlines()] if log.is_file() else []
        return [event for event in events if event['event'] == 'started']

    def conversations(self):
        """The coordinator's Claude conversations, oldest first."""
        return [path.stem for path in sorted(self.project.glob('*.jsonl'), key=lambda item: item.stat().st_mtime)]

    def deliveries(self, marker):
        """How many times Claude got a message with `marker`: as a prompt, or
        steered into a running turn, which Claude Code records as a
        `queued_command` attachment."""
        count = 0
        for path in self.project.glob('*.jsonl'):
            for line in path.read_text().splitlines():
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                attachment = record.get('attachment') or {}
                if record.get('isSidechain'):
                    continue
                if record.get('type') == 'user':
                    text = first.steer.claude_content_text((record.get('message') or {}).get('content'))
                elif record.get('type') == 'attachment' and attachment.get('type') == 'queued_command':
                    text = attachment.get('prompt')
                else:
                    continue
                count += bool(text and marker in text)
        return count


@contextlib.contextmanager
def state(check, name, claude):
    run = State(check, name, claude)
    try:
        yield run
    except Exception:
        try:
            if run.ui and run.instance:
                check.step('failure', state=name, status=run.status(), terminal=run.screen()[-2000:],
                           chat=run.ui.texts()[-600:])
                run.capture('failure')
        except Exception:  # noqa: BLE001 - the first error matters
            pass
        raise
    finally:
        run.finish()


# MARK: - The stages


def update(check, run, previous):
    step = check.step
    # The previous version: two workspaces, and nobody answers its question.
    run.install(previous)
    run.launch()
    window = run.workspaces()[0]['windowID']
    run.cli('action', 'run', 'workspace.create', '--window', window, f'title={SECOND_WORKSPACE}')
    wait_for('the saved layout to hold the second workspace', lambda: SECOND_WORKSPACE in run.layout(), timeout=30)
    saved = [workspace['title'] for workspace in run.workspaces()]
    require(not run.status().get('exists'), f'The previous version has a coordinator: {run.status()}')
    time.sleep(3)
    run.instance.kill()
    step('the previous version saved its layout', workspaces=saved)

    # The candidate asks over the restored layout.
    run.install(check.candidate)
    run.launch()
    run.ui.run('activate')
    question = wait_for('the question over the restored layout', run.question, timeout=30)
    restored = [workspace['title'] for workspace in run.workspaces()]
    require(restored == saved, f'The candidate restored {restored}, not {saved}')
    require(not run.status()['exists'], 'A coordinator exists before the answer')
    run.capture('question-over-restored-layout')
    step('the candidate restored the layout and asked', workspaces=restored, question=question)

    # Start Coordinator, and a first answer.
    run.ui.run('click', first.START)
    wait_for('the question to go', lambda: not run.question(), timeout=30)
    wait_for('the coordinator', lambda: run.status()['exists'], timeout=60)
    wait_for('the chat', lambda: run.ui.exists('coordinator.chat') and run.ui.exists('coordinator.chat.composer'), timeout=60)
    prompt = run.wait_for_first_prompt_without_trust_question()
    if run.ui.has_label('Dismiss'):
        run.ui.run('click-label', 'Dismiss', check=False)
        time.sleep(0.5)
    run.wait_for_no_notice()
    run.ui.send(one_word('UPDATE-FIRST'))
    run.wait_for_reply('UPDATE-FIRST')
    run.capture('first-answer')
    step('Start Coordinator opened it and the first message was answered', prompt=prompt, chat=run.ui.texts()[-400:])


def sessions(check, run, previous):
    step = check.step
    # The previous version: a coordinator's conversation and two tasks' agents.
    run.asks_start_offer = False
    run.install(previous)
    run.launch()
    run.cli('coordinator', 'open')
    wait_for('the coordinator at its prompt in the previous version', run.at_prompt, timeout=180)
    run.cli('coordinator', 'send', one_word('BEFORE-UPDATE'))
    wait_for('the answer in the previous version', lambda: run.replied('BEFORE-UPDATE'), timeout=240)
    wait_for('the coordinator at its prompt again', run.at_prompt, timeout=60)
    for title in ('Fix the unread dot', 'Rename the Tasks view'):
        task = run.cli('task', 'create', title, '--root', str(run.tasks_project), '--wait', '--timeout', '120')
        require(task['setup']['state'] == 'started', f'The task did not start in the previous version: {task}')
    saved = wait_for('both tasks\' agents', lambda: len(run.agent_starts()) == 2 and run.agent_starts(), timeout=60)
    conversation = run.conversations()
    require(len(conversation) == 1, f'The coordinator has {len(conversation)} conversations before the update')
    task_conversations = sorted(start['native'] for start in saved)
    wait_for('the saved layout to name each conversation',
             lambda: all(native in run.layout() for native in (*conversation, *task_conversations)), timeout=60)
    # The coordinator's workspace is in front, as for a user who writes to it.
    run.cli('coordinator', 'open')
    time.sleep(3)
    run.quit()
    step('the previous version saved a coordinator and two task agents, and quit',
         coordinator=conversation[0], tasks=task_conversations)

    # The candidate takes the state over. Its shells start slowly.
    run.slow_shell.write_text(str(SLOW_SHELL_SECONDS))
    run.asks_start_offer = True
    run.install(check.candidate)
    run.launch()
    run.ui.run('activate')
    run.no_question_for(5)
    resumed = wait_for('the coordinator at its prompt after the update', run.at_prompt, timeout=180)
    wait_for('the conversation from before the update in the chat',
             lambda: 'BEFORE-UPDATE' in run.ui.texts(), timeout=120)
    wait_for('each task\'s agent to start again', lambda: len(run.agent_starts()) >= len(saved) + 2, timeout=120)
    # A second launch command in a terminal would start its agent once more.
    time.sleep(SLOW_SHELL_SECONDS + 5)
    again = run.agent_starts()[len(saved):]
    require(sorted((start['native'], start['resumed'], start['panel']) for start in again)
            == sorted((start['native'], True, start['panel']) for start in saved),
            f'After the update the tasks\' agents started as {again}, saved were {saved}')
    run.slow_shell.unlink()
    run.ui.send(one_word('AFTER-UPDATE'))
    run.wait_for_reply('AFTER-UPDATE')
    require(run.conversations() == conversation,
            f'The coordinator answered in {run.conversations()}, not in the saved conversation {conversation}')
    delivered = run.deliveries('AFTER-UPDATE')
    require(delivered == 1, f'Claude got the message {delivered} times')
    run.capture('after-update')
    step('the candidate resumed the coordinator and each task agent once', coordinator=resumed, tasks=again,
         chat=run.ui.texts()[-400:])


def restart(check, run):
    step = check.step
    before = wait_for('the coordinator at its prompt', run.at_prompt, timeout=60)
    run.instance.request('app_control.run_action', dict(id='terminal.send-text', args=dict(
        panelID=before['panelID'], text='/exit', submit=True)))
    wait_for('the coordinator\'s agent to end', lambda: run.status()['agentState'] == 'notRunning', timeout=60)
    run.ui.send(one_word('AFTER-RESTART'))
    wait_for('the message to wait', lambda: run.status()['queuedCount'] == 1, timeout=20)
    wait_for('Restart Coordinator in the chat\'s notice',
             lambda: run.ui.exists('coordinator.chat.notice.restart'), timeout=30)
    notice = run.ui.texts('coordinator.chat.notice')
    run.capture('message-waits-for-the-agent')
    step('with no agent, the message waits and the chat offers Restart Coordinator', notice=notice)

    run.ui.run('click', 'coordinator.chat.notice.restart')
    after = wait_for('a new agent', lambda: (status := run.status())['agentState'] == 'running'
                     and status.get('sessionID') != before.get('sessionID') and status, timeout=120)
    run.wait_for_reply('AFTER-RESTART')
    require(run.deliveries('AFTER-RESTART') == 1, f"Claude got the waiting message {run.deliveries('AFTER-RESTART')} times")
    require(run.status()['queuedCount'] == 0, 'A message still waits')
    require(len(run.conversations()) == 2, f'Restart did not start a new conversation: {run.conversations()}')
    run.capture('after-restart')
    step('Restart Coordinator started a new agent, and it got the waiting message once',
         before=before.get('sessionID'), after=after.get('sessionID'), chat=run.ui.texts()[-400:])


def compact_offer(check, claude):
    check.use(check.candidate)
    before = compact.offer_record()
    try:
        compact.run(check, claude, 'panel', False)
    finally:
        check.step("The offer's record", **compact.restore_offer_record(before))


def run(check, previous):
    host = {key: value for key, value in os.environ.items()
            if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT')}
    host['DISABLE_AUTOUPDATER'] = '1'
    claude = shutil.which('claude') or str(Path.home() / '.local/bin/claude')
    require(Path(claude).is_file(), 'Claude CLI is not installed; install and authenticate it on the validation Mac')
    auth = subprocess.run([claude, '--safe-mode', '--setting-sources', '', 'auth', 'status', '--json'],
                          capture_output=True, text=True, timeout=30, env=host)
    require(auth.returncode == 0 and json.loads(auth.stdout).get('loggedIn'),
            'Claude CLI needs an interactive login on the validation Mac')
    check.evidence.update(cliVersion=subprocess.check_output([claude, '--version'], text=True, timeout=30, env=host).strip(),
                          candidate=str(check.candidate), previous=str(previous))

    def group(names, body):
        """Runs stages that share one saved state. A failure stops the group only."""
        try:
            body()
        except Exception as error:  # noqa: BLE001 - the other groups still run
            print(f'[{NAME}] {"/".join(names)} failed: {error!r}', flush=True)

    def update_group():
        with state(check, 'update', claude) as current, check.stage('update'):
            update(check, current, previous)

    def sessions_group():
        with state(check, 'sessions', claude) as current:
            with check.stage('sessions'):
                sessions(check, current, previous)
            with check.stage('restart'):
                restart(check, current)

    def compact_group():
        with check.stage('compact'):
            compact_offer(check, claude)

    try:
        group(('update',), update_group)
        group(('sessions', 'restart'), sessions_group)
        group(('compact',), compact_group)
    finally:
        # The trust that Toastty wrote for each coordinator's folder, and
        # what a session writes once more as it exits.
        check.evidence['claudeProjectsRemoved'] = first.remove_projects(check.own_folders)
        for folder in check.own_folders:
            shutil.rmtree(first.steer.claude_project_directory(folder), ignore_errors=True)
    failed = {name: result for name, result in check.evidence['stages'].items() if result != 'pass'}
    require(not failed, f'Stages did not pass: {failed} {check.evidence["failures"]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--previous', required=True, help='the app bundle of the last published version')
    parser.add_argument('--work-root', required=True,
                        help='an empty folder with a short path for the stages\' homes and sockets')
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    if options.gui_session:
        chat.run_in_gui_session(['--previous', options.previous, '--work-root', options.work_root], name=NAME, script=__file__)
    check = Check(Path(options.work_root).resolve(), Path(os.environ['TOASTTY_APP_BUNDLE']).resolve())
    try:
        run(check, Path(options.previous).resolve())
        check.evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - always keep the evidence
        check.evidence['failure'] = repr(error)
        raise
    finally:
        # The caller removes the work root after it has ended every process.
        (check.artifacts / f'{NAME}.json').write_text(json.dumps(check.evidence, indent=2, default=str))
    print(f'[{NAME}] passed', flush=True)


if __name__ == '__main__':
    main()
