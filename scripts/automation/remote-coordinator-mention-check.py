#!/usr/bin/env python3
"""Mention a task in the coordinator's chat, through the real UI, with the
real Claude CLI as the coordinator.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-mention-check.py --gui-session'.
The run uses subscription usage. It needs the remote Mac's screen unlocked.

The check starts its own instance of the wrapper's build, with a throwaway
runtime home and user home, as remote-coordinator-chat-check.py does, and
makes two real tasks. Every action goes through the real UI: clicks and keys
from `ax-drive.swift`.

The check proves from Claude's transcript and the chat's own text that:
- `@` in the composer opens the list of tasks, and a search narrows it;
- Return puts the task in as a chip and does not send;
- the sent message holds the task's link, `[title](toastty://task/<id>)`,
  and Claude reads the task's ID from it;
- the chat shows the user's message with the task as a chip, not the link;
- + > Mention a Task... opens the list, Tab puts a task in, Command-Z takes
  it out again with the search back, and Escape closes the list.

Evidence goes to remote-coordinator-mention-check.json, the app log and
Claude's transcripts in the artifacts directory. A build that lets
`automation.capture_screenshot` write to TOASTTY_EVIDENCE_DIR outside
automation mode also leaves frames in remote-coordinator-mention-check-frames;
other builds record that a capture failed, and the check goes on.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

HERE = Path(__file__).parent
NAME = 'remote-coordinator-mention-check'
LIST = 'coordinator.chat.mention'
COMPOSER = 'coordinator.chat.composer'


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


attachments_check = load('attachments_check', 'remote-coordinator-attachments-check.py')
chat_check = attachments_check.chat_check
coordinator_check = chat_check.coordinator_check
steer = chat_check.steer
require, wait_for = coordinator_check.require, coordinator_check.wait_for


def other_runs(own_pids=()):
    """The other checks and the other runs' Toastty instances on this Mac.
    This check's own processes, the wrapper's and the GUI session's, name
    this script."""
    listing = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True, check=True).stdout
    own_bundle = os.environ.get('TOASTTY_APP_BUNDLE', '')
    found = []
    for line in listing.splitlines():
        pid, _, command = line.strip().partition(' ')
        if not pid.isdigit() or int(pid) in own_pids or NAME in command or (own_bundle and own_bundle in command):
            continue
        other_check = re.search(r'remote-[a-z0-9-]+-check\.py', command)
        other_app = '/toastty-remote-gui/' in command and 'Toastty.app/Contents/MacOS/Toastty' in command
        if other_check or other_app:
            found.append(line.strip()[:200])
    return found


def require_mini_to_itself(own_pids=()):
    found = other_runs(own_pids)
    require(not found, 'Another check runs on this Mac; stopping so the two do not meet: ' + ' | '.join(found))


def plain(text):
    """AX text with a chip's no-break spaces as spaces."""
    return text.replace(' ', ' ')


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

    # The coordinator, and the two tasks' agents, only read and write text.
    argv = [claude, '--setting-sources=', '--allowedTools', 'Read', '--tools', 'Read', '--strict-mcp-config']
    runtime_home, user_home = check.home('mention', argv)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)

    frames = check.artifacts / f'{NAME}-frames'
    shutil.rmtree(frames, ignore_errors=True)
    frames.mkdir()
    environment = check.environment('mention', runtime_home, user_home, real_home=True, TOASTTY_EVIDENCE_DIR=str(frames))
    run_cli, cli = check.cli_runner(environment)
    directory = runtime_home / 'coordinator'
    directory.mkdir(parents=True)
    steer.set_directory_trust(directory, True)
    project = steer.claude_project_directory(directory)
    app_log = check.artifacts / f'{check.prefix}-app.log'
    require_mini_to_itself()
    instance = chat_check.ChatInstance(check.binary, environment, environment['TOASTTY_SOCKET_PATH'], runtime_home, app_log)
    step = check.step
    check.evidence['captures'] = []
    frame_count = 0

    def status():
        return cli('coordinator', 'status')

    def at_prompt():
        current = status()
        return current.get('agentState') == 'running' and current.get('status') in ('idle', 'ready') and current

    def transcript():
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
                    entries.append(dict(role=record['type'], text=text))
        return entries

    def user_message(fragment):
        return next((entry['text'] for entry in transcript() if entry['role'] == 'user' and fragment in entry['text']), None)

    def answer(marker):
        return next((entry['text'] for entry in transcript() if entry['role'] == 'assistant' and marker in entry['text']), None)

    def capture(name):
        """The window as the app draws it. Only an evidence build writes it."""
        nonlocal frame_count
        frame_count += 1
        label = f'{frame_count:02d}-{name}'
        try:
            response = instance.request('automation.capture_screenshot', dict(step=label))
        except Exception as error:  # noqa: BLE001 - evidence only
            response = dict(ok=False, error=repr(error))
        check.evidence['captures'].append(dict(step=label, ok=response.get('ok'),
                                               error=None if response.get('ok') else response.get('error')))

    def terminal_text():
        try:
            panel = status().get('panelID')
            response = instance.request('app_control.run_query', dict(id='terminal.visible-text', args=dict(panelID=panel)))
            return ((response.get('result') or {}).get('text') or '')[-1500:]
        except Exception as error:  # noqa: BLE001 - evidence only
            return f'(could not read the terminal: {error!r})'

    def list_text():
        return plain(ui.texts(LIST)) if ui.exists(LIST) else ''

    def composer_text():
        return plain(ui.texts(COMPOSER))

    def type_in_composer(text):
        ui.run('type', text)
        time.sleep(0.4)

    try:
        workspaces = instance.wait_until_ready()
        project_id = workspaces[0]['workspaceID']
        wait_for('instance.json', lambda: (runtime_home / 'instance.json').is_file())
        pid = json.loads((runtime_home / 'instance.json').read_text())['pid']
        ui = chat_check.UI(check.artifacts, pid)
        _, trust = ui.run('status')
        require('trusted=true' in trust and 'locked=false' in trust,
                f'The UI driver cannot act: {trust}. Unlock the screen, or run with --gui-session over SSH')

        # Two real tasks to mention.
        tasks = {}
        for title in ('Restore split ratios', 'Fix the unread dot'):
            created = cli('task', 'create', title, '--workspace', project_id, '--wait', '--timeout', '120')
            require(created['setup']['state'] == 'started', f'The task did not start: {created}')
            tasks[title] = created['taskID']
        split_id, dot_id = tasks['Restore split ratios'], tasks['Fix the unread dot']
        step('two tasks exist', tasks=tasks)

        # Sized before the coordinator starts: a resize while Claude Code
        # runs has ended Toastty's session for it.
        ui.run('window-set-frame', '240', '60', '1000', '760', check=False)
        opened = cli('coordinator', 'open')
        require(opened['startedAgent'] and opened['agentState'] == 'running', f'Open did not start Claude: {opened}')
        ui.run('activate')
        wait_for('the chat', lambda: ui.exists('coordinator.chat') and ui.exists(COMPOSER))
        wait_for('Claude at its first prompt', at_prompt, timeout=180)
        time.sleep(15)
        require(at_prompt(), f'The coordinator\'s agent did not stay at its prompt: {status()} {terminal_text()!r}')
        if ui.has_label('Dismiss'):
            ui.run('click-label', 'Dismiss', check=False)
            time.sleep(0.5)
        capture('chat-open')
        step('the chat is open with Claude at its prompt', version=version)

        # 1. @ opens the list; a search narrows it; Return puts the task in.
        require_mini_to_itself({pid})
        ui.run('focus', COMPOSER)
        time.sleep(0.3)
        type_in_composer('Which task is @')
        wait_for('the list of tasks', lambda: 'Restore split ratios' in list_text() and 'Fix the unread dot' in list_text(),
                 timeout=15)
        capture('at-sign-opens-the-list')
        all_listed = list_text()
        type_in_composer('split')
        wait_for('the search to narrow the list',
                 lambda: 'Restore split ratios' in list_text() and 'Fix the unread dot' not in list_text(), timeout=10)
        capture('search-narrows-the-list')
        ui.run('key', 'return')
        wait_for('the list to close', lambda: not ui.exists(LIST), timeout=10)
        field = composer_text()
        require('@split' not in field and 'Which task is' in field, f'The field does not show the chip: {field!r}')
        require(user_message('Which task is') is None, 'Return sent the message instead of choosing the task')
        capture('chip-in-the-field')
        step('@ opened the list, the search narrowed it, and Return put the task in without sending',
             listed=all_listed, field=field)

        # 2. Send: the message holds the link, and Claude reads the ID.
        type_in_composer('? Reply with MENTION-OK, a space, and the task ID from the link in my message, '
                         'and nothing else.')
        ui.run('key', 'return')
        wait_for('Claude to answer', lambda: answer('MENTION-OK'), timeout=240)
        sent = user_message('MENTION-OK')
        link = f'[Restore split ratios](toastty://task/{split_id})'
        require(sent is not None and link in sent, f'The message does not hold the task\'s link: {sent!r}')
        reply = answer('MENTION-OK')
        require(split_id.lower() in reply.lower(), f'Claude did not read the task ID from the link: {reply!r}')
        wait_for('the chat to show the answer', lambda: 'MENTION-OK' in ui.texts(), timeout=60)
        texts = plain(ui.texts())
        # The chip's text is its dot and the task's title.
        require(re.search(r'Which task is\s+●?\s*Restore split ratios', texts),
                f'The chat does not show the task in the message: {texts[-800:]}')
        require('](toastty://task/' not in texts, f'The chat shows a task link as text: {texts[-800:]}')
        wait_for('the prompt to open again', at_prompt, timeout=120)
        capture('sent-message-shows-a-chip')
        step('the message held the task\'s link, Claude read its ID, and the chat shows a chip',
             message=sent, answer=reply)

        # 3. + > Mention a Task..., Tab, Command-Z, Escape.
        require_mini_to_itself({pid})
        ui.run('focus', COMPOSER)
        type_in_composer('Also')
        ui.run('click', 'coordinator.chat.attach')
        time.sleep(0.6)
        x, y, width, height = (int(value) for value in ui.run('label-frame', 'Mention a Task')[1].split())
        ui.run('click-at', str(x + width // 2), str(y + height // 2))
        wait_for('the list from the menu', lambda: 'Fix the unread dot' in list_text(), timeout=10)
        field = composer_text()
        require(field.endswith('Also @'), f'Mention a Task did not type " @": {field!r}')
        capture('plus-menu-opens-the-list')
        type_in_composer('unread')
        wait_for('the search', lambda: 'Fix the unread dot' in list_text() and 'Restore split' not in list_text(),
                 timeout=10)
        ui.run('key', 'tab')
        wait_for('Tab to put the task in', lambda: not ui.exists(LIST) and '@unread' not in composer_text(), timeout=10)
        capture('tab-put-the-task-in')
        ui.run('key', 'cmd-z')
        wait_for('Undo to bring the search back', lambda: composer_text().endswith('Also @unread'), timeout=10)
        wait_for('the list again', lambda: ui.exists(LIST), timeout=10)
        ui.run('key', 'escape')
        wait_for('Escape to close the list', lambda: not ui.exists(LIST), timeout=10)
        require(composer_text().endswith('Also @unread'), f'Escape changed the text: {composer_text()!r}')
        capture('undo-and-escape')
        ui.run('key', 'cmd-a')
        ui.run('key', 'delete')
        wait_for('an empty field', lambda: composer_text().strip() == '', timeout=10)
        require(user_message('Also') is None, 'A key in this step sent the message')
        step('+ > Mention a Task opened the list, Tab put the task in, Undo took it out, and Escape closed the list',
             dot=dot_id)
    except Exception:
        try:
            check.evidence['statusAtFailure'] = status()
            check.evidence['terminalAtFailure'] = terminal_text()
            capture('failure')
        except Exception:  # noqa: BLE001 - the first error matters
            pass
        raise
    finally:
        try:
            instance.kill()
        except Exception:  # noqa: BLE001 - the evidence below matters more
            pass
        check.copy_instance_log(runtime_home, 'mention')
        steer.set_directory_trust(directory, False)
        if project.is_dir():
            saved = check.artifacts / f'{check.prefix}-transcripts'
            saved.mkdir(exist_ok=True)
            for path in project.glob('*.jsonl'):
                shutil.copyfile(path, saved / path.name)
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
        chat_check.run_in_gui_session([], name=NAME, script=__file__)
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
