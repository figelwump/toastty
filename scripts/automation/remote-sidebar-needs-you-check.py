#!/usr/bin/env python3
"""Check the sidebar's Coordinator row and Needs you list in a real app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-sidebar-needs-you-check.py'. It needs an
unlocked screen: it presses sidebar buttons in its own app instance through
Accessibility and captures its window.

The check starts its own instance of the wrapper's build, as
remote-sidebar-to-ship-check.py does, with a fake agent and a fake `gh` that
reports each pull request open. It creates a task and links a pull request to
its task space, so the task waits for review. Through the UI and the CLI it
checks that:
- the Coordinator row counts the task, and the Projects | Status switcher is
  gone;
- the task's Needs you row shows the review reason and offers Merge;
- Merge asks in the row first: Cancel leaves the task unmerged;
- Merge, then the row's Merge, accepts the merge (`mergeRequestedAt`).
Captures of each step and remote-sidebar-needs-you-check.json go to the
artifacts directory when the app or the screen allows one; a missing capture
is recorded, not failed.
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
_spec = importlib.util.spec_from_file_location('remote_task_create_check', HERE / 'remote-task-create-check.py')
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)
require, wait_for, Instance, FAKE_AGENT = base.require, base.wait_for, base.Instance, base.FAKE_AGENT
_spec = importlib.util.spec_from_file_location('remote_sidebar_to_ship_check', HERE / 'remote-sidebar-to-ship-check.py')
to_ship = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(to_ship)

PREFIX = 'remote-sidebar-needs-you'
SLUG = 'toastty-check/project'
TITLE = 'Unread dot stays on'


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-needs-you-check-', dir='/tmp')).resolve()
    driver, helper = root / 'quick-entry-ui-driver', root / 'task-stages-ui-helper'
    for source, output in ((HERE / 'quick-entry-ui-driver.swift', driver), (HERE / 'task-stages-ui-helper.swift', helper)):
        subprocess.run(['swiftc', '-O', str(source), '-o', str(output)], check=True)

    def run_tool(tool, *arguments, check=True):
        result = subprocess.run([str(tool), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        if check:
            require(result.returncode == 0, f'{tool.name} {arguments[0]} failed: {result.stderr.strip()}')
        return result

    require(run_tool(driver, 'locked').stdout.strip() == '0', 'The remote screen is locked; unlock it to press rows')

    runtime_home, user_home, fake_bin, zdotdir = root / 'runtime-home', root / 'user-home', root / 'bin', root / 'zdotdir'
    for directory in (runtime_home, user_home / '.toastty', fake_bin, zdotdir):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT)
    agent.chmod(0o755)
    gh_state = root / 'gh-state.json'
    gh_state.write_text('{}')
    (fake_bin / 'gh').write_text(to_ship.FAKE_GH)
    (fake_bin / 'gh').chmod(0o755)
    (fake_bin / 'state-path').write_text(str(gh_state))
    for name in ('.zshenv', '.zprofile'):
        (zdotdir / name).write_text(f'[ -f "$HOME/{name}" ] && source "$HOME/{name}"\n')
    (zdotdir / '.zshrc').write_text(f'[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"\nexport PATH="{fake_bin}:$PATH"\n')
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL=PREFIX,
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        ZDOTDIR=str(zdotdir),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], captures=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[sidebar-needs-you-check] {name} {json.dumps(facts, default=str, ensure_ascii=False)}', flush=True)

    def cli_json(*arguments):
        result = subprocess.run([str(cli), '--json', *arguments], env=environment,
                                capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-check-app.log')
    pid = instance.process.pid

    def capture(name):
        """Evidence only: a capture that cannot be made is recorded, not failed."""
        path = artifacts / f'{name}.png'
        run_tool(helper, 'press', pid, 'xmark', check=False)
        time.sleep(0.8)
        response = instance.request('automation.capture_screenshot', dict(step=name, path=str(path)))
        if response.get('ok'):
            if Path(response['result']['path']) != path:
                shutil.copyfile(response['result']['path'], path)
        else:
            result = run_tool(helper, 'capture', pid, path, check=False)
            if result.returncode != 0:
                step('capture unavailable', file=path.name, app=response.get('error'), window=result.stderr.strip())
                return
        evidence['captures'].append(path.name)
        step('captured', file=path.name)

    def labels():
        result = run_tool(driver, 'labels', pid, '*', check=False)
        return json.loads(result.stdout) if result.returncode == 0 else []

    def label_starting(prefix):
        return next((label for label in labels() if label.startswith(prefix)), None)

    def exists(identifier):
        return run_tool(helper, 'exists', pid, identifier, check=False).returncode == 0

    try:
        workspaces = instance.wait_until_ready()
        workspace_id = workspaces[0]['workspaceID']
        wait_for('the first terminal in the user home', lambda: str(user_home) in [
            os.path.realpath(cwd) for w in instance.query('workspace.list')['workspaces']
            if w['workspaceID'] == workspace_id for cwd in w['terminalCwds']], interval=1)

        task = cli_json('task', 'create', TITLE, '--workspace', workspace_id, '--wait', '--timeout', '90')
        task_id = task['taskID']
        cli_json('action', 'run', 'workspace.set-annotation', '--workspace', task['setup']['taskSpaceWorkspaceID'],
                 'key=github-pr', 'text=PR #1', f'url=https://github.com/{SLUG}/pull/1')
        wait_for('the task to wait for review', lambda: cli_json('task', 'get', task_id)['stage'].get('attention') == 'review',
                 interval=1)
        step('task waits for review', taskID=task_id)

        # 1. The Coordinator row counts it; the switcher is gone.
        coordinator = wait_for('the Coordinator row', lambda: label_starting('Coordinator, 1 needs you'))
        require(label_starting('Group the sidebar by') is None, f'The Projects | Status switcher is still there: {labels()}')
        row = wait_for('the Needs you row', lambda: label_starting(f'{TITLE}, review'))
        require(label_starting('Needs you, 1'), f'No Needs you header: {labels()}')
        require(exists(f'sidebar.needsYou.{TITLE}.primary'), 'The row has no primary action')
        step('needs you row', coordinator=coordinator, row=row)
        capture('needs-you-review')

        # 2. Merge asks in the row; Cancel leaves the task alone.
        run_tool(helper, 'press', pid, f'sidebar.needsYou.{TITLE}.primary')
        wait_for('the merge question', lambda: exists(f'sidebar.needsYou.{TITLE}.confirmMerge'))
        require('Merge PR #1?' in run_tool(driver, 'texts', pid, '*').stdout, 'The row does not ask before it merges')
        capture('needs-you-merge-question')
        run_tool(driver, 'press-label', pid, 'Cancel')
        wait_for('the question to close', lambda: exists(f'sidebar.needsYou.{TITLE}.confirmMerge') is False)
        time.sleep(1)
        require(not cli_json('task', 'get', task_id).get('mergeRequestedAt'), 'Cancel accepted the merge')
        step('cancel kept the task')

        # 3. Merge, then Merge in the row, accepts the merge.
        run_tool(helper, 'press', pid, f'sidebar.needsYou.{TITLE}.primary')
        wait_for('the merge question', lambda: exists(f'sidebar.needsYou.{TITLE}.confirmMerge'))
        run_tool(helper, 'press', pid, f'sidebar.needsYou.{TITLE}.confirmMerge')
        accepted = wait_for('the merge to be accepted', lambda: cli_json('task', 'get', task_id).get('mergeRequestedAt'),
                            interval=1)
        step('merge accepted', mergeRequestedAt=accepted)
        capture('needs-you-merge-accepted')

        evidence['status'] = 'passed'
    except Exception:
        dump = subprocess.run([str(helper), 'dump', str(pid)], capture_output=True, text=True, timeout=60)
        (artifacts / f'{PREFIX}-check-ax.txt').write_text(dump.stdout)
        raise
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / f'{PREFIX}-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[sidebar-needs-you-check] passed', flush=True)


if __name__ == '__main__':
    main()
