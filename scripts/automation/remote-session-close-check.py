#!/usr/bin/env python3
"""Close agent sessions through the Remote Access gateway of a disposable app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-session-close-check.py'.

Like remote-session-start-check.py, this check starts its own second instance
of the wrapper's build, with a throwaway runtime home, a throwaway user home
whose `agents.toml` names a fake `claude` command, one seeded paired device,
and a loopback gateway port. It starts two sessions over HTTP as the phone
would, then closes them: a session that has not finished a turn must ask
first, and one that reports a finished turn closes at once. It reads the
results through the app's automation socket and never selects a tab or moves
focus. The check stops its own instance; the wrapper owns everything else.
"""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import uuid

# The start check owns the gateway, socket, device, and wait helpers.
_spec = importlib.util.spec_from_file_location(
    'remote_session_start_check', Path(__file__).with_name('remote-session-start-check.py'))
start_check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(start_check)
require, wait_for = start_check.require, start_check.wait_for

TOKEN = start_check.credential_token()
FINISH_MESSAGE = 'finish this turn'

# A session whose message is FINISH_MESSAGE reports one finished turn through
# the Toastty CLI, as a hooked agent would, and records the CLI's output;
# any other session stays quiet.
FAKE_AGENT = '''#!/bin/sh
case "$1" in
  --version) echo "2.1.288 (Claude Code)"; exit 0 ;;
  plugin|mcp|config) exit 0 ;;
esac
for argument in "$@"; do message="$argument"; done
if [ "$message" = "%s" ]; then
  report="$(dirname "$0")/status-report.txt"
  {
    "$TOASTTY_CLI_PATH" session status --session "$TOASTTY_SESSION_ID" --kind working --summary Working
    "$TOASTTY_CLI_PATH" session status --session "$TOASTTY_SESSION_ID" --kind ready --summary Done
    echo "exit=$?"
  } > "$report" 2>&1
fi
exec sleep 300
''' % FINISH_MESSAGE


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    require(binary.is_file(), f'No Toastty binary at {binary}')

    root = Path(tempfile.mkdtemp(prefix='toastty-remote-close-')).resolve()
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

    phone, credential = start_check.device('Phone', TOKEN, False)
    (runtime_home / 'remote-access/devices.json').write_text(json.dumps(dict(
        devices=[phone], credentials=[credential], nativePairingFailures=[])))

    port = start_check.free_port()
    socket_path = f'/tmp/toastty-rc-{os.getpid()}.sock'
    environment = {key: value for key, value in os.environ.items() if not key.startswith('TOASTTY_')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-session-close-check',
        TOASTTY_SOCKET_PATH=socket_path,
        CFFIXED_USER_HOME=str(user_home),
    )
    evidence = dict(status='failed', gatewayPort=port)
    log = open(artifacts / 'remote-session-close-app.log', 'w')
    app = subprocess.Popen(
        [str(binary), '-toastty.remoteAccess.enabled', 'YES', '-toastty.remoteAccess.port', str(port)],
        env=environment, stdout=log, stderr=subprocess.STDOUT)
    try:
        run(app, start_check.Gateway(port), start_check.AppSocket(socket_path), runtime_home, fake_bin, evidence)
        evidence['status'] = 'passed'
    finally:
        report = fake_bin / 'status-report.txt'
        evidence['fakeAgentStatusReport'] = report.read_text() if report.is_file() else None
        instance_log = runtime_home / 'logs/toastty.log'
        if instance_log.is_file():
            (artifacts / 'remote-session-close-instance.log').write_text(instance_log.read_text())
        (artifacts / 'remote-session-close.json').write_text(json.dumps(evidence, indent=2, sort_keys=True))
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()
        log.close()
        if os.path.exists(socket_path):
            os.unlink(socket_path)
    print(json.dumps(evidence, indent=2, sort_keys=True))


def run(app, gateway, app_socket, runtime_home, fake_bin, evidence):
    def instance_ready():
        require(app.poll() is None, 'The check instance exited during startup')
        path = runtime_home / 'instance.json'
        return json.loads(path.read_text()) if path.is_file() else None

    require(wait_for('instance.json', instance_ready)['pid'] == app.pid, 'instance.json names a different process')
    wait_for('the automation socket', lambda: os.path.exists(app_socket.path))

    def hello():
        try:
            status, body = gateway.call('GET', '/api/hello')
        except (OSError, ConnectionError):
            return None
        return body if status == 200 else None

    capabilities = wait_for('the gateway', hello)['capabilities']
    require('conversation_close' in capabilities, f'Gateway does not advertise conversation_close: {capabilities}')

    _, sessions = gateway.call('GET', '/api/sessions', TOKEN)
    workspace_id = sessions['snapshot']['workspaces'][0]['id']

    def listed(conversation_id):
        _, body = gateway.call('GET', '/api/sessions', TOKEN)
        return next((c for c in body['snapshot']['conversations']
                     if c['conversationID'] == conversation_id), None)

    def start(text):
        status, started = gateway.call('POST', '/api/session.start', TOKEN, dict(
            protocolVersion='1.0', clientRequestID=str(uuid.uuid4()), workspaceID=workspace_id,
            profileID='claude', text=text))
        require(status == 200 and started.get('status') == 'started', f'Start failed: {status} {started}')
        conversation_id = started['conversationID']
        wait_for(f'{text!r} in the session list', lambda: listed(conversation_id))
        return conversation_id

    def close(conversation_id, stop_if_busy):
        status, body = gateway.call('POST', '/api/conversation.close', TOKEN, dict(
            protocolVersion='1.0', conversationID=conversation_id, stopIfBusy=stop_if_busy))
        require(status == 200, f'Close failed: {status} {body}')
        return body['result']

    quiet = start('stay quiet')
    finished = start(FINISH_MESSAGE)
    # The Mac decides from its own session status, which the fake agent sets
    # through the CLI. The phone's list state comes from the provider
    # transcript, which the fake agent does not write.
    report = fake_bin / 'status-report.txt'
    wait_for('the finished turn report', lambda: report.is_file() and 'exit=0' in report.read_text())
    before = app_socket.selection(workspace_id)
    evidence['selectionBefore'] = before
    require(len(before['tabIDs']) == 3, f'Expected the shell tab and two agent tabs: {before}')

    # A session that never finished a turn asks before anything closes.
    evidence['quietFirstClose'] = close(quiet, False)
    require(evidence['quietFirstClose'] == 'confirmation_required', f'Unexpected: {evidence}')
    require(app_socket.selection(workspace_id) == before, 'A refused close changed the workspace')

    # After the user agrees, it closes its background tab only.
    evidence['quietConfirmedClose'] = close(quiet, True)
    require(evidence['quietConfirmedClose'] == 'closed', f'Unexpected: {evidence}')
    after_quiet = app_socket.selection(workspace_id)
    evidence['selectionAfterQuietClose'] = after_quiet
    require(len(after_quiet['tabIDs']) == 2, f'Expected one tab fewer: {after_quiet}')
    require(after_quiet['selectedTabID'] == before['selectedTabID'], 'The selected tab changed')
    require(after_quiet['focusedPanelID'] == before['focusedPanelID'], 'The focused panel changed')
    wait_for('the closed session to leave the list', lambda: listed(quiet) is None)

    # A session that finished its turn closes without asking.
    evidence['finishedClose'] = close(finished, False)
    require(evidence['finishedClose'] == 'closed', f'Unexpected: {evidence}')
    after_finished = app_socket.selection(workspace_id)
    evidence['selectionAfterFinishedClose'] = after_finished
    require(after_finished['tabIDs'] == before['tabIDs'][:1], f'Expected only the shell tab: {after_finished}')
    require(after_finished['selectedTabID'] == before['selectedTabID'], 'The selected tab changed')
    wait_for('the finished session to leave the list', lambda: listed(finished) is None)

    # A repeat finds nothing to close.
    evidence['repeatClose'] = close(finished, True)
    require(evidence['repeatClose'] == 'conversation_not_found', f'Unexpected: {evidence}')

    audit = json.loads((runtime_home / 'remote-access/audit.json').read_text())
    actions = [(entry['action'], entry.get('detail')) for entry in audit if entry['action'] == 'conversation_closed']
    evidence['closeAuditActions'] = actions
    require(actions == [('conversation_closed', 'stopped_if_busy'), ('conversation_closed', 'finished')],
            f'Unexpected close audit entries: {actions}')


if __name__ == '__main__':
    main()
