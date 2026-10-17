#!/usr/bin/env python3
"""Answer real Claude Code permission prompts through a paired-device gateway.

Needs an installed, authenticated `claude` CLI, so run it on a Mac that has
one, against a built app bundle:

    TOASTTY_APP_BUNDLE=Derived/Build/Products/Debug/Toastty.app \\
    TOASTTY_ARTIFACTS_DIR=artifacts/manual/claude-permission-check \\
    python3 scripts/automation/claude-permission-check.py

It starts its own isolated Toastty instance with two seeded native devices
(one allowed to approve requests, one not), launches Claude in a disposable
directory with user settings disabled and only the Bash tool, and drives the
session through loopback HTTP and socket actions without moving focus. Socket
input is pasted text and cannot move Claude's trust-dialog selection, so the
run marks only its own temporary directory trusted in ~/.claude.json and
removes that entry afterwards. Subscription usage is consumed. Evidence goes to claude-permission-check.json.

On a remote host driven over SSH, the Claude login lives in the GUI session's
keychain, which SSH processes cannot read. Pass --gui-session there: the
check reruns itself through Terminal in that session and waits for it.

    sv exec -- scripts/remote/validate.sh --require-remote --validation-command \\
      'python3 scripts/automation/claude-permission-check.py --gui-session'

Checks: an approval-disabled device is refused; Allow once runs the command;
Always allow saves Claude's suggested rule and the next matching command runs
without a prompt; a desktop answer closes the phone's response window; Deny
stops the turn without running the command.
"""

import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

_spec = importlib.util.spec_from_file_location(
    'queue_steer_check', Path(__file__).with_name('remote-queue-steer-check.py'))
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)
require, wait_for, step, Gateway, App = check.require, check.wait_for, check.step, check.Gateway, check.App

DISABLED_TOKEN = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('=')


CLAUDE_CONFIG = Path.home() / '.claude.json'


def set_directory_trust(directory, trusted):
    """Adds or removes one project entry, leaving the rest of the file alone."""
    config = json.loads(CLAUDE_CONFIG.read_text()) if CLAUDE_CONFIG.exists() else {}
    projects = config.setdefault('projects', {})
    if trusted:
        projects[str(directory)] = dict(projects.get(str(directory), {}), hasTrustDialogAccepted=True)
    elif projects.pop(str(directory), None) is None:
        return
    temporary = CLAUDE_CONFIG.with_name(CLAUDE_CONFIG.name + '.toastty-check')
    temporary.write_text(json.dumps(config, indent=2))
    os.replace(temporary, CLAUDE_CONFIG)


def run_in_gui_session():
    """Reruns this check from Terminal in the logged-in GUI session."""
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR']).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    done = artifacts / 'claude-permission-check-gui.exit'
    output = artifacts / 'claude-permission-check-gui.log'
    done.unlink(missing_ok=True)
    command = ' '.join([
        'cd', shlex.quote(os.getcwd()), '&&',
        f"TOASTTY_APP_BUNDLE={shlex.quote(os.environ['TOASTTY_APP_BUNDLE'])}",
        f'TOASTTY_ARTIFACTS_DIR={shlex.quote(str(artifacts))}',
        'python3', shlex.quote(str(Path(__file__).resolve())), '>', shlex.quote(str(output)), '2>&1;',
        'echo $? >', shlex.quote(str(done)), '; exit',
    ])
    script = f'tell application "Terminal" to do script {json.dumps(command)}'
    subprocess.run(['osascript', '-e', script], check=True, capture_output=True, timeout=30)
    wait_for('the GUI-session check', done.exists, timeout=1500, interval=2)
    print(output.read_text())
    raise SystemExit(int(done.read_text().strip() or 1))


def main():
    if '--gui-session' in sys.argv[1:]:
        run_in_gui_session()
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE']).resolve()
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR']).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    binary = bundle / 'Contents/MacOS/Toastty'
    require(binary.is_file(), f'No Toastty binary at {binary}')
    evidence = dict(status='failed', cliVersion=None, steps=[], captures={})
    root = Path(tempfile.mkdtemp(prefix='toastty-permission-check-', dir='/tmp')).resolve()
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_')
                   and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT')}
    app = log = work = None
    try:
        runtime_home = root / 'runtime-home'
        (runtime_home / 'remote-access').mkdir(parents=True)
        devices, credentials = [], []
        for name, token, identity, approve in (('Approving phone', check.TOKEN, check.IDENTITY, True),
                                               ('Read-only approvals phone', DISABLED_TOKEN, check.IDENTITY, False)):
            device = dict(id=str(uuid.uuid4()).upper(), name=name, scopes=['read', 'send'], authKind='native',
                          tailscaleLogin=identity, createdAt=0)
            if approve:
                device['permissionApprovalEnabled'] = True
            devices.append(device)
            credentials.append(dict(credentialHash=hashlib.sha256(token.encode()).hexdigest(),
                                    deviceID=device['id'], issuedAt=0))
        (runtime_home / 'remote-access/devices.json').write_text(json.dumps(dict(
            devices=devices, credentials=credentials, nativePairingFailures=[])))

        cli = shutil.which('claude') or str(Path.home() / '.local/bin/claude')
        require(Path(cli).is_file(), 'Claude CLI is not installed')
        evidence['cliVersion'] = subprocess.check_output([cli, '--version'], text=True, timeout=30, env=environment).strip()
        user_home = root / 'user-home'
        (user_home / '.toastty').mkdir(parents=True)
        # No inherited settings or allow rules, so Bash commands ask first.
        argv = [cli, '--setting-sources=', '--permission-mode', 'default', '--tools', 'Bash', '--strict-mcp-config']
        (user_home / '.toastty/agents.toml').write_text(
            '[claude]\ndisplayName = "Claude Code"\nargv = ' + json.dumps(argv) + '\n')
        work = root / 'work'
        work.mkdir()
        (work / 'README.md').write_text('# Disposable Claude permission check\n')
        set_directory_trust(work, True)

        port = check.free_port()
        socket_path = str(root / 'socket.sock')
        environment.update(
            TOASTTY_RUNTIME_HOME=str(runtime_home),
            TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
            TOASTTY_RUNTIME_LABEL='claude-permission-check',
            TOASTTY_SOCKET_PATH=socket_path,
            CFFIXED_USER_HOME=str(user_home),
            DISABLE_AUTOUPDATER='1',
        )
        evidence['gatewayPort'] = port
        log = open(artifacts / 'claude-permission-check-app.log', 'w')
        app = subprocess.Popen(
            [str(binary), '-toastty.remoteAccess.enabled', 'YES', '-toastty.remoteAccess.port', str(port)],
            env=environment, stdout=log, stderr=subprocess.STDOUT)
        run(app, Gateway(port), App(bundle, socket_path), runtime_home, work, evidence)
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
            shutil.copyfile(instance_log, artifacts / 'claude-permission-check-instance.log')
        if work is not None:
            set_directory_trust(work, False)
            project = check.claude_project_directory(work)
            if project.is_dir():
                capture = artifacts / 'claude-permission-check-transcripts'
                capture.mkdir(exist_ok=True)
                for path in project.glob('*.jsonl'):
                    shutil.copyfile(path, capture / path.name)
                shutil.rmtree(project, ignore_errors=True)
        (artifacts / 'claude-permission-check.json').write_text(json.dumps(evidence, indent=2, sort_keys=True))
        shutil.rmtree(root, ignore_errors=True)
    print(json.dumps(dict(status=evidence['status'], failure=evidence.get('failure')), sort_keys=True))


def run(app, gateway, app_socket, runtime_home, work, evidence):
    wait_for('the check instance', lambda: (runtime_home / 'instance.json').is_file())
    wait_for('the check socket', lambda: os.path.exists(app_socket.socket_path))
    require(app.poll() is None, 'The check instance exited')

    def gateway_ready():
        try:
            return gateway.call('GET', '/api/hello', token=None)[0] == 200
        except OSError:
            return False

    wait_for('the gateway', gateway_ready)
    _, sessions = gateway.call('GET', '/api/sessions')
    workspace_id = sessions['snapshot']['workspaces'][0]['id']
    app_socket.run('action', 'workspace.rename', 'title=Claude permission check (disposable)', workspace=workspace_id)

    def launch_when_ready():
        try:
            return app_socket.run('action', 'agent.launch', 'profileID=claude', f'cwd={work}', workspace=workspace_id)
        except AssertionError as error:
            if 'interactive prompt' in str(error):
                return None
            raise

    launch = wait_for('the terminal to launch Claude', launch_when_ready, timeout=60)
    panel_id, session_id = launch['panelID'], launch['sessionID']
    evidence['launch'] = {key: launch.get(key) for key in ('sessionID', 'panelID', 'cwd')}
    def composer():
        text = app_socket.visible_text(panel_id)
        evidence['captures']['startup'] = text
        require('/login' not in text.lower(), 'Claude needs an interactive subscription login')
        # Trust only this run-owned temporary directory, never another project.
        require('Yes, I trust this folder' not in text, 'Claude ignored the pre-trusted temporary directory')
        footer = 'for shortcuts' in text or 'shift+tab to cycle' in text
        return text if '❯' in text and footer else None

    wait_for('the Claude composer', composer, timeout=180)

    def listed():
        _, body = gateway.call('GET', '/api/sessions')
        return next((c for c in body['snapshot']['conversations']
                     if c['provider'] == 'claude' and c['placement'].get('panelID') == panel_id), None)

    conversation_id = wait_for('the Claude conversation', listed, timeout=60)['conversationID']
    evidence['conversationID'] = conversation_id

    def events():
        return gateway.events(conversation_id)[0]

    def find(predicate, description, timeout=180):
        try:
            return wait_for(description, lambda: next((e for e in reversed(events()) if predicate(e)), None),
                            timeout=timeout, interval=0.5)
        except AssertionError:
            evidence['lastEvents'] = events()[-20:]
            evidence['captures']['failed'] = app_socket.visible_text(panel_id)
            raise

    def prompt(text):
        app_socket.run('action', 'terminal.send-text', f'text={text}', 'submit=true',
                       f'expectedSessionID={session_id}', panel=panel_id)

    seen = set()

    def next_permission(description):
        event = find(lambda e: e['kind'] == 'interaction_presented' and e['payload'].get('kind') == 'permission'
                     and e['payload'].get('responseID') and e['payload']['id'] not in seen, description)
        seen.add(event['payload']['id'])
        interaction = event['payload']
        step(evidence, 'permission-presented', id=interaction['id'], prompt=interaction['prompt'],
             permission=interaction.get('permission'),
             options=[dict(id=o['id'], label=o['label'], detail=o.get('detail'))
                      for o in interaction['questions'][0]['options']])
        return interaction

    def answer(interaction, option_id, token=check.TOKEN):
        body = dict(protocolVersion='1.0', conversationID=conversation_id, interactionID=interaction['id'],
                    responseID=interaction['responseID'], expectedInputEpoch=interaction['inputEpoch'],
                    clientRequestID=str(uuid.uuid4()),
                    answers=[dict(questionID='decision', selectedOptionIDs=[option_id])])
        status, result = gateway.call('POST', '/api/conversation.question.answer', body, token=token)
        require(status == 200, f'Answer failed: {status} {result}')
        step(evidence, 'answered', id=interaction['id'], option=option_id, result=result)
        return result

    def resolved(interaction):
        return find(lambda e: e['kind'] == 'interaction_resolved'
                    and e['payload'].get('interactionID') == interaction['id'], f"{interaction['id']} resolution")

    def reply(marker):
        return find(lambda e: e['kind'] == 'assistant_message' and marker in e['payload'].get('text', ''),
                    f'Claude reply {marker}')

    def idle():
        wait_for('the open prompt', lambda: (gateway.conversation(conversation_id) or {})
                 .get('inputAvailability', {}).get('kind') == 'open_prompt', timeout=120)

    def command_prompt(command, marker):
        return (f'Use the Bash tool to run exactly this command and nothing else: `{command}`. '
                f'If it succeeds, reply with exactly: {marker}')

    # 1. A device without the opt-in is refused, then Allow once runs it.
    prompt(command_prompt('touch allow-once.txt', 'ALLOW-ONCE-OK'))
    first = next_permission('the first permission request')
    require('touch allow-once.txt' in first['permission']['preview'], f"Preview lacks the command: {first}")
    refused = answer(first, 'allow', token=DISABLED_TOKEN)
    require(refused == dict(status='rejected', reason='approvals_disabled'), f'Disabled device was not refused: {refused}')
    require(answer(first, 'allow') == dict(status='submitted'), 'Allow once was not submitted')
    resolved(first)
    reply('ALLOW-ONCE-OK')
    require((work / 'allow-once.txt').exists(), 'Allow once did not run the command')
    idle()

    # 2. Always allow applies Claude's own suggestion, so the next matching
    #    command runs without asking.
    prompt(command_prompt('touch always-one.txt', 'ALWAYS-ONE-OK'))
    second = next_permission('the always-allow request')
    options = second['questions'][0]['options']
    # Prefer a saved rule; Claude may offer only the accept-edits mode for file commands.
    always = sorted((o for o in options if o['id'].startswith('always:')),
                    key=lambda o: not o['label'].startswith('Always allow'))
    require(always, f'Claude offered no supported always-allow suggestion: {second}')
    answer(second, always[0]['id'])
    reply('ALWAYS-ONE-OK')
    require((work / 'always-one.txt').exists(), 'Always allow did not run the command')
    idle()
    settings = work / '.claude/settings.local.json'
    evidence['savedSettings'] = json.loads(settings.read_text()) if settings.exists() else None
    count_before = len(seen)
    prompt(command_prompt('touch always-two.txt', 'ALWAYS-TWO-OK'))
    reply('ALWAYS-TWO-OK')
    require((work / 'always-two.txt').exists(), 'The allowed command did not run')
    require(not any(e['kind'] == 'interaction_presented' and e['payload'].get('kind') == 'permission'
                    and e['payload']['id'] not in seen for e in events()),
            'The saved rule did not stop the next prompt')
    require(len(seen) == count_before, 'Unexpected permission request')
    step(evidence, 'always-allow-rule-applied')
    idle()

    # 3. Answering on the desktop closes the phone's response window and
    #    releases the waiting hook.
    # git init is not a file edit, so neither the saved rule nor accept-edits mode allows it.
    prompt(command_prompt('git init -q desktop-repo', 'DESKTOP-OK'))
    third = next_permission('the desktop-answered request')
    time.sleep(2)
    evidence['captures']['desktop-prompt'] = app_socket.visible_text(panel_id)
    # Submit sends a real Return key, which picks the dialog's default "Yes".
    app_socket.run('action', 'terminal.send-text', 'text=', 'submit=true', f'expectedSessionID={session_id}',
                   panel=panel_id)
    resolved(third)
    reply('DESKTOP-OK')
    late = answer(third, 'deny')
    require(late.get('status') == 'rejected', f'A late phone answer was accepted: {late}')
    idle()

    # 4. Deny refuses the command and stops Claude.
    prompt(command_prompt('git init -q denied-repo', 'DENY-SHOULD-NOT-REPLY'))
    fourth = next_permission('the denied request')
    answer(fourth, 'deny')
    resolved(fourth)
    idle()
    require(not (work / 'denied-repo').exists(), 'Deny ran the command')
    require(not any(e['kind'] == 'assistant_message' and 'DENY-SHOULD-NOT-REPLY' in e['payload'].get('text', '')
                    for e in events()), 'Claude continued after Deny')
    evidence['captures']['final'] = app_socket.visible_text(panel_id)
    step(evidence, 'deny-stopped-claude')


if __name__ == '__main__':
    main()
