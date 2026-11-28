#!/usr/bin/env python3
"""Check the answer card of a permission request in the Mac's Coordinator chat, for a direct session, with
the real CLI and the real UI.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-permission-card-check.py --gui-session'.

The check starts its own disposable Toastty instance from the wrapper's build, with a throwaway runtime home
and user home and TOASTTY_COORDINATOR_CLAUDE_DIRECT_SESSION=1, as remote-coordinator-direct-session-check.py
does. The instance runs in automation mode, so that it can save frames of its window. The check opens the
coordinator's chat and, with real clicks and keys through ax-drive:

1. catches the chat's notice while the direct session starts;
2. sends a message that makes Claude ask to run `touch card-allowed.txt`, and clicks Allow once on the card:
   the command runs, and the card names the decision that this Mac sent;
3. does the same for `touch card-denied.txt` with Deny: the command does not run;
4. has Claude ask a question: its card has no Show Terminal button, and a choice and Submit answer it.

It uses the real, authenticated Claude CLI and subscription usage, never an API key. The profile gives
Claude the Bash tool and the question tool only, and allows only `sleep` without a request. A seeded device
on the loopback gateway only reads the conversation's events. The run marks only its temporary coordinator
folder trusted in ~/.claude.json, and removes that entry and the folder's Claude project directory
afterward. Add --gui-session on a host driven over SSH: the Claude login lives in the GUI session's
keychain, and the clicks come from the SSH side, which Accessibility trusts.

Evidence goes to remote-coordinator-permission-card-check.json, its frames folder, and the app log, under
the wrapper's artifacts directory.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid

HERE = Path(__file__).parent
NAME = 'remote-coordinator-permission-card-check'
SETTING = 'TOASTTY_COORDINATOR_CLAUDE_DIRECT_SESSION'


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coordinator_check = load('coordinator_check', 'remote-coordinator-check.py')
steer = load('queue_steer_check', 'remote-queue-steer-check.py')
chat = load('coordinator_chat_check', 'remote-coordinator-chat-check.py')
require, wait_for, Instance = coordinator_check.require, coordinator_check.wait_for, coordinator_check.Instance


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    if options.gui_session:
        chat.run_in_gui_session([], name=NAME, script=__file__)
    check = coordinator_check.Check('claude')
    check.prefix = NAME
    check.evidence['startedAt'] = datetime.now(timezone.utc).isoformat()
    try:
        run(check)
        check.evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - always keep the evidence
        check.evidence['failure'] = repr(error)
        raise
    finally:
        check.finish()
    print(f'[{NAME}] passed', flush=True)


def run(check):
    host = {key: value for key, value in os.environ.items()
            if not key.startswith('TOASTTY_')
            and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT')}
    claude = shutil.which('claude') or str(Path.home() / '.local/bin/claude')
    require(Path(claude).is_file(), 'Claude CLI is not installed; install and authenticate it on the remote host')
    version = subprocess.check_output([claude, '--version'], text=True, timeout=30, env=host).strip()
    auth = subprocess.run([claude, '--safe-mode', '--setting-sources', '', 'auth', 'status', '--json'],
                          capture_output=True, text=True, timeout=30, env=host)
    require(auth.returncode == 0 and json.loads(auth.stdout).get('loggedIn'),
            'Claude CLI needs an interactive login on the remote host; add --gui-session over SSH')
    require(not any(host.get(key) for key in ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN')),
            'The check must run without an API key in its environment')
    check.evidence.update(cliVersion=version, authMethod=json.loads(auth.stdout).get('authMethod'))

    # Only this disposable app sees the profile. Any Bash command but `sleep` asks first.
    argv = [claude, '--setting-sources=', '--permission-mode', 'default', '--allowedTools', 'Bash(sleep:*)',
            '--tools', 'Bash,AskUserQuestion', '--strict-mcp-config']
    runtime_home, user_home = check.home('card', argv)
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')
    # A device that only reads the conversation's events, for the cards' IDs and Claude's replies.
    (runtime_home / 'remote-access').mkdir(parents=True)
    device = dict(id=str(uuid.uuid4()).upper(), name='Reading phone', scopes=['read'], authKind='native',
                  tailscaleLogin=steer.IDENTITY, createdAt=0)
    credential = dict(credentialHash=hashlib.sha256(steer.TOKEN.encode()).hexdigest(), deviceID=device['id'],
                      issuedAt=0)
    (runtime_home / 'remote-access/devices.json').write_text(json.dumps(dict(
        devices=[device], credentials=[credential], nativePairingFailures=[])))

    frames = check.artifacts / f'{NAME}-frames'
    shutil.rmtree(frames, ignore_errors=True)
    frames.mkdir()
    port = steer.free_port()
    gateway = steer.Gateway(port)
    environment = check.environment('card', runtime_home, user_home, real_home=True, TOASTTY_AUTOMATION='1',
                                    TOASTTY_ARTIFACTS_DIR=str(frames), **{SETTING: '1'})
    _, cli = check.cli_runner(environment)
    folder = runtime_home / 'coordinator'
    folder.mkdir(parents=True)
    steer.set_directory_trust(folder, True)
    project = steer.claude_project_directory(folder)
    app_log = check.artifacts / f'{NAME}-app.log'
    arguments = ('-toastty.remoteAccess.enabled', 'YES', '-toastty.remoteAccess.port', str(port),
                 *coordinator_check.base.START_OFFER_ANSWERED)
    instance = Instance(check.binary, environment, environment['TOASTTY_SOCKET_PATH'], runtime_home, app_log,
                        arguments=arguments)
    step = check.step
    seen = set()
    frame_count = 0

    def capture(name):
        nonlocal frame_count
        frame_count += 1
        label = f'{frame_count:02d}-{name}'
        response = instance.request('automation.capture_screenshot', dict(step=label))
        check.evidence['captures'].append(dict(step=label, ok=response.get('ok'),
                                               path=(response.get('result') or {}).get('path'),
                                               error=None if response.get('ok') else response.get('error')))

    def status():
        return cli('coordinator', 'status')

    def conversation():
        panel = status().get('panelID')
        if not panel:
            return None
        _, body = gateway.call('GET', '/api/sessions')
        return next((c for c in (body or {}).get('snapshot', {}).get('conversations', [])
                     if c['provider'] == 'claude' and c['placement'].get('panelID') == panel), None)

    def events():
        current = conversation()
        return gateway.events(current['conversationID'])[0] if current else []

    def prompt_open():
        current = conversation()
        return current if current and current['inputAvailability'].get('kind') == 'open_prompt' else None

    def last_sequence():
        listed = events()
        return listed[-1]['sequence'] if listed else 0

    def next_interaction(kind):
        def probe():
            return next((e['payload'] for e in events() if e['kind'] == 'interaction_presented'
                         and e['payload'].get('kind') == kind and e['payload'].get('responseID')
                         and e['payload']['id'] not in seen), None)
        interaction = wait_for(f'Claude to ask ({kind})', probe, timeout=240, interval=0.5)
        seen.add(interaction['id'])
        return interaction

    def reply(marker, after):
        return wait_for(f'the reply {marker}', lambda: next(
            (e for e in events() if e['kind'] == 'assistant_message' and marker in e['payload'].get('text', '')
             and e['sequence'] > after), None), timeout=240, interval=1)

    def settle():
        # A turn that just ended can show the prompt of the turn before it for a moment.
        wait_for('the open prompt', lambda: prompt_open() and (time.sleep(3) or prompt_open()), timeout=240)

    def ask_command(path, allowed, refused):
        after = last_sequence()
        ui.send(f'Use the Bash tool to run exactly this command and nothing else: `touch {path}`. '
                f'If it succeeds, reply with exactly: {allowed}. If it is refused, reply with exactly: {refused}')
        return after

    try:
        instance.wait_until_ready()
        wait_for('the gateway', lambda: gateway.call('GET', '/api/hello', token=None)[0] == 200, timeout=60)
        pid = json.loads((runtime_home / 'instance.json').read_text())['pid']
        ui = chat.UI(check.artifacts, pid)

        # 1. The start. The notice says that the agent starts, and names no terminal.
        opened = cli('coordinator', 'open')
        require(opened.get('exists'), f'Open made no coordinator: {opened}')
        ui.run('activate')
        wait_for('the chat', lambda: ui.exists('coordinator.chat') and ui.exists('coordinator.chat.composer'),
                 timeout=60)
        notices = []
        deadline = time.time() + 90
        while time.time() < deadline and not prompt_open():
            texts = ui.texts()
            notice = next((line for line in texts.splitlines() if 'agent' in line.lower() and 'start' in line.lower()),
                          None)
            if notice and notice not in notices:
                notices.append(notice)
                capture('starting-notice')
            time.sleep(0.3)
        settle()
        require(all('terminal' not in notice.lower() for notice in notices),
                f'A direct session\'s start notice names the terminal: {notices}')
        capture('ready')
        step('the direct session started', startNotices=notices, status=status())

        # 2. Allow once on the card.
        after = ask_command('card-allowed.txt', 'CARD-ALLOWED', 'CARD-REFUSED')
        permission = next_interaction('permission')
        allow = f"toastty-mobile-permission-option-{permission['id']}-allow"
        wait_for('the card\'s buttons', lambda: ui.exists(allow), timeout=30)
        waiting = status()
        texts = ui.texts()
        require('touch card-allowed.txt' in texts, f'The card does not show the command: {texts[-800:]}')
        require('Allow once' in texts and 'Deny' in texts, f'The card lacks a decision: {texts[-800:]}')
        for wrong in ('cannot answer', 'respond on the desktop', 'Answer in the terminal', 'Show Terminal'):
            require(wrong not in texts, f'The chat says "{wrong}" for a card it can answer: {texts[-800:]}')
        require(waiting.get('status') == 'needs_approval', f'The coordinator does not wait for approval: {waiting}')
        capture('permission-card')
        ui.run('click', allow)
        reply('CARD-ALLOWED', after)
        wait_for('the card to name the decision sent',
                 lambda: 'Sent from this Mac: Allow once' in ui.texts(), timeout=60)
        require((folder / 'card-allowed.txt').exists(), 'The allowed command did not run')
        settle()
        answered = status()
        capture('allowed')
        step('Allow once on the card ran the command', preview=(permission.get('permission') or {}).get('preview'),
             statusWhileAsked=waiting.get('status'), statusAfter=answered.get('status'))

        # 3. Deny on the card.
        after = ask_command('card-denied.txt', 'CARD-ALLOWED-2', 'CARD-REFUSED-2')
        permission = next_interaction('permission')
        deny = f"toastty-mobile-permission-option-{permission['id']}-deny"
        wait_for('the card\'s buttons', lambda: ui.exists(deny), timeout=30)
        capture('second-permission-card')
        ui.run('click', deny)
        wait_for('the card to name the decision sent', lambda: 'Sent from this Mac: Deny' in ui.texts(), timeout=60)
        # A denial can end the turn with no more words.
        settle()
        require(not (folder / 'card-denied.txt').exists(), 'The denied command ran')
        require(not any(e['kind'] == 'assistant_message' and 'CARD-ALLOWED-2' in e['payload'].get('text', '')
                        and e['sequence'] > after for e in events()), 'Claude reported a denied command as run')
        capture('denied')
        step('Deny on the card stopped the command', status=status().get('status'))

        # 4. A question in a direct session: its card has no Show Terminal button.
        after = last_sequence()
        ui.send('Use the AskUserQuestion tool to ask me exactly one question, "Which color?", with exactly two '
                'options labelled Red and Blue. After my answer, reply with exactly COLOR- followed by my answer '
                'in capital letters, and nothing else.')
        question = next_interaction('question')
        decision = question['questions'][0]
        blue = next(o['id'] for o in decision['options'] if o['label'] == 'Blue')
        option = f"toastty-mobile-interaction-{question['id']}-question-{decision['id']}-option-{blue}"
        wait_for('the question\'s card', lambda: ui.exists(option), timeout=30)
        require(not ui.has_label('Show Terminal'), 'A direct session\'s question card offers Show Terminal')
        capture('question-card')
        ui.run('click', option)
        ui.run('click', f"toastty-mobile-interaction-submit-{question['id']}")
        reply('COLOR-BLUE', after)
        settle()
        capture('question-answered')
        step('a direct session\'s question was answered on its card without Show Terminal')
    finally:
        try:
            check.evidence['finalStatus'] = status()
            check.evidence['lastEvents'] = [dict(sequence=e['sequence'], kind=e['kind']) for e in events()[-30:]]
        except Exception:  # noqa: BLE001 - keep what there is
            pass
        try:
            instance.kill()
        except Exception:  # noqa: BLE001
            pass
        # The direct session's guard ends Claude Code when the app ends.
        time.sleep(8)
        check.copy_instance_log(runtime_home, 'card')
        steer.set_directory_trust(folder, False)
        if project.is_dir():
            capture_folder = check.artifacts / f'{NAME}-transcripts'
            capture_folder.mkdir(exist_ok=True)
            for path in project.glob('*.jsonl'):
                shutil.copyfile(path, capture_folder / path.name)
            # Only the project for this run's unique temporary folder.
            shutil.rmtree(project, ignore_errors=True)


if __name__ == '__main__':
    main()
