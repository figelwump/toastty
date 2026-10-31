#!/usr/bin/env python3
"""Check the Status sidebar's Needs you group and `task needs-reply` in a real app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-needs-you-check.py'. It needs an unlocked
screen: it reads the sidebar through Accessibility.

The check starts its own instance of the wrapper's build with a throwaway
runtime home and user home and a fake agent, as remote-task-stages-check.py
does, and shows the Status segment. Through the real CLI and socket it checks
that:
- a task whose agent ran `task needs-reply --question` before it ended its
  turn is `needsYou`/`awaitingReply`, shows the question, stays so after the
  user reads the turn, and clears when its agent starts the next turn;
- an idle task lists in Needs you, as context, with its child that waits for
  review, instead of apart in Idle;
- selecting an unread finished task reads it, but its row keeps its place in
  Needs you until another task is selected; then it moves to Idle.
Captures of each step go to the artifacts directory when the app allows one;
a missing capture is recorded, not failed.
"""

import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).parent
_spec = importlib.util.spec_from_file_location('task_create_check', HERE / 'remote-task-create-check.py')
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)
require, wait_for, Instance, FAKE_AGENT = base.require, base.wait_for, base.Instance, base.FAKE_AGENT

PULL_REQUEST = 'https://github.com/toastty-check/no-such-repo/pull/11'
QUESTION = 'Pick a hostname option'
# One line of task-stages-ui-helper's dump.
DUMP_LINE = re.compile(r'^\d+ \S+ id=(?P<id>\S*) title=(?P<title>.*) frame=-?\d+,(?P<y>-?\d+) \d+x\d+$')
# The Status segment draws its group titles in capitals.
GROUP_HEADERS = {'NEEDS YOU': 'Needs you', 'RUNNING': 'Running', 'IDLE': 'Idle'}


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-needs-you-check-', dir='/tmp')).resolve()
    helper = root / 'task-stages-ui-helper'
    subprocess.run(['swiftc', '-O', str(HERE / 'task-stages-ui-helper.swift'), '-o', str(helper)], check=True)

    def run_tool(*arguments, check=True):
        result = subprocess.run([str(helper), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        if check:
            require(result.returncode == 0, f'helper {arguments[0]} failed: {result.stderr.strip()}')
        return result

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
        TOASTTY_RUNTIME_LABEL='remote-needs-you-check',
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], root=str(root), captures=[])

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[needs-you-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def cli_json(*arguments, extra_env=None):
        result = subprocess.run([str(cli), '--json', *arguments], env={**environment, **(extra_env or {})},
                                capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    def task(task_id):
        return cli_json('task', 'get', task_id)

    def stage(task_id):
        return task(task_id)['stage']

    def status(session, kind, summary):
        cli_json('session', 'status', '--session', session, '--kind', kind, '--summary', summary)
        time.sleep(0.3)

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / 'remote-needs-you-check-app.log')
    pid = instance.process.pid

    def capture(name):
        path = artifacts / f'{name}.png'
        time.sleep(0.8)
        response = instance.request('automation.capture_screenshot', dict(step=name))
        if response.get('ok'):
            shutil.copyfile(response['result']['path'], path)
        else:
            result = run_tool('capture', pid, path, check=False)
            if result.returncode != 0:
                step('capture unavailable', file=path.name, app=response.get('error'), window=result.stderr.strip())
                return
        evidence['captures'].append(path.name)
        step('captured', file=path.name)

    def sidebar_order():
        """The Status segment's group headers and task space rows, top to
        bottom, from the Accessibility tree: ('header', 'Needs you') or
        ('row', workspaceID)."""
        found = []
        for line in run_tool('dump', pid).stdout.splitlines():
            match = DUMP_LINE.match(line)
            if not match:
                continue
            identifier, title, y = match['id'], match['title'].strip(), int(match['y'])
            row_id = identifier.removeprefix('sidebar.workspace.subspace.')
            if row_id != identifier and len(row_id) == 36:
                found.append((y, 'row', row_id))
            elif title in GROUP_HEADERS:
                found.append((y, 'header', GROUP_HEADERS[title]))
        seen, ordered = set(), []
        for item in sorted(found):
            if item[1:] not in seen:
                seen.add(item[1:])
                ordered.append(item[1:])
        return ordered

    def group_of(order, workspace_id):
        group = None
        for kind, value in order:
            if kind == 'header':
                group = value
            elif value == workspace_id:
                return group
        return None

    def rows_in(order, group_name):
        rows, current = [], None
        for kind, value in order:
            if kind == 'header':
                current = value
            elif current == group_name:
                rows.append(value)
        return rows

    def start(text):
        created = cli_json('task', 'create', text, '--workspace', workspace_id, '--wait', '--timeout', '90')
        return created['taskID'], created['setup']['sessionID'], created['setup']['taskSpaceWorkspaceID']

    def finish_unread(session):
        status(session, 'working', 'Working')
        status(session, 'ready', 'Ready')

    def first_panel(workspace):
        return instance.query('workspace.snapshot', workspaceID=workspace)['slotPanelIDs'][0]

    try:
        workspaces = instance.wait_until_ready()
        workspace_id, window_id = workspaces[0]['workspaceID'], workspaces[0]['windowID']
        cli_json('action', 'run', 'window.sidebar.set-segment', '--window', window_id, 'segment=status')
        step('booted', workspaceID=workspace_id)

        # 1. A question waits for the user's reply, read or not.
        asked_id, asked_session, asked_space = start('Choose a hostname for private pages')
        status(asked_session, 'working', 'Working')
        marked = cli_json('task', 'needs-reply', asked_id, '--question', QUESTION)
        require(marked['replyRequest']['question'] == QUESTION, f'needs-reply did not save the question: {marked}')
        status(asked_session, 'ready', 'Ready')
        asking = wait_for('the question to need the user',
                          lambda: (s := stage(asked_id)).get('attention') == 'awaitingReply' and s)
        require(asking['group'] == 'needsYou' and asking['needsUser'], f'Unexpected stage: {asking}')
        step('question needs you', stage=asking)
        capture('1-question-unread')
        cli_json('action', 'run', 'workspace.focus-panel', '--workspace', asked_space, '--panel', first_panel(asked_space))
        time.sleep(1.5)
        read = stage(asked_id)
        require(read.get('attention') == 'awaitingReply', f'Reading the turn answered the question: {read}')
        step('question still needs you after reading', stage=read)
        capture('2-question-read')
        status(asked_session, 'working', 'Working')
        answered = wait_for('the reply to clear the question', lambda: (t := task(asked_id))['replyRequest'] is None and t)
        require(answered['stage']['group'] == 'running', f'The answered task should run: {answered["stage"]}')
        step('reply cleared the question', stage=answered['stage'])
        status(asked_session, 'idle', 'Waiting')

        # 2. A family lists in its most urgent group: an idle parent with a
        # child that waits for review lists in Needs you.
        parent_id, parent_session, parent_space = start('Explain the public URL warning')
        child = cli_json('task', 'create', 'Keep private pages private', '--workspace', workspace_id,
                         '--wait', '--timeout', '90', extra_env={'TOASTTY_SESSION_ID': parent_session})
        child_id, child_space = child['taskID'], child['setup']['taskSpaceWorkspaceID']
        require(task(child_id)['parentTaskID'] == parent_id, f'The child did not record its parent: {task(child_id)}')
        cli_json('action', 'run', 'workspace.set-annotation', '--workspace', child_space,
                 'key=github-pr', 'text=PR #11', f'url={PULL_REQUEST}')
        wait_for('the child to wait for review', lambda: stage(child_id).get('attention') == 'review')
        require(stage(parent_id)['group'] == 'idle', f'The parent should be idle: {stage(parent_id)}')
        family = wait_for('the family to list in Needs you', lambda: (
            (order := sidebar_order()) and group_of(order, parent_space) == 'Needs you'
            and group_of(order, child_space) == 'Needs you' and order))
        needs_you = rows_in(family, 'Needs you')
        require(needs_you.index(child_space) == needs_you.index(parent_space) + 1,
                f'The child should list right under its parent: {family}')
        require(parent_space not in rows_in(family, 'Idle'), f'The parent listed twice: {family}')
        step('family lists together', order=family)
        capture('3-family-in-needs-you')

        # 3. Selecting an unread finished task reads it; its row holds its
        # place until another task is selected.
        clicked_id, clicked_session, clicked_space = start('Remove thumbnail filenames')
        finish_unread(clicked_session)
        wait_for('the finished turn to need the user', lambda: stage(clicked_id).get('attention') == 'agentFinished')
        before = wait_for('the finished task in Needs you',
                          lambda: (o := sidebar_order()) and group_of(o, clicked_space) == 'Needs you' and o)
        slot = rows_in(before, 'Needs you').index(clicked_space)
        step('before the click', order=before)
        capture('4-before-select')
        cli_json('action', 'run', 'workspace.focus-panel', '--workspace', clicked_space,
                 '--panel', first_panel(clicked_space))
        wait_for('the read task to be idle', lambda: stage(clicked_id)['group'] == 'idle')
        time.sleep(1.0)
        held = sidebar_order()
        require(group_of(held, clicked_space) == 'Needs you', f'The selected row left Needs you: {held}')
        require(rows_in(held, 'Needs you').index(clicked_space) == slot, f'The selected row moved: {before} -> {held}')
        step('selected row holds its slot', order=held)
        capture('5-selected-holds')
        cli_json('action', 'run', 'workspace.select', '--workspace', workspace_id)
        moved = wait_for('the row to move to Idle once deselected',
                         lambda: (o := sidebar_order()) and group_of(o, clicked_space) == 'Idle' and o)
        step('row moved after selection changed', order=moved)
        capture('6-after-deselect')

        evidence['status'] = 'passed'
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / 'remote-needs-you-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[needs-you-check] passed', flush=True)


if __name__ == '__main__':
    main()
