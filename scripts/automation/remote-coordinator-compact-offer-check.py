#!/usr/bin/env python3
"""Live check: Claude Code's real "We recommend compacting earlier" offer in
the coordinator's terminal, answered with the keyboard after Show Terminal.

Claude Code shows the offer in its terminal only, and the chat cannot answer
it. The check makes the real CLI show it: a first turn, then synthetic text
added to that turn's transcript, a relaunch that resumes it, and one more
real turn. Then it checks what a person meets:

1. A message sent in the chat waits, and the chat says that the coordinator
   waits for an answer in the terminal.
2. Show Terminal, in the full view's chat or in the dock (`--host dock`),
   gives the terminal the keyboard: one second later an arrow key moves the
   offer's choice. Arrow keys go as a keyboard sends them.
3. The wheel moves Claude's page up and the offer out of it. The message
   still waits: typed now, it would go into the offer.
4. Escape closes the offer, and Claude gets the waiting message once.

It uses the Claude account of the Mac that runs it. Escape leaves a count in
that account's `~/.claude.json`; the check puts the offer's record back as it
was. Each run costs two real turns, the second with about 230k input tokens.

Run on the Mac mini:
  sv exec -- scripts/remote/validate.sh --require-remote --scope working-tree \\
    --validation-command 'python3 scripts/automation/remote-coordinator-compact-offer-check.py --gui-session'

`--record-bytes` puts `pty-recorder.py` between the terminal and Claude and
keeps every byte that Claude receives, with its time, beside the evidence.
"""
import importlib.util
import json
import os
from pathlib import Path
from random import Random
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
NAME = 'remote-coordinator-compact-offer-check'
TITLE = 'We recommend compacting earlier'
SCROLLED = 'Jump to bottom'
MODEL = 'claude-fable-5-2'
MARKER = 'COMPACT-QUEUE-DELIVERED'


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


first = load('coordinator_first_run_check', 'remote-coordinator-first-run-check.py')
require, wait_for = first.require, first.wait_for


def offer_record():
    """The offer's record for the model in the account's config file."""
    offers = first.read_config().get('autoCompactOffer', {})
    return {key: entries[MODEL] for key, entries in offers.items() if MODEL in entries}


def restore_offer_record(before):
    """Takes this run's own change out of the offer's record: Claude Code
    notes when it first offered, and counts the Escape. A record that
    changed in any other way belongs to another session, and stays."""
    with first.claude_config_lock():
        config = first.read_config()
        restored, left = [], []
        for key, entries in list(config.get('autoCompactOffer', {}).items()):
            record, earlier = entries.get(MODEL), before.get(key)
            if record is None or record == earlier:
                continue
            # Without the time of the first offer, this run leaves the record
            # as it was, or with one more Escape.
            def rest(entry):
                return {name: value for name, value in entry.items() if name != 'eligibleLoggedAt'}
            earlier_rest = rest(earlier or {})
            if rest(record) not in (earlier_rest, dict(earlier_rest, escCount=earlier_rest.get('escCount', 0) + 1)):
                left.append(key)
                continue
            if earlier is None:
                del entries[MODEL]
            else:
                entries[MODEL] = earlier
            restored.append(key)
        if restored:
            with tempfile.NamedTemporaryFile(mode='w', dir=first.CLAUDE_CONFIG.parent, delete=False) as file:
                json.dump(config, file, ensure_ascii=False, indent=2)
                swap = Path(file.name)
            try:
                shutil.copymode(first.CLAUDE_CONFIG, swap)
                os.replace(swap, first.CLAUDE_CONFIG)
            finally:
                swap.unlink(missing_ok=True)
        return dict(restored=len(restored), changedByAnotherSession=len(left))


class Run(first.Run):
    def __init__(self, check, claude, record_bytes):
        super().__init__(check, 'offer', claude, asks_start_offer=False)
        # The log then has each forwarded key, beside the record of key
        # presses that Toastty keeps after Show Terminal.
        self.environment['TOASTTY_LOG_LEVEL'] = 'debug'
        self.bytes_log = check.artifacts / f'{NAME}-bytes-to-claude.jsonl'
        self.bytes_log.unlink(missing_ok=True)
        executable = claude
        if record_bytes:
            # Toastty takes a profile whose command is named `claude`.
            shim = self.user_home / 'recorder-bin/claude'
            shim.parent.mkdir()
            shim.write_text('#!/bin/sh\nexec /usr/bin/python3 {} {} {} "$@"\n'.format(
                *map(shlex.quote, (str(HERE / 'pty-recorder.py'), str(self.bytes_log), claude))))
            shim.chmod(0o755)
            executable = str(shim)
        argv = [executable, '--setting-sources', 'user', '--tools', 'Bash', '--strict-mcp-config']
        (self.user_home / '.toastty/agents.toml').write_text(
            f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps(argv)}\n')
        (self.user_home / '.toastty/tasks.toml').write_text(f'[coordinator]\nagent = "claude"\nmodel = "{MODEL}"\n')

    def offer(self, screen=None):
        """The offer's two choices as the terminal shows them, or ''."""
        screen = self.screen() if screen is None else screen
        return ' | '.join(line.strip() for line in screen.splitlines()
                          if 'Autocompact at' in line or 'Keep auto' in line)

    def received_since(self, moment):
        if not self.bytes_log.is_file():
            return None
        records = [json.loads(line) for line in self.bytes_log.read_text().splitlines() if line.strip()]
        return [record['bytes'] for record in records if record['at'] >= moment]

    def lengthen_transcript(self):
        """Adds text to the first turn, so that the next turn is long enough for the offer."""
        paths = list(self.project.glob('*.jsonl'))
        require(len(paths) == 1, f'Expected one transcript, got {len(paths)}')
        rows = [json.loads(line) for line in paths[0].read_text().splitlines()]
        message = next(row['message'] for row in rows if row.get('type') == 'user')
        numbers = Random(49241)
        text = 'Synthetic numbers for the compact-offer check. Do not process this list.\n' + '\n'.join(
            ','.join(str(numbers.randint(100, 999)) for _ in range(100)) for _ in range(1110))
        if isinstance(message['content'], str):
            message['content'] += '\n' + text
        else:
            message['content'].append({'type': 'text', 'text': text})
        paths[0].write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows))
        self.check.step('Lengthened the transcript', chars=len(text))

    def press(self, key, settle=0.7):
        """One key press: whether the offer changed, and what Claude received."""
        before, moment = self.offer(), time.time()
        self.ui.run('key', key)
        time.sleep(settle)
        after, status = self.offer(), self.status()
        self.check.step('Key at the offer', key=key, before=before, after=after, changed=after != before,
                        hold=status.get('hold'), queued=status.get('queuedCount'),
                        claudeReceived=self.received_since(moment))
        return after != before

    def terminal_point(self):
        """A point in the full view's terminal, right of the sidebar."""
        x, y, width, height = map(int, self.ui.run('window-frame')[1].split())
        return str(int(x + width * 0.62)), str(int(y + height * 0.5))

    def deliveries(self):
        return sum(1 for entry in self.transcript() if entry['role'] == 'user' and MARKER in entry['text'])


def run(check, claude, host, record_bytes):
    current = Run(check, claude, record_bytes)
    try:
        current.launch()
        current.cli('coordinator', 'open')
        current.ui.run('activate')
        wait_for('Claude at its prompt', current.at_prompt, timeout=85)
        current.ui.send('Reply with exactly: COMPACT-SEED')
        current.wait_for_reply('COMPACT-SEED', timeout=90)
        wait_for('Claude done with the first turn', current.at_prompt, timeout=20)
        time.sleep(2)
        current.instance.kill()
        time.sleep(2)
        current.lengthen_transcript()
        current.launch()
        current.ui.run('activate')
        wait_for('Claude resumed at its prompt', current.at_prompt, timeout=60)
        wait_for('the chat composer', lambda: current.ui.exists('coordinator.chat.composer'), timeout=30)
        current.ui.send('Ignore the previous synthetic numbers. Reply with just: COMPACT-TRIGGER')
        current.wait_for_reply('COMPACT-TRIGGER', timeout=160)
        wait_for("Claude Code's real compact offer", lambda: TITLE in current.screen(), timeout=35)
        check.step('The offer shows', offer=current.offer())

        # 1. A message waits, and the chat says why.
        if host == 'dock':
            current.ui.run('click', 'coordinator.panel.dock')
            wait_for('the dock', lambda: current.ui.exists('coordinator.dock')
                     and not current.ui.exists('coordinator.panel.mode-toggle'), timeout=20)
        current.ui.send(f'Reply with exactly: {MARKER}')
        wait_for('the waiting message', lambda: current.status()['queuedCount'] == 1, timeout=15)
        wait_for('the notice with Show Terminal',
                 lambda: current.ui.exists('coordinator.chat.notice.show-terminal'), timeout=20)
        hold = current.status().get('hold')
        check.step('The chat says why its message waits', hold=hold,
                   notice=current.ui.texts('coordinator.chat.notice'))
        require(hold == 'terminalDialog', f'The message waits for {hold}, not for the dialog')
        current.capture('chat-holds-message')

        # 2. Show Terminal gives the terminal the keyboard.
        current.ui.run('click', 'coordinator.chat.notice.show-terminal')
        time.sleep(1)
        moved = [current.press(key) for key in ('down', 'up', 'right', 'left')]
        current.capture('after-arrows')
        require(all(moved), f'One second after Show Terminal, the arrow keys did not move the offer: {moved}')
        require(current.status().get('hold') == 'terminalDialog',
                f"Arrow keys changed why the message waits: {current.status().get('hold')}")
        wait_for('the terminal in place of the chat', lambda: not current.ui.exists('coordinator.chat'), timeout=20)

        # 3. The wheel moves the offer out of the page. The message still waits.
        point = current.terminal_point()
        current.ui.run('scroll-at', *point, '4')
        wait_for("Claude's page away from its bottom", lambda: SCROLLED in current.screen(), timeout=10)
        time.sleep(2)
        status = current.status()
        check.step('The wheel moved the page up', offerOnPage=TITLE in current.screen(), hold=status.get('hold'),
                   queued=status.get('queuedCount'), deliveries=current.deliveries())
        current.capture('page-scrolled-up')
        require(status.get('queuedCount') == 1 and current.deliveries() == 0,
                'Toastty typed the waiting message while the offer was out of the page')
        require(status.get('hold') == 'terminalDialog', f"The message waits for {status.get('hold')}")
        current.ui.run('scroll-at', *point, '-8')
        wait_for('the offer on the page again', lambda: SCROLLED not in current.screen()
                 and TITLE in current.screen(), timeout=10)
        require(current.press('down'), 'After the wheel, the arrow key did not move the offer')

        # 4. Escape closes the offer, and Claude gets the message once.
        moment = time.time()
        current.ui.run('key', 'escape')
        wait_for('Escape to close the offer', lambda: TITLE not in current.screen(), timeout=8)
        check.step('Escape closed the offer', claudeReceived=current.received_since(moment))
        current.ui.run('click', 'coordinator.panel.mode-toggle')
        wait_for('the chat again', lambda: current.ui.exists('coordinator.chat'), timeout=15)
        current.wait_for_reply(MARKER, timeout=90)
        require(current.deliveries() == 1, f'Claude got the waiting message {current.deliveries()} times')
        require(current.status()['queuedCount'] == 0, 'A message still waits')
        check.step('Claude got the waiting message once', notice=current.ui.texts('coordinator.chat.notice'))
        current.capture('message-delivered')
    except Exception:
        if current.ui:
            try:
                check.step('failure', terminal=current.screen()[-2000:], status=current.status())
                current.capture('failure')
            except Exception:  # noqa: BLE001 - the first failure matters
                pass
        raise
    finally:
        current.finish()


def main():
    arguments = sys.argv[1:]
    host = 'dock' if '--host' in arguments and arguments[arguments.index('--host') + 1] == 'dock' else 'panel'
    if '--gui-session' in arguments:
        first.chat.run_in_gui_session([argument for argument in arguments if argument != '--gui-session'],
                                      name=NAME, script=__file__)
    claude = str(Path.home() / '.local/bin/claude')
    check = first.Check()
    check.prefix = NAME
    before = offer_record()
    try:
        check.step('Target', cli=subprocess.check_output([claude, '--version'], text=True).strip(),
                   app=str(check.bundle), host=host)
        run(check, claude, host, '--record-bytes' in arguments)
        check.evidence['status'] = 'passed'
    except Exception as error:
        check.evidence['failure'] = repr(error)
        raise
    finally:
        first.remove_projects(check.own_folders)
        check.step("The offer's record", **restore_offer_record(before))
        check.finish()
    print(f'[{NAME}] passed', flush=True)


if __name__ == '__main__':
    main()
