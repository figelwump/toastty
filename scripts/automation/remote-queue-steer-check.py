#!/usr/bin/env python3
"""Check real provider input through a paired-device Remote Access gateway.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-queue-steer-check.py --provider claude'.
The default provider is codex. Both checks start and stop their own isolated
Toastty instance from the wrapper's build. They use loopback HTTP and socket
queries, without moving focus or changing the installed production app.

The remote host needs an installed, authenticated provider CLI. Codex uses
its existing profile and a trusted directory under the host user's home.
Claude uses a temporary launch profile, permits only Bash sleep commands,
and trusts only its run-owned temporary working directory. Subscription
usage is consumed. Evidence includes the CLI version and is written to
remote-queue-steer-<provider>.json under the wrapper's artifacts directory.
"""

import argparse
import base64
import hashlib
import json
import os
import re
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=('codex', 'claude'), default='codex')
    provider = parser.parse_args().provider
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    require(binary.is_file(), f'No Toastty binary at {binary}')

    evidence = dict(status='failed', provider=provider, cliVersion=None, steps=[], captures={})
    prefix = f'remote-queue-steer-{provider}'
    root = Path(tempfile.mkdtemp(prefix='toastty-queue-steer-', dir='/tmp')).resolve()
    app = None
    log = None
    work = None
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith('TOASTTY_') or key in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT'):
            del environment[key]
    try:
        runtime_home = root / 'runtime-home'
        (runtime_home / 'remote-access').mkdir(parents=True)

        device = dict(id=str(uuid.uuid4()).upper(), name='Check phone', scopes=['read', 'send'],
                      authKind='native', tailscaleLogin=IDENTITY, createdAt=0)
        credential = dict(credentialHash=hashlib.sha256(TOKEN.encode()).hexdigest(),
                          deviceID=device['id'], issuedAt=0)
        (runtime_home / 'remote-access/devices.json').write_text(json.dumps(dict(
            devices=[device], credentials=[credential], nativePairingFailures=[])))

        user_home = None
        version = None
        if provider == 'claude':
            cli = shutil.which('claude')
            if not cli:
                candidate = Path.home() / '.local/bin/claude'
                cli = str(candidate) if candidate.is_file() else None
            require(cli, 'Claude CLI is not installed; install and authenticate it on the remote host')
            version = subprocess.check_output([cli, '--version'], text=True, timeout=30, env=environment).strip()
            auth = subprocess.run([cli, '--safe-mode', '--setting-sources', '', 'auth', 'status', '--json'],
                                  capture_output=True, text=True, timeout=30, env=environment)
            require(auth.returncode == 0, f'Claude auth status failed with exit {auth.returncode}; check CLI flag support')
            require(json.loads(auth.stdout).get('loggedIn'), 'Claude CLI needs an interactive login on the remote host')
            # Only this disposable app sees the test profile. The CLI keeps the
            # host subscription login; no credential files are copied.
            user_home = root / 'user-home'
            (user_home / '.toastty').mkdir(parents=True)
            argv = [cli, '--setting-sources', '', '--allowedTools', 'Bash(sleep:*)', '--tools', 'Bash', '--strict-mcp-config']
            (user_home / '.toastty/agents.toml').write_text(
                '[claude]\ndisplayName = "Claude Code"\nargv = ' + json.dumps(argv) + '\n')
            work = root / 'work'
            work.mkdir()
            (work / 'README.md').write_text('# Disposable Claude input check\n')

        port = free_port()
        socket_path = str(root / 'socket.sock')
        environment.update(
            TOASTTY_RUNTIME_HOME=str(runtime_home),
            TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
            TOASTTY_RUNTIME_LABEL='remote-queue-steer-check',
            TOASTTY_SOCKET_PATH=socket_path,
        )
        if user_home:
            environment['CFFIXED_USER_HOME'] = str(user_home)
            environment['DISABLE_AUTOUPDATER'] = '1'
        evidence.update(cliVersion=version, gatewayPort=port)
        log = open(artifacts / f'{prefix}-app.log', 'w')
        app = subprocess.Popen(
            [str(binary), '-toastty.remoteAccess.enabled', 'YES', '-toastty.remoteAccess.port', str(port)],
            env=environment, stdout=log, stderr=subprocess.STDOUT)
        if provider == 'claude':
            run_claude(app, Gateway(port), App(bundle, socket_path), runtime_home, work, evidence)
        else:
            evidence['cliVersion'] = subprocess.check_output(['codex', '--version'], text=True, timeout=30).strip()
            run(app, Gateway(port), App(bundle, socket_path), runtime_home, evidence)
        evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - always preserve failure evidence
        evidence['failure'] = repr(error)
        raise
    finally:
        if app is not None:
            app.send_signal(signal.SIGTERM)
            try:
                app.wait(timeout=15)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait(timeout=5)
        if log is not None:
            log.close()
        instance_log = root / 'runtime-home/logs/toastty.log'
        if instance_log.exists():
            shutil.copyfile(instance_log, artifacts / f'{prefix}-instance.log')
        if provider == 'claude' and work is not None:
            project = claude_project_directory(work)
            if project.is_dir():
                capture = artifacts / f'{prefix}-transcripts'
                capture.mkdir(exist_ok=True)
                for path in project.glob('*.jsonl'):
                    shutil.copyfile(path, capture / path.name)
                # Only the project for this run's unique temporary cwd.
                shutil.rmtree(project, ignore_errors=True)
        (artifacts / f'{prefix}.json').write_text(json.dumps(evidence, indent=2, sort_keys=True))
        shutil.rmtree(root, ignore_errors=True)
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
    evidence['launch'] = {key: launch.get(key) for key in ('sessionID', 'panelID', 'cwd')}
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
        evidence['captures']['startup'] = text
        # Codex may open an update prompt first; "Skip until next version"
        # is its third option. The trust prompt would mean the directory is
        # not a trusted project, which this check does not work around.
        if 'Update available' in text:
            if 'update' not in dismissed_dialogs:
                step(evidence, 'update-dialog', terminalText=text)
                dismissed_dialogs.append('update')
                app_socket.run('action', 'terminal.send-text', 'text=3', 'submit=true', panel=panel_id)
            return None
        require('Do you trust' not in text and 'trust this' not in text, f'Codex trust prompt: {text[-600:]}')
        # The composer line starts with › once the TUI is up.
        return text if '›' in text else None

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
    require(steer_echo['payload'].get('origin') == 'remote', f'Steer echo lacks its origin: {steer_echo}')
    steered_reply = find(assistant_containing('STEERED-OK'), 'Codex to act on the steer', 180)[0]
    step(evidence, 'steered-reply', sequence=steered_reply['sequence'], text=steered_reply['payload']['text'][:200])
    require(not any(assistant_containing('ALL-EIGHT-DONE')(e) for e in message_events()),
            'Codex finished the original plan: the steer did not change the running turn')

    queued_echo = find(user_with('queued-1'), 'the queued message to be typed at the next prompt', 120)[0]
    step(evidence, 'queued-echo', payload=queued_echo['payload'], sequence=queued_echo['sequence'])
    require(queued_echo['payload'].get('deliveryMode') == 'queue', f'Queued echo lacks its mode: {queued_echo}')
    require(queued_echo['payload'].get('origin') == 'remote', f'Queue echo lacks its origin: {queued_echo}')
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
    final_echo = find(user_with('after-stop-1'), 'the direct send after Stop to be confirmed', 120)[0]
    require(final_echo['payload'].get('origin') == 'remote', f'Direct echo lacks its origin: {final_echo}')
    find(assistant_containing('AFTER-STOP-OK'), 'Codex to answer after the stop', 120)
    evidence['captures']['final'] = app_socket.visible_text(panel_id)

    audit = json.loads((runtime_home / 'remote-access/audit.json').read_text())
    evidence['auditActions'] = [(entry['action'], entry.get('detail')) for entry in audit]
    require(('remote_send_queued', None) in evidence['auditActions'], 'No queued audit entry')
    require(('remote_interrupt_accepted', None) in evidence['auditActions'], 'No interrupt audit entry')
    require(all(marker not in json.dumps(audit) for marker in ('STEERED', 'QUEUED-OK')),
            'The audit log holds message text')


def claude_project_directory(work):
    return Path.home() / '.claude/projects' / re.sub(r'[^A-Za-z0-9]', '-', str(work))


def claude_content_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(block['text'] for block in content
                         if isinstance(block, dict) and block.get('type') == 'text'
                         and isinstance(block.get('text'), str))
    return ''


def run_claude(app, gateway, app_socket, runtime_home, work, evidence):
    """Exercise real Claude transcript receipts, including its dequeue path."""
    wait_for('the check instance', lambda: (runtime_home / 'instance.json').is_file())
    wait_for('the check socket', lambda: os.path.exists(app_socket.socket_path))
    require(app.poll() is None, 'The check instance exited')
    def gateway_ready():
        try:
            return gateway.call('GET', '/api/hello', token=None)[0] == 200
        except (urllib.error.URLError, ConnectionError):
            return False
    wait_for('the gateway', gateway_ready)
    profile = app_socket.run('query', 'agent.profile.state', 'profileID=claude')
    require(profile.get('resolved'), f'Claude profile is not resolvable: {profile}')
    _, sessions = gateway.call('GET', '/api/sessions')
    workspace_id = sessions['snapshot']['workspaces'][0]['id']

    def launch_when_ready():
        try:
            return app_socket.run('action', 'agent.launch', 'profileID=claude', f'cwd={work}',
                                  workspace=workspace_id)
        except AssertionError as error:
            if 'interactive prompt' in str(error):
                return None
            raise

    launch = wait_for('the terminal to launch Claude', launch_when_ready, timeout=60)
    panel_id = launch['panelID']
    evidence['launch'] = {key: launch.get(key) for key in ('sessionID', 'panelID', 'cwd')}
    trusted = False

    def composer():
        nonlocal trusted
        text = app_socket.visible_text(panel_id)
        require('sign in' not in text.lower() and '/login' not in text.lower(),
                'Claude needs an interactive subscription login')
        # Trust only this run-owned temporary directory, never another project.
        if 'trust' in text.lower() and 'folder' in text.lower() and not trusted:
            require(str(work) in text, f'Unexpected trust target: {text[-600:]}')
            app_socket.run('action', 'terminal.send-text', 'text=1', 'submit=true', panel=panel_id)
            trusted = True
            return None
        return text if '❯' in text and ('shortcuts' in text or 'Claude Code' in text) else None

    wait_for('the Claude composer', composer, timeout=90)
    app_socket.run('action', 'terminal.send-text', f'text={BUSY_PROMPT}', 'submit=true', panel=panel_id)

    def listed():
        _, body = gateway.call('GET', '/api/sessions')
        return next((c for c in body['snapshot']['conversations']
                     if c['provider'] == 'claude' and c['placement'].get('panelID') == panel_id), None)

    conversation = wait_for('the Claude conversation', listed, timeout=60)
    conversation_id = conversation['conversationID']
    evidence['conversationID'] = conversation_id

    def events():
        return gateway.events(conversation_id)[0]

    def find(predicate, description, timeout=150):
        try:
            return wait_for(description, lambda: next((e for e in events() if predicate(e)), None),
                            timeout=timeout, interval=0.2)
        except AssertionError:
            evidence['lastEvents'] = events()[-20:]
            evidence['captures']['failed'] = app_socket.visible_text(panel_id)
            raise

    def receipt(request_id, mode):
        event = find(lambda e: e['kind'] == 'user_message'
                     and e['payload'].get('clientRequestID') == request_id, f'{request_id} receipt')
        require(event['payload'].get('origin') == 'remote', f'Unstamped receipt: {event}')
        require(event['payload'].get('deliveryMode') == mode, f'Incorrect delivery mode: {event}')
        step(evidence, 'confirmed', requestID=request_id, payload=event['payload'], sequence=event['sequence'])
        return event

    def reply(marker):
        return find(lambda e: e['kind'] == 'assistant_message' and marker in e['payload'].get('text', ''),
                    f'Claude reply {marker}')

    def prompt():
        current = gateway.conversation(conversation_id)
        return current if current and current['inputAvailability'].get('kind') == 'open_prompt' else None

    def send(request_id, text, mode='prompt', epoch=None):
        if epoch is None:
            epoch = wait_for('an open Claude prompt', prompt, timeout=120)['inputAvailability']['epoch']
        status, result = gateway.call('POST', '/api/conversation.message.send', dict(
            conversationID=conversation_id, clientRequestID=request_id, deliveryMode=mode,
            expectedInputEpoch=epoch, text=text))
        require(status == 200, f'Send failed: {status} {result}')
        require(result.get('status') == ('queued' if mode == 'queue' else 'accepted'),
                f'Send rejected: {result}')
        step(evidence, 'send', requestID=request_id, mode=mode, result=result)

    def working():
        current = gateway.conversation(conversation_id)
        return current if ((current or {}).get('inputControl') or {}).get('canSteer') else None

    # An actual Bash call proves this lands inside a tool window, rather than
    # merely while the host summary still says working.
    find(lambda e: e['kind'] == 'tool_started' and e['payload'].get('toolName') == 'Bash',
         'Claude to start its sleep tool')
    busy = wait_for('Claude steer availability', working)
    turn_epoch = busy['inputControl']['turnEpoch']
    send('queued-1', QUEUED_TEXT, 'queue', turn_epoch)
    send('steer-1', STEER_TEXT, 'steer', turn_epoch)
    receipt('steer-1', 'steer')
    steered_reply = reply('STEERED-OK')
    queued_echo = receipt('queued-1', 'queue')
    require(queued_echo['sequence'] > steered_reply['sequence'], 'Queue was delivered during the steered turn')
    reply('QUEUED-OK')
    send('direct-1', 'Reply with exactly: DIRECT-OK')
    receipt('direct-1', None)
    reply('DIRECT-OK')

    # No tool follows this boundary. Claude must dequeue a steer into an
    # ordinary next user turn. Long final output gives the gateway a window.
    before = max(e['sequence'] for e in events())
    late_prompt = ('Run Bash `sleep 4` exactly once. Then use no more tools. '
                   'Print a numbered list of 400 separate lines, each with the word complete. '
                   'Do not abbreviate the list. End with FINAL-END.')
    send('late-busy', late_prompt)
    receipt('late-busy', None)
    find(lambda e: e['sequence'] > before and e['kind'] == 'tool_finished', 'the last tool boundary')
    busy = wait_for('the final Claude generation to still allow steer', working, timeout=10, interval=0.1)
    late_text = 'After the current answer, reply with exactly: LATE-STEER-OK'
    send('late-steer', late_text, 'steer', busy['inputControl']['turnEpoch'])
    receipt('late-steer', 'steer')
    late_reply = reply('LATE-STEER-OK')
    final_reply = reply('FINAL-END')
    require(late_reply['sequence'] > final_reply['sequence'], 'Late steer answered before the first turn ended')
    wait_for('the final Claude prompt', prompt, timeout=120)

    # Read only the transcript for the run-owned directory, never unrelated
    # host sessions. Capture structural proof of both provider delivery paths.
    project = claude_project_directory(work)
    files = sorted(project.glob('*.jsonl'))
    require(files, f'No Claude transcript for the test working directory: {project}')
    records = []
    for path in files:
        for line in path.read_text().splitlines():
            record = json.loads(line)
            require(record.get('cwd', str(work)) == str(work), 'Transcript belongs to another working directory')
            records.append(record)
    attachments = [r['attachment'] for r in records if r.get('type') == 'attachment'
                   and r.get('attachment', {}).get('type') == 'queued_command']
    require(sum(a.get('prompt') == STEER_TEXT for a in attachments) == 1,
            'Live steer did not produce one queued_command attachment')
    ordinary = [claude_content_text(r['message'].get('content')) for r in records if r.get('type') == 'user']
    require(not any(STEER_TEXT in text for text in ordinary), 'Mid-turn steer also produced an ordinary user record')
    require(sum(text == late_text for text in ordinary) == 1,
            'Late steer did not exercise the ordinary user-record path')
    require(not any(a.get('prompt') == late_text for a in attachments),
            'Late steer was absorbed mid-turn; required end-of-turn path was not exercised')
    require(any(r.get('type') == 'queue-operation' and r.get('operation') == 'dequeue'
                and r.get('content') == late_text for r in records), 'No late-steer dequeue record')
    require(ordinary.count(QUEUED_TEXT) == 1 and not any(a.get('prompt') == QUEUED_TEXT for a in attachments),
            'Queued input must start an ordinary next user turn')
    evidence['midTurnCommand'] = next(a for a in attachments if a.get('prompt') == STEER_TEXT)
    evidence['endOfTurnDequeue'] = next(r for r in records if r.get('type') == 'queue-operation'
                                     and r.get('operation') == 'dequeue' and r.get('content') == late_text)
    final_events = events()
    for request_id in ('steer-1', 'queued-1', 'direct-1', 'late-busy', 'late-steer'):
        require(sum(e['kind'] == 'user_message' and e['payload'].get('clientRequestID') == request_id
                    for e in final_events) == 1, f'Duplicate or missing receipt for {request_id}')
    require(not any(e['kind'] == 'send_delivery_unconfirmed' for e in final_events),
            'The live session emitted an unconfirmed send')
    evidence['captures']['final'] = app_socket.visible_text(panel_id)


if __name__ == '__main__':
    main()
