#!/usr/bin/env python3
"""Coordinate two tasks with real agents through a relaunch, in a disposable app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-coordination-check.py [--provider codex|claude] [--gui-session]'.

The check starts its own second instance of the wrapper's build, with a
throwaway runtime home and a git repository as its user home, and real agents
(subscription usage is consumed). Claude's login lives in the GUI session on a
host driven over SSH, so add --gui-session for Claude. This script plays a
coordinator outside Toastty: it has no TOASTTY_SESSION_ID, so it is unscoped.

It checks that:
- the coordinator creates two tasks, reads each agent's state and last reply,
  and polls with `task list --changed-since`;
- task B's own agent runs `task watch <A> --until idle` and ends its turn;
- the watch is saved and still pending after the app is killed and relaunched,
  and both agents come back in their panes;
- `task send` by task ID reaches A's restored agent; when A finishes that turn,
  Toastty wakes B with a one-line message, and B answers it;
- a cursor from before the relaunch gets `reset`, and a later cursor lists A;
- `task watch --wait` blocks until A's next turn ends and exits 0;
- a stage watch, `--until ready-for-review --wait`, returns once A's task space
  links a pull request while its agent is idle.
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

PREFIX = 'remote-task-coordination'
A_TEXT = (
    'This is an automated Toastty check. Run no command and edit no file unless a message asks you to. '
    'Reply with exactly READY-A now. For each later message, do what it says and nothing more.'
)


def b_text(a_task_id):
    return (
        'This is an automated Toastty check. Do not edit files.\n'
        f'1. Now: run exactly this one shell command, and no other command: '
        f'"$TOASTTY_CLI_PATH" task watch {a_task_id} --until idle\n'
        '   Then reply with exactly WATCHING-B and end your turn.\n'
        '2. Later, when a message that starts with [Toastty watch arrives: run no command, and reply with exactly WOKE-B.'
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=('codex', 'claude'), default='codex')
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

    root = Path(tempfile.mkdtemp(prefix='toastty-coordination-check-', dir='/tmp')).resolve()
    runtime_home = root / 'runtime-home'
    runtime_home.mkdir()
    # Codex trusts the host home's subfolders, so the repository stays there.
    parent = Path.home() / 'toastty-queue-steer-checks' / f'coordination-{uuid.uuid4().hex[:8]}'
    parent.mkdir(parents=True)
    repository = parent / 'project'
    subprocess.run(['git', 'init', '-q', '-b', 'main', str(repository)], check=True)
    (repository / '.git/info/exclude').write_text('.toastty/\n.codex\n.claude\n')
    toastty_dir = repository / '.toastty'
    toastty_dir.mkdir()
    for name in ('.codex', '.claude'):
        if (Path.home() / name).exists():
            (repository / name).symlink_to(Path.home() / name)

    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    version, argv = start_work_check.provider_profile(provider, environment, repository)
    if provider == 'codex':
        # A resumed Codex offers an update; nobody should take it on a shared host.
        argv = [argv[0], '-c', 'check_for_update_on_startup=false', *argv[1:]]
    else:
        queue_check.set_directory_trust(repository, True)
    (toastty_dir / 'agents.toml').write_text(
        f'[{provider}]\ndisplayName = "{provider}"\nargv = {json.dumps(argv)}\ninitialPromptPlacement = "trailing"\n')
    (toastty_dir / 'tasks.toml').write_text(f'[defaults]\nagent = "{provider}"\n')

    socket_path = str(root / 'socket.sock')
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-task-coordination-check',
        TOASTTY_SOCKET_PATH=socket_path,
        CFFIXED_USER_HOME=str(repository),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', provider=provider, cliVersion=version, steps=[])

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[coordination-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_cli(*arguments, timeout=600):
        # No TOASTTY_SESSION_ID: a coordinator outside Toastty.
        result = subprocess.run([str(cli), '--json', *arguments], env=environment,
                                capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout, result.stderr

    def cli_result(*arguments):
        code, out, err = run_cli(*arguments)
        require(code == 0, f'{" ".join(arguments[:2])} failed ({code}): {out} {err}')
        return json.loads(out)['result']

    state = dict(instance=None, launch=0)
    answered = []

    def answer_dialogs():
        """Answers Codex's folder trust prompt, and skips an update prompt, as a
        person would: once per prompt per app launch, and only the prompt shown
        last, so an answer never lands on a later prompt."""
        instance = state['instance']
        for workspace in instance.query('workspace.list')['workspaces']:
            for panel in panel_ids(instance.query('workspace.snapshot', workspaceID=workspace['workspaceID'])):
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
                key = (panel, kind, state['launch'])
                if key in [(a['panel'], a['kind'], a['launch']) for a in answered]:
                    continue
                answered.append(dict(panel=panel, kind=kind, launch=state['launch'], at=time.time()))
                instance.request('app_control.run_action', dict(
                    id='terminal.send-text', args=dict(panelID=panel, text=choice, submit=True)))

    def answering(probe):
        def wrapped():
            answer_dialogs()
            return probe()
        return wrapped

    def reply_on(task, marker, timeout=300):
        snapshot = state['instance'].query('workspace.snapshot', workspaceID=task['setup']['taskSpaceWorkspaceID'])
        return wait_for(f'{marker} on screen', answering(lambda: visible_text_with(state['instance'], snapshot, marker)),
                        timeout=timeout, interval=3)

    def launch():
        state['launch'] += 1
        state['instance'] = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-{provider}-app.log')
        return state['instance'].wait_until_ready()

    try:
        workspace_id = launch()[0]['workspaceID']

        def terminal_in_repository():
            listed = state['instance'].query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == workspace_id)['terminalCwds']
            return str(repository) in [os.path.realpath(cwd) for cwd in cwds]

        wait_for('the first terminal in the repository', terminal_in_repository, interval=1)
        step('booted', workspaceID=workspace_id)

        # 1. The coordinator makes two tasks; B's own agent watches A.
        a = cli_result('task', 'create', A_TEXT, '--title', 'Coordination check A', '--workspace', workspace_id,
                       '--wait', '--timeout', '120')
        reply_on(a, 'READY-A')
        b = cli_result('task', 'create', b_text(a['taskID']), '--title', 'Coordination check B', '--workspace', workspace_id,
                       '--wait', '--timeout', '120')
        reply_on(b, 'WATCHING-B')
        step('both tasks started', a=a['taskID'], b=b['taskID'])

        watches = cli_result('task', 'watches', '--notify', b['taskID'])['watches']
        require(len(watches) == 1 and watches[0]['taskID'] == a['taskID'] and watches[0]['until'] == 'idle'
                and watches[0]['state'] == 'pending', f'B did not leave one pending watch on A: {watches}')
        watch_id = watches[0]['watchID']
        step('B watches A', watch=watches[0])

        # 2. The coordinator reads both agents and polls for changes.
        listed = cli_result('task', 'list', '--include-reply')
        by_id = {task['taskID']: task for task in listed['tasks']}
        require(by_id[a['taskID']]['agentState']['state'] == 'idle', f"A is not idle: {by_id[a['taskID']]['agentState']}")
        a_reply = wait_for('A\'s last reply', lambda: (lambda r: r if r and 'READY-A' in r['text'] else None)(
            cli_result('task', 'get', a['taskID'])['lastReply']), timeout=60, interval=2)
        step('read A', agentState=by_id[a['taskID']]['agentState'], lastReply=a_reply)
        cursor_before = listed['cursor']
        quiet = cli_result('task', 'list', '--changed-since', cursor_before)
        require(quiet['tasks'] == [] and quiet['reset'] is False, f'Idle tasks were listed as changed: {quiet}')

        # 3. Relaunch: the watch is saved and both agents come back.
        state['instance'].kill()
        step('killed the app')
        launch()
        restored = wait_for('both agents back', answering(lambda: (lambda tasks: tasks if all(
            t['agentState']['state'] != 'notRunning' for t in tasks) else None)(
            [cli_result('task', 'get', task['taskID']) for task in (a, b)])), timeout=300, interval=3)
        step('relaunched', agents=[t['agentState'] for t in restored])
        after = cli_result('task', 'watches', '--notify', b['taskID'])['watches']
        require([w['watchID'] for w in after] == [watch_id] and after[0]['state'] == 'pending',
                f'The watch did not survive the relaunch: {after}')
        reset = cli_result('task', 'list', '--changed-since', cursor_before)
        require(reset['reset'] is True and len(reset['tasks']) == 2, f'An old cursor did not reset: {reset}')
        cursor = reset['cursor']
        # Let the restored agents settle at their prompts.
        time.sleep(10)
        cursor = cli_result('task', 'list', '--changed-since', cursor)['cursor']

        # 4. A follow-up by task ID reaches A; A's turn wakes B.
        sent = cli_result('task', 'send', a['taskID'], 'Run no command. Reply with exactly DONE-A.')
        step('sent to A', result=sent)
        reply_on(a, 'DONE-A')
        fired = wait_for('the watch to fire and be delivered', lambda: (lambda w: w if w and w[0]['state'] != 'pending'
                         and w[0].get('delivered') else None)(cli_result('task', 'watches', '--notify', b['taskID'])['watches']),
                         timeout=120, interval=2)
        require(fired[0]['state'] == 'fired' and fired[0]['reason'] == 'is idle', f'Unexpected watch outcome: {fired}')
        woke = reply_on(b, 'WOKE-B')
        evidence['bScreen'] = woke[-3000:]
        require(f'[Toastty watch {watch_id}]' in woke.replace('\n', ''), 'B\'s screen does not show the watch message')
        step('B was woken', watch=fired[0])
        changed = cli_result('task', 'list', '--changed-since', cursor)
        require(a['taskID'] in [t['taskID'] for t in changed['tasks']], f'A is not listed as changed: {changed}')
        done_reply = wait_for('A\'s new reply', lambda: (lambda r: r if r and 'DONE-A' in r['text'] else None)(
            cli_result('task', 'get', a['taskID'])['lastReply']), timeout=60, interval=2)
        step('polled the change', changed=[t['taskID'] for t in changed['tasks']], lastReply=done_reply)

        # 5. A caller outside Toastty blocks on a watch instead.
        waiter = subprocess.Popen([str(cli), 'task', 'watch', a['taskID'], '--until', 'idle', '--wait', '--timeout', '300'],
                                  env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(2)
        cli_result('task', 'send', a['taskID'], 'Run no command. Reply with exactly AGAIN-A.')
        out, err = waiter.communicate(timeout=360)
        require(waiter.returncode == 0 and 'is idle' in out, f'watch --wait failed ({waiter.returncode}): {out} {err}')
        step('watch --wait returned', output=out.strip())

        # 6. A stage watch: a linked pull request that GitHub does not know,
        # and an idle agent, wait for review.
        waiter = subprocess.Popen([str(cli), 'task', 'watch', a['taskID'], '--until', 'ready-for-review', '--wait',
                                   '--timeout', '120'],
                                  env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(2)
        cli_result('action', 'run', 'workspace.set-annotation', '--workspace', a['setup']['taskSpaceWorkspaceID'],
                   'key=github-pr', 'text=PR #9', 'url=https://github.com/example/toastty/pull/9')
        out, err = waiter.communicate(timeout=180)
        require(waiter.returncode == 0 and 'is ready for review' in out,
                f'the stage watch failed ({waiter.returncode}): {out} {err}')
        step('stage watch returned', output=out.strip(), stage=cli_result('task', 'get', a['taskID']).get('stage'))

        evidence['status'] = 'passed'
    except Exception as error:  # Always keep the failure evidence.
        evidence['failure'] = repr(error)
        try:
            instance = state['instance']
            screens = {}
            for workspace in instance.query('workspace.list')['workspaces']:
                for panel in panel_ids(instance.query('workspace.snapshot', workspaceID=workspace['workspaceID'])):
                    try:
                        screens[panel] = instance.query('terminal.visible-text', panelID=panel, tail=40).get('text', '')[-2000:]
                    except AssertionError:
                        pass
            evidence['screens'] = screens
            evidence['tasks'] = json.loads(run_cli('task', 'list', '--include-reply')[1])['result']['tasks']
            evidence['watches'] = json.loads(run_cli('task', 'watches')[1])['result']['watches']
        except Exception as diagnostics_error:
            evidence['diagnosticsError'] = repr(diagnostics_error)
        raise
    finally:
        evidence['dialogs'] = answered
        instance_log = runtime_home / 'logs/toastty.log'
        if instance_log.is_file():
            shutil.copyfile(instance_log, artifacts / f'{PREFIX}-{provider}-instance.log')
            evidence['logLines'] = [line for line in instance_log.read_text().splitlines()
                                    if 'watch' in line.lower() or 'sent a message to a task' in line.lower()]
        (artifacts / f'{PREFIX}-{provider}.json').write_text(json.dumps(evidence, indent=2, sort_keys=True, default=str))
        try:
            state['instance'].kill()
        except Exception:
            pass
        if provider == 'claude':
            queue_check.set_directory_trust(repository, False)
        else:
            start_work_check.forget_codex_trust(parent)
        shutil.rmtree(parent, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    print(json.dumps(evidence, indent=2, sort_keys=True, default=str))


if __name__ == '__main__':
    main()
