#!/usr/bin/env python3
"""Check All tasks, beside the coordinator chat, in a real app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-all-tasks-check.py'. It needs
an unlocked screen: it presses keys in its own app instance and captures its
window.

The check starts its own instance of the wrapper's build in automation mode,
as remote-sidebar-needs-you-check.py does: TOASTTY_COORDINATOR_AUTOSTART=1,
the fake agent from remote-coordinator-session-check.py for the coordinator
and the tasks, and a fake `gh` that reports pull request 1 open and 2 merged.
The project's origin is a local bare repository, and tasks.toml gives it a
release_prompt. Four tasks are set up: one waiting for review with a packet
card, one running with no card, one To ship, and one archived. Through the
UI, the page's own handlers and the CLI it checks that:
- `toastty coordinator tasks` shows All tasks, with each task in its group,
  and Done and Archived closed;
- the review row's Merge asks first, naming the merge policy;
- Down Arrow moves the selection, and Return opens the selected task's card
  in the chat;
- Option+Cmd+T shows All tasks again;
- the To ship row's menu offers Release, which starts a release task;
- the Archived group opens, and its row's Delete Task deletes the task;
- setup controls open from All tasks and Needs you, and choosing a workspace
  starts the task in Running without an Inbox group.
Captures of each step and remote-coordinator-all-tasks-check.json go to the
artifacts directory.
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


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


base = _load('remote_task_create_check', 'remote-task-create-check.py')
require, wait_for, Instance = base.require, base.wait_for, base.Instance
to_ship = _load('remote_sidebar_to_ship_check', 'remote-sidebar-to-ship-check.py')
chat_check = _load('remote_coordinator_chat_check', 'remote-coordinator-chat-check.py')
session_check = _load('remote_coordinator_session_check', 'remote-coordinator-session-check.py')

PREFIX = 'remote-coordinator-all-tasks'
SLUG = 'toastty-check/project'
KEY_RETURN, KEY_ESCAPE, KEY_DOWN, KEY_T = 36, 53, 125, 17


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary, cli = bundle / 'Contents/MacOS/Toastty', bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-all-tasks-check-', dir='/tmp')).resolve()
    driver, helper = root / 'quick-entry-ui-driver', root / 'task-stages-ui-helper'
    for source, output in ((HERE / 'quick-entry-ui-driver.swift', driver), (HERE / 'task-stages-ui-helper.swift', helper)):
        subprocess.run(['swiftc', '-O', str(source), '-o', str(output)], check=True)

    def run_tool(tool, *arguments, check=True):
        result = subprocess.run([str(tool), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        if check:
            require(result.returncode == 0, f'{tool.name} {arguments[0]} failed: {result.stderr.strip()}')
        return result

    require(run_tool(driver, 'locked').stdout.strip() == '0', 'The remote screen is locked; unlock it to press keys')

    runtime_home, user_home, fake_bin, zdotdir = root / 'runtime-home', root / 'user-home', root / 'bin', root / 'zdotdir'
    work, origin = root / 'work', root / 'origin.git'
    for directory in (runtime_home, user_home / '.toastty', fake_bin, zdotdir, work):
        directory.mkdir(parents=True)

    def git(*arguments, cwd=user_home):
        return subprocess.run(['git', '-C', str(cwd), *arguments], check=True, capture_output=True, text=True).stdout.strip()

    # The user home is the project, with an origin that Release fetches.
    subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(origin)], check=True)
    git('init', '-q', '-b', 'main')
    git('config', 'user.name', 'All Tasks Check')
    git('config', 'user.email', 'all-tasks-check@example.invalid')
    (user_home / '.git/info/exclude').write_text('.toastty/\n')
    (user_home / 'README.md').write_text('all tasks check\n')
    git('add', 'README.md')
    git('commit', '-q', '-m', 'base')
    git('remote', 'add', 'origin', str(origin))
    git('push', '-q', 'origin', 'main')

    chat_check.png(work / 'after-390.png', 390, 700, [(220, 218, 213), (207, 227, 212), (45, 107, 70)])
    (work / 'packet.json').write_text(json.dumps({
        'summary': 'Pins the totals bar on narrow screens.',
        'look_at': 'The pinned totals bar at 390 px.',
        'checks': [{'name': 'unit tests', 'ok': True}],
        'not_verified': [],
        'screenshots': [{'name': 'after-390', 'width': 390}],
    }))
    agent = fake_bin / 'claude'
    agent.write_text(session_check.FAKE_AGENT)
    agent.chmod(0o755)
    gh_state = root / 'gh-state.json'
    gh_state.write_text(json.dumps({'2': 'MERGED'}))
    (fake_bin / 'gh').write_text(to_ship.FAKE_GH)
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
        TOASTTY_RUNTIME_LABEL=PREFIX,
        TOASTTY_SOCKET_PATH=socket_path,
        TOASTTY_COORDINATOR_AUTOSTART='1',
        TOASTTY_AUTOMATION='1',
        TOASTTY_ARTIFACTS_DIR=str(artifacts),
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        ZDOTDIR=str(zdotdir),
        # The app uses its own PATH when the login shell's PATH probe is slow.
        PATH=f'{fake_bin}:{os.environ.get("PATH", "/usr/bin:/bin")}',
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], captures=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[all-tasks-check] {name} {json.dumps(facts, default=str, ensure_ascii=False)}', flush=True)

    cli_environment = {key: value for key, value in environment.items()
                       if key not in ('TOASTTY_COORDINATOR_AUTOSTART', 'TOASTTY_AUTOMATION')}
    # The CLI reads relative paths from PWD.
    cli_environment['PWD'] = str(work)

    def cli_json(*arguments, session=None):
        env = dict(cli_environment)
        if session:
            env.update(TOASTTY_SESSION_ID=session['sessionID'], TOASTTY_PANEL_ID=session['panelID'])
        result = subprocess.run([str(cli), '--json', '--socket-path', socket_path, *arguments], env=env, cwd=work,
                                capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-check-app.log')
    pid = instance.process.pid

    def capture(name):
        run_tool(helper, 'activate', pid, check=False)
        time.sleep(1.0)
        response = instance.request('automation.capture_screenshot', dict(step=name))
        require(response.get('ok'), f'Could not capture {name}: {response.get("error")}')
        path = artifacts / f'{name}.png'
        if Path(response['result']['path']).resolve() != path.resolve():
            shutil.copyfile(response['result']['path'], path)
        evidence['captures'].append(path.name)
        step('captured', file=path.name)

    def chat_state():
        return instance.query('coordinator.chat.state')

    def rows():
        return {row['taskID']: row for row in chat_state()['tasks']}

    def page(action, element, text=None):
        args = dict(action=action, elementID=element)
        if text is not None:
            args['text'] = text
        response = instance.request('automation.coordinator_chat_action', args)
        require(response.get('ok'), f'Could not {action} {element}: {response}')

    def key(code, modifiers=None):
        run_tool(helper, 'activate', pid, check=False)
        time.sleep(0.3)
        run_tool(driver, 'key', code, *([modifiers] if modifiers else []))
        time.sleep(0.6)

    def started(title):
        task = cli_json('task', 'create', title, '--title', title, '--workspace', workspace_id, '--wait', '--timeout', '90')
        session_file = fake_bin / 'sessions' / f"{task['setup']['sessionID']}.json"
        session = json.loads(wait_for(f'{title} to record its session', lambda: session_file.is_file() and session_file.read_text()))
        return task, session

    try:
        workspaces = instance.wait_until_ready()
        workspace_id = workspaces[0]['workspaceID']
        wait_for('the coordinator to run', lambda: instance.query('coordinator.status')['state'] == 'running', timeout=90, interval=1)
        wait_for('the first terminal in the user home', lambda: str(user_home) in [
            os.path.realpath(cwd) for w in instance.query('workspace.list')['workspaces']
            if w['workspaceID'] == workspace_id for cwd in w['terminalCwds']], interval=1)

        review, review_session = started('Unread dot stays on')
        cli_json('task', 'packet', 'publish', '--file', 'packet.json', '--screenshot', 'after-390.png', session=review_session)
        cli_json('coordinator', 'post', 'packet', '--task', review['taskID'])
        cli_json('action', 'run', 'workspace.set-annotation', '--workspace', review['setup']['taskSpaceWorkspaceID'],
                 'key=github-pr', 'text=PR #1', f'url=https://github.com/{SLUG}/pull/1')
        running, _ = started('Tidy the logs')
        shipping, _ = started('Badge contrast')
        cli_json('action', 'run', 'workspace.set-annotation', '--workspace', shipping['setup']['taskSpaceWorkspaceID'],
                 'key=github-pr', 'text=PR #2', f'url=https://github.com/{SLUG}/pull/2')
        archived, _ = started('Old idea')
        cli_json('task', 'archive', archived['taskID'], '--discard-changes')
        ids = dict(review=review['taskID'], running=running['taskID'], shipping=shipping['taskID'], archived=archived['taskID'])
        step('tasks set up', **ids)

        # 1. All tasks, with each task in its group.
        cli_json('coordinator', 'tasks')
        wait_for('All tasks', lambda: chat_state()['pages'] >= 1 and chat_state()['view'] == 'tasks', timeout=20, interval=0.5)
        expected = dict(review='needsYou', running='running', shipping='toShip', archived='archived')

        def grouped():
            current = rows()
            return all(current.get(ids[name], {}).get('group') == group for name, group in expected.items())

        # Opening All tasks asks GitHub, which reports pull request 2 merged.
        wait_for('each task in its group', grouped, timeout=60, interval=1)
        current = rows()
        require(current[ids['review']]['hasCard'] and not current[ids['running']]['hasCard'], f'Unexpected cards: {current}')
        require(current[ids['review']]['primary'] == 'action:merge', f'The review row offers no Merge: {current[ids["review"]]}')
        require('release' in current[ids['shipping']]['menu'], f'The To ship row offers no Release: {current[ids["shipping"]]}')
        require('delete' in current[ids['archived']]['menu'], f'The archived row offers no Delete: {current[ids["archived"]]}')
        step('groups', rows={name: current[ids[name]]['group'] for name in ids})
        capture('all-tasks')

        # 2. Merge asks first.
        review_row = current[ids['review']]['id']
        page('click', f'task-primary-{review_row}')
        capture('all-tasks-merge-question')
        key(KEY_ESCAPE)
        require(not cli_json('task', 'get', ids['review']).get('mergeRequestedAt'), 'Merge did not ask first')
        step('merge asks first')

        # 3. Down Arrow moves the selection; Return opens the card in the chat.
        page('click', f'task-row-{review_row}')
        wait_for('the review row selected', lambda: chat_state()['selectedRowID'] == review_row, timeout=10, interval=0.3)
        key(KEY_DOWN)
        running_row = current[ids['running']]['id']
        wait_for('Down Arrow to select the next row', lambda: chat_state()['selectedRowID'] == running_row, timeout=10, interval=0.3)
        capture('all-tasks-selection')
        page('click', f'task-row-{review_row}')
        key(KEY_RETURN)
        wait_for('Return to open the card in the chat', lambda: chat_state()['view'] == 'chat'
                 and chat_state()['currentTaskID'] == ids['review'], timeout=15, interval=0.3)
        step('return opened the card')
        capture('all-tasks-opens-card')

        # 4. Option+Cmd+T shows All tasks again.
        key(KEY_T, 'cmd,opt')
        wait_for('Option+Cmd+T to show All tasks', lambda: chat_state()['view'] == 'tasks', timeout=15, interval=0.3)
        step('shortcut shows all tasks')

        # 5. Release from the To ship row's menu.
        shipping_row = current[ids['shipping']]['id']
        page('click', f'task-menu-{shipping_row}')
        capture('all-tasks-release-menu')
        page('click', f'task-action-{shipping_row}-release')
        release = wait_for('the release task', lambda: next((t for t in cli_json('task', 'list')['tasks'] if t.get('release')), None),
                           timeout=60, interval=1)
        step('release started', taskID=release['taskID'])

        # 6. Archived opens; its row's Delete Task deletes the task.
        archived_row = current[ids['archived']]['id']
        page('click', 'group-archived')
        page('click', f'task-menu-{archived_row}')
        capture('all-tasks-archived')
        page('click', f'task-action-{archived_row}-delete')
        def deleted():
            result = subprocess.run([str(cli), '--json', '--socket-path', socket_path, 'task', 'get', ids['archived']],
                                    env=cli_environment, cwd=work, capture_output=True, text=True, timeout=60)
            return result.returncode != 0
        wait_for('the task to be deleted', deleted, timeout=20, interval=0.5)
        step('archived task deleted')

        # 7. Setup recovery is reachable without an Inbox or a chat card.
        waiting = cli_json('task', 'create', 'Choose a project for setup', '--title', 'Choose a project for setup')
        waiting_id = waiting['taskID']
        wait_for('the task to need a workspace', lambda: cli_json('task', 'get', waiting_id)['setup']['state'] == 'needsWorkspace')
        wait_for('workspace selection in Needs you', lambda: rows().get(waiting_id, {}).get('group') == 'needsYou')
        setup_row = rows()[waiting_id]
        require(setup_row['primary'] == 'setup' and not setup_row['hasCard'], f'Setup controls are unreachable: {setup_row}')
        require(all(row['group'] != 'inbox' for row in rows().values()), 'An Inbox group remains')
        page('click', f"task-primary-{setup_row['id']}")
        wait_for('the setup card from All tasks', lambda: run_tool(helper, 'exists', pid, 'task.setup.workspacePicker', check=False).returncode == 0)
        capture('all-tasks-setup-workspace')
        key(KEY_ESCAPE)

        # The sidebar opens the same card while the task has no task space.
        run_tool(helper, 'press', pid, f'sidebar.needsYou.task.{waiting_id}.primary')
        wait_for('the setup card from Needs you', lambda: run_tool(helper, 'exists', pid, 'task.setup.workspacePicker', check=False).returncode == 0)
        workspace_title = next(w['title'] for w in instance.query('workspace.list')['workspaces'] if w['workspaceID'] == workspace_id)
        run_tool(driver, 'press-menu', pid, 'task.setup.workspacePicker', workspace_title)
        capture('needs-you-setup-workspace')
        run_tool(helper, 'press', pid, 'task.setup.start')
        wait_for('workspace selection to start the task', lambda: cli_json('task', 'get', waiting_id)['setup']['state'] == 'started', timeout=60)
        wait_for('setup controls to close', lambda: run_tool(helper, 'exists', pid, 'task.setup.start', check=False).returncode != 0)
        wait_for('the started task in Running', lambda: rows().get(waiting_id, {}).get('group') == 'running')
        step('setup recovered from Needs you and All tasks', taskID=waiting_id, group=rows()[waiting_id]['group'])

        # 8. An installed agent that exits before readiness leaves a setup
        # failure in Needs you; Retry uses the repaired agent in the same task.
        original_agent = agent.read_text()
        try:
            agent.write_text('#!/bin/sh\nexit 1\n')
            broken = cli_json('task', 'create', 'Recover a failed agent start', '--title', 'Recover a failed agent start', '--workspace', workspace_id)
            broken_id = broken['taskID']
            wait_for('setup to report the failed start', lambda: cli_json('task', 'get', broken_id)['setup']['state'] == 'setupFailed', timeout=90)
        finally:
            agent.write_text(original_agent)
            agent.chmod(0o755)
        wait_for('the failed setup in Needs you', lambda: rows().get(broken_id, {}).get('group') == 'needsYou')
        page('click', f"task-primary-{rows()[broken_id]['id']}")
        wait_for('Retry on the failed setup card', lambda: run_tool(helper, 'exists', pid, 'task.setup.retry', check=False).returncode == 0)
        capture('all-tasks-setup-retry')
        run_tool(helper, 'press', pid, 'task.setup.retry')
        wait_for('Retry to start the same task', lambda: cli_json('task', 'get', broken_id)['setup']['state'] == 'started', timeout=60)
        wait_for('the recovered task in Running', lambda: rows().get(broken_id, {}).get('group') == 'running')
        step('failed setup retried from All tasks', taskID=broken_id, group=rows()[broken_id]['group'])

        evidence['status'] = 'passed'
    except Exception:
        try:
            evidence['chatState'] = chat_state()
            capture('all-tasks-failure')
        except Exception as error:
            evidence['diagnosticsError'] = repr(error)
        raise
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / f'{PREFIX}-check.json').write_text(json.dumps(evidence, indent=2, default=str))
        shutil.rmtree(root, ignore_errors=True)
    print('[all-tasks-check] passed', flush=True)


if __name__ == '__main__':
    main()
