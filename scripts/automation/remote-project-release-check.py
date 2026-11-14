#!/usr/bin/env python3
"""Start a project's release through the Remote Access gateway of a disposable app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-project-release-check.py'.

The check starts its own second instance of the wrapper's build, with a
throwaway runtime home, a throwaway user home and a loopback gateway port. The
user home is a git repository whose `origin` is a bare repository next to it.
Its `agents.toml` maps `claude` to a fake agent that records its first message
and waits, and its `tasks.toml` gives the project release tags and a release
prompt that only asks to echo. Nothing can publish: no real agent runs, and the
check confirms that the bare remote has no tags at the end.

A release needs a task that waits to ship. The check creates one with the
real CLI, stops the app, marks that record merged in `task-records.json`, and
starts the app again. It then acts as three paired phones over HTTP:
- a phone with Start sessions off and one with Task actions off are refused;
- the allowed phone sees Release on the project's To ship lane, starts the
  release, gets the same release for a repeat of its request, and is refused a
  second release while the first runs;
- the release task starts its agent on no branch in a new worktree with the
  release prompt, and the lane names the running release;
- after the app restarts, a repeat of the request still finds that release.
The check never selects a workspace or moves focus, and stops its own app.
"""

import base64
import datetime
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

TIMEOUT = 60
IDENTITY = 'remote-release-check@example.com'
RELEASE_PROMPT = 'Echo the release plan, then stop. Do not tag, push or publish anything.'
TASK_TITLE = 'Fix the parser'
# A new runtime home is a first launch; this check is not about that question.
START_OFFER_ANSWERED = ('-toastty.coordinator.startOfferAnswered', 'YES')

# Records the first message (the last argument) and the session, then waits.
FAKE_AGENT = r'''#!/bin/sh
case "$1" in
  --version) echo "2.1.288 (Claude Code)"; exit 0 ;;
  plugin|mcp|config) exit 0 ;;
esac
for argument in "$@"; do message="$argument"; done
dir="$(dirname "$0")/sessions"; mkdir -p "$dir"
printf '%s' "$message" > "$dir/$TOASTTY_SESSION_ID.message"
printf '{"sessionID":"%s","cwd":"%s"}\n' "$TOASTTY_SESSION_ID" "$PWD" > "$dir/$TOASTTY_SESSION_ID.json"
while IFS= read -r line; do :; done
'''


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def wait_for(description, probe, timeout=TIMEOUT, interval=0.3):
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


def credential_token():
    """The gateway accepts only 32 random bytes as unpadded base64url."""
    return base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('=')


def device(name, token, **settings):
    record = dict(id=str(uuid.uuid4()).upper(), name=name, scopes=['read', 'send'],
                  authKind='native', tailscaleLogin=IDENTITY, createdAt=0, **settings)
    credential = dict(credentialHash=hashlib.sha256(token.encode()).hexdigest(),
                      deviceID=record['id'], issuedAt=0)
    return record, credential


def git(*arguments, cwd=None):
    return subprocess.run(['git', '-c', 'user.name=Release Check', '-c', 'user.email=release-check@example.com',
                           *arguments], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


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

    def release(self, token, workspace_id, request_id):
        return self.call('POST', '/api/project.release', token,
                         dict(protocolVersion='1.0', workspaceID=workspace_id, clientRequestID=request_id))

    def board(self, token):
        status, body = self.call('GET', '/api/sessions', token)
        require(status == 200, f'Session list failed: {status} {body}')
        return body['snapshot'].get('tasks')


class Instance:
    """One running app on a private socket, runtime home and gateway port."""

    def __init__(self, binary, environment, socket_path, port, log_path):
        self.socket_path = socket_path
        self.log = open(log_path, 'a')
        self.process = subprocess.Popen(
            [str(binary), '-toastty.remoteAccess.enabled', 'YES', '-toastty.remoteAccess.port', str(port),
             *START_OFFER_ANSWERED],
            env=environment, stdout=self.log, stderr=subprocess.STDOUT)

    def query(self, query_id, **args):
        envelope = dict(protocolVersion='1.0', kind='request', requestID=str(uuid.uuid4()),
                        command='app_control.run_query', payload=dict(id=query_id, args=args))
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(15)
            connection.connect(self.socket_path)
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

    def wait_until_ready(self):
        def socket_answers():
            require(self.process.poll() is None, 'The check instance exited during startup')
            if not os.path.exists(self.socket_path):
                return None
            try:
                return self.query('workspace.list')['workspaces']
            except (OSError, AssertionError, json.JSONDecodeError):
                return None

        return wait_for('the automation socket', socket_answers)

    def stop(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        self.log.close()


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-release-check-', dir='/tmp')).resolve()
    runtime_home, user_home, fake_bin, remote = root / 'runtime-home', root / 'user-home', root / 'bin', root / 'remote.git'
    for directory in (runtime_home / 'remote-access', user_home, fake_bin):
        directory.mkdir(parents=True)

    # The project and the remote a release starts from.
    git('init', '-q', '--bare', '-b', 'main', str(remote))
    git('init', '-q', '-b', 'main', str(user_home))
    (user_home / 'README.md').write_text('release check\n')
    (user_home / '.gitignore').write_text('.toastty/\n')
    git('add', '.', cwd=user_home)
    git('commit', '-q', '-m', 'Initial commit', cwd=user_home)
    git('remote', 'add', 'origin', str(remote), cwd=user_home)
    git('push', '-q', '-u', 'origin', 'main', cwd=user_home)
    tip = git('rev-parse', 'HEAD', cwd=user_home)

    (user_home / '.toastty').mkdir()
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT)
    agent.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text(
        '[defaults]\nagent = "claude"\n\n'
        f'[workspace.{json.dumps(str(user_home))}]\nrelease_tags = "v*"\n'
        f'release_prompt = {json.dumps(RELEASE_PROMPT)}\n')

    allowed_token, start_off_token, actions_off_token = credential_token(), credential_token(), credential_token()
    allowed, allowed_credential = device('Allowed phone', allowed_token)
    start_off, start_off_credential = device('Start-off phone', start_off_token, sessionStartDisabled=True)
    actions_off, actions_off_credential = device('Actions-off phone', actions_off_token, taskActionsEnabled=False)
    (runtime_home / 'remote-access/devices.json').write_text(json.dumps(dict(
        devices=[allowed, start_off, actions_off],
        credentials=[allowed_credential, start_off_credential, actions_off_credential],
        nativePairingFailures=[])))

    port = free_port()
    socket_path = f'/tmp/toastty-release-{os.getpid()}.sock'
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-project-release-check',
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], root=str(root), gatewayPort=port, releasePrompt=RELEASE_PROMPT)

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, **facts))
        print(f'[release-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_cli(*arguments):
        result = subprocess.run([str(cli), '--json', *arguments], env=environment,
                                capture_output=True, text=True, timeout=180)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout)['result']

    app_log = artifacts / 'remote-project-release-check-app.log'
    gateway = Gateway(port)
    instance = Instance(binary, environment, socket_path, port, app_log)
    try:
        workspace_id = instance.wait_until_ready()[0]['workspaceID']

        def terminal_in_home():
            listed = instance.query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == workspace_id)['terminalCwds']
            return cwds if str(user_home) in [os.path.realpath(cwd) for cwd in cwds] else None

        wait_for('the first terminal in the user home', terminal_in_home)

        # 1. A task, through the real CLI, that then merges.
        task = run_cli('task', 'create', TASK_TITLE, '--workspace', workspace_id, '--request-id', 'seed-1',
                       '--wait', '--timeout', '90')
        task_id = task['taskID']
        require(os.path.realpath(task['projectRoot']) == str(user_home), f'Project root is not the repo: {task}')
        instance.stop()
        records_file = runtime_home / 'task-records.json'
        records = json.loads(records_file.read_text())
        record = next(r for r in records['records'] if r['id'].upper() == task_id.upper())
        record['mergedAt'] = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        record['mergeCommit'] = tip
        record['pullRequestURL'] = 'https://github.com/example/release-check/pull/7'
        records_file.write_text(json.dumps(records, indent=2))
        step('seeded a merged task', taskID=task_id, mergeCommit=tip)

        instance = Instance(binary, environment, socket_path, port, app_log)
        instance.wait_until_ready()

        def hello():
            try:
                status, body = gateway.call('GET', '/api/hello')
            except (urllib.error.URLError, ConnectionError):
                return None
            return body if status == 200 else None

        capabilities = wait_for('the gateway', hello)['capabilities']
        require('project_release' in capabilities, f'Gateway does not advertise project_release: {capabilities}')

        # 2. The phone's board: one To ship lane that can release.
        def lane():
            board = gateway.board(allowed_token)
            return next(iter(board['toShip']), None) if board else None

        shipping = wait_for('the To ship lane', lane)
        evidence['laneBefore'] = shipping
        require(shipping['count'] == 1 and shipping.get('taskIDs') == [task_id.upper()], f'Unexpected lane: {shipping}')
        require(shipping.get('releaseWorkspaceID') == workspace_id.upper(), f'Lane names no release workspace: {shipping}')
        require('releaseTaskID' not in shipping, f'A release runs already: {shipping}')
        release_workspace = shipping['releaseWorkspaceID']
        step('lane offers Release', lane=shipping)

        # 3. Either missing permission is refused, and nothing starts.
        for name, token in (('start sessions off', start_off_token), ('task actions off', actions_off_token)):
            status, body = gateway.release(token, release_workspace, str(uuid.uuid4()))
            require(status == 200 and body == dict(protocolVersion='1.0', status='rejected', reason='permission_denied'),
                    f'{name}: unexpected answer {status} {body}')
            step('refused', device=name, answer=body)
        require(all(t.get('release') is None for t in run_cli('task', 'list')['tasks']), 'A refused request started a release')

        # 4. The allowed phone starts the release once.
        status, started = gateway.release(allowed_token, release_workspace, 'phone-release-1')
        require(status == 200 and started.get('status') == 'started', f'Release did not start: {status} {started}')
        release_id = started['taskID']
        step('started', answer=started)
        status, repeated = gateway.release(allowed_token, release_workspace, 'phone-release-1')
        require(status == 200 and repeated == started, f'A repeat differed: {repeated}')
        step('repeat returned the same release', answer=repeated)
        status, second = gateway.release(allowed_token, release_workspace, 'phone-release-2')
        require(status == 200 and second.get('status') == 'rejected' and second.get('reason') == 'release_under_way',
                f'A second release was not refused: {status} {second}')
        require('Release ' in (second.get('message') or ''), f'The refusal does not name the release: {second}')
        step('second release refused', answer=second)
        def release_ids():
            return [t['taskID'].upper() for t in run_cli('task', 'list')['tasks'] if t.get('release') is not None]

        require(release_ids() == [release_id.upper()], f'Expected one release task: {release_ids()}')

        # 5. The release task sets up on no branch and its agent gets the
        # release prompt and the task that waits to ship.
        def release_started():
            current = run_cli('task', 'get', release_id)
            return current if current['setup']['state'] in ('started', 'setupFailed') else None

        release = wait_for('the release setup', release_started, timeout=120)
        evidence['releaseTask'] = {key: release.get(key) for key in ('taskID', 'title', 'setup', 'source', 'worktree')}
        require(release['setup']['state'] == 'started', f'Release setup failed: {release["setup"]}')
        # The agent may start under the worktree's session, so find its
        # message by what it says.
        def release_session():
            for path in (fake_bin / 'sessions').glob('*.message'):
                text = path.read_text()
                if RELEASE_PROMPT in text:
                    return text, json.loads(path.with_suffix('.json').read_text())
            return None

        message, session = wait_for('the release agent to record its message', release_session, timeout=120)
        evidence['releaseMessage'] = message
        evidence['releaseAgentCwd'] = session['cwd']
        require(RELEASE_PROMPT in message and TASK_TITLE in message, f'Unexpected release message: {message!r}')
        # The agent works in a new worktree on no branch, at the remote's tip,
        # never in the project checkout.
        agent_cwd = os.path.realpath(session['cwd'])
        require(agent_cwd != str(user_home), f'The release agent started in the project checkout: {agent_cwd}')
        detached = subprocess.run(['git', 'symbolic-ref', '-q', 'HEAD'], cwd=agent_cwd, capture_output=True)
        require(detached.returncode != 0, f'The release worktree is on a branch: {detached.stdout!r}')
        require(git('rev-parse', 'HEAD', cwd=agent_cwd) == tip, 'The release worktree is not at the remote tip')
        step('release agent started', title=release['title'], cwd=agent_cwd, message=message)

        # 6. The lane names the running release, and the board lists it.
        board = gateway.board(allowed_token)
        shipping = board['toShip'][0]
        evidence['laneAfter'] = shipping
        require(shipping.get('releaseTaskID') == release_id.upper(), f'Lane does not name the release: {shipping}')
        require(any(t['id'] == release_id.upper() for t in board['tasks']), 'The release task is not on the board')
        step('lane reads releasing', lane=shipping)

        # 7. A repeat after the Mac restarts still finds the same release:
        # the request ID is saved on the release task.
        instance.stop()
        instance = Instance(binary, environment, socket_path, port, app_log)
        instance.wait_until_ready()
        wait_for('the gateway after the restart', hello)
        status, after_restart = gateway.release(allowed_token, release_workspace, 'phone-release-1')
        require(status == 200 and after_restart == started, f'A repeat after the restart differed: {after_restart}')
        require(release_ids() == [release_id.upper()], f'The repeat started another release: {release_ids()}')
        step('repeat after restart returned the same release', answer=after_restart)

        audit = json.loads((runtime_home / 'remote-access/audit.json').read_text())
        actions = [(entry['action'], entry.get('detail')) for entry in audit if entry['action'].startswith('project_release')]
        evidence['auditActions'] = actions
        require(actions.count(('project_release_rejected', 'permission_denied')) == 2, f'Audit: {actions}')
        require(actions.count(('project_release_started', None)) == 3, f'Audit: {actions}')
        require(('project_release_rejected', 'release_under_way') in actions, f'Audit: {actions}')

        # 8. Nothing was published.
        tags = git('ls-remote', '--tags', str(remote))
        require(tags == '', f'The remote has tags: {tags}')
        step('remote has no tags')
        evidence['status'] = 'passed'
    finally:
        try:
            instance.stop()
        except Exception:
            pass
        if os.path.exists(socket_path):
            os.unlink(socket_path)
        (artifacts / 'remote-project-release-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[release-check] passed', flush=True)


if __name__ == '__main__':
    main()
