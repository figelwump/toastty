#!/usr/bin/env python3
"""Check task stages, the Status sidebar and the Tasks view in a real app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-stages-check.py'. It needs an unlocked
screen: it posts real key events to its own app instance and captures its
window.

The check starts its own instance of the wrapper's build with a throwaway
runtime home and user home (a git repository, so the first terminal's
directory is the project root), a fake agent, and a tasks.toml with
`release_tags`. Through the real CLI it checks that:
- a started task reports stage `running`; a linked pull request with no answer
  from GitHub makes it `needsYou`/`review`, and the link is copied to the
  record; the task space's done mark makes it `done`;
- `task adopt` gives a task space made by `workspace.create` a record;
- `window.sidebar.set-segment` and `window.tasks.show` work without changing
  the selected workspace;
- the sidebar Tasks row's + and the Tasks view's New Task open the quick
  entry panel;
- while the Tasks view shows, typing does not reach the terminal under it;
  Esc closes the view, and typing then reaches the terminal again.
Captures of both sidebar segments and the Tasks view go to the artifacts
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
_spec = importlib.util.spec_from_file_location('task_create_check', HERE / 'remote-task-create-check.py')
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)
require, wait_for, Instance, FAKE_AGENT = base.require, base.wait_for, base.Instance, base.FAKE_AGENT

KEY_RETURN, KEY_ESCAPE = 36, 53
PULL_REQUEST = 'https://github.com/toastty-check/no-such-repo/pull/9'


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-task-stages-check-', dir='/tmp')).resolve()
    driver, helper = root / 'quick-entry-ui-driver', root / 'task-stages-ui-helper'
    for source, output in ((HERE / 'quick-entry-ui-driver.swift', driver), (HERE / 'task-stages-ui-helper.swift', helper)):
        subprocess.run(['swiftc', '-O', str(source), '-o', str(output)], check=True)

    def run_tool(tool, *arguments, check=True):
        result = subprocess.run([str(tool), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        if check:
            require(result.returncode == 0, f'{tool.name} {arguments[0]} failed: {result.stderr.strip()}')
        return result

    require(run_tool(driver, 'locked').stdout.strip() == '0', 'The remote screen is locked; unlock it to post key events')

    runtime_home, user_home, fake_bin = root / 'runtime-home', root / 'user-home', root / 'bin'
    for directory in (runtime_home, user_home / '.toastty', fake_bin):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT)
    agent.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text(
        f'[defaults]\nagent = "claude"\n\n[workspace.{json.dumps(str(user_home))}]\nrelease_tags = "v*"\n')

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-task-stages-check',
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], root=str(root), captures=[])

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[task-stages-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def cli_json(*arguments):
        result = subprocess.run([str(cli), '--json', *arguments], env=environment,
                                capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    def stage(task_id):
        return cli_json('task', 'get', task_id)['stage']

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / 'remote-task-stages-check-app.log')
    pid = instance.process.pid

    def capture(name):
        """Evidence only: a capture that cannot be made is recorded, not
        failed. `automation.capture_screenshot` renders in the app, which
        works over SSH, but needs automation mode; a window capture needs
        Screen Recording."""
        path = artifacts / f'{name}.png'
        time.sleep(0.6)
        response = instance.request('automation.capture_screenshot', dict(step=name))
        if response.get('ok'):
            shutil.copyfile(response['result']['path'], path)
        else:
            result = run_tool(helper, 'capture', pid, path, check=False)
            if result.returncode != 0:
                step('capture unavailable', file=path.name, app=response.get('error'), window=result.stderr.strip())
                return
        evidence['captures'].append(path.name)
        step('captured', file=path.name)

    def tasks_view_shown():
        return run_tool(helper, 'exists', pid, 'tasks.view.close', check=False).returncode == 0

    def quick_entry_open():
        listed = run_tool(driver, 'windows', pid, check=False)
        return listed.returncode == 0 and any(w['identifier'] == 'quick-entry.panel' for w in json.loads(listed.stdout))

    def open_and_close_quick_entry(button):
        run_tool(helper, 'press', pid, button)
        wait_for(f'{button} to open quick entry', quick_entry_open, timeout=15)
        run_tool(driver, 'key', KEY_ESCAPE)
        wait_for('quick entry to close', lambda: quick_entry_open() is False, timeout=15)
        step('quick entry opened and closed', button=button)

    try:
        workspaces = instance.wait_until_ready()
        workspace_id, window_id = workspaces[0]['workspaceID'], workspaces[0]['windowID']

        def terminal_in_home():
            listed = instance.query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == workspace_id)['terminalCwds']
            return cwds if str(user_home) in [os.path.realpath(cwd) for cwd in cwds] else None

        wait_for('the first terminal in the user home', terminal_in_home, interval=1)
        snapshot = instance.query('workspace.snapshot', workspaceID=workspace_id)
        terminal_panel = snapshot['slotPanelIDs'][0]
        step('booted', workspaceID=workspace_id, panelID=terminal_panel)

        # 1. A started task runs; a linked pull request with no answer from
        # GitHub waits for review; the done mark finishes it.
        task = cli_json('task', 'create', 'Fix the unread dot', '--workspace', workspace_id, '--wait', '--timeout', '90')
        task_id, task_space = task['taskID'], task['setup']['taskSpaceWorkspaceID']
        require(stage(task_id)['group'] == 'running', f'A started task should be running: {stage(task_id)}')
        cli_json('action', 'run', 'workspace.set-annotation', '--workspace', task_space,
                 'key=github-pr', 'text=PR #9', f'url={PULL_REQUEST}')
        review = wait_for('the review stage', lambda: (s := stage(task_id)).get('attention') == 'review' and s)
        require(cli_json('task', 'get', task_id)['pullRequestURL'] == PULL_REQUEST, 'The link was not copied to the task')
        step('review', stage=review)

        # 2. A task space without a record can be adopted.
        created = cli_json('action', 'run', 'workspace.create', '--window', window_id,
                           'title=qa-untracked', f'parent={workspace_id}', 'activate=false')
        untracked = created.get('workspaceID') or next(
            w['workspaceID'] for w in instance.query('workspace.list')['workspaces'] if w['title'] == 'qa-untracked')
        adopted = cli_json('task', 'adopt', '--workspace', untracked)
        require(adopted['source'] == 'adopted' and adopted['setup']['taskSpaceWorkspaceID'] == untracked,
                f'Adopt did not track the task space: {adopted}')
        step('adopted', taskID=adopted['taskID'], stage=adopted.get('stage'))

        # 3. Both sidebar segments, then the Tasks view; none changes the
        # selected workspace. The + opens quick entry.
        capture('sidebar-projects-review')
        open_and_close_quick_entry('sidebar.tasks.new')
        cli_json('action', 'run', 'window.sidebar.set-segment', '--window', window_id, 'segment=status')
        capture('sidebar-status')
        cli_json('action', 'run', 'workspace.set-done', '--workspace', task_space)
        require(stage(task_id)['group'] == 'done', f'The done mark should finish the task: {stage(task_id)}')
        cli_json('action', 'run', 'window.sidebar.set-segment', '--window', window_id, 'segment=projects')
        capture('sidebar-projects-done')
        cli_json('action', 'run', 'window.tasks.show', '--window', window_id)
        capture('tasks-view')
        try:
            wait_for('the Tasks view', tasks_view_shown, timeout=20)
        except AssertionError:
            (artifacts / 'tasks-view-ax.txt').write_text(run_tool(helper, 'dump', pid, check=False).stdout)
            raise
        open_and_close_quick_entry('tasks.view.new')
        cli_json('action', 'run', 'window.sidebar.toggle', '--window', window_id)
        capture('tasks-view-without-sidebar')
        cli_json('action', 'run', 'window.sidebar.toggle', '--window', window_id)
        selected = [w['workspaceID'] for w in instance.query('workspace.list')['workspaces'] if w['isSelected']]
        require(selected == [workspace_id], f'Showing the Tasks view changed the selection: {selected}')

        # 4. Typing under the Tasks view does not reach the terminal; Esc
        # closes it, and typing then does.
        run_tool(helper, 'activate', pid)
        wait_for('the instance in front', lambda: run_tool(helper, 'frontmost-pid').stdout.strip() == str(pid), timeout=15)
        run_tool(driver, 'type', 'echo covered-marker')
        run_tool(driver, 'key', KEY_RETURN)
        time.sleep(1.5)

        def terminal_text():
            return instance.query('terminal.visible-text', panelID=terminal_panel).get('text', '')

        require('covered-marker' not in terminal_text(), 'Typing under the Tasks view reached the terminal')
        require(tasks_view_shown(), 'The Tasks view closed while typing')
        step('typing stayed out of the covered terminal')
        run_tool(driver, 'key', KEY_ESCAPE)
        wait_for('Esc to close the Tasks view', lambda: tasks_view_shown() is False)
        time.sleep(0.5)
        run_tool(driver, 'type', 'echo visible-marker')
        run_tool(driver, 'key', KEY_RETURN)
        wait_for('typing to reach the terminal again', lambda: 'visible-marker' in terminal_text())
        step('focus returned to the terminal')
        capture('after-tasks-view')

        evidence['status'] = 'passed'
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / 'remote-task-stages-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[task-stages-check] passed', flush=True)


if __name__ == '__main__':
    main()
