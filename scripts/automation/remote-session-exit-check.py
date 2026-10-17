#!/usr/bin/env python3
"""Exit an agent after its turn, and close its phone-started tab, in a disposable app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-session-exit-check.py [--provider fake|codex|claude] [--gui-session]'.

Each run starts its own second instance of the wrapper's build, with a
throwaway runtime home, a throwaway user home whose `agents.toml` holds the
profile under test, one seeded paired device, and a loopback gateway port.
Sessions start over HTTP, as the phone starts them, so each runs in a tab
Toastty opened for it. The check reads results through the app's socket and
its log, and never selects a tab or moves focus.

- fake (default): a script stands in for the agent. It reports a working turn
  through the Toastty CLI, the check arms `session.exit-after-turn` through
  the socket, and the script then reports a finished turn and reads its
  terminal. Toastty must type `/exit`, the script exits 0, and the tab must
  close while the selected tab stays. Typing during the turn must skip the
  exit, and a crashed agent must keep its tab.
- codex, claude: the real CLI gets one prompt: run the action as its last
  tool call, then reply. The agent must exit and its tab must close. Codex
  ends its turn with that reply, the case the action exists for. Subscription
  usage is consumed. Claude's login lives in the GUI session on a host driven
  over SSH, so add --gui-session to rerun the check through Terminal there.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import uuid


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The start check owns the gateway, socket, device, and wait helpers; the
# queue-steer check owns Claude trust and the GUI-session rerun.
start_check = _load('remote_session_start_check', 'remote-session-start-check.py')
queue_check = _load('remote_queue_steer_check', 'remote-queue-steer-check.py')
require, wait_for = start_check.require, start_check.wait_for

TOKEN = start_check.credential_token()
EXIT_REPLY = 'EXIT-REQUESTED'
REAL_PROMPT = (
    'This is an automated Toastty check. Run exactly this one shell command, and no other command:\n'
    '"$TOASTTY_CLI_PATH" --json action run session.exit-after-turn --panel "$TOASTTY_PANEL_ID" '
    '"expectedSessionID=$TOASTTY_SESSION_ID"\n'
    f'Then reply with exactly: {EXIT_REPLY}'
)

# The fake agent records its identity, reports a working turn, waits for the
# check's go-ahead file, reports a finished turn, and reads its terminal until
# a line is `/exit`. A message starting with "crash" exits 3 instead.
FAKE_AGENT = r'''#!/bin/sh
case "$1" in
  --version) echo "2.1.288 (Claude Code)"; exit 0 ;;
  plugin|mcp|config) exit 0 ;;
esac
for argument in "$@"; do message="$argument"; done
dir="$(dirname "$0")/sessions"; mkdir -p "$dir"
slug=$(printf %s "$message" | tr -c 'A-Za-z0-9' '-')
printf '{"sessionID":"%s","panelID":"%s"}\n' "$TOASTTY_SESSION_ID" "$TOASTTY_PANEL_ID" > "$dir/$slug.json"
"$TOASTTY_CLI_PATH" session status --session "$TOASTTY_SESSION_ID" --kind working --summary Working > /dev/null
echo working > "$dir/$slug.state"
case "$message" in crash*) exit 3 ;; esac
while [ ! -f "$dir/$slug.go" ]; do sleep 0.2; done
"$TOASTTY_CLI_PATH" session status --session "$TOASTTY_SESSION_ID" --kind ready --summary Done > /dev/null
echo ready > "$dir/$slug.state"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$dir/$slug.input"
  [ "$line" = "/exit" ] && exit 0
done
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=('fake', 'codex', 'claude'), default='fake')
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    provider = options.provider
    if options.gui_session:
        queue_check.run_in_gui_session(f'remote-session-exit-{provider}', __file__, ['--provider', provider])

    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    require(binary.is_file(), f'No Toastty binary at {binary}')
    prefix = f'remote-session-exit-{provider}'

    root = Path(tempfile.mkdtemp(prefix='toastty-exit-check-', dir='/tmp')).resolve()
    runtime_home, user_home, fake_bin = root / 'runtime-home', root / 'user-home', root / 'bin'
    for directory in (runtime_home / 'remote-access', user_home / '.toastty', fake_bin):
        directory.mkdir(parents=True)
    # Codex trusts the host home's subfolders; Claude trusts only this folder,
    # marked for the run.
    work = Path.home() / 'toastty-queue-steer-checks' / f'exit-{uuid.uuid4().hex[:8]}'
    work.mkdir(parents=True)
    (work / 'README.md').write_text('# Disposable exit-after-turn check\n')

    evidence = dict(status='failed', provider=provider, steps=[])
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    evidence['cliVersion'] = write_profile(provider, user_home, fake_bin, work, environment)

    phone, credential = start_check.device('Phone', TOKEN, False)
    (runtime_home / 'remote-access/devices.json').write_text(json.dumps(dict(
        devices=[phone], credentials=[credential], nativePairingFailures=[])))
    port = start_check.free_port()
    socket_path = str(root / 'socket.sock')
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-session-exit-check',
        TOASTTY_SOCKET_PATH=socket_path,
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    log = open(artifacts / f'{prefix}-app.log', 'w')
    app = subprocess.Popen(
        [str(binary), '-toastty.remoteAccess.enabled', 'YES', '-toastty.remoteAccess.port', str(port)],
        env=environment, stdout=log, stderr=subprocess.STDOUT)
    try:
        check = Check(app, start_check.Gateway(port), start_check.AppSocket(socket_path), runtime_home, fake_bin, work, evidence)
        check.boot()
        if provider == 'fake':
            check.run_fake()
        else:
            check.run_real(provider)
        evidence['status'] = 'passed'
    except Exception as error:  # Always keep the failure evidence.
        evidence['failure'] = repr(error)
        raise
    finally:
        instance_log = runtime_home / 'logs/toastty.log'
        if instance_log.is_file():
            shutil.copyfile(instance_log, artifacts / f'{prefix}-instance.log')
            evidence['logLines'] = [line for line in instance_log.read_text().splitlines()
                                    if any(marker in line for marker in (
                                        'exit after the turn', 'native exit', 'pane close evaluated',
                                        'Stopped managed session'))]
        (artifacts / f'{prefix}.json').write_text(json.dumps(evidence, indent=2, sort_keys=True))
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(timeout=15)
        except subprocess.TimeoutExpired:
            app.kill()
        log.close()
        if provider == 'claude':
            queue_check.set_directory_trust(work, False)
            project = queue_check.claude_project_directory(work)
            if project.is_dir():
                for path in project.glob('*.jsonl'):
                    shutil.copyfile(path, artifacts / f'{prefix}-transcript-{path.name}')
                shutil.rmtree(project, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    print(json.dumps(evidence, indent=2, sort_keys=True))


def write_profile(provider, user_home, fake_bin, work, environment):
    """Writes the profile under test and returns the CLI version."""
    if provider == 'fake':
        agent = fake_bin / 'claude'
        agent.write_text(FAKE_AGENT)
        agent.chmod(0o755)
        name, argv, version = 'claude', [str(agent)], 'fake'
    elif provider == 'codex':
        cli = shutil.which('codex', path=environment.get('PATH'))
        require(cli, 'Codex CLI is not installed on the remote host')
        version = subprocess.check_output([cli, '--version'], text=True, timeout=30).strip()
        # The host's default sandbox asks before the socket call, and nobody
        # is there to answer; this run-owned profile skips that.
        name, argv = 'codex', [cli, '--dangerously-bypass-approvals-and-sandbox']
    else:
        cli = shutil.which('claude', path=environment.get('PATH')) or str(Path.home() / '.local/bin/claude')
        require(Path(cli).is_file(), 'Claude CLI is not installed on the remote host')
        version = subprocess.check_output([cli, '--version'], text=True, timeout=30, env=environment).strip()
        argv = [cli, '--setting-sources=', '--allowedTools', 'Bash', '--tools', 'Bash', '--strict-mcp-config']
        name = 'claude'
        queue_check.set_directory_trust(work, True)
    display = 'Codex' if name == 'codex' else 'Claude Code'
    # Extra arguments hide whether the command takes the first message last,
    # so the profile says so for the phone start to pass it.
    placement = '' if provider == 'fake' else 'initialPromptPlacement = "trailing"\n'
    (user_home / '.toastty/agents.toml').write_text(
        f'[{name}]\ndisplayName = "{display}"\nargv = {json.dumps(argv)}\n{placement}')
    return version


class Check:
    def __init__(self, app, gateway, app_socket, runtime_home, fake_bin, work, evidence):
        self.app, self.gateway, self.app_socket = app, gateway, app_socket
        self.runtime_home, self.fake_bin, self.work, self.evidence = runtime_home, fake_bin, work, evidence

    def step(self, name, **facts):
        self.evidence['steps'].append(dict(step=name, **facts))
        print(f'[exit-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def action(self, action_id, **args):
        envelope = dict(protocolVersion='1.0', kind='request', requestID=str(uuid.uuid4()),
                        command='app_control.run_action', payload=dict(id=action_id, args=args))
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(15)
            connection.connect(self.app_socket.path)
            connection.sendall(json.dumps(envelope).encode() + b'\n')
            data = b''
            while b'\n' not in data:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                data += chunk
        return json.loads(data)

    def boot(self):
        def instance_ready():
            require(self.app.poll() is None, 'The check instance exited during startup')
            path = self.runtime_home / 'instance.json'
            return json.loads(path.read_text()) if path.is_file() else None

        wait_for('instance.json', instance_ready)
        wait_for('the automation socket', lambda: os.path.exists(self.app_socket.path))

        def hello():
            try:
                status, body = self.gateway.call('GET', '/api/hello')
            except (OSError, ConnectionError):
                return None
            return body if status == 200 else None

        wait_for('the gateway', hello)
        _, sessions = self.gateway.call('GET', '/api/sessions', TOKEN)
        self.workspace_id = sessions['snapshot']['workspaces'][0]['id']
        self.shell_tab = self.app_socket.selection(self.workspace_id)['selectedTabID']
        # A phone start opens its tab in the workspace's terminal folder.
        panel = self.app_socket.query('workspace.snapshot', workspaceID=self.workspace_id)['focusedPanelID']

        def at_work():
            # The first terminal's surface can still be starting; try again.
            response = self.action('terminal.send-text', panelID=panel, text=f'cd {self.work}', submit=True)
            if not response.get('ok'):
                return None
            state = self.app_socket.query('terminal.state', panelID=panel)
            return str(state.get('cwd', '')).rstrip('/') == str(self.work)

        wait_for('the shell to enter the work folder', at_work, timeout=60, interval=2)

    def start(self, text):
        status, body = self.gateway.call('POST', '/api/session.start', TOKEN, dict(
            protocolVersion='1.0', clientRequestID=str(uuid.uuid4()), workspaceID=self.workspace_id,
            profileID=self.profile_id, text=text))
        require(status == 200 and body.get('status') == 'started', f'Start failed: {status} {body}')
        return body['conversationID']

    def tabs(self):
        return self.app_socket.selection(self.workspace_id)

    def listed(self, conversation_id):
        _, body = self.gateway.call('GET', '/api/sessions', TOKEN)
        return next((c for c in body['snapshot']['conversations'] if c['conversationID'] == conversation_id), None)

    # MARK: fake agent

    def fake(self, message):
        slug = ''.join(c if c.isalnum() else '-' for c in message)
        sessions = self.fake_bin / 'sessions'
        return dict(
            info=sessions / f'{slug}.json', state=sessions / f'{slug}.state',
            go=sessions / f'{slug}.go', input=sessions / f'{slug}.input')

    def run_fake(self):
        self.profile_id = 'claude'

        # 1. The armed turn completes: Toastty types /exit, the agent exits 0,
        #    and its tab closes while the selected tab stays.
        files = self.fake('exit after this turn')
        self.start('exit after this turn')
        wait_for('the working report', lambda: files['state'].is_file() and 'working' in files['state'].read_text())
        info = json.loads(files['info'].read_text())
        before = self.tabs()
        armed = self.action('session.exit-after-turn', panelID=info['panelID'], expectedSessionID=info['sessionID'])
        require(armed.get('ok') and armed['result']['armed'], f'Arming failed: {armed}')
        self.step('armed', result=armed['result'], tabsBefore=before)
        files['go'].touch()
        wait_for('the agent to read /exit', lambda: files['input'].is_file() and '/exit' in files['input'].read_text())
        wait_for('its tab to close', lambda: len(self.tabs()['tabIDs']) == len(before['tabIDs']) - 1)
        after = self.tabs()
        require(after['selectedTabID'] == before['selectedTabID'], f'The selected tab changed: {after}')
        self.step('exited and closed', input=files['input'].read_text().splitlines(), tabsAfter=after)

        # 2. Typing during the armed turn keeps the agent running.
        files = self.fake('typed during the turn')
        typed_conversation = self.start('typed during the turn')
        wait_for('the working report', lambda: files['state'].is_file() and 'working' in files['state'].read_text())
        info = json.loads(files['info'].read_text())
        self.action('session.exit-after-turn', panelID=info['panelID'], expectedSessionID=info['sessionID'])
        typed = self.action('terminal.send-text', panelID=info['panelID'], text='draft', submit=False)
        require(typed.get('ok'), f'Typing failed: {typed}')
        files['go'].touch()
        wait_for('the ready report', lambda: 'ready' in files['state'].read_text())
        time.sleep(3)
        require(self.listed(typed_conversation) is not None, 'The typed-in session ended')
        require(not files['input'].is_file() or '/exit' not in files['input'].read_text(), 'An exit was typed over a draft')
        self.step('typing kept the agent', tabs=self.tabs())

        # 3. A crashed agent keeps its tab, so its output stays readable.
        files = self.fake('crash right away')
        before = self.tabs()
        conversation = self.start('crash right away')
        wait_for('the crash report', files['state'].is_file)
        wait_for('the crashed session to end', lambda: self.listed(conversation) is None, timeout=30)
        time.sleep(2)
        require(len(self.tabs()['tabIDs']) == len(before['tabIDs']) + 1, 'A crashed agent lost its tab')
        self.step('crash kept the tab', tabs=self.tabs())

    # MARK: real agent

    def run_real(self, provider):
        self.profile_id = provider
        before = self.tabs()
        conversation = self.start(REAL_PROMPT)
        self.step('started', conversationID=conversation, tabsBefore=before)
        wait_for('the session tab', lambda: len(self.tabs()['tabIDs']) == len(before['tabIDs']) + 1, timeout=60)
        log = self.runtime_home / 'logs/toastty.log'

        def logged(marker):
            return log.is_file() and marker in log.read_text()

        wait_for('the agent to arm the exit', lambda: logged('Armed exit after the current turn'), timeout=240, interval=2)
        self.step('agent armed the exit')
        wait_for('Toastty to type the exit', lambda: logged('Sent the native exit after the turn')
                 or logged('Skipped the exit after the turn'), timeout=240, interval=2)
        require(logged('Sent the native exit after the turn'), 'Toastty skipped the exit; see the instance log')
        wait_for('the agent to exit and its tab to close',
                 lambda: len(self.tabs()['tabIDs']) == len(before['tabIDs']), timeout=60, interval=1)
        after = self.tabs()
        require(after['selectedTabID'] == before['selectedTabID'], f'The selected tab changed: {after}')
        wait_for('the session to leave the list', lambda: self.listed(conversation) is None, timeout=30)
        self.step('exited and closed', tabsAfter=after)
        if provider == 'codex':
            self.evidence['codexFinalTurn'] = codex_final_turn(self.work)


def codex_final_turn(work):
    """The last assistant messages and tool calls of the Codex rollout for `work`."""
    sessions = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex')) / 'sessions'
    rollouts = sorted(sessions.rglob('rollout-*.jsonl'), key=lambda path: path.stat().st_mtime)[-20:]
    for path in reversed(rollouts):
        lines = path.read_text().splitlines()
        if str(work) not in '\n'.join(lines[:5]):
            continue
        tail = []
        for line in lines:
            record = json.loads(line)
            payload = record.get('payload', {})
            if payload.get('type') == 'message' and payload.get('role') == 'assistant':
                text = ''.join(part.get('text', '') for part in payload.get('content', []))
                tail.append(dict(kind='assistant', phase=payload.get('phase'), text=text[:200]))
            elif payload.get('type') in ('function_call', 'local_shell_call', 'custom_tool_call'):
                tail.append(dict(kind='tool', name=payload.get('name') or payload.get('type')))
            elif payload.get('type') in ('task_complete', 'turn_aborted'):
                tail.append(dict(kind=payload['type']))
        return dict(rollout=path.name, tail=tail[-6:])
    return None


if __name__ == '__main__':
    main()
