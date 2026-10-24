#!/usr/bin/env python3
"""Run the coordinator with a real agent in a disposable app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-agent-check.py [--provider claude|codex] [--gui-session]'.

The check starts its own second instance of the wrapper's build with a
throwaway runtime home and TOASTTY_COORDINATOR_AUTOSTART=1. Its user home is a
throwaway folder under the host's home, so the coordinator starts there with
the shipped toastty-coordinator skill and a real agent (subscription usage is
consumed). Claude's login lives in the GUI session on a host driven over SSH,
so add --gui-session for Claude.

It checks that:
- Toastty starts the agent at launch with `Use the toastty-coordinator skill.`;
- asked in its terminal, the agent posts a note card with
  `toastty coordinator post`, and Toastty records the coordinator's own session
  on it;
- asked to end its session as the skill describes, the agent exits, and
  Toastty starts a fresh coordinator session in the same terminal.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
import uuid


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


create_check = _load('remote_task_create_check', 'remote-task-create-check.py')
start_work_check = _load('remote_task_start_work_check', 'remote-task-start-work-check.py')
queue_check = _load('remote_queue_steer_check', 'remote-queue-steer-check.py')
require, wait_for, Instance = create_check.require, create_check.wait_for, create_check.Instance

PREFIX = 'remote-coordinator-agent'
NOTE = f'CHECK-NOTE-{uuid.uuid4().hex[:8]}'
POST_REQUEST = (
    'This is an automated Toastty check. Run exactly this command and nothing else: '
    f'"$TOASTTY_CLI_PATH" coordinator post note "{NOTE}" ; then reply with exactly POSTED.'
)
END_REQUEST = (
    'This is an automated Toastty check. End this coordinator session now, as the '
    '"End a session" section of the toastty-coordinator skill describes, but skip its steps 1 and 2.'
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=('codex', 'claude'), default='claude')
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    provider = options.provider
    if options.gui_session:
        queue_check.run_in_gui_session(f'{PREFIX}-{provider}', __file__, ['--provider', provider])
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary, cli = bundle / 'Contents/MacOS/Toastty', bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-coordinator-agent-', dir='/tmp')).resolve()
    runtime_home = root / 'runtime-home'
    runtime_home.mkdir()
    # Codex trusts the host home's subfolders, so the coordinator's home stays
    # there; the provider's own login is linked in.
    user_home = Path.home() / 'toastty-queue-steer-checks' / f'coordinator-{uuid.uuid4().hex[:8]}'
    (user_home / '.toastty').mkdir(parents=True)
    for name in ('.codex', '.claude'):
        if (Path.home() / name).exists():
            (user_home / name).symlink_to(Path.home() / name)

    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    version, argv = start_work_check.provider_profile(provider, environment, user_home)
    if provider == 'codex':
        argv = [argv[0], '-c', 'check_for_update_on_startup=false', *argv[1:]]
    else:
        queue_check.set_directory_trust(user_home, True)
    (user_home / '.toastty/agents.toml').write_text(
        f'[{provider}]\ndisplayName = "{provider}"\nargv = {json.dumps(argv)}\ninitialPromptPlacement = "trailing"\n')
    (user_home / '.toastty/tasks.toml').write_text(f'[coordinator]\nagent = "{provider}"\n')

    socket_path = str(root / 'socket.sock')
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL=PREFIX,
        TOASTTY_SOCKET_PATH=socket_path,
        TOASTTY_COORDINATOR_AUTOSTART='1',
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', provider=provider, cliVersion=version, note=NOTE, steps=[])

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[coordinator-agent-check] {name} {json.dumps(facts, default=str)}', flush=True)

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-{provider}-app.log')
    answered = []

    def screen(panel):
        try:
            return instance.query('terminal.visible-text', panelID=panel, tail=60).get('text', '')
        except AssertionError:
            return ''

    def answer_dialogs(panel):
        """Answers a folder trust prompt or skips an update prompt, once each."""
        text = screen(panel)
        trust, update = text.rfind('Trust this folder?'), text.rfind('Update available')
        if trust >= 0 and trust > update and 'Trust and continue' in text[trust:] and 'trust' not in answered:
            answered.append('trust')
            choice = '1'
        elif update >= 0 and update > trust and 'Skip' in text[update:] and 'update' not in answered:
            answered.append('update')
            choice = '3'
        else:
            return
        instance.request('app_control.run_action', dict(
            id='terminal.send-text', args=dict(panelID=panel, text=choice, submit=True)))

    def running(excluding=()):
        status = instance.query('coordinator.status')
        require(status['state'] != 'failed', f'The coordinator failed: {status}')
        if status['panelID']:
            answer_dialogs(status['panelID'])
        if status['state'] == 'running' and status['sessionID'] not in excluding:
            return status
        return None

    def say(panel, text):
        response = instance.request('app_control.run_action', dict(
            id='terminal.send-text', args=dict(panelID=panel, text=text, submit=True)))
        require(response.get('ok'), f'Could not type into the coordinator terminal: {response}')

    try:
        instance.wait_until_ready()
        first = wait_for('the coordinator to run', running, timeout=120, interval=2)
        step('started', sessionID=first['sessionID'], panelID=first['panelID'])

        # The agent shows its prompt once its first turn has started; a message
        # typed while it works waits in its queue.
        wait_for('the agent to show its screen', lambda: running() and len(screen(first['panelID']).strip()) > 0,
                 timeout=120, interval=2)
        time.sleep(5)
        say(first['panelID'], POST_REQUEST)

        def posted_note():
            running()
            events_file = Path(first['eventsFile'])
            if not events_file.is_file():
                return None
            for line in events_file.read_text().splitlines():
                event = json.loads(line)
                if event.get('text') == NOTE:
                    return event
            return None

        event = wait_for('the agent to post its note card', posted_note, timeout=420, interval=3)
        require(event['kind'] == 'note', f'Unexpected card: {event}')
        require(event.get('sessionID') == first['sessionID'], f'The card does not name the coordinator session: {event}')
        step('posted a card', event=event)

        say(first['panelID'], END_REQUEST)
        second = wait_for('a fresh coordinator session', lambda: running(excluding=(first['sessionID'],)),
                          timeout=420, interval=3)
        require(second['panelID'] == first['panelID'], f'The fresh session moved terminals: {first} {second}')
        step('restarted after the agent ended its session', sessionID=second['sessionID'])

        evidence['status'] = 'passed'
    finally:
        evidence['dialogs'] = answered
        try:
            evidence['finalScreen'] = screen(instance.query('coordinator.status')['panelID'] or '')
        except Exception as error:
            evidence['finalScreenError'] = repr(error)
        instance_log = runtime_home / 'logs/toastty.log'
        if instance_log.is_file():
            shutil.copyfile(instance_log, artifacts / f'{PREFIX}-{provider}-instance.log')
        (artifacts / f'{PREFIX}-{provider}.json').write_text(json.dumps(evidence, indent=2, sort_keys=True, default=str))
        try:
            instance.kill()
        except Exception:
            pass
        if provider == 'claude':
            queue_check.set_directory_trust(user_home, False)
        else:
            start_work_check.forget_codex_trust(user_home)
        shutil.rmtree(user_home, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    print(json.dumps(evidence, indent=2, sort_keys=True, default=str))


if __name__ == '__main__':
    main()
