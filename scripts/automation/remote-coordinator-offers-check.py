#!/usr/bin/env python3
"""Answer the coordinator's offers on their cards in its chat, through the
real UI, with the real Claude CLI as the coordinator.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-offers-check.py --gui-session'.
The run uses subscription usage. It needs the remote Mac's screen unlocked.

The check starts its own instance of the wrapper's build, with a throwaway
runtime home and user home, as remote-coordinator-reply-check.py does. Every
action goes through the real UI: clicks and keys from `ax-drive.swift`.

The coordinator writes a message with a `toastty-offers` block: the check
gives Claude a file with the message and asks for its exact text. The check
then proves from Claude's transcript and the chat's own text that:
- the chat draws the block as cards and does not show its data, with 5
  offers as cards and the others behind two lines;
- a click on an offer's line opens what the offer is;
- Ask on a card makes the next message a reply that quotes one line with the
  offer's ID, and Claude reads that ID; the choices made before stay;
- Yes on a card and "Skip all" collect, and Send answers types one message
  with Toastty's line for answers and one line for each answer;
- the chat shows the answers as the user's bubble, and the cards as answered;
- a newer message with offers closes the older cards, and its own cards are
  open again.

Evidence goes to remote-coordinator-offers-check.json, the app log and
Claude's transcripts in the artifacts directory. A build that lets
`automation.capture_screenshot` write to TOASTTY_EVIDENCE_DIR outside
automation mode also leaves frames in remote-coordinator-offers-check-frames;
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
NAME = 'remote-coordinator-offers-check'
ANSWERS_LINE = '[Toastty] Answers from the user | to your offers of '
REPLY_LINE = '[Toastty] Reply from the user | quotes your message'
OLDER_LIST = 'A newer list has the offers that are open now.'

# Seven offers that the coordinator suggests, so two fold behind "more",
# and two that it would skip.
OFFERS = [
    dict(id='safari-check', kind='task', title='Check the sign-up page in Safari',
         what='One run of the sign-up flow in Safari, with a screenshot of each step.',
         example='On 2026-11-12 a customer wrote that the PINEAPPLE button does nothing in Safari.',
         why='Two reports this week, and no task holds it.', yes='A task in webapp: codex, high.',
         suggested='yes', list=2, lists=3),
    dict(id='release-hold', kind='rule', title='Hold merges while a release task is open',
         what='While a release task of a repository is open, hold merges into its default branch.',
         example='A change merged while the release built, and the build did not match the checked commit.',
         yes='This line under Releases in `policy.md`.', suggested='yes', list=3, lists=3),
    dict(id='export-docs', kind='task', title='Document the export command', suggested='yes', list=1, lists=3),
    dict(id='disk-cleanup', kind='task', title='Delete compiler caches after a test run', suggested='yes'),
    dict(id='busy-message', kind='task', title='Deliver a message when a busy agent ends its turn', suggested='yes'),
    dict(id='signed-build', kind='task', title='Check the signed build before a release', suggested='yes'),
    dict(id='update-check', kind='task', title='Check that the site offers the new download', suggested='yes'),
    dict(id='preamble-sooner', kind='task', title='Show the first-run preamble sooner', suggested='skip', list=3, lists=3),
    dict(id='model-list', kind='task', title='A command that lists model IDs', suggested='skip', list=2, lists=3),
]


def offers_message(marker):
    """The coordinator's message: a line with `marker`, then the block."""
    block = json.dumps(dict(offers=OFFERS), indent=1)
    return f'{marker}: 2 items block work, and 9 offers wait.\n\n```toastty-offers\n{block}\n```\n'


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


reply_check = load('reply_check', 'remote-coordinator-reply-check.py')
chat_check = reply_check.chat_check
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

    # The coordinator only reads its two files and writes text in this check.
    argv = [claude, '--setting-sources=', '--allowedTools', 'Read', '--tools', 'Read', '--strict-mcp-config']
    runtime_home, user_home = check.home('offers', argv)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)

    frames = check.artifacts / f'{NAME}-frames'
    shutil.rmtree(frames, ignore_errors=True)
    frames.mkdir()
    environment = check.environment('offers', runtime_home, user_home, real_home=True, TOASTTY_EVIDENCE_DIR=str(frames))
    run_cli, cli = check.cli_runner(environment)
    directory = runtime_home / 'coordinator'
    directory.mkdir(parents=True)
    (directory / 'first-list.md').write_text(offers_message('FIRSTLIST'))
    (directory / 'second-list.md').write_text(offers_message('SECONDLIST'))
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

    def click(identifier):
        ui.run('activate')
        ui.run('click', identifier)
        time.sleep(0.5)

    def count_text():
        """What the cards' last line says about the answers."""
        return ui.texts('toastty-offers-count') if ui.exists('toastty-offers-count') else ''

    def ask_for(file, marker):
        ui.send(f'Read the file {file} in this folder. Reply with its exact text and nothing else: '
                'do not add a word, and keep the code block as it is.')
        wait_for(f'the message of {file}', lambda: answer(f'{marker}: 2 items') and '```toastty-offers' in answer(f'{marker}: 2 items'),
                 timeout=240)
        wait_for('the chat to show it', lambda: f'{marker}: 2 items' in ui.texts(), timeout=60)
        wait_for('the prompt to open again', at_prompt, timeout=120)

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
        ui.run('window-set-frame', '200', '40', '1040', '900', check=False)
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

        # 1. The coordinator's message with offers shows as cards.
        require_mini_to_itself({pid})
        ask_for('first-list.md', 'FIRSTLIST')
        wait_for('the cards', lambda: ui.exists('toastty-offer-safari-check-yes'), timeout=30)
        texts = ui.texts()
        require('"id"' not in texts and '"suggested"' not in texts, f'The chat shows the block\'s data: {texts[-800:]}')
        require('Offers · 9' in texts and '7 that I suggest, 2 that I would skip' in texts,
                f'The cards\' first line is not there: {texts[-800:]}')
        # A card shows its title. A folded offer's title is only in its line.
        shown = [offer['id'] for offer in OFFERS if ui.exists(f'toastty-offer-{offer["id"]}-yes')]
        require(shown == [offer['id'] for offer in OFFERS[:5]], f'Not the first 5 suggested offers show as cards: {shown}')
        require('2 more that I suggest' in texts and '2 that I would skip' in texts and 'No answers yet' in count_text(),
                f'The folded lines or the count are not there: {texts[-800:]}')
        capture('offer-cards')
        step('the offers show as cards: 5 open, 2 more and 2 to skip behind their lines', shown=shown)

        # 2. A click on an offer's line opens what it is.
        require('PINEAPPLE' not in texts, 'The offer\'s example shows before its card is open')
        click('toastty-offer-safari-check-toggle')
        wait_for('the open card', lambda: 'PINEAPPLE button does nothing' in ui.texts(), timeout=10)
        opened_texts = ui.texts()
        require('One run of the sign-up flow' in opened_texts and 'A task in webapp' in opened_texts,
                f'The open card does not show what the offer does and what a yes starts: {opened_texts[-800:]}')
        capture('offer-open')
        step('a click on the offer opened what it does, an example and what a yes starts')

        # 3. Yes on one card, and Skip all on the folded line.
        click('toastty-offer-safari-check-yes')
        wait_for('one choice', lambda: '1 answer not sent' in count_text(), timeout=10)
        click('toastty-offers-skip-all')
        wait_for('three choices', lambda: '3 answers not sent' in count_text(), timeout=10)
        capture('choices-made')
        step('Yes and Skip all made 3 choices, and nothing is sent yet', count=count_text())
        require(user_message(ANSWERS_LINE) is None, 'Answers were sent before Send answers')

        # 4. Ask on another card: the next message is a reply about that offer.
        require_mini_to_itself({pid})
        click('toastty-offer-release-hold-ask')
        wait_for('the offer in the message bar',
                 lambda: ui.exists('coordinator.chat.reply') and 'Offer release-hold' in ui.texts('coordinator.chat.reply'),
                 timeout=15)
        capture('ask-in-message-bar')
        ui.run('type', 'Which offer do I ask about? Reply with ASK-OK and the word that follows Offer in the '
                       'quoted line, and nothing else.')
        ui.run('key', 'return')
        wait_for('Claude to answer the question', lambda: answer('ASK-OK'), timeout=240)
        asked = user_message('Which offer do I ask about')
        require(asked is not None and REPLY_LINE in asked
                and '> Offer release-hold: Hold merges while a release task is open' in asked,
                f'The question does not quote the offer after Toastty\'s line: {asked!r}')
        require('release-hold' in answer('ASK-OK'), f'Claude did not read the offer\'s ID: {answer("ASK-OK")!r}')
        wait_for('the prompt to open again', at_prompt, timeout=120)
        require('3 answers not sent' in count_text(), f'The choices did not stay after the question: {count_text()!r}')
        require(ui.exists('toastty-offer-release-hold-yes'), 'The card that was asked about takes no answer anymore')
        capture('asked-about-an-offer')
        step('Ask sent a reply that quotes the offer, Claude read its ID, and the choices stayed',
             message=asked, answer=answer('ASK-OK'))

        # 5. Send answers: one message with Toastty's line.
        require_mini_to_itself({pid})
        click('toastty-offers-send')
        wait_for('the answers in Claude\'s conversation', lambda: user_message(ANSWERS_LINE), timeout=120)
        sent = user_message(ANSWERS_LINE)
        lines = sent.splitlines()
        first = lines[0] if lines else ''
        require(first.startswith(ANSWERS_LINE) and first.endswith(', 3 answers') and lines[1:4] == [
            '- yes: safari-check "Check the sign-up page in Safari"',
            '- skip: preamble-sooner "Show the first-run preamble sooner"',
            '- skip: model-list "A command that lists model IDs"',
        ], f'The answers are not typed as Toastty types them: {sent!r}')
        wait_for('the cards to show the answers', lambda: '3 of 9 answered' in count_text(), timeout=60)
        wait_for('the prompt to open again', at_prompt, timeout=240)
        texts = ui.texts()
        require('Yes: Check the sign-up page in Safari' in texts and 'Skip: A command that lists model IDs' in texts,
                f'The chat does not show the answers as the user\'s message: {texts[-900:]}')
        require(ANSWERS_LINE not in texts and 'did not show it' not in texts,
                f'The chat shows Toastty\'s line, or says that the message did not show: {texts[-900:]}')
        require(ui.exists('toastty-offer-safari-check-answered') and not ui.exists('toastty-offer-safari-check-yes'),
                'The answered card still takes an answer')
        capture('answers-sent')
        step('Send answers typed one message with one line for each answer, and the cards show the answers',
             message=sent, count=count_text())

        # 6. A newer message with offers closes the older cards.
        require_mini_to_itself({pid})
        ask_for('second-list.md', 'SECONDLIST')
        wait_for('the older cards to close', lambda: OLDER_LIST in ui.texts(), timeout=30)
        wait_for('the newer cards to take answers', lambda: ui.exists('toastty-offer-safari-check-yes'), timeout=30)
        capture('newer-list')
        step('a newer list closed the older cards, and its own offers are open again')
    except Exception:
        try:
            check.evidence['statusAtFailure'] = status()
            check.evidence['terminalAtFailure'] = terminal_text()
            check.evidence['chatAtFailure'] = ui.texts()[-3000:]
            capture('failure')
        except Exception:  # noqa: BLE001 - the first error matters
            pass
        raise
    finally:
        try:
            instance.kill()
        except Exception:  # noqa: BLE001 - the evidence below matters more
            pass
        check.copy_instance_log(runtime_home, 'offers')
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
