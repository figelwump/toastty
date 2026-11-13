#!/usr/bin/env python3
"""Check that a task finishes when the child tasks it started finish.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-parent-task-rollup-check.py'.

The check starts its own instance of the wrapper's build with a throwaway
runtime home and user home (a git repository with `release_tags`), a fake
agent, and a fake `gh` first on the instance's login-shell PATH. Through the
real CLI it checks that:
- tasks created from a task's agent session record that task as their parent;
- the parent stays Idle while a child is open;
- after the last child merges, an unread finished turn keeps the parent in
  Needs you; once the turn is read the parent is To ship, with
  `finishedThroughChildren`, and its record has no merge or done time;
- `task watch <parent> --until to-ship --wait` holds at once;
- once every child is Done, the parent is Done.
Captures of the All segment and the Tasks view go to the artifacts
directory when the app or the screen allows one; a missing capture is
recorded, not failed.
"""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


base = load('task_create_check', 'remote-task-create-check.py')
merge_check = load('task_merge_check', 'remote-task-merge-check.py')
require, wait_for, Instance, FAKE_AGENT = base.require, base.wait_for, base.Instance, base.FAKE_AGENT
SLUG = 'toastty-check/project'


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-parent-rollup-check-', dir='/tmp')).resolve()
    helper = root / 'task-stages-ui-helper'
    subprocess.run(['swiftc', '-O', str(HERE / 'task-stages-ui-helper.swift'), '-o', str(helper)], check=True)

    runtime_home, user_home, fake_bin, zdotdir = root / 'runtime-home', root / 'user-home', root / 'bin', root / 'zdotdir'
    for directory in (runtime_home, user_home / '.toastty', fake_bin, zdotdir):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT)
    agent.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text(
        f'[defaults]\nagent = "claude"\n\n[workspace.{json.dumps(str(user_home))}]\nrelease_tags = "v*"\n')

    # The fake gh serves the children's pull requests from a state file.
    gh_state = root / 'gh-state.json'
    prs = {}

    def save_prs():
        gh_state.write_text(json.dumps(dict(slug=SLUG, project=str(user_home), prs=prs)))

    save_prs()
    (fake_bin / 'gh').write_text(merge_check.FAKE_GH)
    (fake_bin / 'gh').chmod(0o755)
    (fake_bin / 'state-path').write_text(str(gh_state))
    for name in ('.zshenv', '.zprofile'):
        (zdotdir / name).write_text('')
    (zdotdir / '.zshrc').write_text(f'export PATH="{fake_bin}:$PATH"\n')

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-parent-rollup-check',
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        ZDOTDIR=str(zdotdir),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], root=str(root), captures=[])

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[parent-rollup-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def cli_json(*arguments, session=None, check=True):
        env = dict(environment, TOASTTY_SESSION_ID=session) if session else environment
        result = subprocess.run([str(cli), '--json', *arguments], env=env, capture_output=True, text=True, timeout=120)
        if check:
            require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        if not result.stdout.strip():
            return {}
        return json.loads(result.stdout).get('result') or {}

    def task(task_id):
        return cli_json('task', 'get', task_id)

    def stage(task_id):
        return task(task_id)['stage']

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / 'remote-parent-rollup-check-app.log')
    pid = instance.process.pid

    def capture(name):
        """Evidence only, as in remote-task-stages-check.py."""
        path = artifacts / f'{name}.png'
        time.sleep(0.6)
        response = instance.request('automation.capture_screenshot', dict(step=name))
        if response.get('ok'):
            shutil.copyfile(response['result']['path'], path)
        else:
            result = subprocess.run([str(helper), 'capture', str(pid), str(path)], capture_output=True, text=True, timeout=60)
            if result.returncode != 0:
                step('capture unavailable', file=path.name, app=response.get('error'), window=result.stderr.strip())
                return
        evidence['captures'].append(path.name)
        step('captured', file=path.name)

    def end_turn(session):
        for kind, summary in (('working', 'Working'), ('ready', 'Ready')):
            cli_json('session', 'status', '--session', session, '--kind', kind, '--summary', summary)
            time.sleep(0.3)

    def read_turn(task_space):
        panel = instance.query('workspace.snapshot', workspaceID=task_space)['slotPanelIDs'][0]
        cli_json('action', 'run', 'workspace.focus-panel', '--workspace', task_space, '--panel', panel)

    def refresh_pull_requests():
        # Opening the Tasks view asks GitHub about every open pull request.
        cli_json('action', 'run', 'window.tasks.show', '--window', window_id)
        time.sleep(0.5)

    try:
        workspaces = instance.wait_until_ready()
        workspace_id, window_id = workspaces[0]['workspaceID'], workspaces[0]['windowID']
        wait_for('the first terminal in the user home', lambda: str(user_home) in [
            os.path.realpath(cwd) for cwd in next(
                w for w in instance.query('workspace.list')['workspaces'] if w['workspaceID'] == workspace_id
            )['terminalCwds']], interval=1)
        step('booted', workspaceID=workspace_id)

        # 1. The parent task, and two children its agent creates.
        parent = cli_json('task', 'create', 'Act on the signup feedback', '--workspace', workspace_id, '--wait', '--timeout', '90')
        parent_id, parent_space, parent_session = parent['taskID'], parent['setup']['taskSpaceWorkspaceID'], parent['setup']['sessionID']
        children = []
        for title in ('Tighten the signup copy', 'Fix the signup email'):
            child = cli_json('task', 'create', title, '--workspace', workspace_id, '--wait', '--timeout', '90', session=parent_session)
            require(child.get('parentTaskID') == parent_id, f'The child should record its parent: {child.get("parentTaskID")}')
            children.append(child)
        for child in children:
            end_turn(child['setup']['sessionID'])
        end_turn(parent_session)
        read_turn(parent_space)
        idle = wait_for('the parent to be idle', lambda: (s := stage(parent_id))['group'] == 'idle' and s)
        step('parent idle with open children', stage=idle)

        # 2. Each child links a pull request; the first one merges.
        for number, child in enumerate(children, start=1):
            prs[str(number)] = dict(number=number, state='OPEN', branch=f'child-{number}', head=f'{number:040d}', pending=False)
            save_prs()
            cli_json('action', 'run', 'workspace.set-annotation', '--workspace', child['setup']['taskSpaceWorkspaceID'],
                     'key=github-pr', f'text=PR #{number}', f'url=https://github.com/{SLUG}/pull/{number}')
        prs['1']['state'] = 'MERGED'
        save_prs()
        refresh_pull_requests()
        wait_for('the first child to wait to ship', lambda: stage(children[0]['taskID'])['group'] == 'toShip')
        require(stage(parent_id)['group'] == 'idle', f'One open child should keep the parent idle: {stage(parent_id)}')
        cli_json('action', 'run', 'window.tasks.hide', '--window', window_id, check=False)
        cli_json('action', 'run', 'window.sidebar.set-segment', '--window', window_id, 'segment=all')
        capture('1-all-one-child-open')

        # 3. The parent's agent reports, and the last child merges. The
        # unread turn keeps the parent in Needs you.
        cli_json('action', 'run', 'workspace.select', '--workspace', workspace_id)
        end_turn(parent_session)
        wait_for('the parent turn to be unread', lambda: stage(parent_id).get('attention') == 'agentFinished')
        prs['2']['state'] = 'MERGED'
        save_prs()
        refresh_pull_requests()
        wait_for('the last child to wait to ship', lambda: stage(children[1]['taskID'])['group'] == 'toShip')
        unread = stage(parent_id)
        require(unread.get('attention') == 'agentFinished', f'The unread turn should keep the parent in Needs you: {unread}')
        step('parent waits for its unread turn', stage=unread)
        cli_json('action', 'run', 'window.tasks.hide', '--window', window_id, check=False)
        capture('2-all-parent-unread')

        # 4. Reading the turn moves the parent to To ship, through its
        # children; nothing is stored on it.
        read_turn(parent_space)
        shipping = wait_for('the parent to wait to ship', lambda: (s := stage(parent_id))['group'] == 'toShip' and s)
        require(shipping.get('finishedThroughChildren') is True, f'Expected finishedThroughChildren: {shipping}')
        record = task(parent_id)
        require(all(record.get(key) is None for key in ('mergedAt', 'doneAt', 'shippedAt', 'archivedAt')),
                f'The parent record should store no ending: {record}')
        step('parent to ship through its children', stage=shipping)
        watched = subprocess.run([str(cli), 'task', 'watch', parent_id, '--until', 'to-ship', '--wait', '--timeout', '20'],
                                 env=environment, capture_output=True, text=True, timeout=60)
        require(watched.returncode == 0, f'The to-ship watch should hold: {watched.stdout} {watched.stderr}')
        step('to-ship watch held', output=watched.stdout.strip())
        cli_json('action', 'run', 'workspace.select', '--workspace', workspace_id)
        capture('3-all-parent-to-ship')
        cli_json('action', 'run', 'window.tasks.show', '--window', window_id)
        cli_json('task', 'list')  # let the view settle
        capture('4-tasks-view-parent-to-ship')

        # 5. Once every child is Done, the parent is Done.
        for child in children:
            cli_json('task', 'mark-done', child['taskID'])
        done = wait_for('the parent to be done', lambda: (s := stage(parent_id))['group'] == 'done' and s)
        require(done.get('finishedThroughChildren') is True, f'Expected finishedThroughChildren: {done}')
        step('parent done through its children', stage=done)
        capture('5-tasks-view-parent-done')

        evidence['status'] = 'passed'
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / 'remote-parent-rollup-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[parent-rollup-check] passed', flush=True)


if __name__ == '__main__':
    main()
