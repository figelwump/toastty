#!/usr/bin/env python3
"""Reply to one of the coordinator's messages in its chat, through the real
UI, with the real Claude CLI as the coordinator.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-reply-check.py --gui-session'.
The run uses subscription usage. It needs the remote Mac's screen unlocked.

The check starts its own instance of the wrapper's build, with a throwaway
runtime home and user home, as remote-coordinator-chat-check.py does. Every
action goes through the real UI: pointer moves, clicks and keys from
`ax-drive.swift`.

The check proves from Claude's transcript and the chat's own text that:
- with the pointer over the coordinator's message, Reply under it puts the
  message in the message bar, and Escape in the empty field takes it out;
- the sent message starts with Toastty's reply line and quotes the whole
  message, and Claude reads the quote;
- the chat shows the user's text with one line of the quote, not the quote
  or Toastty's line, and never says that the conversation did not show the
  message;
- a click on that line scrolls the chat back to the quoted message.

Evidence goes to remote-coordinator-reply-check.json, the app log and
Claude's transcripts in the artifacts directory. A build that lets
`automation.capture_screenshot` write to TOASTTY_EVIDENCE_DIR outside
automation mode also leaves frames in remote-coordinator-reply-check-frames;
other builds record that a capture failed, and the check goes on.
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
NAME = 'remote-coordinator-reply-check'
NOT_SHOWN = 'did not show it'
REPLY_LINE = '[Toastty] Reply from the user | quotes your message'


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


def require_mini_to_itself(own_pids=()):
    found = [line for line in attachments_check.other_runs(own_pids) if NAME not in line]
    require(not found, 'Another check runs on this Mac; stopping so the two do not meet: ' + ' | '.join(found))


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

    # The coordinator only writes text in this check.
    argv = [claude, '--setting-sources=', '--allowedTools', 'Read', '--tools', 'Read', '--strict-mcp-config']
    runtime_home, user_home = check.home('reply', argv)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)

    frames = check.artifacts / f'{NAME}-frames'
    shutil.rmtree(frames, ignore_errors=True)
    frames.mkdir()
    environment = check.environment('reply', runtime_home, user_home, real_home=True, TOASTTY_EVIDENCE_DIR=str(frames))
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

    def chat_frame():
        return [int(value) for value in ui.run('frame', 'coordinator.chat')[1].split()]

    def text_y(fragment):
        """Where the fragment shows on screen. The pointer moves there."""
        code, output = ui.run('hover-text', fragment, check=False)
        return int(output.split()[1]) if code == 0 else None

    def reply_bar():
        return ui.texts('coordinator.chat.reply') if ui.exists('coordinator.chat.reply') else ''

    def click_reply(fragment):
        """Pointer over the message, then Reply under it, as a hand does."""
        ui.run('activate')
        y = text_y(fragment)
        require(y is not None, f'The message with {fragment} does not show')
        time.sleep(0.6)
        capture(f'pointer-over-{fragment.lower()}')
        ui.run('click-label-below', 'Reply to message', str(y))
        wait_for('the reply in the message bar', lambda: 'Replying to the coordinator' in reply_bar(), timeout=15)

    try:
        instance.wait_until_ready()
        wait_for('instance.json', lambda: (runtime_home / 'instance.json').is_file())
        pid = json.loads((runtime_home / 'instance.json').read_text())['pid']
        ui = chat_check.UI(check.artifacts, pid)
        _, trust = ui.run('status')
        require('trusted=true' in trust and 'locked=false' in trust,
                f'The UI driver cannot act: {trust}. Unlock the screen, or run with --gui-session over SSH')

        # Sized before the coordinator starts: a resize while Claude Code
        # runs has ended Toastty's session for it.
        ui.run('window-set-frame', '240', '60', '1000', '760', check=False)
        opened = cli('coordinator', 'open')
        require(opened['startedAgent'] and opened['agentState'] == 'running', f'Open did not start Claude: {opened}')
        ui.run('activate')
        wait_for('the chat', lambda: ui.exists('coordinator.chat') and ui.exists('coordinator.chat.composer'))
        wait_for('Claude at its first prompt', at_prompt, timeout=180)
        time.sleep(15)
        require(at_prompt(), f'The coordinator\'s agent did not stay at its prompt: {status()} {terminal_text()!r}')
        if ui.has_label('Dismiss'):
            ui.run('click-label', 'Dismiss', check=False)
            time.sleep(0.5)
        capture('chat-open')
        step('the chat is open with Claude at its prompt', version=version)

        # 1. A long message from the coordinator: a question first, then
        # enough lines that its start leaves the screen. The prompt does not
        # hold the lines it asks for: the chat shows the prompt too.
        require_mini_to_itself({pid})
        prompt = ('Reply with exactly these lines and nothing else. First line: the word FRUITY, a colon, a space, '
                  'and the question mango or kiwi. Then a Markdown numbered list of the numbers 1 to 45. Last line: '
                  'the word DONE, a space, and the number 77.')
        ui.send(prompt)
        wait_for('the long message', lambda: answer('FRUITY') and '77' in answer('FRUITY'), timeout=240)
        long_message = answer('FRUITY')
        lines = [line.strip() for line in long_message.splitlines() if line.strip()]
        first, last = lines[0], lines[-1]
        require(first.startswith('FRUITY: ') and last == 'DONE 77' and first not in prompt,
                f'The coordinator did not write the lines asked for: {long_message!r}')
        wait_for('the chat to show it', lambda: last in ui.texts(), timeout=60)
        wait_for('the prompt to open again', at_prompt, timeout=120)
        capture('long-message')
        step('the coordinator wrote a long message', first=first, last=last, lines=len(lines))

        # 2. Reply under it, Escape, and Reply again.
        click_reply(last)
        bar = reply_bar()
        require(first in bar, f'The bar does not show the start of the message: {bar!r}')
        capture('reply-in-message-bar')
        ui.run('focus', 'coordinator.chat.composer')
        time.sleep(0.3)
        ui.run('key', 'escape')
        wait_for('Escape to remove the reply', lambda: reply_bar() == '', timeout=10)
        capture('escape-removed-reply')
        click_reply(last)
        step('Reply put the message in the bar, and Escape took it out', bar=bar)

        # 3. The reply.
        require_mini_to_itself({pid})
        ui.run('focus', 'coordinator.chat.composer')
        time.sleep(0.3)
        ui.run('type', 'Kiwi. Which line of yours am I answering? Reply with REPLY-OK and the first word of the '
                       'quoted message, and nothing else.')
        capture('reply-typed')
        ui.run('key', 'return')
        wait_for('Claude to answer the reply', lambda: answer('REPLY-OK'), timeout=240)
        sent = user_message('REPLY-OK')
        quoted = [line for line in long_message.splitlines()]
        require(sent is not None and REPLY_LINE in sent
                and all((f'> {line}' if line else '>') in sent for line in quoted),
                f'The message does not quote the whole message after Toastty\'s line: {sent!r}')
        reply_answer = answer('REPLY-OK')
        require('FRUITY' in reply_answer, f'Claude did not read the quote: {reply_answer!r}')
        wait_for('the chat to show the answer',
                 lambda: any('REPLY-OK' in text and 'FRUITY' in text for text in ui.texts().splitlines()), timeout=60)
        texts = ui.texts()
        require(NOT_SHOWN not in texts, f'The chat says the message did not show: {texts[-600:]}')
        require(REPLY_LINE not in texts and f'> {first}' not in texts,
                f'The chat shows Toastty\'s line or the quote: {texts[-800:]}')
        require(f'Reply to: {first}' in texts and 'Kiwi. Which line' in texts,
                f'The chat does not show the quote line and the text: {texts[-800:]}')
        require(reply_bar() == '', 'The message bar still shows the reply after the send')
        wait_for('the prompt to open again', at_prompt, timeout=120)
        capture('reply-sent-and-answered')
        step('the reply quoted the whole message, Claude read it, and the chat shows one line of it',
             message=sent, answer=reply_answer)

        # 4. A click on the quote line goes back to the message.
        x, top, width, height = chat_frame()
        before = text_y(first)
        ui.run('click-label', f'Reply to: {first}')
        time.sleep(1.2)
        after = text_y(first)
        check.evidence['quoteClick'] = dict(chatTop=top, chatHeight=height, before=before, after=after)
        require(after is not None and top <= after <= top + height // 2,
                f'The chat did not scroll to the quoted message: {check.evidence["quoteClick"]}')
        require(before is None or before < top or before > top + height, 'The message showed before the click')
        capture('quote-click-scrolled-to-message')
        step('a click on the quote line scrolled to the quoted message', **check.evidence['quoteClick'])
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
        check.copy_instance_log(runtime_home, 'reply')
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
