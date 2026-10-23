#!/usr/bin/env python3
"""Check task context menus and Tasks view keyboard selection in a real app.

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
- the Status segment's task space row and its row for a task whose task space
  closed, and the Tasks view's row, offer the same task actions;
- Up and Down Arrow move the Tasks view selection through its rows in order,
  and the detail pane follows;
- Archive… from a Tasks view row opens the archive alert; Cancel keeps the
  task and the selection; Archive archives it and selects the next row;
- Mark Done from a row's menu moves the task into the collapsed Done group
  and selects the next row.
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

KEY_DOWN, KEY_UP = 125, 126
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
            capture(f'menu-{name}')
            run_driver('close-menu', pid)
        # The open menu can end with an untitled item of its own.
        while items and items[-1] == '—':
            items.pop()
        evidence['menus'][name] = items
        step('menu', menu=name, items=items, pressed=press)
        time.sleep(0.4)
        return items

    def detail_title():
        """The title of the task the detail pane shows: the only static text
        that is a task's title, since rows read as one element each."""
        result = run_driver('texts', pid, '*', check=False)
        texts = json.loads(result.stdout) if result.returncode == 0 else []
        return next((text for text in texts if text in titles), None)

    def tasks_view_rows():
        """The Tasks view's row titles, top to bottom. SwiftUI rows can take
        their container's identifier, so rows are found by label; only the
        Tasks view labels a row with a task's title."""
        rows = []
        for label in json.loads(run_driver('labels', pid, '*').stdout):
            title = next((title for title in titles if label.startswith(title + ', ')), None)
            if title and title not in rows:
                rows.append(title)
        return rows

    def row_label(workspace):
        """A sidebar task space row's label starts with its workspace title."""
        title = next(w['title'] for w in instance.query('workspace.list')['workspaces'] if w['workspaceID'] == workspace)
        return f'{title}, task space'

    def key(code):
        run_driver('key', code)
        time.sleep(0.5)

    try:
        workspaces = instance.wait_until_ready()
        workspace_id, window_id = workspaces[0]['workspaceID'], workspaces[0]['windowID']
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
        titles = ['Fix the unread dot', 'Composer keeps a blank line', 'Explain the empty file search',
                  'Close the stale task space']
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

        # 2. Status rows: a task space, and a task whose task space closed.
        cli_json('action', 'run', 'window.sidebar.set-segment', '--window', window_id, 'segment=status')
        items = menu('status-without-pr', '*', row_label(without_pr_space))
        require(items[:4] == ['Open Task Space', '—', 'Mark Done', 'Archive…'], f'Unexpected Status menu: {items}')
        items = menu('status-closed-task-space', '*', 'Close the stale task space,')
        require(items == ['Archive…', 'Delete Task'], f'Unexpected menu for a closed task space: {items}')
        cli_json('action', 'run', 'window.sidebar.set-segment', '--window', window_id, 'segment=projects')

        # 3. The Tasks view's rows, and the arrow keys.
        cli_json('action', 'run', 'window.tasks.show', '--window', window_id)
        wait_for('the Tasks view rows', lambda: len(tasks_view_rows()) == 4)
        items = menu('tasks-view-with-pr', '*', 'Fix the unread dot,')
        require(items == ['Open Task Space', 'Open PR #9', '—', 'Merge', 'Merge Without Checks', 'Archive…'],
                f'Unexpected Tasks view menu: {items}')
        rows = tasks_view_rows()
        step('tasks view rows', rows=rows)
        require(detail_title() == rows[0], f'The first row should show by default: {detail_title()} {rows}')
        capture('arrow-0')
        for index, expected in enumerate(rows[1:], start=1):
            key(KEY_DOWN)
            require(detail_title() == expected, f'Down should select {expected}: {detail_title()}')
            capture(f'arrow-{index}')
        key(KEY_DOWN)
        require(detail_title() == rows[-1], 'Down should stop at the last row')
        for expected in reversed(rows[:-1]):
            key(KEY_UP)
            require(detail_title() == expected, f'Up should select {expected}: {detail_title()}')
        step('arrow keys walked the rows', rows=rows)

        # 4. Archive… opens the archive alert; Cancel changes nothing.
        while detail_title() != 'Explain the empty file search':
            key(KEY_DOWN)
        rows = tasks_view_rows()
        menu('tasks-view-archive', '*', 'Explain the empty file search,', press='Archive…')
        dialog = wait_for('the archive alert', lambda: (d := json.loads(run_driver('dialog', pid).stdout)) and d)
        evidence['archiveAlert'] = dialog
        step('archive alert', **dialog)
        capture('archive-alert')
        require('Archive Explain the empty file search?' in dialog['texts'], f'Unexpected alert: {dialog}')
        run_driver('dialog-press', pid, 'Cancel')
        time.sleep(1)
        require(stage(to_archive)['group'] == 'running', 'Cancel should keep the task')
        require(detail_title() == 'Explain the empty file search', f'Cancel should keep the selection: {detail_title()}')
        step('archive cancelled', selected=detail_title())
        capture('tasks-view-after-cancel')

        # Archive selects the next row.
        index = rows.index('Explain the empty file search')
        expected = rows[index + 1] if index + 1 < len(rows) else rows[index - 1]
        menu('tasks-view-archive-again', '*', 'Explain the empty file search,', press='Archive…')
        wait_for('the archive alert', lambda: json.loads(run_driver('dialog', pid).stdout))
        run_driver('dialog-press', pid, 'Archive')
        wait_for('the archived task', lambda: stage(to_archive)['group'] == 'archived')
        wait_for(f'{expected} to be selected', lambda: detail_title() == expected)
        step('archived and selected the next row', selected=detail_title(), rows=tasks_view_rows())
        capture('tasks-view-after-archive')

        # 5. Mark Done moves the task into collapsed Done and selects the next row.
        while detail_title() != 'Composer keeps a blank line':
            key(KEY_UP if rows.index(detail_title()) > rows.index('Composer keeps a blank line') else KEY_DOWN)
        rows = tasks_view_rows()
        index = rows.index('Composer keeps a blank line')
        expected = rows[index + 1] if index + 1 < len(rows) else rows[index - 1]
        menu('tasks-view-mark-done', '*', 'Composer keeps a blank line,', press='Mark Done')
        wait_for('the done task', lambda: stage(without_pr)['group'] == 'done')
        wait_for(f'{expected} to be selected', lambda: detail_title() == expected)
        step('marked done and selected the next row', selected=detail_title(), rows=tasks_view_rows())
        capture('tasks-view-after-mark-done')

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
