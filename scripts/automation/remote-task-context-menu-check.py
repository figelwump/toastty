#!/usr/bin/env python3
"""Check task context menus in the sidebar of a real app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-context-menu-check.py'. It needs an
unlocked screen: it right-clicks rows and posts key events to its own app
instance through Accessibility.

The check starts its own instance of the wrapper's build, as
remote-task-stages-check.py does, with a fake agent and four tasks. Through
real right-clicks, key events and the CLI it checks that:
- a task space row offers the task's actions: Open PR and Merge with a pull
  request, Mark Done without one, Archive… on both, and the workspace items
  below a divider, with no Mark as done; once its task space is selected,
  Open Task Space leaves the menu and Merge shows Option+Shift+M;
- the Needs you rows, for a task whose task space closed and for a pull
  request waiting for review, offer the same task actions;
- Archive… from a task space row opens the archive alert; Cancel keeps the
  task; Archive archives it;
- Mark Done from a task space row's menu finishes the task.
The menus, the alert's text and each step go to
remote-task-context-menu-check.json in the artifacts directory.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

HERE = Path(__file__).parent
_spec = importlib.util.spec_from_file_location('task_create_check', HERE / 'remote-task-create-check.py')
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)
require, wait_for, Instance, FAKE_AGENT = base.require, base.wait_for, base.Instance, base.FAKE_AGENT

PULL_REQUEST = 'https://github.com/toastty-check/no-such-repo/pull/9'
MERGE_SHORTCUT = 'Merge\t⌥⇧M'
WORKSPACE_ITEMS = ['Move to top level', 'Close workspace']


def plain(items):
    """Menu titles without their shortcut hints."""
    return [item.split('\t')[0] for item in items]


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-task-context-menu-check-', dir='/tmp')).resolve()
    driver, helper = root / 'quick-entry-ui-driver', root / 'task-stages-ui-helper'
    for source, output in ((HERE / 'quick-entry-ui-driver.swift', driver), (HERE / 'task-stages-ui-helper.swift', helper)):
        subprocess.run(['swiftc', '-O', str(source), '-o', str(output)], check=True)

    def run_driver(*arguments, check=True):
        result = subprocess.run([str(driver), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        if check:
            require(result.returncode == 0, f'driver {arguments[0]} failed: {result.stderr.strip()}')
        return result

    require(run_driver('locked').stdout.strip() == '0', 'The remote screen is locked; unlock it to right-click rows')

    runtime_home, user_home, fake_bin = root / 'runtime-home', root / 'user-home', root / 'bin'
    for directory in (runtime_home, user_home / '.toastty', fake_bin):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT)
    agent.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-task-context-menu-check',
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], menus={}, root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[task-context-menu-check] {name} {json.dumps(facts, default=str, ensure_ascii=False)}', flush=True)

    def cli_json(*arguments):
        result = subprocess.run([str(cli), '--json', *arguments], env=environment,
                                capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    def stage(task_id):
        return cli_json('task', 'get', task_id)['stage']

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / 'remote-task-context-menu-check-app.log')
    pid = instance.process.pid

    def capture(name):
        """Evidence only: a capture that cannot be made is recorded, not
        failed. `automation.capture_screenshot` needs automation mode, which
        skips the archive alert, so this instance captures only in an
        evidence build that allows it outside automation mode."""
        time.sleep(0.4)
        try:
            response = instance.request('automation.capture_screenshot', dict(step=name, path=str(artifacts / f'{name}.png')))
        except OSError as error:
            response = dict(ok=False, error=str(error))
        if response.get('ok'):
            evidence.setdefault('captures', []).append(f'{name}.png')
        else:
            evidence.setdefault('capturesUnavailable', []).append(name)

    def menu(name, identifier, label='-', press=None):
        """Right-clicks a row and records its menu; `press` picks an item.
        Without one, the open menu is captured, then closed."""
        arguments = ['context-menu', pid, identifier, label, press or '@keep']
        items = json.loads(run_driver(*arguments).stdout)
        if press is None:
            # The app draws an open menu's window blank in its own capture,
            # so its items' frames are kept to draw them over it.
            frames = run_driver('menu-frames', pid, check=False)
            if frames.returncode == 0:
                evidence.setdefault('menuFrames', {})[name] = json.loads(frames.stdout)
            capture(f'menu-{name}')
            run_driver('close-menu', pid)
        # The open menu can end with an untitled item of its own.
        while items and items[-1] == '—':
            items.pop()
        evidence['menus'][name] = items
        step('menu', menu=name, items=items, pressed=press)
        time.sleep(0.4)
        return items

    def row_label(workspace):
        """A sidebar task space row's label starts with its workspace title."""
        title = next(w['title'] for w in instance.query('workspace.list')['workspaces'] if w['workspaceID'] == workspace)
        return f'{title}, task space'

    try:
        workspaces = instance.wait_until_ready()
        workspace_id = workspaces[0]['workspaceID']
        wait_for('the first terminal in the user home', lambda: str(user_home) in [
            os.path.realpath(cwd) for w in instance.query('workspace.list')['workspaces']
            if w['workspaceID'] == workspace_id for cwd in w['terminalCwds']], interval=1)

        def started(title):
            task = cli_json('task', 'create', title, '--workspace', workspace_id, '--wait', '--timeout', '90')
            return task['taskID'], task['setup']['taskSpaceWorkspaceID']

        with_pr, with_pr_space = started('Fix the unread dot')
        cli_json('action', 'run', 'workspace.set-annotation', '--workspace', with_pr_space,
                 'key=github-pr', 'text=PR #9', f'url={PULL_REQUEST}')
        wait_for('the review stage', lambda: stage(with_pr).get('attention') == 'review')
        without_pr, without_pr_space = started('Composer keeps a blank line')
        to_archive, _ = started('Explain the empty file search')
        closed, closed_space = started('Close the stale task space')
        cli_json('action', 'run', 'workspace.close', '--workspace', closed_space)
        wait_for('the closed task space', lambda: stage(closed).get('attention') == 'taskSpaceClosed')
        step('tasks created', withPR=with_pr, withoutPR=without_pr, toArchive=to_archive, closed=closed)

        # 1. Task space rows in Projects.
        items = menu('projects-with-pr', '*', row_label(with_pr_space))
        require(plain(items) == ['Open Task Space', 'Open PR #9', '—', 'Merge', 'Merge Without Checks', 'Archive…', '—',
                                 *WORKSPACE_ITEMS], f'Unexpected menu for a task with a pull request: {items}')
        items = menu('projects-without-pr', '*', row_label(without_pr_space))
        require(plain(items) == ['Open Task Space', '—', 'Mark Done', 'Archive…', '—', *WORKSPACE_ITEMS],
                f'Unexpected menu for a task without a pull request: {items}')
        cli_json('action', 'run', 'workspace.select', '--workspace', with_pr_space)
        items = menu('projects-selected-with-pr', '*', row_label(with_pr_space))
        require(items[:4] == ['Open PR #9', '—', MERGE_SHORTCUT, 'Merge Without Checks'],
                f'The selected task space should show the Merge shortcut and no Open Task Space: {items}')
        cli_json('action', 'run', 'workspace.select', '--workspace', workspace_id)

        # 2. The Needs you row of a task whose task space closed.
        items = menu('needs-you-closed-task-space', '*', 'Close the stale task space, closed')
        require(items == ['Archive…', 'Delete Task'], f'Unexpected menu for a closed task space: {items}')

        # 3. The Needs you row of a pull request waiting for review.
        items = menu('needs-you-review', '*', 'Fix the unread dot, review')
        require(items == ['Open Task Space', 'Open PR #9', '—', 'Merge', 'Merge Without Checks', 'Archive…'],
                f'Unexpected Needs you menu for a review: {items}')

        # 4. Archive… opens the archive alert; Cancel changes nothing.
        to_archive_space = cli_json('task', 'get', to_archive)['setup']['taskSpaceWorkspaceID']
        menu('projects-archive', '*', row_label(to_archive_space), press='Archive…')
        dialog = wait_for('the archive alert', lambda: (d := json.loads(run_driver('dialog', pid).stdout)) and d)
        evidence['archiveAlert'] = dialog
        step('archive alert', **dialog)
        capture('archive-alert')
        require('Archive Explain the empty file search?' in dialog['texts'], f'Unexpected alert: {dialog}')
        run_driver('dialog-press', pid, 'Cancel')
        time.sleep(1)
        require(stage(to_archive)['group'] == 'running', 'Cancel should keep the task')
        step('archive cancelled')
        capture('after-cancel')

        menu('projects-archive-again', '*', row_label(to_archive_space), press='Archive…')
        wait_for('the archive alert', lambda: json.loads(run_driver('dialog', pid).stdout))
        run_driver('dialog-press', pid, 'Archive')
        wait_for('the archived task', lambda: stage(to_archive)['group'] == 'archived')
        step('archived')
        capture('after-archive')

        # 5. Mark Done from a task space row's menu.
        menu('projects-mark-done', '*', row_label(without_pr_space), press='Mark Done')
        wait_for('the done task', lambda: stage(without_pr)['group'] == 'done')
        step('marked done')
        capture('after-mark-done')

        evidence['status'] = 'passed'
    except Exception:
        dump = subprocess.run([str(helper), 'dump', str(pid)], capture_output=True, text=True, timeout=60)
        (artifacts / 'remote-task-context-menu-check-ax.txt').write_text(dump.stdout)
        raise
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / 'remote-task-context-menu-check.json').write_text(
            json.dumps(evidence, indent=2, default=str, ensure_ascii=False))
    print('[task-context-menu-check] passed', flush=True)


if __name__ == '__main__':
    main()
