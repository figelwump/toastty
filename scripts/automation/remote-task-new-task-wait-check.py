#!/usr/bin/env python3
"""Wait for new tasks through the real CLI in a disposable app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-new-task-wait-check.py'.

The check starts its own second instance of the wrapper's build, set up as
remote-task-create-check.py sets it up: a throwaway runtime home, a git
repository as the user home, and a fake agent. It never selects a workspace or
moves focus.

It checks that `toastty task list --changed-since <cursor> --wait --until created`:
- keeps waiting while an existing task changes;
- returns when a task made elsewhere appears, naming it in createdTaskIDs and
  printing a cursor to wait from next;
- ignores a task the calling session created, and exits 1 at --timeout;
- prints one line per new task without --json;
- returns at once, with reset, for a cursor from an earlier launch.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


create_check = _load('remote_task_create_check', 'remote-task-create-check.py')
require, wait_for, Instance = create_check.require, create_check.wait_for, create_check.Instance

PREFIX = 'remote-task-new-task-wait-check'


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-new-task-wait-', dir='/tmp')).resolve()
    runtime_home, user_home, fake_bin = root / 'runtime-home', root / 'user-home', root / 'bin'
    for directory in (runtime_home, user_home / '.toastty', fake_bin):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(create_check.FAKE_AGENT)
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
        TOASTTY_RUNTIME_LABEL=PREFIX,
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, **facts))
        print(f'[new-task-wait] {name} {json.dumps(facts, default=str)}', flush=True)

    def cli_env(session_id=None):
        env = dict(environment)
        if session_id:
            env['TOASTTY_SESSION_ID'] = session_id
        return env

    def cli_result(*arguments, session_id=None):
        result = subprocess.run([str(cli), '--json', *arguments], env=cli_env(session_id),
                                capture_output=True, text=True, timeout=180)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed ({result.returncode}): {result.stdout} {result.stderr}')
        return json.loads(result.stdout)['result']

    def start_wait(cursor, *extra, session_id=None, json_output=True):
        arguments = [str(cli)] + (['--json'] if json_output else []) + [
            'task', 'list', '--changed-since', cursor, '--wait', '--until', 'created', *extra]
        return subprocess.Popen(arguments, env=cli_env(session_id), stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)

    def create(title, workspace_id, session_id=None):
        # A task's agent creates a task in its own task's workspace.
        place = [] if session_id else ['--workspace', workspace_id]
        return cli_result('task', 'create', f'{title}. Automated check; do nothing.', '--title', title,
                          *place, '--wait', '--timeout', '90', session_id=session_id)

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-app.log')
    try:
        workspace_id = instance.wait_until_ready()[0]['workspaceID']

        def terminal_in_home():
            listed = instance.query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == workspace_id)['terminalCwds']
            return str(user_home) in [os.path.realpath(cwd) for cwd in cwds]

        wait_for('the first terminal in the user home', terminal_in_home, interval=1)
        step('booted', workspaceID=workspace_id)

        a = create('New task wait A', workspace_id)
        a_session = a['setup']['sessionID']
        cursor = cli_result('task', 'list')['cursor']
        step('created A', taskID=a['taskID'], sessionID=a_session, cursor=cursor)

        # 1. A change to A does not end the wait.
        waiter = start_wait(cursor, '--timeout', '120')
        cli_result('action', 'run', 'workspace.set-annotation', '--workspace', a['setup']['taskSpaceWorkspaceID'],
                   'key=github-pr', 'text=PR #9', 'url=https://github.com/example/toastty/pull/9')
        changed = wait_for('A listed as changed', lambda: (lambda r: r if a['taskID'] in [t['taskID'] for t in r['tasks']] else None)(
            cli_result('task', 'list', '--changed-since', cursor)), timeout=30, interval=1)
        time.sleep(3)
        if waiter.poll() is not None:
            raise AssertionError(f'The wait ended on a change to A: {waiter.communicate(timeout=10)}')
        require(changed['createdTaskIDs'] == [], f'A change counted as a new task: {changed}')
        step('kept waiting through a change', changed=[t['taskID'] for t in changed['tasks']])

        # 2. A's agent creates B: B is not new to A's own wait, which times out.
        own_waiter = start_wait(cursor, '--timeout', '15', session_id=a_session)
        b = create('New task wait B', workspace_id, session_id=a_session)
        own_out, own_err = own_waiter.communicate(timeout=60)
        require(own_waiter.returncode == 1 and 'no new task within 15 s' in own_err,
                f'The creating session was woken by its own task ({own_waiter.returncode}): {own_out} {own_err}')
        step('own task ignored', taskID=b['taskID'], stderr=own_err.strip())

        # 3. The first wait, from a caller that did not create B, returns with B.
        out, err = waiter.communicate(timeout=60)
        require(waiter.returncode == 0, f'The wait failed ({waiter.returncode}): {out} {err}')
        woke = json.loads(out)['result']
        require(woke['createdTaskIDs'] == [b['taskID']], f'Expected B as the new task: {woke}')
        require(woke['cursor'] != cursor and woke['reset'] is False, f'Unexpected cursor or reset: {woke}')
        step('returned with the new task', createdTaskIDs=woke['createdTaskIDs'], cursor=woke['cursor'])

        # 4. Without --json, one line per new task, then the cursor.
        c = create('New task wait C', workspace_id)
        plain = start_wait(woke['cursor'], '--timeout', '30', json_output=False)
        out, err = plain.communicate(timeout=60)
        require(plain.returncode == 0 and f"new task {c['taskID']} New task wait C" in out and '\ncursor ' in out,
                f'Unexpected plain output ({plain.returncode}): {out} {err}')
        step('plain output', output=out.strip())

        # 5. A cursor from an earlier launch returns at once with reset.
        started = time.time()
        stale = start_wait('earlier.1', '--timeout', '30')
        out, err = stale.communicate(timeout=60)
        reset = json.loads(out)['result'] if stale.returncode == 0 else None
        require(reset and reset['reset'] is True and time.time() - started < 10,
                f'A stale cursor did not return at once with reset ({stale.returncode}): {out} {err}')
        step('stale cursor reset', seconds=round(time.time() - started, 1), tasks=len(reset['tasks']))

        evidence['status'] = 'passed'
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / f'{PREFIX}.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[new-task-wait] passed', flush=True)


if __name__ == '__main__':
    main()
