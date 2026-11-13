#!/usr/bin/env python3
"""Send to a real task agent with `task send --steer`, whatever the agent does.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-steer-check.py [--provider claude|codex] [--gui-session]'.

The check starts its own instance of the wrapper's build, with a throwaway
runtime home and a git repository as its user home, and one task with a real
agent (subscription usage is consumed). Remote Access stays off, so nothing
follows the agent's conversation before the first send. Claude's login lives
in the GUI session on a host driven over SSH, so add --gui-session for Claude.
This script plays a coordinator outside Toastty.

It checks that `task send --steer`:
- types the message at an idle agent's open prompt (`sent`);
- types it into a running turn (`steered`), and the agent reads it in that
  turn: it answers as the message says, and not as the turn's first message
  said;
- with Claude, while a permission prompt is on screen: types nothing and
  holds the message (`queued`). The prompt stays unanswered and its command
  does not run. After the check answers the prompt and the turn ends,
  Toastty types the message, and the agent answers it;
- never counts as the user's typing (`lastUserInputAt` stays null).

It also records how long after the prompt was on screen Toastty reported the
agent as waiting. Codex runs without permission prompts here, so that part is
for Claude only.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
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
panel_ids, visible_text_with = start_work_check.panel_ids, start_work_check.visible_text_with

PREFIX = 'remote-task-steer'
MARKER_FILE = 'steer-check-marker.txt'
TASK_TEXT = (
    'This is an automated Toastty check. Run no command and edit no file unless a message asks you to. '
    'Reply with exactly READY-T now. For each later message, do what it says and nothing more.'
)
# Claude Code runs a plain `sleep` in the background and ends the turn, so
# the turn is held by a script of the run's own.
HOLD_SCRIPT = 'hold-turn.sh'
HOLD_TEXT = (
    f'Run exactly this one shell command in the foreground, with a timeout of 120 seconds, and no other command: '
    f'./{HOLD_SCRIPT} 40 . Then reply with exactly HOLD-DONE.'
)
STEER_TEXT = 'Change of plan: when the current command ends, reply with exactly STEERED-OK and not with HOLD-DONE.'
TOUCH_TEXT = (
    f'Run exactly this one shell command, and no other command: touch {MARKER_FILE} . '
    'Then reply with exactly TOUCH-DONE.'
)
QUEUED_TEXT = 'Run no command. Reply with exactly QUEUED-OK.'
LOG_WORDS = ('under the input checks', 'local conversation send evaluated', 'remote send queued',
             'remote queued send evaluated', 'remote steer delivered')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=('claude', 'codex'), default='claude')
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

    root = Path(tempfile.mkdtemp(prefix='toastty-task-steer-check-', dir='/tmp')).resolve()
    runtime_home = root / 'runtime-home'
    runtime_home.mkdir()
    # Codex trusts the host home's subfolders, so the repository stays there.
    parent = Path.home() / 'toastty-queue-steer-checks' / f'task-steer-{uuid.uuid4().hex[:8]}'
    parent.mkdir(parents=True)
    repository = parent / 'project'
    subprocess.run(['git', 'init', '-q', '-b', 'main', str(repository)], check=True)
    (repository / '.git/info/exclude').write_text(f'.toastty/\n.codex\n.claude\n{HOLD_SCRIPT}\n')
    hold = repository / HOLD_SCRIPT
    hold.write_text('#!/bin/sh\nsleep "$1"\n')
    hold.chmod(0o755)
    toastty_dir = repository / '.toastty'
    toastty_dir.mkdir()
    for name in ('.codex', '.claude'):
        if (Path.home() / name).exists():
            (repository / name).symlink_to(Path.home() / name)

    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    version, argv = start_work_check.provider_profile(provider, environment, repository)
    if provider == 'codex':
        argv = [argv[0], '-c', 'check_for_update_on_startup=false', *argv[1:]]
    else:
        # No inherited settings or allow rules: the hold script runs
        # without a prompt, and every other command asks first.
        argv = [argv[0], '--setting-sources=', '--permission-mode', 'default', '--allowedTools',
                f'Bash(./{HOLD_SCRIPT}:*)', '--tools', 'Bash', '--strict-mcp-config']
        queue_check.set_directory_trust(repository, True)
    (toastty_dir / 'agents.toml').write_text(
        f'[{provider}]\ndisplayName = "{provider}"\nargv = {json.dumps(argv)}\ninitialPromptPlacement = "trailing"\n')
    (toastty_dir / 'tasks.toml').write_text(f'[defaults]\nagent = "{provider}"\n')

    socket_path = str(root / 'socket.sock')
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-task-steer-check',
        TOASTTY_SOCKET_PATH=socket_path,
        CFFIXED_USER_HOME=str(repository),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', provider=provider, cliVersion=version, steps=[], screens={})
    instance = None

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[task-steer-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def cli_result(*arguments):
        # No TOASTTY_SESSION_ID: a coordinator outside Toastty.
        result = subprocess.run([str(cli), '--json', *arguments], env=environment,
                                capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'{" ".join(arguments[:2])} failed ({result.returncode}): {result.stdout} {result.stderr}')
        return json.loads(result.stdout)['result']

    try:
        instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-{provider}-app.log')
        workspace_id = instance.wait_until_ready()[0]['workspaceID']

        def terminal_in_repository():
            listed = instance.query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == workspace_id)['terminalCwds']
            return str(repository) in [os.path.realpath(cwd) for cwd in cwds]

        wait_for('the first terminal in the repository', terminal_in_repository, interval=1)
        task = cli_result('task', 'create', TASK_TEXT, '--title', 'Steer check', '--workspace', workspace_id,
                          '--wait', '--timeout', '120')
        task_id = task['taskID']

        def get():
            return instance.query('task.get', taskID=task_id)

        def agent_state():
            return get()['agentState']['state']

        def snapshot():
            return instance.query('workspace.snapshot', workspaceID=task['setup']['taskSpaceWorkspaceID'])

        def screen():
            panel = get()['agentState']['panelID']
            return instance.query('terminal.visible-text', panelID=panel, tail=60).get('text', '')

        answered = []

        def answer_dialogs():
            """Answers Codex's folder trust prompt, and skips an update
            prompt, as a person would: each once."""
            for panel in panel_ids(snapshot()):
                try:
                    text = instance.query('terminal.visible-text', panelID=panel, tail=40).get('text', '')
                except AssertionError:
                    continue
                trust, update = text.rfind('Trust this folder?'), text.rfind('Update available')
                if trust >= 0 and trust > update and 'Trust and continue' in text[trust:]:
                    choice, kind = '1', 'trust'
                elif update >= 0 and update > trust and 'Skip' in text[update:]:
                    choice, kind = '3', 'update'
                else:
                    continue
                if (panel, kind) not in answered:
                    answered.append((panel, kind))
                    instance.request('app_control.run_action', dict(
                        id='terminal.send-text', args=dict(panelID=panel, text=choice, submit=True)))

        def reply(marker, timeout=300):
            def shown():
                if provider == 'codex':
                    answer_dialogs()
                return visible_text_with(instance, snapshot(), marker)

            text = wait_for(f'{marker} on screen', shown, timeout=timeout, interval=2)
            evidence['screens'][marker] = text[-3000:]
            return text

        def steer(text):
            return cli_result('task', 'send', task_id, text, '--steer')

        reply('READY-T')
        wait_for('the agent at its prompt', lambda: agent_state() == 'idle', interval=1)
        step('task started', taskID=task_id, agentState=get()['agentState'])

        # 1. An idle agent: typed at the open prompt.
        sent = steer('Run no command. Reply with exactly SENT-OK.')
        require(sent.get('delivery') == 'sent' and sent.get('delivered') is True, f'Not sent at the open prompt: {sent}')
        reply('SENT-OK')
        wait_for('the agent at its prompt', lambda: agent_state() == 'idle', interval=1)
        step('idle agent: sent', result=sent)

        # 2. A running turn: typed into the turn, and the agent follows it.
        cli_result('task', 'send', task_id, HOLD_TEXT)
        wait_for('the agent in a turn', lambda: agent_state() == 'busy', interval=0.5)
        wait_for('the held command on screen', lambda: f'{HOLD_SCRIPT} 40' in screen(), interval=1)
        states = []
        for _ in range(8):
            time.sleep(1)
            states.append(agent_state())
        require(states[-1] == 'busy', f'The agent did not stay in its turn; its states were {states}')
        steered = steer(STEER_TEXT)
        require(steered.get('delivery') == 'steered', f'Not steered into the running turn: {steered}')
        reply('STEERED-OK')
        # An agent that read the message only after its turn would have
        # ended that turn with the first message's answer.
        require(visible_text_with(instance, snapshot(), 'HOLD-DONE') is None,
                'The agent answered the first message before it read the steered one')
        wait_for('the agent at its prompt', lambda: agent_state() == 'idle', interval=1)
        step('busy agent: steered and read in the turn', result=steered)

        if provider == 'claude':
            # 3. A permission prompt on screen: nothing is typed.
            marker = repository / MARKER_FILE
            cli_result('task', 'send', task_id, TOUCH_TEXT)
            seen = dict(dialog=None, waiting=None)

            def on_screen(text):
                return 'Do you want to' in text or '1. Yes' in text

            def prompt_known():
                if seen['dialog'] is None and on_screen(screen()):
                    seen['dialog'] = time.monotonic()
                if seen['waiting'] is None and agent_state() == 'waiting':
                    seen['waiting'] = time.monotonic()
                return seen['dialog'] and seen['waiting']

            wait_for('the permission prompt, on screen and reported', prompt_known, timeout=120, interval=0.02)
            prompt_screen = screen()
            evidence['screens']['permission-prompt'] = prompt_screen[-3000:]
            require(not marker.exists(), 'The command ran before anyone answered its prompt')
            step('permission prompt', reportedAfterSeenOnScreenSeconds=round(seen['waiting'] - seen['dialog'], 3))

            queued = steer(QUEUED_TEXT)
            require(queued.get('delivery') == 'queued' and queued.get('delivered') is False
                    and queued.get('queuePosition') == 1, f'Not held while the prompt was on screen: {queued}')
            time.sleep(8)
            held_screen = screen()
            evidence['screens']['prompt-after-queued-send'] = held_screen[-3000:]
            require(on_screen(held_screen) and agent_state() == 'waiting',
                    'The permission prompt did not stay on screen after the send')
            require(not marker.exists(), 'The held message answered the permission prompt: its command ran')
            require(QUEUED_TEXT not in held_screen, 'The held message was typed while the prompt was on screen')
            step('prompt on screen: queued, nothing typed', result=queued)

            # The check answers the prompt, as the user would. The turn goes
            # on and ends, and then Toastty types the held message.
            instance.request('app_control.run_action', dict(
                id='terminal.send-text', args=dict(panelID=get()['agentState']['panelID'], text='1', submit=True)))
            wait_for('the approved command to run', marker.exists, timeout=60, interval=0.5)
            reply('TOUCH-DONE')
            reply('QUEUED-OK')
            step('held message typed after the turn', lastReply=get().get('lastReply'))

        final = cli_result('task', 'get', task_id)
        require(final.get('lastUserInputAt') is None,
                f"The sends counted as the user's typing: {final.get('lastUserInputAt')}")
        step('not the user\'s typing', lastUserInputAt=final.get('lastUserInputAt'))
        evidence['status'] = 'passed'
    except Exception as error:  # Always keep the failure evidence.
        evidence['failure'] = repr(error)
        try:
            evidence['screens']['failed'] = {
                panel: instance.query('terminal.visible-text', panelID=panel, tail=60).get('text', '')[-3000:]
                for workspace in instance.query('workspace.list')['workspaces']
                for panel in panel_ids(instance.query('workspace.snapshot', workspaceID=workspace['workspaceID']))
            }
            evidence['tasks'] = instance.query('task.list')['tasks']
        except Exception as diagnostics_error:
            evidence['diagnosticsError'] = repr(diagnostics_error)
        raise
    finally:
        instance_log = runtime_home / 'logs/toastty.log'
        if instance_log.is_file():
            shutil.copyfile(instance_log, artifacts / f'{PREFIX}-{provider}-instance.log')
            evidence['logLines'] = [line for line in instance_log.read_text().splitlines()
                                    if any(word in line.lower() for word in LOG_WORDS)]
        (artifacts / f'{PREFIX}-{provider}.json').write_text(json.dumps(evidence, indent=2, sort_keys=True, default=str))
        if instance is not None:
            try:
                instance.kill()
            except Exception:
                pass
        if provider == 'claude':
            queue_check.set_directory_trust(repository, False)
            project = queue_check.claude_project_directory(repository)
            if project.is_dir():
                capture = artifacts / f'{PREFIX}-{provider}-transcripts'
                capture.mkdir(exist_ok=True)
                for path in project.glob('*.jsonl'):
                    shutil.copyfile(path, capture / path.name)
                # Only the project for this run's own repository.
                shutil.rmtree(project, ignore_errors=True)
        else:
            start_work_check.forget_codex_trust(parent)
        shutil.rmtree(parent, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    print(json.dumps(evidence, indent=2, sort_keys=True, default=str))


if __name__ == '__main__':
    main()
