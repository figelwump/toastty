#!/usr/bin/env python3
"""Check the coordinator's Claude Code agent as a direct session, with the real CLI.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-direct-session-check.py --gui-session'.

The check starts its own disposable Toastty instance from the wrapper's
build, with a throwaway runtime home and user home, and with
TOASTTY_COORDINATOR_CLAUDE_DIRECT_SESSION=1: the coordinator's Claude Code
agent is then a process of Toastty's own, with no terminal between them. It
uses the real, authenticated Claude CLI and subscription usage, and never an
API key. Three seeded devices stand in for paired iPhones on the loopback
gateway: two may approve permission requests, one may not. Nothing moves
focus, and the installed production app is not touched.

The profile gives Claude the Bash tool and the question tool only, and allows
only commands that start with `sleep` without a request. The run marks only
its temporary coordinator folder trusted in ~/.claude.json, and removes that
entry and the folder's Claude project directory afterward. Add --gui-session
on a host driven over SSH: the Claude login lives in the GUI session's
keychain.

Evidence goes to remote-coordinator-direct-session-check.json, with the app
logs and Claude's transcripts, under the wrapper's artifacts directory.
"""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
import traceback
import uuid

HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coordinator_check = load('coordinator_check', 'remote-coordinator-check.py')
steer = load('queue_steer_check', 'remote-queue-steer-check.py')
require, wait_for, Instance = coordinator_check.require, coordinator_check.wait_for, coordinator_check.Instance

SETTING = 'TOASTTY_COORDINATOR_CLAUDE_DIRECT_SESSION'
SECOND_TOKEN = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('=')
NO_APPROVAL_TOKEN = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('=')
WAKE = '[Toastty] Wake'


def word(marker):
    return f'Use no tools. Reply with exactly this one word and nothing else: {marker}'


def sleeps(count, marker):
    return (f'Use the Bash tool to run `sleep 4` {count} separate times, one tool call per sleep. Do not combine '
            f'the sleeps and do not stop early. When all are done, reply with exactly: {marker}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    if options.gui_session:
        steer.run_in_gui_session('remote-coordinator-direct-session-check', __file__, timeout=3600)
    check = coordinator_check.Check('claude')
    check.prefix = 'remote-coordinator-direct-session-check'
    check.evidence['startedAt'] = datetime.now(timezone.utc).isoformat()
    try:
        run(check)
        check.evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - always keep the evidence
        check.evidence['failure'] = repr(error)
        raise
    finally:
        check.finish()
    print('[coordinator-check] passed (direct session)', flush=True)


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
    runtime_home, user_home = check.home('direct', argv)
    # The real model list is the user's; the check names none.
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')
    (runtime_home / 'remote-access').mkdir(parents=True)
    devices, credentials = [], []
    for name, token, approve in (('First phone', steer.TOKEN, True), ('Second phone', SECOND_TOKEN, True),
                                 ('Phone without approvals', NO_APPROVAL_TOKEN, False)):
        device = dict(id=str(uuid.uuid4()).upper(), name=name, scopes=['read', 'send'], authKind='native',
                      tailscaleLogin=steer.IDENTITY, createdAt=0)
        if approve:
            device['permissionApprovalEnabled'] = True
        devices.append(device)
        credentials.append(dict(credentialHash=hashlib.sha256(token.encode()).hexdigest(),
                                deviceID=device['id'], issuedAt=0))
    (runtime_home / 'remote-access/devices.json').write_text(json.dumps(dict(
        devices=devices, credentials=credentials, nativePairingFailures=[])))

    port = steer.free_port()
    gateway = steer.Gateway(port)
    # A Debug build takes the check's own answer to a question card as the user's, as the chat's card gives it.
    direct = check.environment('direct', runtime_home, user_home, real_home=True,
                               TOASTTY_TEST_TERMINAL_ANSWERS_AS_USER='1', **{SETTING: '1'})
    terminal = {key: value for key, value in direct.items() if key != SETTING}
    _, cli = check.cli_runner(direct)
    folder = runtime_home / 'coordinator'
    folder.mkdir(parents=True)
    steer.set_directory_trust(folder, True)
    project = steer.claude_project_directory(folder)
    app_log = check.artifacts / f'{check.prefix}-app.log'
    arguments = ('-toastty.remoteAccess.enabled', 'YES', '-toastty.remoteAccess.port', str(port),
                 *coordinator_check.base.START_OFFER_ANSWERED)
    step = check.step
    # `deny` is on while a turn that the check did not write may ask for a command, as a wake's turn can.
    state = dict(instance=None, counter=0, log_offset=0, pids=set(), deny=False, denied=[])

    def launch(environment):
        state['instance'] = Instance(check.binary, environment, environment['TOASTTY_SOCKET_PATH'], runtime_home,
                                     app_log, arguments=arguments)
        state['instance'].wait_until_ready()

        def gateway_ready():
            try:
                return gateway.call('GET', '/api/hello', token=None)[0] == 200
            except OSError:
                return False

        wait_for('the gateway', gateway_ready, timeout=60)

    def status():
        return cli('coordinator', 'status')

    def app_pid():
        return state['instance'].process.pid

    def stream_processes(parent=None):
        """Claude Code processes in stream-json mode: all of this user's, or the children of `parent`."""
        rows = []
        for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command='], text=True).splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3 and '--input-format stream-json' in parts[2]:
                rows.append(dict(pid=int(parts[0]), ppid=int(parts[1]), command=parts[2]))
        rows = [row for row in rows if parent is None or row['ppid'] == parent]
        if parent is not None:
            state['pids'].update(row['pid'] for row in rows)
        return rows

    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def log_records(message):
        """The app's log lines with this message, written since the last launch mark."""
        log = runtime_home / 'logs/toastty.log'
        records = []
        for line in (log.read_text(errors='replace')[state['log_offset']:].splitlines() if log.is_file() else []):
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get('message') == message:
                records.append(record.get('metadata') or {})
        return records

    def mark_log():
        log = runtime_home / 'logs/toastty.log'
        state['log_offset'] = len(log.read_text(errors='replace')) if log.is_file() else 0

    def screen():
        panel = status().get('panelID')
        response = state['instance'].request('app_control.run_query',
                                             dict(id='terminal.visible-text', args=dict(panelID=panel)))
        return (response.get('result') or {}).get('text', '') if response.get('ok') else ''

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

    def find(predicate, description, timeout=180, after=None):
        """The first event that matches, among those after the event `after`."""
        def probe():
            listed = events()
            if state['deny']:
                deny_requests(listed)
            return next((e for e in listed if predicate(e) and (after is None or e['sequence'] > after['sequence'])),
                        None)
        try:
            return wait_for(description, probe, timeout=timeout, interval=0.5)
        except AssertionError:
            check.evidence['lastEvents'] = events()[-25:]
            check.evidence['lastStatus'] = status()
            raise

    def prompt_open():
        current = conversation()
        return current if current and current['inputAvailability'].get('kind') == 'open_prompt' else None

    def working():
        current = conversation()
        control = (current or {}).get('inputControl') or {}
        return current if control.get('turnEpoch') and control.get('canSteer') else None

    seen = set()

    def next_id(name):
        state['counter'] += 1
        return f"{name}-{state['counter']}"

    def phone_send(text, name='send', mode=None, epoch=None, token=steer.TOKEN, timeout=180):
        """A message from a paired phone, in the user's own words. Returns its request ID."""
        request_id = next_id(name)
        if epoch is None:
            epoch = wait_for('an open prompt', prompt_open, timeout=timeout)['inputAvailability']['epoch']
        body = dict(conversationID=conversation()['conversationID'], clientRequestID=request_id,
                    expectedInputEpoch=epoch, text=text)
        if mode:
            body['deliveryMode'] = mode
        code, result = gateway.call('POST', '/api/conversation.message.send', body, token=token)
        require(code == 200 and result.get('status') == ('queued' if mode == 'queue' else 'accepted'),
                f'The phone\'s message was not taken: {code} {result}')
        return request_id

    def receipt(request_id, mode=None, timeout=180):
        event = find(lambda e: e['kind'] == 'user_message' and e['payload'].get('clientRequestID') == request_id,
                     f'the receipt of {request_id}', timeout=timeout)
        require(event['payload'].get('origin') == 'remote' and event['payload'].get('deliveryMode') == mode,
                f'The receipt is not stamped as sent: {event}')
        return event

    def reply(marker, after=None, timeout=240):
        return find(lambda e: e['kind'] == 'assistant_message' and marker in e['payload'].get('text', ''),
                    f'the reply {marker}', timeout=timeout, after=after)

    def ask(text, marker, name='send'):
        """One whole turn from the phone: the receipt under its ID, the reply, and the open prompt."""
        request_id = phone_send(text, name)
        got = receipt(request_id)
        answer = reply(marker, after=got)
        wait_for('the prompt to open again', prompt_open, timeout=120)
        return request_id, got, answer

    def transcript_records():
        records = []
        for path in sorted(project.glob('*.jsonl')) if project.is_dir() else []:
            for line in path.read_text().splitlines():
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        return records

    def user_texts():
        """Each message that Claude received as the user's, in the order of the transcript, once per record."""
        texts, seen = [], set()
        for record in transcript_records():
            if record.get('type') != 'user' or record.get('isMeta') or record.get('uuid') in seen:
                continue
            seen.add(record.get('uuid'))
            content = (record.get('message') or {}).get('content')
            parts = [dict(type='text', text=content)] if isinstance(content, str) else [p for p in content or []
                                                                                       if isinstance(p, dict)]
            if any(p.get('type') == 'tool_result' for p in parts):
                continue
            text = '\n'.join(p.get('text', '') for p in parts if p.get('type') == 'text').strip()
            if text:
                texts.append(text)
        return texts

    def next_interaction(kind, description):
        event = find(lambda e: e['kind'] == 'interaction_presented' and e['payload'].get('kind') == kind
                     and e['payload'].get('responseID') and e['payload']['id'] not in seen, description)
        seen.add(event['payload']['id'])
        return event['payload']

    def phone_answer(interaction, question_id, option_id, token=steer.TOKEN):
        body = dict(protocolVersion='1.0', conversationID=conversation()['conversationID'],
                    interactionID=interaction['id'], responseID=interaction['responseID'],
                    expectedInputEpoch=interaction['inputEpoch'], clientRequestID=str(uuid.uuid4()),
                    answers=[dict(questionID=question_id, selectedOptionIDs=[option_id])])
        code, result = gateway.call('POST', '/api/conversation.question.answer', body, token=token)
        require(code == 200, f'The answer call failed: {code} {result}')
        return result

    def race(first, second):
        """Runs both answers at the same moment and returns their results."""
        results, barrier = [None, None], threading.Barrier(2)

        def runner(index, action):
            barrier.wait()
            try:
                results[index] = action()
            except Exception as error:  # noqa: BLE001 - a refused answer is a result
                results[index] = dict(status='rejected', reason=repr(error)[:300])

        threads = [threading.Thread(target=runner, args=(i, a)) for i, a in enumerate((first, second))]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=60)
        return results

    def deny_requests(listed):
        """Denies each open permission request, as a user would who is asked for a command that the check
        does not allow."""
        for event in listed:
            pending = event['payload'] if event['kind'] == 'interaction_presented' else {}
            if pending.get('kind') == 'permission' and pending.get('responseID') and pending['id'] not in seen:
                seen.add(pending['id'])
                state['denied'].append(dict(preview=(pending.get('permission') or {}).get('preview'),
                                            result=phone_answer(pending, 'decision', 'deny')))

    def settle(timeout=240):
        """Waits for the open prompt, and denies each permission request on the way."""
        deadline, since = time.time() + timeout, None
        while time.time() < deadline:
            deny_requests(events())
            # A turn that just started can still show the prompt of the turn before it.
            since = (since or time.time()) if prompt_open() else None
            if since and time.time() - since >= 5:
                return
            time.sleep(1)
        raise AssertionError(f'The prompt did not open: {conversation()}')

    def started_direct(resumes):
        """The facts of a direct session's start, from the app's log and the process list."""
        ready = wait_for('the direct session to take messages',
                         lambda: log_records('A direct session takes messages'), timeout=180, interval=1)[-1]
        started = log_records('Started a Claude Code process for a direct session')[-1]
        require(ready.get('plan') not in (None, '', 'none'), f'The session started without a Claude plan: {ready}')
        require(started.get('resumes') == ('true' if resumes else 'false'), f'Unexpected resume state: {started}')
        current = wait_for('the coordinator to run', lambda: (s := status()).get('agentState') == 'running' and s,
                           timeout=120)
        children = stream_processes(app_pid())
        require(len(children) == 1 and str(children[0]['pid']) == started.get('pid'),
                f'Expected one Claude Code process of the app in stream-json mode: {children} {started}')
        text = screen()
        require('for shortcuts' not in text and 'shift+tab to cycle' not in text,
                f'The terminal shows Claude Code, but the session is direct:\n{text[-800:]}')
        wait_for('the open prompt', prompt_open, timeout=120)
        return dict(log=ready, process=children[0], status=current, terminal=text[-300:])

    def kill_app(child_deadline):
        """Kills the app as a crash does. Returns the seconds until its Claude Code process was gone too."""
        children = stream_processes(app_pid())
        coordinator_check.wait_for_layout(runtime_home, '"isCoordinator"', '"resumeRecord"')
        state['instance'].kill()
        began = time.time()
        for child in children:
            wait_for(f"the Claude Code process {child['pid']} to end after the app's death",
                     lambda pid=child['pid']: not alive(pid), timeout=child_deadline, interval=0.5)
        return dict(children=[c['pid'] for c in children], seconds=round(time.time() - began, 1))

    # 1. Start. The plan is known, and the checks of the start passed, before any message is taken.
    def start():
        launch(direct)
        opened = cli('coordinator', 'open', '--no-select')
        require(opened.get('exists'), f'Open made no coordinator: {opened}')
        first_start = started_direct(resumes=False)
        state['first'] = conversation()['conversationID']
        step('a direct session started with a Claude plan and no terminal agent', version=version, **first_start)

    # 2. A message from the phone: a receipt under its own ID, a reply, and the prompt opens.
    def phone_message():
        _, _, answer = ask(word('DIRECT-ONE'), 'DIRECT-ONE')
        step('a phone message got its receipt and its reply', reply=answer['payload'].get('text'))

    # 3. A message from the Mac's side, through the coordinator's queue. A phone that was away reads
    #    what it missed from its cursor.
    def mac_message():
        before, cursor = gateway.events(state['first'])
        sent = cli('coordinator', 'send', word('DIRECT-MAC'))
        require(sent.get('delivery') == 'sent', f'The message was not given at the open prompt: {sent}')
        reply('DIRECT-MAC', after=before[-1])
        wait_for('the prompt to open again', prompt_open, timeout=120)
        missed, _ = gateway.events(state['first'], after=cursor)
        kinds = [e['kind'] for e in missed]
        require('user_message' in kinds and 'assistant_message' in kinds,
                f'A phone that returns did not get the turn it missed: {kinds}')
        step('a message from the Mac ran a turn, and a returning phone read it from its cursor',
             sent=sent, missedKinds=kinds)

    # 4. A wake at the open prompt: Toastty's timer digest starts a turn.
    def idle_wake():
        state['deny'] = True
        timer = cli('coordinator', 'wake', '--in', '60s')['wake']
        wake_event = find(lambda e: e['kind'] == 'user_message' and e['payload'].get('text', '').startswith(WAKE),
                          'the timer digest', timeout=150)
        settle()
        after_wake = status()
        require(after_wake['wake']['nextWakeAt'] is None and after_wake['wake']['pendingTaskCount'] == 0,
                f'The digest did not clear the timer: {after_wake}')
        step('a timer wake started a turn', timer=timer, digest=wake_event['payload'].get('text', '')[:400],
             deniedRequests=list(state['denied']))

    # 5. A busy turn. A queued phone message, a message from the Mac and a timer wake all wait for
    #    the end of the turn, and each then runs as a turn of its own.
    def busy_turn():
        state['deny'] = True
        timer = cli('coordinator', 'wake', '--in', '60s')['wake']
        time.sleep(30)
        busy_id = phone_send(sleeps(10, 'ALL-TEN-DONE'), 'busy')
        busy_receipt = receipt(busy_id)
        find(lambda e: e['kind'] == 'tool_started' and e['payload'].get('toolName') == 'Bash',
             'the first sleep', after=busy_receipt)
        turn_epoch = wait_for('the turn to run', working, timeout=60)['inputControl']['turnEpoch']
        queued_id = phone_send(word('QUEUED-OK'), 'queued', mode='queue', epoch=turn_epoch)
        mac_queued = cli('coordinator', 'send', word('MAC-QUEUED-OK'))
        require(mac_queued.get('delivery') == 'queued', f'A message during a turn was not queued: {mac_queued}')
        done = reply('ALL-TEN-DONE', after=busy_receipt, timeout=300)
        queued_receipt = receipt(queued_id, 'queue')
        require(queued_receipt['sequence'] > done['sequence'], 'The queued message ran inside the busy turn')
        early = [e for e in events() if busy_receipt['sequence'] < e['sequence'] < done['sequence']
                 and e['kind'] == 'user_message']
        require(not early, f'A message entered the busy turn: {early}')
        reply('QUEUED-OK', after=queued_receipt)
        mac_reply = reply('MAC-QUEUED-OK', after=done)
        second_wake = find(lambda e: e['kind'] == 'user_message' and e['payload'].get('text', '').startswith(WAKE),
                           'the timer digest after the busy turn', timeout=240, after=done)
        settle()
        wait_for('the queue to empty', lambda: status().get('queuedCount') == 0, timeout=120)
        settle()
        state['deny'] = False
        step('a queued phone message, a Mac message and a wake each ran after the busy turn',
             timer=timer, doneSequence=done['sequence'], queuedSequence=queued_receipt['sequence'],
             macReplySequence=mac_reply['sequence'], wakeSequence=second_wake['sequence'],
             deniedRequests=list(state['denied']))

    # 6. A steer enters the running turn, with a receipt of its own.
    def steered_turn():
        busy_id = phone_send(sleeps(10, 'SHOULD-NOT-FINISH'), 'busy')
        busy_receipt = receipt(busy_id)
        find(lambda e: e['kind'] == 'tool_started' and e['payload'].get('toolName') == 'Bash',
             'the first sleep', after=busy_receipt)
        turn_epoch = wait_for('the turn to run', working, timeout=60)['inputControl']['turnEpoch']
        steer_id = phone_send('Change of plan: stop after the current sleep and reply with exactly: STEERED-OK',
                              'steer', mode='steer', epoch=turn_epoch)
        steer_receipt = receipt(steer_id, 'steer')
        reply('STEERED-OK', after=steer_receipt)
        wait_for('the prompt to open again', prompt_open, timeout=120)
        step('a steer entered the running turn', receiptSequence=steer_receipt['sequence'])

    # 7. Stop. The request is taken; the prompt opens when Claude Code reports the turn's end.
    def stopped_turn():
        busy_id = phone_send(sleeps(30, 'SHOULD-NOT-FINISH-EITHER'), 'stopped')
        busy_receipt = receipt(busy_id)
        find(lambda e: e['kind'] == 'tool_started' and e['payload'].get('toolName') == 'Bash',
             'the first sleep', after=busy_receipt)
        turn_epoch = wait_for('the turn to run', working, timeout=60)['inputControl']['turnEpoch']
        code, stopped = gateway.call('POST', '/api/conversation.interrupt', dict(
            protocolVersion='1.0', conversationID=state['first'], expectedTurnEpoch=turn_epoch))
        require(code == 200 and stopped.get('result') == dict(status='accepted'), f'Stop was not taken: {stopped}')
        after_stop = wait_for('the prompt to open after the stop', prompt_open, timeout=90)
        require(not any(e['kind'] == 'assistant_message' and 'SHOULD-NOT-FINISH-EITHER' in e['payload'].get('text', '')
                        for e in events()), 'The stopped turn ran to its end')
        ask(word('AFTER-STOP-OK'), 'AFTER-STOP-OK')
        step('a stop ended the turn and the next message ran', state=after_stop.get('state'))

    # 8. A permission request. A phone without approvals is refused. Then two phones answer at the
    #    same moment with different answers: one answer is taken, and the turn follows it.
    def permission_request():
        request_id = phone_send('Use the Bash tool to run exactly this command and nothing else: '
                                '`touch direct-allowed.txt`. If it succeeds, reply with exactly: TOUCH-RAN. '
                                'If it is refused, reply with exactly: TOUCH-REFUSED', 'permission')
        asked = receipt(request_id)
        permission = next_interaction('permission', 'the permission request')
        require('touch direct-allowed.txt' in (permission.get('permission') or {}).get('preview', ''),
                f'The request does not show the command: {permission}')
        waiting = status()
        refused = phone_answer(permission, 'decision', 'allow', token=NO_APPROVAL_TOKEN)
        require(refused == dict(status='rejected', reason='approvals_disabled'), f'Not refused: {refused}')
        allow, deny = race(lambda: phone_answer(permission, 'decision', 'allow'),
                           lambda: phone_answer(permission, 'decision', 'deny', token=SECOND_TOKEN))
        taken = [r for r in (allow, deny) if r == dict(status='submitted')]
        require(len(taken) == 1 and sorted(r.get('status') for r in (allow, deny)) == ['rejected', 'submitted'],
                f'Expected exactly one answer to be taken: allow {allow}, deny {deny}')
        allowed = allow == dict(status='submitted')
        # The answer ends the wait at once. Claude Code's hooks report the
        # request and not its answer, so only the session's own report can.
        answered = status()
        require(waiting.get('status') == 'needs_approval' and answered.get('status') != 'needs_approval',
                f'The status did not follow the request and its answer: {waiting.get("status")}, then '
                f'{answered.get("status")}')
        late = phone_answer(permission, 'decision', 'deny' if allowed else 'allow')
        require(late.get('status') == 'rejected', f'A late answer was taken: {late}')
        if allowed:
            reply('TOUCH-RAN', after=asked)
        # A refusal may end the turn with no more words.
        wait_for('the prompt to open again', prompt_open, timeout=180)
        require((folder / 'direct-allowed.txt').exists() == allowed, 'The command did not follow the answer taken')
        require(allowed or not any(e['kind'] == 'assistant_message' and 'TOUCH-RAN' in e['payload'].get('text', '')
                                   and e['sequence'] > asked['sequence'] for e in events()),
                'Claude reported a refused command as run')
        step('one of two answers to a permission request was taken, and the turn followed it',
             preview=permission['permission']['preview'], macStatus=waiting.get('status'),
             macStatusAfterAnswer=answered.get('status'), allow=allow, deny=deny, late=late)

    # 9. A question. The phone and the Mac answer at the same moment with different choices.
    def question():
        request_id = phone_send('Use the AskUserQuestion tool to ask me exactly one question, "Which color?", with '
                                'exactly two options labelled Red and Blue. After my answer, reply with exactly '
                                'COLOR- followed by my answer in capital letters, and nothing else.', 'question')
        asked = receipt(request_id)
        question = next_interaction('question', 'the question')
        options = {o['label']: o['id'] for o in question['questions'][0]['options']}
        require({'Red', 'Blue'} <= set(options), f'The question lacks the two choices: {question}')
        card = wait_for('the Mac to present the card', lambda: (status().get('openQuestion') or {}).get('card'),
                        timeout=30, interval=1)

        def mac_answer():
            response = state['instance'].request('app_control.run_action', dict(
                id='coordinator.answer-question', args=dict(card=card, option='Blue')))
            return dict(status='submitted') if response.get('ok') else dict(status='rejected', reason=str(response)[:300])

        waiting = status()
        phone, mac = race(lambda: phone_answer(question, question['questions'][0]['id'], options['Red']), mac_answer)
        require(sorted(r.get('status') for r in (phone, mac)) == ['rejected', 'submitted'],
                f'Expected exactly one answer to be taken: phone {phone}, Mac {mac}')
        answered = status()
        require(waiting.get('status') == 'needs_approval' and answered.get('status') != 'needs_approval',
                f'The status did not follow the question and its answer: {waiting.get("status")}, then '
                f'{answered.get("status")}')
        winner = 'COLOR-RED' if phone.get('status') == 'submitted' else 'COLOR-BLUE'
        reply(winner, after=asked)
        wait_for('the prompt to open again', prompt_open, timeout=120)
        step('one of the phone\'s and the Mac\'s answers to a question was taken', phone=phone, mac=mac, reply=winner,
             macStatus=waiting.get('status'), macStatusAfterAnswer=answered.get('status'))

    # A Claude Code command that answers with text, sent as a message: the answer shows as the
    # coordinator's message, and the prompt opens again.
    def text_command():
        request_id = phone_send('/model', 'model')
        answer = find(lambda e: e['kind'] == 'assistant_message' and 'Current model' in e['payload'].get('text', ''),
                      'the answer of /model', timeout=60)
        wait_for('the prompt to open after the command', prompt_open, timeout=60)
        step('a command that answers with text gave its answer as a message', request=request_id,
             answer=answer['payload'].get('text', '')[:200])

    # 10. Compaction at the open prompt, then one message: one turn.
    def compaction():
        compact_id = phone_send('/compact', 'compact')
        wait_for('the compaction to start and end', lambda: any(
            r.get('type') == 'system' and r.get('subtype') == 'compact_boundary' for r in transcript_records()),
            timeout=300, interval=2)
        wait_for('the prompt to open after the compaction', prompt_open, timeout=180)
        after_id, got, _ = ask(word('AFTER-COMPACT-OK'), 'AFTER-COMPACT-OK', 'after-compact')
        time.sleep(8)
        listed = events()
        receipts = [e for e in listed if e['kind'] == 'user_message' and e['payload'].get('clientRequestID') == after_id]
        answers = [e for e in listed if e['kind'] == 'assistant_message' and e['sequence'] > got['sequence']
                   and 'AFTER-COMPACT-OK' in e['payload'].get('text', '')]
        received = [t for t in user_texts() if 'AFTER-COMPACT-OK' in t]
        require(len(receipts) == 1 and len(answers) == 1 and len(received) == 1,
                f'Expected one turn after the compaction: {len(receipts)} receipts, {len(answers)} replies, '
                f'{len(received)} messages in the transcript')
        step('a message after a compaction at the open prompt ran one turn', compactRequest=compact_id)

    # 11. The conversation's place is gone: closing the coordinator's workspace ends the process.
    def closed_workspace():
        child = stream_processes(app_pid())[0]['pid']
        workspace_id = status()['workspaceID']
        state['instance'].request('app_control.run_action', dict(id='workspace.close', args=dict(workspaceID=workspace_id)))
        wait_for('the coordinator to be gone', lambda: not status().get('exists'), timeout=30)
        wait_for('the Claude Code process to end with its workspace', lambda: not alive(child), timeout=30)
        require(not stream_processes(app_pid()), f'A Claude Code process stayed: {stream_processes(app_pid())}')
        step('closing the workspace ended the Claude Code process', pid=child)

    # 12. A second start in the same app, then a crash at the open prompt. The relaunched app goes on
    #     with the same conversation, which remembers its first answer.
    def crash_at_the_prompt():
        if status().get('exists'):
            # The part before did not close the first coordinator. Go on with it.
            second_start = dict(log='the first coordinator, which is still open')
        else:
            mark_log()
            opened = cli('coordinator', 'open', '--no-select')
            require(opened.get('exists'), f'Open made no second coordinator: {opened}')
            second_start = started_direct(resumes=False)
            require(conversation()['conversationID'] != state.get('first'),
                    'The second coordinator has the conversation of the first')
        state['second'] = conversation()['conversationID']
        ask(word('SECOND-ONE'), 'SECOND-ONE')
        state['files'] = sorted(p.name for p in project.glob('*.jsonl'))
        death = kill_app(child_deadline=30)
        mark_log()
        launch(direct)
        resumed = started_direct(resumes=True)
        require('--resume' in resumed['process']['command'], f"Not resumed: {resumed['process']}")
        require(conversation()['conversationID'] == state['second'], 'The relaunch gave the conversation a new ID')
        history = events()
        require(any(e['kind'] == 'assistant_message' and 'SECOND-ONE' in e['payload'].get('text', '') for e in history),
                'The relaunched app does not show the conversation\'s history')
        _, got, _ = ask('Use no tools. What was the one word of your first answer in this conversation? Reply with '
                        'exactly that word and nothing else.', 'SECOND-ONE', 'memory')
        require(sorted(p.name for p in project.glob('*.jsonl')) == state['files'],
                f'The relaunch started another conversation: {sorted(p.name for p in project.glob("*.jsonl"))}')
        step('after a crash at the open prompt the same conversation went on', secondStart=second_start['log'],
             childEnded=death, resumed=resumed['process']['command'][-200:])

    # 13. A crash during a turn, right after a send. The message is in the conversation once, nothing
    #     is sent again, and the next message runs.
    def crash_during_a_turn():
        crash_text = sleeps(30, 'SHOULD-NOT-FINISH-AFTER-CRASH')
        crash_id = phone_send(crash_text, 'crash')
        crash_receipt = receipt(crash_id)
        find(lambda e: e['kind'] == 'tool_started' and e['payload'].get('toolName') == 'Bash',
             'the first sleep', after=crash_receipt)
        # A process that went on with the turn would write to the same transcript as the resumed one.
        death = kill_app(child_deadline=15)
        tool_calls = crashed_turn_tool_calls()
        mark_log()
        launch(direct)
        started_direct(resumes=True)
        time.sleep(15)
        copies = [t for t in user_texts() if 'SHOULD-NOT-FINISH-AFTER-CRASH' in t]
        require(len(copies) == 1, f'The message of the crashed turn is in the transcript {len(copies)} times')
        ask(word('AFTER-CRASH-OK'), 'AFTER-CRASH-OK', 'after-crash')
        copies = [t for t in user_texts() if 'SHOULD-NOT-FINISH-AFTER-CRASH' in t]
        require(len(copies) == 1, f'The message of the crashed turn was sent again: {len(copies)} copies')
        require(crashed_turn_tool_calls() == tool_calls,
                f'The turn went on after the crash: {tool_calls} tool calls then, {crashed_turn_tool_calls()} now')
        step('after a crash during a turn nothing was sent again and the next message ran', childEnded=death,
             toolCallsOfTheCutOffTurn=tool_calls)

    def crashed_turn_tool_calls():
        return sum(1 for r in transcript_records() if r.get('type') == 'assistant'
                   for block in (r.get('message') or {}).get('content') or []
                   if isinstance(block, dict) and block.get('type') == 'tool_use'
                   and 'sleep 4' in json.dumps(block.get('input')))

    # 14. The way back: with the setting off, the same conversation goes on in the terminal.
    def terminal_again():
        kill_app(child_deadline=30)
        mark_log()
        launch(terminal)
        wait_for('Claude Code to be resumed in the terminal',
                 lambda: (s := status()).get('agentState') == 'running' and s.get('sessionID') and s, timeout=180)

        def composer():
            text = screen()
            return text if '❯' in text and ('for shortcuts' in text or 'shift+tab to cycle' in text) else None

        wait_for("Claude Code's composer in the terminal", composer, timeout=180)
        require(not stream_processes(app_pid()) and not log_records('Started a Claude Code process for a direct session'),
                'A direct session started with the setting off')
        sent = cli('coordinator', 'send', word('TERMINAL-OK'))
        wait_for('the reply in the terminal', lambda: any(
            r.get('type') == 'assistant' and 'TERMINAL-OK' in json.dumps((r.get('message') or {}).get('content'))
            for r in transcript_records()), timeout=240, interval=2)
        require(sorted(p.name for p in project.glob('*.jsonl')) == state.get('files'),
                f'The terminal started another conversation: {sorted(p.name for p in project.glob("*.jsonl"))}')
        step('with the setting off the same conversation went on in the terminal', sent=sent, screen=screen()[-600:])

    failures = []

    def brief(listed):
        return [dict(sequence=e['sequence'], kind=e['kind'],
                     **{key: (str(value)[:160] if key == 'text' else value) for key, value in e['payload'].items()
                        if key in ('text', 'clientRequestID', 'deliveryMode', 'toolName', 'id', 'interactionID', 'kind',
                                   'state', 'status')}) for e in listed]

    def recover():
        """After a failed part: stops a running turn, denies the open requests and waits for the prompt, so
        that the next part starts from a known state."""
        try:
            state['deny'] = False
            current = conversation()
            control = (current or {}).get('inputControl') or {}
            if control.get('turnEpoch') and control.get('canInterrupt'):
                gateway.call('POST', '/api/conversation.interrupt', dict(
                    protocolVersion='1.0', conversationID=current['conversationID'],
                    expectedTurnEpoch=control['turnEpoch']))
            settle(timeout=90)
            return 'the prompt is open'
        except Exception as error:  # noqa: BLE001 - the next part reports its own state
            return repr(error)[:400]

    def part(body):
        """Runs one part. A failed part is recorded, and the parts after it still run."""
        name = body.__name__.replace('_', ' ')
        print(f'[coordinator-check] part: {name}', flush=True)
        try:
            body()
        except Exception as error:  # noqa: BLE001 - one part must not hide the others
            failures.append(name)
            facts = dict(error=repr(error)[:2000], trace=traceback.format_exc()[-2500:])
            for key, read in (('status', status), ('conversation', conversation), ('lastEvents', lambda: brief(events()[-30:])),
                              ('processes', lambda: stream_processes(app_pid())), ('recovery', recover)):
                try:
                    facts[key] = read()
                except Exception as inner:  # noqa: BLE001
                    facts[key] = repr(inner)[:300]
            step(f'FAILED: {name}', **facts)

    try:
        # Without a start there is nothing to check.
        start()
        for body in (phone_message, mac_message, idle_wake, busy_turn, steered_turn, stopped_turn, permission_request,
                     question, text_command, compaction, closed_workspace, crash_at_the_prompt, crash_during_a_turn, terminal_again):
            part(body)
        require(not failures, f'Parts that failed: {failures}')
    finally:
        try:
            check.evidence['finalStatus'] = status()
            state['instance'].kill()
        except Exception:  # noqa: BLE001 - keep what there is
            pass
        time.sleep(5)
        # Only the processes that this run's app started. A stopped check must not leave one running.
        left = [pid for pid in sorted(state['pids']) if alive(pid)]
        check.evidence['claudeProcessesLeftAtTheEnd'] = left
        for pid in left:
            try:
                os.kill(pid, 15)
            except OSError:
                pass
        check.copy_instance_log(runtime_home, 'direct')
        steer.set_directory_trust(folder, False)
        if project.is_dir():
            capture = check.artifacts / f'{check.prefix}-transcripts'
            capture.mkdir(exist_ok=True)
            for path in project.glob('*.jsonl'):
                shutil.copyfile(path, capture / path.name)
            # Only the project for this run's unique temporary folder.
            shutil.rmtree(project, ignore_errors=True)


if __name__ == '__main__':
    main()
