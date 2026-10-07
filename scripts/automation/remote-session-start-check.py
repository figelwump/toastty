#!/usr/bin/env python3
"""Start an agent session through the Remote Access gateway of a disposable app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-session-start-check.py'.

The wrapper builds Toastty and exports TOASTTY_APP_BUNDLE. This check starts
its own second instance of that build, because Remote Access and the paired
device must exist before the app launches. That instance uses a throwaway
runtime home, a throwaway user home (so `agents.toml` names a fake `claude`
command instead of a real agent), and a loopback gateway port. The check then
acts as a paired phone over HTTP and reads the result through the app's
automation socket. It never selects a workspace or tab and never moves focus.
The check stops its own instance; the wrapper owns everything else.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

TIMEOUT = 30
IDENTITY = 'remote-start-check@example.com'


def credential_token():
    """The gateway accepts only 32 random bytes as unpadded base64url."""
    return base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('=')


ALLOWED_TOKEN = credential_token()
DISABLED_TOKEN = credential_token()
MESSAGE = '--help fix the flaky test'

FAKE_AGENT = '''#!/bin/sh
# Stands in for the Claude CLI. A version or plugin probe answers and exits;
# a session launch records its arguments and stays running.
case "$1" in
  --version) echo "2.1.288 (Claude Code)"; exit 0 ;;
  plugin|mcp|config) exit 0 ;;
esac
printf '%s\\n' "$@" > "$(dirname "$0")/claude-argv.txt"
exec sleep 300
'''


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def wait_for(description, probe, timeout=TIMEOUT, interval=0.2):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = probe()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError(f'Timed out waiting for {description}; last value: {last!r}')


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def device(name, token, start_disabled):
    record = dict(id=str(uuid.uuid4()).upper(), name=name, scopes=['read', 'send'],
                  authKind='native', tailscaleLogin=IDENTITY, createdAt=0)
    if start_disabled:
        record['sessionStartDisabled'] = True
    credential = dict(credentialHash=hashlib.sha256(token.encode()).hexdigest(),
                      deviceID=record['id'], issuedAt=0)
    return record, credential


class Gateway:
    def __init__(self, port):
        self.base = f'http://127.0.0.1:{port}'

    def call(self, method, path, token=None, body=None):
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


class AppSocket:
    def __init__(self, path):
        self.path = path

    def query(self, query_id, **args):
        request_id = str(uuid.uuid4())
        envelope = dict(protocolVersion='1.0', kind='request', requestID=request_id,
                        command='app_control.run_query', payload=dict(id=query_id, args=args))
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(10)
            connection.connect(self.path)
            connection.sendall(json.dumps(envelope).encode() + b'\n')
            data = b''
            while b'\n' not in data:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                data += chunk
        response = json.loads(data)
        require(response.get('ok'), f'{query_id} failed: {response}')
        return response['result']

    def selection(self, workspace_id):
        snapshot = self.query('workspace.snapshot', workspaceID=workspace_id)
        return {key: snapshot[key] for key in ('selectedTabID', 'focusedPanelID', 'tabIDs')}


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    require(binary.is_file(), f'No Toastty binary at {binary}')

    root = Path(tempfile.mkdtemp(prefix='toastty-remote-start-')).resolve()
    runtime_home = root / 'runtime-home'
    user_home = root / 'user-home'
    fake_bin = root / 'bin'
    for directory in (runtime_home / 'remote-access', user_home / '.toastty', fake_bin):
        directory.mkdir(parents=True)
    fake_agent = fake_bin / 'claude'
    fake_agent.write_text(FAKE_AGENT)
    fake_agent.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = ["{fake_agent}"]\n')

    allowed, allowed_credential = device('Allowed phone', ALLOWED_TOKEN, False)
    disabled, disabled_credential = device('Start-disabled phone', DISABLED_TOKEN, True)
    (runtime_home / 'remote-access/devices.json').write_text(json.dumps(dict(
        devices=[allowed, disabled], credentials=[allowed_credential, disabled_credential],
        nativePairingFailures=[])))

    port = free_port()
    socket_path = f'/tmp/toastty-rs-{os.getpid()}.sock'
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith('TOASTTY_'):
            del environment[key]
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-session-start-check',
        TOASTTY_SOCKET_PATH=socket_path,
        # Moves `~/.toastty/agents.toml` to the throwaway home.
        CFFIXED_USER_HOME=str(user_home),
    )
    evidence = dict(status='failed', gatewayPort=port, message=MESSAGE)
    log = open(artifacts / 'remote-session-start-app.log', 'w')
    # The argument domain turns Remote Access on without writing preferences.
    app = subprocess.Popen(
        [str(binary), '-toastty.remoteAccess.enabled', 'YES', '-toastty.remoteAccess.port', str(port)],
        env=environment, stdout=log, stderr=subprocess.STDOUT)
    try:
        run(app, Gateway(port), AppSocket(socket_path), runtime_home, fake_bin, allowed, evidence)
        evidence['status'] = 'passed'
    finally:
        (artifacts / 'remote-session-start.json').write_text(json.dumps(evidence, indent=2, sort_keys=True))
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()
        log.close()
        if os.path.exists(socket_path):
            os.unlink(socket_path)
    print(json.dumps(evidence, indent=2, sort_keys=True))


def run(app, gateway, app_socket, runtime_home, fake_bin, allowed, evidence):
    def instance_ready():
        require(app.poll() is None, 'The check instance exited during startup')
        path = runtime_home / 'instance.json'
        return json.loads(path.read_text()) if path.is_file() else None

    instance = wait_for('instance.json', instance_ready)
    require(instance['pid'] == app.pid, 'instance.json names a different process')
    wait_for('the automation socket', lambda: os.path.exists(app_socket.path))

    def hello():
        try:
            status, body = gateway.call('GET', '/api/hello')
        except (urllib.error.URLError, ConnectionError):
            return None
        return body if status == 200 else None

    capabilities = wait_for('the gateway', hello)['capabilities']
    require('session_start' in capabilities, f'Gateway does not advertise session_start: {capabilities}')

    status, sessions = gateway.call('GET', '/api/sessions', ALLOWED_TOKEN)
    require(status == 200, f'Session list failed: {status} {sessions}')
    workspace_id = sessions['snapshot']['workspaces'][0]['id']
    require(sessions['snapshot']['conversations'] == [], 'Expected no sessions before the start')

    status, options = gateway.call('POST', '/api/session.start.options', ALLOWED_TOKEN,
                                   dict(protocolVersion='1.0', workspaceID=workspace_id))
    require(status == 200, f'Options failed: {status} {options}')
    evidence['options'] = options
    require(options['permission'] == 'allowed', 'A paired device should be allowed by default')
    require(options['workspace'] == 'available', f'Workspace not available: {options}')
    agent = next(agent for agent in options['agents'] if agent['profileID'] == 'claude')
    require(agent['availability'] == 'available', f'Fake agent not available: {agent}')
    require('high' in agent['reasoningEfforts'], f'No effort choices: {agent}')

    _, disabled_options = gateway.call('POST', '/api/session.start.options', DISABLED_TOKEN,
                                       dict(protocolVersion='1.0', workspaceID=workspace_id))
    require(disabled_options['permission'] == 'start_disabled', f'Unexpected: {disabled_options}')

    before = app_socket.selection(workspace_id)
    evidence['selectionBefore'] = before
    start = dict(protocolVersion='1.0', clientRequestID=str(uuid.uuid4()), workspaceID=workspace_id,
                 profileID='claude', model='claude-check-model', reasoningEffort='high', text=MESSAGE)

    status, refused = gateway.call('POST', '/api/session.start', DISABLED_TOKEN,
                                   dict(start, clientRequestID=str(uuid.uuid4())))
    require(status == 200 and refused == dict(protocolVersion='1.0', status='rejected',
                                              reason='permission_denied'), f'Unexpected: {status} {refused}')
    require(app_socket.selection(workspace_id) == before, 'A refused start changed the workspace')

    started_at = time.time()
    status, started = gateway.call('POST', '/api/session.start', ALLOWED_TOKEN, start)
    evidence['startResponse'] = started
    evidence['startSeconds'] = round(time.time() - started_at, 2)
    require(status == 200 and started.get('status') == 'started', f'Start failed: {status} {started}')
    conversation_id = started['conversationID']

    # The agent runs in a new tab; the visible tab and focus are untouched.
    after = app_socket.selection(workspace_id)
    evidence['selectionAfter'] = after
    require(len(after['tabIDs']) == len(before['tabIDs']) + 1, f'Expected one new tab: {after}')
    require(after['tabIDs'][:-1] == before['tabIDs'], 'Existing tabs changed')
    require(after['selectedTabID'] == before['selectedTabID'], 'The selected tab changed')
    require(after['focusedPanelID'] == before['focusedPanelID'], 'The focused panel changed')

    # The real terminal ran the command with the choices and the message.
    argv_file = fake_bin / 'claude-argv.txt'
    argv = wait_for('the agent command to run', lambda: argv_file.read_text().splitlines()
                    if argv_file.is_file() else None)
    evidence['agentArguments'] = argv
    require(argv[-2:] == ['--', MESSAGE], f'The message was not passed as text: {argv}')
    require(argv[argv.index('--model') + 1] == 'claude-check-model', f'Model missing: {argv}')
    require(argv[argv.index('--effort') + 1] == 'high', f'Effort missing: {argv}')

    # The phone's session list shows the conversation under the returned ID.
    def listed():
        _, body = gateway.call('GET', '/api/sessions', ALLOWED_TOKEN)
        return next((c for c in body['snapshot']['conversations']
                     if c['conversationID'] == conversation_id), None)

    conversation = wait_for('the conversation in the session list', listed)
    evidence['listedConversation'] = {key: conversation.get(key) for key in
                                      ('conversationID', 'provider', 'placement', 'cwd', 'state')}
    require(conversation['provider'] == 'claude', f'Unexpected provider: {conversation}')
    require(conversation['placement']['workspaceID'] == workspace_id, 'Listed in another workspace')
    require(conversation['placement']['workspaceTabID'] == after['tabIDs'][-1], 'Listed in another tab')

    # A repeat of the same request returns the same session and opens nothing.
    status, repeated = gateway.call('POST', '/api/session.start', ALLOWED_TOKEN, start)
    require(status == 200 and repeated == started, f'Repeat differed: {repeated}')
    require(app_socket.selection(workspace_id) == after, 'A repeated request changed the workspace')

    audit = json.loads((runtime_home / 'remote-access/audit.json').read_text())
    actions = [(entry['action'], entry.get('detail')) for entry in audit]
    evidence['auditActions'] = actions
    require(('session_start_rejected', 'permission_denied') in actions, f'No refusal audit: {actions}')
    require(sum(action == 'session_start_accepted' for action, _ in actions) == 2,
            f'Expected two accepted entries (the start and its repeat): {actions}')
    require(all(MESSAGE not in json.dumps(entry) for entry in audit), 'The audit log holds message text')
    evidence['checkedDeviceID'] = allowed['id']


if __name__ == '__main__':
    main()
