#!/usr/bin/env python3
"""Open the quick entry panel with its global shortcut from another app,
create a task with it, and cancel a second one, in a disposable app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-quick-entry-check.py'.

The remote Mac's screen must be unlocked: the check posts real key events
and reads the panel through Accessibility, with quick-entry-ui-driver.swift.

The check starts its own second instance of the wrapper's build, with a
throwaway runtime home and user home, as remote-task-create-check.py does.
Its `tasks.toml` sets the shortcut to Control+Option+Shift+T, so it does not
compete with the wrapper's own instance, which holds the default. With
Finder in front, it checks that:
- the shortcut opens the panel while Finder stays the active app;
- typed text, a pasted image and a picked workspace become the task, with
  source quickEntry, and the agent starts with the text as written;
- the panel closes and Finder is still in front;
- Esc closes a second panel without creating a task, and Command+T in the
  panel opens no tab in Toastty;
- Command+W closes the panel without closing the terminal behind it.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from importlib.util import module_from_spec, spec_from_file_location

HERE = Path(__file__).resolve().parent
_spec = spec_from_file_location('task_check', HERE / 'remote-task-create-check.py')
task_check = module_from_spec(_spec)
_spec.loader.exec_module(task_check)
Instance, require, wait_for, FAKE_AGENT = task_check.Instance, task_check.require, task_check.wait_for, task_check.FAKE_AGENT

TASK_LINES = ['Unread dot stays on after reading', 'Seen on the phone first.']
FINDER = 'com.apple.finder'
# Virtual key codes on a US keyboard.
KEY_T, KEY_V, KEY_W, KEY_RETURN, KEY_ESCAPE = 17, 9, 13, 36, 53
PANEL = 'quick-entry.panel'


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-quick-entry-check-', dir='/tmp')).resolve()
    driver = root / 'quick-entry-ui-driver'
    subprocess.run(['swiftc', '-O', str(HERE / 'quick-entry-ui-driver.swift'), '-o', str(driver)], check=True)

    def drive(*arguments, check=True):
        result = subprocess.run([str(driver), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        if check:
            require(result.returncode == 0, f'driver {arguments[0]} failed: {result.stderr.strip()}')
        return result.stdout.strip()

    require(drive('locked') == '0', 'The remote screen is locked; unlock it to post key events')

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
        '[defaults]\nagent = "claude"\n\n[quick_entry]\nshortcut = "ctrl+opt+shift+t"\n')
    image = root / 'pasted.png'
    subprocess.run(['sips', '-s', 'format', 'png', '/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns',
                    '--out', str(image)], check=True, capture_output=True)

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-quick-entry-check',
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[quick-entry-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_cli(*arguments):
        result = subprocess.run([str(cli), '--json', *arguments], env=environment,
                                capture_output=True, text=True, timeout=60)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout)['result']

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / 'remote-quick-entry-check-app.log')
    pid = instance.process.pid

    def listed_windows():
        """The app's windows, or None when Accessibility could not list them."""
        result = subprocess.run([str(driver), 'windows', str(pid)], capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            step('windows unreadable', error=result.stderr.strip())
            return None
        return json.loads(result.stdout)

    def panel_windows():
        listed = listed_windows()
        return [w for w in listed or [] if w['identifier'] == PANEL]

    def panel_closed():
        # Only a successful listing that still shows the main window proves
        # the panel is gone; an empty or failed read proves nothing.
        listed = listed_windows()
        return listed is not None and len(listed) > 0 and all(w['identifier'] != PANEL for w in listed)

    def wait_for_text(expected):
        def read():
            value = drive('value', pid, 'quick-entry.text')
            if value == expected:
                return value
            step('text so far', value=value, focused=drive('focused', pid), frontmost=drive('frontmost'))
            return None
        return wait_for('the typed text', read, timeout=10, interval=1)

    def open_panel_from_finder():
        drive('activate', FINDER)
        wait_for('Finder in front', lambda: drive('frontmost') == FINDER, timeout=15)
        drive('key', KEY_T, 'ctrl,opt,shift')
        wait_for('the quick entry panel', panel_windows, timeout=15)
        # The panel is non-activating: the app you were in stays active.
        front = drive('frontmost')
        require(front == FINDER, f'Opening the panel activated {front!r}')
        step('panel open over Finder', windows=panel_windows(), frontmost=front)

    try:
        workspaces = instance.wait_until_ready()
        workspace = workspaces[0]
        wait_for('the first terminal in the user home', lambda: str(user_home) in [
            os.path.realpath(cwd) for w in instance.query('workspace.list')['workspaces']
            if w['workspaceID'] == workspace['workspaceID'] for cwd in w['terminalCwds']], interval=1)
        step('booted', workspaceID=workspace['workspaceID'], title=workspace['title'])

        # 1. Create a task from the panel.
        open_panel_from_finder()
        drive('press-menu', pid, 'quick-entry.workspace', workspace['title'])
        # The menu applies its choice after it closes.
        wait_for('the picked workspace', lambda: drive('value', pid, 'quick-entry.workspace') == workspace['title'], timeout=10)
        drive('type', TASK_LINES[0])
        drive('key', KEY_RETURN)
        drive('type', TASK_LINES[1])
        typed = wait_for_text('\n'.join(TASK_LINES))
        drive('pasteboard-png', image)
        drive('key', KEY_V, 'cmd')
        time.sleep(0.5)
        step('filled in', text=typed, workspace=drive('value', pid, 'quick-entry.workspace'))
        drive('key', KEY_RETURN, 'cmd')

        def created_task():
            task = next(iter(run_cli('task', 'list')['tasks']), None)
            if task is None:
                error = subprocess.run([str(driver), 'value', str(pid), 'quick-entry.error'], capture_output=True, text=True)
                step('no task yet', error=error.stdout.strip() or error.stderr.strip(), panel=bool(panel_windows()))
            return task

        task = wait_for('the created task', created_task, timeout=20, interval=2)
        wait_for('the panel to close', panel_closed, timeout=10)
        front = drive('frontmost')
        require(front == FINDER, f'Focus did not go back to Finder: {front!r}')
        task = wait_for('setup to end', lambda: (lambda t: t if t['setup']['state'] != 'settingUp' else None)(
            run_cli('task', 'get', task['taskID'])), timeout=60)
        require(task['source'] == 'quickEntry', f'Wrong source: {task}')
        require(task['text'] == '\n'.join(TASK_LINES), f'Text not kept as typed: {task["text"]!r}')
        require(task['workspaceID'] == workspace['workspaceID'], f'Workspace not the picked one: {task}')
        require(len(task['files']) == 1 and task['files'][0].endswith('Pasted image.png'), f'Pasted image missing: {task}')
        require(Path(task['files'][0]).read_bytes()[:8] == b'\x89PNG\r\n\x1a\n', 'The attachment is not a PNG')
        require(task['setup']['state'] == 'started', f'Task did not start: {task}')
        message_file = fake_bin / 'sessions' / f"{task['setup']['sessionID']}.message"
        message = wait_for('the agent message', lambda: message_file.is_file() and message_file.read_text())
        require('\n'.join(TASK_LINES) in message and task['files'][0] in message,
                f'The agent did not get the task as written: {message!r}')
        step('task created', taskID=task['taskID'], files=task['files'], frontmost=front, message=message)

        def terminal_count():
            listed = instance.query('workspace.list')['workspaces']
            return sum(len(w['terminalCwds']) for w in listed)

        # 2. Esc closes a second panel and creates nothing. Command+T in the
        # panel must not reach Toastty's menus.
        terminals = terminal_count()
        open_panel_from_finder()
        drive('type', 'Never mind')
        wait_for_text('Never mind')
        drive('key', KEY_T, 'cmd')
        time.sleep(1)
        require(terminal_count() == terminals and panel_windows(), 'Command+T in the panel acted on Toastty')
        drive('key', KEY_ESCAPE)
        wait_for('the panel to close', panel_closed, timeout=10)
        tasks = run_cli('task', 'list')['tasks']
        require(len(tasks) == 1, f'Esc created a task: {tasks}')
        require(drive('frontmost') == FINDER, 'Focus did not go back to Finder after Esc')
        step('escape discarded', tasks=len(tasks), terminals=terminal_count())

        # 3. Command+W closes the panel only.
        open_panel_from_finder()
        drive('key', KEY_W, 'cmd')
        wait_for('the panel to close', panel_closed, timeout=10)
        time.sleep(1)
        require(terminal_count() == terminals, f'Command+W closed a terminal: {terminal_count()} of {terminals}')
        require(len(run_cli('task', 'list')['tasks']) == 1, 'Command+W created a task')
        step('command-w closed the panel only', terminals=terminal_count())

        evidence['status'] = 'passed'
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / 'remote-quick-entry-check.json').write_text(json.dumps(evidence, indent=2, default=str))
        app_log = runtime_home / 'logs' / 'toastty.log'
        if app_log.is_file():
            (artifacts / 'remote-quick-entry-check-toastty.log').write_bytes(app_log.read_bytes())
    print('[quick-entry-check] passed', flush=True)


if __name__ == '__main__':
    main()
