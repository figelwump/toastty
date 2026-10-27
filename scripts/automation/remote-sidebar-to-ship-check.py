#!/usr/bin/env python3
"""Check the sidebar's latest To ship tasks in a real app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-sidebar-to-ship-check.py'. It needs an
unlocked screen: it presses sidebar rows in its own app instance through
Accessibility and captures its window.

The check starts its own instance of the wrapper's build, as
remote-task-context-menu-check.py does, with a fake agent, a tasks.toml with
`release_tags` and a `release_prompt`, and a fake `gh` first on the instance's login-shell PATH that
reports each task's pull request merged. It merges five tasks one at a time,
so their merge times differ, and closes every task space but the newest
task's, whose agent is quiet. Through the UI and the CLI it checks that:
- the project card shows the three newest merges as rows, newest first, then
  "Show 2 more", including the task whose quiet task space left the card;
- "Show 2 more" lists the other two under the three, oldest last;
- a To ship row opens the coordinator chat to its task;
- with two To ship tasks and three done, the card shows both rows with no
  "Show N more", and the footer keeps the Done count and the Release pill;
- the To ship group API and the Done footer open All tasks in the
  coordinator's right panel, keep its chat in the center, and share the
  project's ID filter;
- the Done count leaves Done open and one of
  the project's done tasks selected;
- the Release pill makes the project's release task. The home folder is no
  git repository, so its setup then fails; only the task's creation counts.
The coordinator runs the fake agent too; opening its chat asks GitHub about
every open pull request. Captures of each step and
remote-sidebar-to-ship-check.json go to the artifacts directory; a missing
capture is recorded, not failed.

Coverage gap: this fixture shows recent To ship rows, so the sidebar hides
its To ship count. That count uses the same finishedTasksCount handler as
the Done count, but its visible count variant is not exercised here.
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

SLUG = 'toastty-check/project'
# Oldest merge first.
TITLES = ['Unread dot', 'Composer blank line', 'task create --fork', 'Close question', 'Task context menus']

# Answers `gh pr view <url> --json ...` from $state-path: {"<number>": "OPEN"|"MERGED"}.
FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
path = open(os.path.join(os.path.dirname(__file__), "state-path")).read().strip()
args = sys.argv[1:]
if args[:2] != ["pr", "view"]:
    sys.exit(f"unexpected gh call: {args}")
number = args[2].rstrip("/").split("/")[-1]
state = json.load(open(path)).get(number, "OPEN")
print(json.dumps({"number": int(number), "state": state, "isDraft": False, "headRefOid": "abc" + number,
                  "mergeCommit": {"oid": "abc" + number} if state == "MERGED" else None}))
'''


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-sidebar-to-ship-check-', dir='/tmp')).resolve()
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
    (fake_bin / 'gh').write_text(FAKE_GH)
    (fake_bin / 'gh').chmod(0o755)
    (fake_bin / 'state-path').write_text(str(gh_state))
    for name in ('.zshenv', '.zprofile'):
        (zdotdir / name).write_text(f'[ -f "$HOME/{name}" ] && source "$HOME/{name}"\n')
    (zdotdir / '.zshrc').write_text(f'[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"\nexport PATH="{fake_bin}:$PATH"\n')
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text(
        f'[defaults]\nagent = "claude"\n\n[workspace.{json.dumps(str(user_home))}]\nrelease_tags = "v*"\n'
        'release_prompt = "Release check: do nothing."\n')

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-sidebar-to-ship-check',
        TOASTTY_SOCKET_PATH=socket_path,
        TOASTTY_COORDINATOR_AUTOSTART='1',
        TOASTTY_AUTOMATION='1',
        TOASTTY_ARTIFACTS_DIR=str(artifacts),
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        ZDOTDIR=str(zdotdir),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], captures=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[sidebar-to-ship-check] {name} {json.dumps(facts, default=str, ensure_ascii=False)}', flush=True)

    def cli_json(*arguments):
        result = subprocess.run([str(cli), '--json', *arguments], env=environment,
                                capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    def stage(task_id):
        return cli_json('task', 'get', task_id)['stage']

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / 'remote-sidebar-to-ship-check-app.log')
    pid = instance.process.pid

    def capture(name):
        """Evidence only: a capture that cannot be made is recorded, not failed."""
        path = artifacts / f'{name}.png'
        # The skills banner can cover the workspace; dismiss it if it shows.
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

    def chat_state():
        return instance.query('coordinator.chat.state')

    def filtered_tasks(project_id, group, task_ids):
        """Check actual rows and the right-panel route, not only selection."""
        state = chat_state()
        response = instance.request('automation.coordinator_page_state', {})
        require(response.get('ok'), f'Could not inspect coordinator pages: {response}')
        pages = response['result']['pages']
        summary = next((page for page in pages if page['view'] == 'tasks'), None)
        center = next((page for page in pages if page['view'] == 'chat'), None)
        if not summary or not center or state['projectFilter'] != project_id:
            return None
        if summary['projectFilter'] != project_id or center['projectFilter'] != project_id:
            return None
        if group not in summary['openGroupIDs'] or state.get('selectedRowID') not in task_ids:
            return None
        right = instance.query('workspace.snapshot', workspaceID=coordinator['workspaceID'])['rightPanel']
        tabs = [tab for tab in right['tabs'] if (tab.get('url') or '').rstrip('/') in
                ('toastty://coordinator/today', 'toastty://coordinator/tasks')]
        if not right['isVisible'] or len(tabs) != 1 or tabs[0]['panelID'] != right['activePanelID']:
            return None
        row_projects = {row['id']: row['projectID'] for row in state['tasks']}
        if not all(row_projects[row] == project_id for row in summary['visibleTaskRowIDs']):
            return None
        return summary

    def sidebar_rows():
        """The task rows' and "Show N more" labels, top to bottom. A row's
        label starts with its task's title, which only rows carry, or with
        its task space's title for a task space row."""
        rows = []
        for label in labels():
            title = next((t for t in TITLES if label.startswith(f'{t}, ')), None)
            if title is None and kept_title and label.startswith(f'{kept_title}, task space'):
                title = TITLES[-1]
            if title:
                rows.append(title)
            elif label.startswith('Show ') and label.endswith(' to ship'):
                rows.append(label)
        return rows

    def press_label(label):
        """Presses a sidebar row or button by its label: SwiftUI gives them
        their container's identifier."""
        run_tool(driver, 'press-label', pid, label)
        step('pressed', label=label)

    kept_title = None
    try:
        workspaces = instance.wait_until_ready()
        workspace_id, window_id = workspaces[0]['workspaceID'], workspaces[0]['windowID']
        wait_for('the first terminal in the user home', lambda: str(user_home) in [
            os.path.realpath(cwd) for w in instance.query('workspace.list')['workspaces']
            if w['workspaceID'] == workspace_id for cwd in w['terminalCwds']], interval=1)
        coordinator = wait_for('the coordinator to run', lambda: (lambda s: s if s['state'] == 'running' else None)(
            instance.query('coordinator.status')), timeout=60, interval=1)

        tasks = {}
        for number, title in enumerate(TITLES, start=1):
            task = cli_json('task', 'create', title, '--workspace', workspace_id, '--wait', '--timeout', '90')
            tasks[title] = task['taskID']
            cli_json('action', 'run', 'workspace.set-annotation', '--workspace', task['setup']['taskSpaceWorkspaceID'],
                     'key=github-pr', f'text=PR #{number}', f'url=https://github.com/{SLUG}/pull/{number}')
        # The chat shows a task that the coordinator posted about.
        for title in TITLES:
            cli_json('coordinator', 'post', 'task-started', '--task', tasks[title])
        step('tasks created', tasks=tasks)

        # Merge one at a time, oldest first. Opening the coordinator chat
        # asks GitHub about every open pull request.
        merged = {}
        for number, title in enumerate(TITLES, start=1):
            merged[str(number)] = 'MERGED'
            gh_state.write_text(json.dumps(merged))
            cli_json('coordinator', 'show')
            wait_for(f'{title} to be To ship', lambda: stage(tasks[title])['group'] == 'toShip')
            time.sleep(1.1)
        evidence['mergedAt'] = {title: cli_json('task', 'get', tasks[title]).get('mergedAt') for title in TITLES}
        # Keep the newest task's task space open, with its agent quiet.
        kept = cli_json('task', 'get', tasks[TITLES[-1]])['setup']['taskSpaceWorkspaceID']
        kept_title = next(w['title'] for w in instance.query('workspace.list')['workspaces'] if w['workspaceID'] == kept)
        open_spaces = [w['workspaceID'] for w in instance.query('workspace.list')['workspaces']
                       if w['workspaceID'] not in (workspace_id, kept, coordinator['workspaceID'])]
        for workspace in open_spaces:
            cli_json('action', 'run', 'workspace.close', '--workspace', workspace)
        step('merged', closedTaskSpaces=len(open_spaces), keptTaskSpace=kept)

        # 1. Projects: three rows, newest first, then "Show 2 more".
        cli_json('action', 'run', 'workspace.select', '--workspace', workspace_id)
        newest = list(reversed(TITLES))
        wait_for('the card rows', lambda: sidebar_rows()[:3] == newest[:3])
        rows = sidebar_rows()
        step('projects rows', rows=rows)
        require(rows == [*newest[:3], 'Show 2 more tasks to ship'], f'Unexpected card rows: {rows}')
        capture('projects-five-to-ship')

        press_label('Show 2 more')
        wait_for('all five rows', lambda: sidebar_rows() == newest)
        capture('projects-show-more')

        # Recent rows suppress the To ship footer count. Exercise the same
        # group's API directly; the visible Done footer is clicked below.
        shipping_ids = set(tasks.values())
        project_id = next(row['projectID'] for row in chat_state()['tasks'] if row['taskID'] in shipping_ids)
        cli_json('action', 'run', 'coordinator.tasks.show', 'group=toShip', f'project={project_id}')
        wait_for('To ship group API to filter the right panel', lambda: filtered_tasks(project_id, 'toShip', shipping_ids))
        capture('projects-to-ship-api-opens-all-tasks')
        step('To ship group API opened right-panel All tasks', projectID=project_id,
             coverageGap='Visible To ship count is hidden by recent rows; only Done footer click is exercised.')
        cli_json('action', 'run', 'workspace.select', '--workspace', workspace_id)

        press_label(f'{newest[1]}, ')
        # The page opens the task's card, which the palette then acts on.
        wait_for(f'the chat to open the card of {newest[1]}', lambda: chat_state()['currentTaskID'] == tasks[newest[1]])
        selected = [w['workspaceID'] for w in instance.query('workspace.list')['workspaces'] if w['isSelected']]
        require(selected == [coordinator['workspaceID']], f'The row did not open the chat: {selected}')
        step('chat opened', task=newest[1])
        capture('projects-row-opens-chat')
        cli_json('action', 'run', 'workspace.select', '--workspace', workspace_id)

        # 2. Two To ship tasks and three done.
        for title in TITLES[:3]:
            cli_json('task', 'mark-done', tasks[title])
            wait_for(f'{title} to be done', lambda: stage(tasks[title])['group'] == 'done')
        wait_for('two card rows', lambda: sidebar_rows() == newest[:2])
        done_label = 'Finished tasks: 3 done. Opens All tasks.'
        require(done_label in labels(), f'The footer should keep the Done count: {labels()}')
        require('Release' in labels(), f'The footer should offer Release for a project that can release: {labels()}')
        step('projects rows with two', rows=sidebar_rows(), doneCount=True, release=True)
        capture('projects-two-to-ship')

        # 3. The Done count opens All tasks at the project's Done group.
        done_ids = {tasks[title] for title in TITLES[:3]}
        press_label(done_label)
        wait_for('All tasks at a done task in the right panel', lambda: filtered_tasks(project_id, 'done', done_ids))
        state = chat_state()
        selected = [w['workspaceID'] for w in instance.query('workspace.list')['workspaces'] if w['isSelected']]
        require(selected == [coordinator['workspaceID']], f'The count did not open the coordinator: {selected}')
        step('done count opened right-panel All tasks', selectedRowID=state['selectedRowID'], projectID=project_id)
        capture('projects-done-count-opens-all-tasks')

        # 4. Release makes the project's release task.
        press_label('Release')
        release = wait_for('the release task', lambda: next(
            (t for t in cli_json('task', 'list')['tasks'] if t.get('release')), None), timeout=20, interval=0.5)
        step('release pill made a release task', taskID=release.get('taskID'), title=release.get('title'))

        evidence['status'] = 'passed'
    except Exception:
        dump = subprocess.run([str(helper), 'dump', str(pid)], capture_output=True, text=True, timeout=60)
        (artifacts / 'remote-sidebar-to-ship-check-ax.txt').write_text(dump.stdout)
        raise
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / 'remote-sidebar-to-ship-check.json').write_text(
            json.dumps(evidence, indent=2, default=str, ensure_ascii=False))
    print('[sidebar-to-ship-check] passed', flush=True)


if __name__ == '__main__':
    main()
