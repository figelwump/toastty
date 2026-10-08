#!/usr/bin/env python3
"""Queue, steer, and stop a real Codex turn through the Remote Access gateway.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-queue-steer-check.py'.

The wrapper builds Toastty and exports TOASTTY_APP_BUNDLE. Like the session
start check, this starts its own second instance of that build so Remote
Access and a paired device exist before launch. Unlike it, this check starts
the real Codex CLI from the host user's own configuration, through the
gateway's session start so the first prompt runs at once, because the point is
to verify what the live provider does with text typed into a running turn and
with the interrupt key. The check acts as a paired phone over HTTP and reads
the terminal through the app's automation socket. It never moves focus. It
stops its own instance; the wrapper owns everything else.

Needs a working `codex` login on the remote host, and the workspace's working
directory (the host user's home) must be a trusted Codex project, or Codex
blocks on its trust prompt. Evidence goes to remote-queue-steer.json under the
run's artifacts directory.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

TIMEOUT = 30
IDENTITY = 'remote-queue-steer-check@example.com'
TOKEN = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('=')

# A turn long enough to queue, steer, and stop into, made of short shell
# calls so a steer is read between them.
BUSY_PROMPT = (
    'Use your shell tool to run `sleep 4` eight separate times, one tool call per sleep. '
    'After each call, print only the iteration number. Do not combine the sleeps and do not stop early. '
    'When all eight are done, reply with exactly: ALL-EIGHT-DONE'
)
STEER_TEXT = 'Change of plan: stop after the current sleep and reply with exactly: STEERED-OK'
QUEUED_TEXT = 'Reply with exactly: QUEUED-OK'
STOP_PROMPT = (
    'Use your shell tool to run `sleep 4` thirty separate times, one tool call per sleep, '
    'printing the iteration number after each. Do not stop early.'
)
AFTER_STOP_TEXT = 'Reply with exactly: AFTER-STOP-OK'


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def wait_for(description, probe, timeout=TIMEOUT, interval=0.5):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = probe()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError(f'Timed out waiting for {description}; last value: {last!r}')


def free_port():
    import socket
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


class Gateway:
    def __init__(self, port):
        self.base = f'http://127.0.0.1:{port}'

    def call(self, method, path, body=None, token=TOKEN):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header('Accept', 'application/json')
        if data is not None:
            request.add_header('Content-Type', 'application/json')
        if token is not None:
            request.add_header('Authorization', f'Bearer {token}')
            request.add_header('Tailscale-User-Login', IDENTITY)
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                return response.status, json.loads(response.read() or b'null')
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read() or b'null')

    def conversation(self, conversation_id):
        status, body = self.call('GET', '/api/sessions')
        require(status == 200, f'Session list failed: {status} {body}')
        return next((c for c in body['snapshot']['conversations']
                     if c['conversationID'] == conversation_id), None)

    def events(self, conversation_id, after=None):
        """Every event after the cursor, following the page chain."""
        cursor = after
        collected = []
        while True:
            body = dict(protocolVersion='1.0', conversationID=conversation_id, limit=200)
            if cursor:
                body['cursor'] = cursor
            status, page = self.call('POST', '/api/conversation.events.get', body)
            require(status == 200, f'Events failed: {status} {page}')
            if page.get('outcome') != 'page':
                evidence_note = dict(outcome=page.get('outcome'), cursor=cursor)
                self.last_non_page = evidence_note
                return collected, cursor
            events = page['page']['events']
            collected.extend(events)
            if not events:
                return collected, cursor
            cursor = dict(projectionRunID=page['page']['projectionRunID'],
                          projectionGeneration=page['page']['projectionGeneration'],
                          afterSequence=page['page']['latestSequence'])
            if len(events) < 200:
                return collected, cursor


class App:
    def __init__(self, bundle, socket_path):
        self.cli = bundle / 'Contents/Helpers/toastty'
        self.socket_path = socket_path

    def run(self, kind, command_id, *args, workspace=None, panel=None):
        argv = [str(self.cli), '--json', '--socket-path', self.socket_path, kind, 'run', command_id]
        if workspace:
            argv += ['--workspace', workspace]
        if panel:
            argv += ['--panel', panel]
        argv += list(args)
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        require(completed.returncode == 0, f'{command_id} failed: {completed.stdout} {completed.stderr}')
        response = json.loads(completed.stdout)
        require(response.get('ok'), f'{command_id} failed: {response}')
        return response['result']

    def visible_text(self, panel_id):
        try:
            return self.run('query', 'terminal.visible-text', panel=panel_id).get('text', '')
        except AssertionError as error:
            return f'<unavailable: {error}>'


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    require(binary.is_file(), f'No Toastty binary at {binary}')

    root = Path(tempfile.mkdtemp(prefix='toastty-queue-steer-')).resolve()
    runtime_home = root / 'runtime-home'
    (runtime_home / 'remote-access').mkdir(parents=True)

    device = dict(id=str(uuid.uuid4()).upper(), name='Check phone', scopes=['read', 'send'],
                  authKind='native', tailscaleLogin=IDENTITY, createdAt=0)
    credential = dict(credentialHash=hashlib.sha256(TOKEN.encode()).hexdigest(),
                      deviceID=device['id'], issuedAt=0)
    (runtime_home / 'remote-access/devices.json').write_text(json.dumps(dict(
        devices=[device], credentials=[credential], nativePairingFailures=[])))

    port = free_port()
    socket_path = f'/tmp/toastty-qs-{os.getpid()}.sock'
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith('TOASTTY_'):
            del environment[key]
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-queue-steer-check',
        TOASTTY_SOCKET_PATH=socket_path,
    )
    evidence = dict(status='failed', gatewayPort=port, steps=[], captures={})
    log = open(artifacts / 'remote-queue-steer-app.log', 'w')
    app = subprocess.Popen(
        [str(binary), '-toastty.remoteAccess.enabled', 'YES', '-toastty.remoteAccess.port', str(port)],
        env=environment, stdout=log, stderr=subprocess.STDOUT)
    try:
        run(app, Gateway(port), App(bundle, socket_path), runtime_home, evidence)
        evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - the evidence file must say what failed
        evidence['failure'] = repr(error)
        raise
    finally:
        (artifacts / 'remote-queue-steer.json').write_text(json.dumps(evidence, indent=2, sort_keys=True))
        instance_log = runtime_home / 'logs' / 'toastty.log'
        if instance_log.exists():
            shutil.copyfile(instance_log, artifacts / 'remote-queue-steer-instance.log')
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(timeout=15)
        except subprocess.TimeoutExpired:
            app.kill()
        log.close()
        if os.path.exists(socket_path):
            os.unlink(socket_path)
    print(json.dumps(evidence, indent=2, sort_keys=True))


def step(evidence, name, **facts):
    facts['at'] = round(time.time(), 3)
    facts['step'] = name
    evidence['steps'].append(facts)
    print(json.dumps(facts, sort_keys=True), flush=True)


def run(app, gateway, app_socket, runtime_home, evidence):
    def instance_ready():
        require(app.poll() is None, 'The check instance exited during startup')
        path = runtime_home / 'instance.json'
        return json.loads(path.read_text()) if path.is_file() else None

    wait_for('instance.json', instance_ready)
    wait_for('the automation socket', lambda: os.path.exists(app_socket.socket_path))

    def hello():
        try:
            status, body = gateway.call('GET', '/api/hello', token=None)
        except (urllib.error.URLError, ConnectionError):
            return None
        return body if status == 200 else None

    capabilities = wait_for('the gateway', hello)['capabilities']
    require('conversation_input_control' in capabilities, f'No input control capability: {capabilities}')
    evidence['capabilities'] = capabilities

    profile = app_socket.run('query', 'agent.profile.state', 'profileID=codex')
    evidence['codexProfile'] = profile
    require(profile.get('resolved'), f'Codex is not resolvable on this host: {profile}')

    status, sessions = gateway.call('GET', '/api/sessions')
    require(status == 200, f'Session list failed: {status} {sessions}')
    workspace_id = sessions['snapshot']['workspaces'][0]['id']

    # 1. Launch Codex in a fresh directory under the host user's home, which
    #    is a trusted Codex project there, then type the first prompt into
    #    its composer through the automation socket. (The gateway's session
    #    start needs a bare `codex` profile, which this host does not have.)
    work = Path.home() / 'toastty-queue-steer-checks' / uuid.uuid4().hex[:8]
    work.mkdir(parents=True)
    (work / 'README.md').write_text('# queue steer check\n')
    def launched():
        # The bootstrap terminal's shell can still be starting; the launch
        # refuses a panel that is not yet at an interactive prompt.
        try:
            return app_socket.run('action', 'agent.launch', 'profileID=codex', f'cwd={work}', workspace=workspace_id)
        except AssertionError as error:
            if 'interactive prompt' in str(error):
                return None
            raise

    launch = wait_for('a terminal at an interactive prompt to launch Codex in', launched, timeout=60, interval=1)
    evidence['launch'] = {key: launch.get(key) for key in ('sessionID', 'panelID', 'cwd', 'command')}
    step(evidence, 'launched', sessionID=launch.get('sessionID'))
    panel_id = launch['panelID']

    def listed():
        _, body = gateway.call('GET', '/api/sessions')
        return next((c for c in body['snapshot']['conversations']
                     if c['provider'] == 'codex' and c['placement'].get('panelID') == panel_id), None)

    conversation = wait_for('the Codex conversation', listed, timeout=60)
    conversation_id = conversation['conversationID']
    evidence['conversationID'] = conversation_id

    dismissed_dialogs = []

    def composer_ready():
        text = app_socket.visible_text(panel_id)
        # Codex may open an update prompt first; "Skip until next version"
        # is its third option. The trust prompt would mean the directory is
        # not a trusted project, which this check does not work around.
        if 'Update available' in text:
            if 'update' not in dismissed_dialogs:
                dismissed_dialogs.append('update')
                app_socket.run('action', 'terminal.send-text', 'text=3', 'submit=true', panel=panel_id)
            return None
        require('Do you trust' not in text and 'trust this' not in text, f'Codex trust prompt: {text[-600:]}')
        # The composer line starts with › once the TUI is up.
        return text if '›' in text and 'shortcuts' in text else None

    wait_for("Codex's composer", composer_ready, timeout=120)
    evidence['dismissedDialogs'] = dismissed_dialogs
    time.sleep(3)
    evidence['captures']['idle'] = app_socket.visible_text(panel_id)
    app_socket.run('action', 'terminal.send-text', f'text={BUSY_PROMPT}', 'submit=true', panel=panel_id)
    step(evidence, 'busy-send', via='terminal.send-text')

    def prompt_open():
        current = gateway.conversation(conversation_id)
        return current if current and current['inputAvailability'].get('kind') == 'open_prompt' else None

    def working():
        current = gateway.conversation(conversation_id)
        control = (current or {}).get('inputControl') or {}
        return current if control.get('turnEpoch') and control.get('canSteer') else None

    busy = wait_for('the turn to run with steer available', working, timeout=150)
    turn_epoch = busy['inputControl']['turnEpoch']
    step(evidence, 'working', inputControl=busy['inputControl'], state=busy['state'])
    require(busy['inputControl']['canInterrupt'], f'Expected canInterrupt while working: {busy}')
    # Give the model time to make its first tool call so the steer lands mid-turn.
    time.sleep(8)
    evidence['captures']['working'] = app_socket.visible_text(panel_id)

    # 2. Queue one message and steer another into the running turn.
    _, queued = gateway.call('POST', '/api/conversation.message.send', dict(
        conversationID=conversation_id, clientRequestID='queued-1', deliveryMode='queue',
        expectedInputEpoch=turn_epoch, text=QUEUED_TEXT))
    step(evidence, 'queue-send', result=queued)
    require(queued == dict(status='queued', position=1), f'Queue was not accepted: {queued}')
    listed_queue = gateway.conversation(conversation_id)['inputControl'].get('queuedMessages', [])
    require([m['clientRequestID'] for m in listed_queue] == ['queued-1'], f'Queue not listed: {listed_queue}')

    _, steered = gateway.call('POST', '/api/conversation.message.send', dict(
        conversationID=conversation_id, clientRequestID='steer-1', deliveryMode='steer',
        expectedInputEpoch=turn_epoch, text=STEER_TEXT))
    step(evidence, 'steer-send', result=steered)
    require(steered.get('status') == 'accepted', f'Steer was not accepted: {steered}')
    time.sleep(3)
    evidence['captures']['after-steer'] = app_socket.visible_text(panel_id)

    # 3. The provider reads the steer mid-turn and the queued message is
    #    typed only after the turn ends, each echoed with its request ID.
    def message_events():
        events, _ = gateway.events(conversation_id)
        return [e for e in events if e['kind'] in ('user_message', 'assistant_message', 'status_changed')]

    def find(predicate, description, timeout):
        def probe():
            matches = [e for e in message_events() if predicate(e)]
            return matches or None
        try:
            return wait_for(description, probe, timeout=timeout)
        except AssertionError:
            # Keep what the transcript did show so a failed wait is diagnosable.
            evidence['lastMessageEvents'] = [
                dict(kind=e['kind'], sequence=e.get('sequence'), payload=e.get('payload'))
                for e in message_events()[-20:]]
            evidence['lastNonPageOutcome'] = getattr(gateway, 'last_non_page', None)
            raise

    def user_with(request_id):
        return lambda e: e['kind'] == 'user_message' and e['payload'].get('clientRequestID') == request_id

    def assistant_containing(marker):
        return lambda e: e['kind'] == 'assistant_message' and marker in e['payload'].get('text', '')

    steer_echo = find(user_with('steer-1'), 'the steer echo in the transcript', 120)[0]
    step(evidence, 'steer-echo', payload=steer_echo['payload'], sequence=steer_echo['sequence'])
    require(steer_echo['payload'].get('deliveryMode') == 'steer', f'Steer echo lacks its mode: {steer_echo}')
    steered_reply = find(assistant_containing('STEERED-OK'), 'Codex to act on the steer', 180)[0]
    step(evidence, 'steered-reply', sequence=steered_reply['sequence'], text=steered_reply['payload']['text'][:200])
    require(not any(assistant_containing('ALL-EIGHT-DONE')(e) for e in message_events()),
            'Codex finished the original plan: the steer did not change the running turn')

    queued_echo = find(user_with('queued-1'), 'the queued message to be typed at the next prompt', 120)[0]
    step(evidence, 'queued-echo', payload=queued_echo['payload'], sequence=queued_echo['sequence'])
    require(queued_echo['payload'].get('deliveryMode') == 'queue', f'Queued echo lacks its mode: {queued_echo}')
    require(queued_echo['sequence'] > steered_reply['sequence'],
            'The queued message was typed before the steered turn finished')
    queued_reply = find(assistant_containing('QUEUED-OK'), 'Codex to answer the queued message', 180)[0]
    step(evidence, 'queued-reply', sequence=queued_reply['sequence'])
    wait_for('the queue to empty', lambda: not gateway.conversation(conversation_id)['inputControl'].get('queuedMessages'))
    evidence['captures']['after-queue'] = app_socket.visible_text(panel_id)

    # 4. Stop a turn from the phone and send again at the reopened prompt.
    reopened = wait_for('the prompt after the queued turn', prompt_open, timeout=120)
    _, stop_started = gateway.call('POST', '/api/conversation.message.send', dict(
        conversationID=conversation_id, clientRequestID='busy-2',
        expectedInputEpoch=reopened['inputAvailability']['epoch'], text=STOP_PROMPT))
    require(stop_started.get('status') == 'accepted', f'The second busy prompt was not accepted: {stop_started}')
    busy_again = wait_for('the second turn to run', working, timeout=90)
    second_turn = busy_again['inputControl']['turnEpoch']
    time.sleep(8)
    _, wrong_turn = gateway.call('POST', '/api/conversation.interrupt', dict(
        protocolVersion='1.0', conversationID=conversation_id,
        expectedTurnEpoch=dict(second_turn, counter=second_turn['counter'] + 1)))
    require(wrong_turn['result'] == dict(status='rejected', reason='turn_mismatch'), f'Unexpected: {wrong_turn}')
    _, stopped = gateway.call('POST', '/api/conversation.interrupt', dict(
        protocolVersion='1.0', conversationID=conversation_id, expectedTurnEpoch=second_turn))
    step(evidence, 'interrupt', result=stopped)
    require(stopped['result'] == dict(status='accepted'), f'Interrupt was not accepted: {stopped}')

    def interrupted_or_open():
        current = gateway.conversation(conversation_id)
        if not current:
            return None
        kind = current['inputAvailability'].get('kind')
        if current['state'] == 'interrupted' or kind == 'open_prompt':
            return current
        return None

    after_stop = wait_for('the provider to report the aborted turn', interrupted_or_open, timeout=60)
    step(evidence, 'after-interrupt', state=after_stop['state'], inputAvailability=after_stop['inputAvailability'])
    evidence['captures']['after-interrupt'] = app_socket.visible_text(panel_id)
    reopened_after_stop = wait_for('the prompt to reopen after the stop', prompt_open, timeout=60)
    require(not any(assistant_containing('iteration 30')(e) for e in message_events()),
            'Codex ran the whole stopped plan')
    _, final = gateway.call('POST', '/api/conversation.message.send', dict(
        conversationID=conversation_id, clientRequestID='after-stop-1',
        expectedInputEpoch=reopened_after_stop['inputAvailability']['epoch'], text=AFTER_STOP_TEXT))
    step(evidence, 'send-after-stop', result=final)
    require(final.get('status') == 'accepted', f'Send after stop was not accepted: {final}')
    find(assistant_containing('AFTER-STOP-OK'), 'Codex to answer after the stop', 120)
    evidence['captures']['final'] = app_socket.visible_text(panel_id)

    audit = json.loads((runtime_home / 'remote-access/audit.json').read_text())
    evidence['auditActions'] = [(entry['action'], entry.get('detail')) for entry in audit]
    require(('remote_send_queued', None) in evidence['auditActions'], 'No queued audit entry')
    require(('remote_interrupt_accepted', None) in evidence['auditActions'], 'No interrupt audit entry')
    require(all(marker not in json.dumps(audit) for marker in ('STEERED', 'QUEUED-OK')),
            'The audit log holds message text')


if __name__ == '__main__':
    main()
