#!/usr/bin/env python3
"""Steer the coordinator's running turn from its chat, through the real UI,
with the real Claude CLI.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-steer-check.py --gui-session'.
The run uses subscription usage and takes about 15 minutes. It needs the
remote Mac's screen unlocked.

The check starts its own instance of the wrapper's build, with a throwaway
runtime home and user home, as remote-coordinator-chat-check.py does. It
does not touch the installed production app. The coordinator is the real,
authenticated Claude CLI in a folder of this run, and it may run the run's
own wait script and nothing else. The instance's quick entry shortcut is
Control+Option+Shift+T, so it does not compete with the wrapper's own app.

Every action a person makes goes through the real UI: the chat's composer,
its rows and its chip through Accessibility and key events
(`ax-drive.swift`, `quick-entry-ui-driver.swift`), and the quick entry
panel through its global shortcut while Finder is in front. Under
'--gui-session' the check itself runs in Terminal in the GUI session, where
the Claude login is readable, and the process that started it over SSH
makes the clicks and keys.

The check proves from Claude's transcript, the chat's own text, the saved
queue and the CLI that:
- at an open prompt the chat offers no Steer or Queue choice, and Return
  sends as before;
- while a turn runs the chip says Steer, and Return types the message into
  that turn: Claude takes it as a queued command while its command runs and
  answers it in the same turn, and nothing waits in Toastty's queue;
- Queue on the chip, and Command-Return, make a message wait as Queued, and
  the chip goes back to Steer after the send;
- a quick entry message sent while the turn runs waits as Queued, and its
  row offers no Steer now; a message from `coordinator send` waits too:
  neither goes into the turn;
- Steer now on a waiting message types it into the running turn and takes
  it out of the saved queue, and Claude answers it in that turn;
- after the turn, each waiting message gets its own turn, in order.

Evidence goes to remote-coordinator-steer-check.json, the app log, Claude's
transcripts and still frames of the window under
remote-coordinator-steer-check-frames in the artifacts directory.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
NAME = 'remote-coordinator-steer-check'


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


chat = load('chat_check', 'remote-coordinator-chat-check.py')
quick = load('quick_entry_check', 'remote-coordinator-quick-entry-check.py')
coordinator_check, steer = chat.coordinator_check, chat.steer
require, wait_for = chat.require, chat.wait_for

COMPOSER = 'coordinator.chat.composer'
CHIP = 'coordinator.chat.delivery'
STEER_ROW = 'toastty-mobile-queued-steer-'
# A message that asks for nothing but a word. The quick entry and the
# `coordinator send` messages say so outright, because the coordinator's
# instructions treat such messages as requests for work.
QUIET = 'This is a check of the chat. Create no task and run no command. '
# x, y, width, height. 980 is the window's least width.
WINDOW_FRAME = (-100, 40, 980, 1000)


def reply_line(marker):
    return f'Reply with exactly this one word and nothing else: {marker}'


class Check(coordinator_check.Check):
    def __init__(self):
        super().__init__('claude')
        self.prefix = NAME
        self.frames = self.artifacts / f'{NAME}-frames'
        shutil.rmtree(self.frames, ignore_errors=True)
        self.frames.mkdir(parents=True)
        self.frame_count = 0


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

    # Only this disposable app sees the profile. The coordinator may run the
    # run's own wait script, which holds a turn open, and nothing else.
    argv = [claude, '--setting-sources=', '--allowedTools', f'Bash({chat.HOLD_COMMAND}:*)', '--tools', 'Bash',
            '--strict-mcp-config']
    runtime_home, user_home = check.home('steer', argv)
    with open(user_home / '.toastty/tasks.toml', 'a') as config:
        config.write('\n[quick_entry]\nshortcut = "ctrl+opt+shift+t"\n')
    # The first terminal starts in the user home, which is the tasks' project.
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    environment = check.environment('steer', runtime_home, user_home, real_home=True)
    _, cli = check.cli_runner(environment)
    directory = runtime_home / 'coordinator'
    directory.mkdir(parents=True)
    hold = directory / 'hold-turn.sh'
    hold.write_text('#!/bin/sh\nsleep "$1"\necho waited "$1" seconds\n')
    hold.chmod(0o755)
    # Typed text cannot answer the folder-trust dialog, so trust only this
    # run's folder for the run.
    steer.set_directory_trust(directory, True)
    project = steer.claude_project_directory(directory)
    queue_file = runtime_home / 'coordinator-queue.json'
    app_log = check.artifacts / f'{NAME}-app.log'
    instance = chat.ChatInstance(check.binary, environment, environment['TOASTTY_SOCKET_PATH'], runtime_home, app_log)
    step = check.step
    ui = None

    def status():
        return cli('coordinator', 'status')

    def at_prompt():
        current = status()
        return current.get('agentState') == 'running' and current.get('status') in ('idle', 'ready') and current

    def records():
        found = []
        for path in sorted(project.glob('*.jsonl'), key=lambda item: item.stat().st_mtime):
            for line in path.read_text().splitlines():
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not record.get('isSidechain'):
                    found.append(record)
        return found

    def entries():
        """The conversation in order: the user's messages, Claude's text,
        Claude's runs of the wait script, and the input that Claude took in
        while it worked (a queued command)."""
        found = []
        for record in records():
            kind = record.get('type')
            if kind in ('user', 'assistant'):
                content = (record.get('message') or {}).get('content')
                text = steer.claude_content_text(content)
                if text:
                    found.append(dict(role=kind, text=text))
                for block in content if isinstance(content, list) else []:
                    if isinstance(block, dict) and block.get('type') == 'tool_use':
                        found.append(dict(role='tool', text=json.dumps(block.get('input'))))
            elif kind == 'attachment' and (record.get('attachment') or {}).get('type') == 'queued_command':
                found.append(dict(role='queued_command', text=str(record['attachment'].get('prompt') or '')))
        return found

    def index_of(role, fragment, after=-1):
        return next((index for index, entry in enumerate(entries())
                     if index > after and entry['role'] == role and fragment in entry['text']), None)

    def wait_for_reply(marker, timeout=300):
        wait_for(f'the reply {marker}', lambda: index_of('assistant', marker) is not None, timeout=timeout)

    def saved_queue():
        return json.loads(queue_file.read_text()) if queue_file.is_file() else dict(queued=[], paused=[])

    def capture(name):
        """A still picture of the window's part of the screen. Never a
        recording: one from Terminal makes macOS show a consent prompt."""
        check.frame_count += 1
        label = f'{check.frame_count:02d}-{name}'
        path = check.frames / f'{label}.png'
        code, output = ui.ax('window-frame', check=False)
        rect = None
        if code == 0 and len(output.split()) == 4:
            x, y, width, height = map(int, output.split())
            left, top = max(x, 0), max(y, 0)
            rect = f'{left},{top},{x + width - left},{y + height - top}'
        done = subprocess.run(['screencapture', '-x', *(['-R', rect] if rect else []), str(path)],
                              capture_output=True, text=True, timeout=30)
        check.evidence['captures'].append(dict(step=label, rect=rect, path=str(path),
                                               ok=done.returncode == 0 and path.is_file(),
                                               error=(done.stdout + done.stderr).strip() or None))

    def focus_composer():
        ui.activate()

        def has_keyboard():
            ui.ax('focus', COMPOSER)
            time.sleep(0.3)
            return json.loads(ui.drive('focused', ui.pid) or '{}').get('identifier') == COMPOSER

        wait_for('the composer to take the keyboard', has_keyboard, timeout=30, interval=0.3)

    def type_in_composer(text):
        """Types into the chat's composer. While a turn runs, the chip shows
        only with text in the field: an empty field offers Stop."""
        focus_composer()
        ui.type(text)
        wait_for('the typed text in the composer', lambda: ui.value(COMPOSER) == text, timeout=20)

    def press_send(modifiers=None):
        """Return, or Command-Return with modifiers='cmd'."""
        focus_composer()
        if modifiers == 'cmd':
            # The key that remote-coordinator-chat-check.py queues with.
            ui.ax('key', 'cmd-return')
        else:
            ui.key(quick.KEY_RETURN, modifiers)
        wait_for('the composer to clear', lambda: not ui.value(COMPOSER), timeout=20)

    def compose(text, modifiers=None):
        type_in_composer(text)
        press_send(modifiers)

    def start_long_turn(seconds, marker):
        """Sends a message whose turn runs the wait script, and waits until
        the script runs."""
        before = len(entries())
        compose(chat.long_turn(seconds, marker))
        wait_for('the long turn to run', lambda: status().get('status') == 'working', timeout=60)
        wait_for('Claude to run the wait script',
                 lambda: index_of('tool', chat.HOLD_COMMAND, after=before - 1) is not None, timeout=120)
        return index_of('user', marker, after=before - 1)

    def took_in_turn(marker, prompt):
        """Claude took the message `marker` into the turn of `prompt` and
        answered it there: a queued command, then the answer, and no user
        message of its own in between."""
        listed = entries()
        taken = next((i for i, e in enumerate(listed) if i > prompt and e['role'] == 'queued_command'
                      and marker in e['text']), None)
        answer = next((i for i, e in enumerate(listed) if taken is not None and i > taken
                       and e['role'] == 'assistant' and marker in e['text']), None)
        require(taken is not None and answer is not None,
                f'Claude did not take {marker} into the running turn: {listed[prompt:][-8:]}')
        require(not any(e['role'] == 'user' for e in listed[prompt + 1:answer]),
                f'A new turn started before Claude answered {marker}: {listed[prompt:answer + 1]}')
        require(not any(e['role'] == 'user' and marker in e['text'] for e in listed),
                f'{marker} also reached Claude as a message of its own')
        return answer, dict(prompt=listed[prompt]['text'], taken=listed[taken]['text'], answer=listed[answer]['text'])

    try:
        instance.wait_until_ready()
        wait_for('instance.json', lambda: (runtime_home / 'instance.json').is_file())
        pid = json.loads((runtime_home / 'instance.json').read_text())['pid']
        ui = quick.UI(check.artifacts, pid)
        trust = ui.ax('status')[1]
        require('trusted=true' in trust and 'locked=false' in trust,
                f'The UI driver cannot act: {trust}. Unlock the screen, or run with --gui-session over SSH')

        # 1. At an open prompt there is no choice, and Return sends.
        opened = cli('coordinator', 'open')
        require(opened['startedAgent'] and opened['agentState'] == 'running', f'Open did not start Claude: {opened}')
        ui.activate()
        wait_for('the chat', lambda: ui.exists('coordinator.chat') and ui.exists(COMPOSER), timeout=60)
        # A system prompt stays on the right of the mini's screen. The
        # window keeps clear of it, partly off the left edge.
        check.evidence['windowFrame'] = ui.ax('window-set-frame', *WINDOW_FRAME)[1]
        wait_for('Claude at its first prompt', at_prompt, timeout=180)
        ui.dismiss_notice()
        require(not ui.exists(CHIP), 'The chat offers Steer or Queue while no turn runs')
        compose(reply_line('STEER-READY'))
        wait_for_reply('STEER-READY')
        require(index_of('user', 'STEER-READY') is not None and index_of('queued_command', 'STEER-READY') is None,
                f'The message at the open prompt did not start a turn: {entries()[-4:]}')
        wait_for('the prompt to open again', at_prompt, timeout=120)
        capture('open-prompt-no-chip')
        step('at an open prompt the chat offered no choice and Return sent', version=version)

        # 2. While a turn runs, Return steers it.
        prompt = start_long_turn(45, 'HOLD-ONE')
        type_in_composer('Also add the word STEER-ONE at the end of your reply.')
        wait_for('the chip that says Steer', lambda: ui.has_label('Steer selected'), timeout=30)
        capture('chip-says-steer')
        press_send()
        time.sleep(1)
        require(status()['queuedCount'] == 0, f'The steered message waits in the queue: {status()}')
        wait_for_reply('STEER-ONE', timeout=240)
        _, steered = took_in_turn('STEER-ONE', prompt)
        wait_for('the chat to mark the message as steered', lambda: 'steered' in ui.chat(), timeout=60)
        wait_for('the prompt to open again', at_prompt, timeout=120)
        capture('steered-into-the-turn')
        step('Return steered the running turn', **steered)

        # 3. Queue on the chip, Command-Return, quick entry and coordinator
        #    send wait. Steer now takes a waiting message into the turn.
        prompt = start_long_turn(180, 'HOLD-TWO')
        type_in_composer(reply_line('QUEUED-CHIP'))
        wait_for('the chip that says Steer', lambda: ui.has_label('Steer selected'), timeout=30)
        ui.drive('press-menu', ui.pid, CHIP, 'Queue')
        wait_for('the chip that says Queue', lambda: ui.has_label('Queue selected'), timeout=20)
        capture('chip-says-queue')
        press_send()
        wait_for('the message to wait', lambda: status()['queuedCount'] == 1, timeout=20)
        type_in_composer(reply_line('QUEUED-CMD'))
        wait_for('the chip back on Steer', lambda: ui.has_label('Steer selected'), timeout=20)
        press_send('cmd')
        wait_for('the second message to wait', lambda: status()['queuedCount'] == 2, timeout=20)

        # Quick entry, from another app while the turn runs.
        ui.drive('activate', quick.FINDER)
        wait_for('Finder in front', lambda: ui.drive('frontmost') == quick.FINDER, timeout=20)
        ui.key(quick.KEY_T, quick.SHORTCUT)
        wait_for('the quick entry panel', lambda: ui.has_window(quick.PANEL), timeout=20)
        quick_text = QUIET + reply_line('QUICK-ENTRY')
        ui.type(quick_text)
        wait_for('the typed text in the panel', lambda: ui.value('quick-entry.text') == quick_text, timeout=20)
        capture('quick-entry-panel')
        ui.key(quick.KEY_RETURN, 'cmd')
        toast = None
        for _ in range(10):
            toast = ui.value('quick-entry.toast.message')
            if toast:
                break
            time.sleep(0.1)
        wait_for('the panel to close', ui.panel_closed, timeout=20)
        require(toast == 'Waits: the coordinator is working', f'The quick entry toast says {toast!r}')
        wait_for('the quick entry message to wait', lambda: status()['queuedCount'] == 3, timeout=20)

        # A message from an agent through the CLI.
        sent = cli('coordinator', 'send', QUIET + reply_line('FROM-CLI'))
        require(sent.get('delivery') == 'queued', f'coordinator send did not queue: {sent}')
        wait_for('four messages to wait', lambda: status()['queuedCount'] == 4, timeout=20)

        # Steer now on a waiting message.
        compose('Also add the word STEER-NOW at the end of your reply.', 'cmd')
        wait_for('five messages to wait', lambda: status()['queuedCount'] == 5, timeout=20)
        waiting = saved_queue()['queued']
        target = next(entry for entry in waiting if 'STEER-NOW' in entry['text'])
        from_quick_entry = next((entry for entry in waiting if 'QUICK-ENTRY' in entry['text']), None)
        require(from_quick_entry is not None, f'The quick entry message is not saved: {waiting}')
        wait_for('the chat to list five waiting', lambda: 'queued 5' in ui.chat().lower(), timeout=30)
        wait_for('Steer now on its row', lambda: ui.exists(STEER_ROW + target['id']), timeout=30)
        require(not ui.exists(STEER_ROW + from_quick_entry['id']), 'The quick entry message offers Steer now')
        capture('five-waiting')
        require(index_of('queued_command', 'STEER-NOW') is None, 'Claude took STEER-NOW before Steer now')
        ui.ax('click', STEER_ROW + target['id'])
        wait_for('the message to leave the queue', lambda: status()['queuedCount'] == 4, timeout=20)
        require(all(entry['id'] != target['id'] for entry in saved_queue()['queued'] + saved_queue()['paused']),
                f'The steered message is still saved: {saved_queue()}')
        capture('after-steer-now')
        wait_for_reply('STEER-NOW', timeout=300)
        # The answer in the turn of HOLD-TWO, which ends that turn.
        turn_end, steered_now = took_in_turn('STEER-NOW', prompt)
        step('Queue, Command-Return, quick entry and coordinator send waited; Steer now went into the turn',
             toast=toast, **steered_now)

        # 4. After the turn, each waiting message gets its own turn, in order.
        markers = ['QUEUED-CHIP', 'QUEUED-CMD', 'QUICK-ENTRY', 'FROM-CLI']
        for marker in markers:
            wait_for(f'the message {marker} in its own turn', lambda: index_of('user', marker) is not None, timeout=300)
        order = [index_of('user', marker) for marker in markers]
        require(all(index > turn_end for index in order) and order == sorted(order),
                f'The waiting messages were not typed after the turn, in order: {order} after {turn_end}')
        require(all(index_of('queued_command', marker) is None for marker in markers),
                'A waiting message went into the running turn')
        wait_for('the queue to empty', lambda: status()['queuedCount'] == 0 and at_prompt(), timeout=300)
        capture('queue-done')
        step('each waiting message had its own turn after the turn, in order', order=order)
    except Exception:
        # What the window showed when the check stopped.
        try:
            if ui:
                capture('failure')
        except Exception:  # noqa: BLE001 - the first error matters
            pass
        raise
    finally:
        try:
            instance.kill()
        except Exception:  # noqa: BLE001 - the evidence below matters more
            pass
        check.copy_instance_log(runtime_home, 'steer')
        steer.set_directory_trust(directory, False)
        if project.is_dir():
            saved = check.artifacts / f'{NAME}-transcripts'
            saved.mkdir(exist_ok=True)
            for path in project.glob('*.jsonl'):
                shutil.copyfile(path, saved / path.name)
            # Only the project for this run's unique temporary folder.
            shutil.rmtree(project, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    if options.gui_session:
        quick.run_in_gui_session([argument for argument in sys.argv[1:] if argument != '--gui-session'],
                                 name=NAME, script=__file__)
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
