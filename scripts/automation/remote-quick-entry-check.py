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
- Command+1 opens the Workspace picker, typing filters it and Return picks
  and puts the caret back in the text; Command+2 then Right Arrow raises the
  `[defaults]` preset's effort, all without making Toastty active;
- typed text, a pasted image, the picked workspace and the preset become the
  task, with source quickEntry, and the agent starts with the text as
  written and the preset's model and effort;
- the panel closes and Finder is still in front;
- with Workspace left on Auto, triage (a fake command that picks the first
  open workspace) places the task and it starts;
- Esc in a picker closes only the picker; Esc then closes a second panel
  without creating a task, and Command+T in the panel opens no tab in
  Toastty;
- Command+Delete deletes in the text; the three columns (Command+Right
  Arrow, typing, Tab) pin an agent, a typed model and an effort; clicks on
  a pill and a picker row work;
- Command+W closes the panel without closing the terminal behind it;
- a file, a file promise and PNG data dragged from another process attach,
  dropped on the text or on the footer, and dragged text joins the text;
  the drop highlight is gone after each drop;
- Command+V pastes text, with Finder in front and with Toastty in front.
"""

import json
import os
import select
import shutil
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
AUTO_TEXT = 'Placed by triage'
PASTE_TEXT = 'Pasted words from the clipboard'

# Answers triage with the first open workspace in the JSON Toastty writes.
FAKE_TRIAGE = r'''import json, re, sys
data = sys.stdin.read()
match = re.search(r'"workspaces"\s*:\s*\[.*?"id"\s*:\s*"([0-9A-F-]{36})"', data, re.S)
print(json.dumps({"workspace": match.group(1) if match else None, "reason": "remote check"}))
'''
FINDER = 'com.apple.finder'
# Virtual key codes on a US keyboard.
KEY_T, KEY_V, KEY_W, KEY_RETURN, KEY_ESCAPE = 17, 9, 13, 36, 53
KEY_1, KEY_2, KEY_TAB, KEY_DELETE, KEY_RIGHT = 18, 19, 48, 51, 124
PANEL = 'quick-entry.panel'
PICKER = 'quick-entry.picker'


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-quick-entry-check-', dir='/tmp')).resolve()
    driver = root / 'quick-entry-ui-driver'
    subprocess.run(['swiftc', '-O', str(HERE / 'quick-entry-ui-driver.swift'), '-o', str(driver)], check=True)
    drag_source = root / 'quick-entry-drag-source'
    subprocess.run(['swiftc', '-O', str(HERE / 'quick-entry-drag-source.swift'), '-o', str(drag_source)], check=True)

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
    triage = root / 'triage.py'
    triage.write_text(FAKE_TRIAGE)
    (user_home / '.toastty/tasks.toml').write_text(
        '[triage]\ncommand = "/usr/bin/python3 ' + str(triage) + '"\ntimeout_seconds = 30\n\n'
        '[defaults]\nagent = "claude"\nmodel = "claude-opus-5-5"\neffort = "high"\n\n'
        '[quick_entry]\nshortcut = "ctrl+opt+shift+t"\n')
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

    def picker_windows():
        listed = listed_windows()
        return [w for w in listed or [] if w['identifier'] == PICKER]

    def picker_closed():
        listed = listed_windows()
        return listed is not None and any(w['identifier'] == PANEL for w in listed) \
            and all(w['identifier'] != PICKER for w in listed)

    def wait_for_value(identifier, expected):
        return wait_for(f'{identifier} to read {expected!r}',
                        lambda: drive('value', pid, identifier) == expected, timeout=10, interval=0.5)

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

        # 1. Create a task from the panel, picking the workspace and the
        # agent preset from the keyboard.
        open_panel_from_finder()
        require(drive('value', pid, 'quick-entry.workspace') == 'Auto', 'The workspace did not start on Auto')
        drive('key', KEY_1, 'cmd')
        wait_for('the workspace picker', picker_windows, timeout=10)
        drive('type', workspace['title'])
        drive('key', KEY_RETURN)
        wait_for('the workspace picker to close', picker_closed, timeout=10)
        wait_for_value('quick-entry.workspace', workspace['title'])
        # Return put the caret back in the text: typing lands there.
        drive('type', TASK_LINES[0])
        drive('key', KEY_RETURN)
        drive('type', TASK_LINES[1])
        typed = wait_for_text('\n'.join(TASK_LINES))
        drive('key', KEY_2, 'cmd')
        wait_for('the agent picker', picker_windows, timeout=10)
        require(drive('frontmost') == FINDER, 'Opening a picker activated Toastty')
        drive('key', KEY_RIGHT)
        drive('key', KEY_RETURN)
        wait_for('the agent picker to close', picker_closed, timeout=10)
        wait_for_value('quick-entry.agent', 'claude-opus-5-5 · xhigh')
        drive('pasteboard-png', image)
        drive('key', KEY_V, 'cmd')
        time.sleep(0.5)
        step('filled in', text=typed, workspace=drive('value', pid, 'quick-entry.workspace'),
             agent=drive('value', pid, 'quick-entry.agent'), frontmost=drive('frontmost'))
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
        task = wait_for('setup to end', lambda: (lambda t: t if t['setup']['state'] not in ('routing', 'settingUp') else None)(
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
        argv = (fake_bin / 'sessions' / f"{task['setup']['sessionID']}.argv").read_text().split('\n')
        # [defaults] says high; the preset's xhigh must win.
        require(task.get('model') == 'claude-opus-5-5' and task.get('effort') == 'xhigh',
                f'The task did not keep the preset: {task}')
        require(argv[argv.index('--model') + 1] == 'claude-opus-5-5' and argv[argv.index('--effort') + 1] == 'xhigh',
                f'The agent did not start with the preset: {argv}')
        step('task created', taskID=task['taskID'], files=task['files'], frontmost=front, message=message,
             model=task.get('model'), effort=task.get('effort'), argv=argv)

        # 1b. Workspace left on Auto: triage places the task.
        open_panel_from_finder()
        require(drive('value', pid, 'quick-entry.workspace') == 'Auto', 'The workspace did not start on Auto')
        drive('type', AUTO_TEXT)
        wait_for_text(AUTO_TEXT)
        drive('key', KEY_RETURN, 'cmd')
        wait_for('the panel to close', panel_closed, timeout=10)

        def auto_task():
            listed = [t for t in run_cli('task', 'list')['tasks'] if t['text'] == AUTO_TEXT]
            if not listed:
                return None
            placed = run_cli('task', 'get', listed[0]['taskID'])
            return placed if placed['setup']['state'] not in ('routing', 'settingUp') else None

        placed = wait_for('triage to place the task', auto_task, timeout=60)
        require(placed['source'] == 'quickEntry', f'Wrong source: {placed}')
        require(placed['workspaceID'] == workspace['workspaceID'], f'Triage did not place it in the open workspace: {placed}')
        require(placed['setup']['state'] == 'started', f'The placed task did not start: {placed}')
        step('auto workspace placed by triage', taskID=placed['taskID'], workspaceID=placed['workspaceID'],
             triageNote=placed.get('triageNote'))

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
        drive('key', KEY_1, 'cmd')
        wait_for('the workspace picker', picker_windows, timeout=10)
        drive('type', 'zz')
        drive('key', KEY_ESCAPE)
        wait_for('Esc to close only the picker', picker_closed, timeout=10)
        require(drive('value', pid, 'quick-entry.workspace') == 'Auto', 'Esc in the picker changed the workspace')
        drive('type', ' at all')
        wait_for_text('Never mind at all')
        step('escape closed only the picker', text=drive('value', pid, 'quick-entry.text'))
        drive('key', KEY_ESCAPE)
        wait_for('the panel to close', panel_closed, timeout=10)
        tasks = run_cli('task', 'list')['tasks']
        require(len(tasks) == 2, f'Esc created a task: {tasks}')
        require(drive('frontmost') == FINDER, 'Focus did not go back to Finder after Esc')
        step('escape discarded', tasks=len(tasks), terminals=terminal_count())

        # 3. Command+W closes the panel only.
        open_panel_from_finder()
        drive('key', KEY_W, 'cmd')
        wait_for('the panel to close', panel_closed, timeout=10)
        time.sleep(1)
        require(terminal_count() == terminals, f'Command+W closed a terminal: {terminal_count()} of {terminals}')
        require(len(run_cli('task', 'list')['tasks']) == 2, 'Command+W created a task')
        step('command-w closed the panel only', terminals=terminal_count())

        # 3b. Command+Delete in the text, the three columns, and the mouse.
        open_panel_from_finder()
        drive('type', 'Delete this line')
        wait_for_text('Delete this line')
        drive('key', KEY_DELETE, 'cmd')
        wait_for_text('')
        drive('key', KEY_2, 'cmd')
        wait_for('the agent picker', picker_windows, timeout=10)
        drive('key', KEY_RIGHT, 'cmd')
        drive('type', 'claude')
        drive('key', KEY_TAB)
        drive('type', 'claude-sonnet-5-5')
        drive('key', KEY_TAB)
        drive('type', 'low')
        drive('key', KEY_RETURN)
        wait_for('the columns to close', picker_closed, timeout=10)
        wait_for_value('quick-entry.agent', 'claude-sonnet-5-5 · low')
        step('columns pinned a typed model', agent=drive('value', pid, 'quick-entry.agent'))

        # The first row is the [defaults] preset.
        x, y, w, h = map(float, drive('frame', pid, 'quick-entry.agent').split())
        drive('click', x + w / 2, y + h / 2)
        wait_for('a click on the pill to open its picker', picker_windows, timeout=10)
        x, y, w, h = map(float, drive('frame', pid, 'quick-entry.picker.row').split())
        drive('click', x + w / 2, y + h / 2)
        wait_for('a click on a row to close the picker', picker_closed, timeout=10)
        wait_for_value('quick-entry.agent', 'claude-opus-5-5 · high')
        step('mouse picked a row', agent=drive('value', pid, 'quick-entry.agent'))
        drive('key', KEY_ESCAPE)
        wait_for('the panel to close', panel_closed, timeout=10)

        # 4. Real drags from another process, and Command+V with text. Each
        # case records its outcome and the check fails at the end, so one
        # run shows every case.
        outcomes = {}

        def frame(identifier):
            return tuple(map(float, drive('frame', pid, identifier).split()))

        def submit_and_find(text):
            # The drag source's click can take key status from the panel;
            # the shortcut gives it back to the open panel.
            drive('key', KEY_T, 'ctrl,opt,shift')
            time.sleep(0.5)
            for _ in range(10):
                drive('key', KEY_RETURN, 'cmd')
                time.sleep(1)
                if panel_closed():
                    break
            listed = [t for t in run_cli('task', 'list')['tasks'] if t['text'].startswith(text)]
            return run_cli('task', 'get', listed[0]['taskID']) if listed else None

        def drop_case(name, mode, path, target):
            open_panel_from_finder()
            drive('type', name)
            wait_for_text(name)
            px, py, pw, ph = frame(PANEL)
            if target == 'text':
                tx, ty, tw, th = frame('quick-entry.text')
                point = (tx + tw / 2, ty + min(th / 2, 24))
            else:
                # The panel's bottom padding, below the footer's controls.
                point = (px + pw / 2, py + ph - 5)
            source_x = px - 180 if px > 200 else px + pw + 40
            source = subprocess.Popen([str(drag_source), mode, str(path), str(source_x), str(py + 20)],
                                      stdout=subprocess.PIPE, text=True)
            try:
                started, _, _ = select.select([source.stdout], [], [], 20)
                require(started and source.stdout.readline().strip() == 'ready', f'The {mode} drag source did not start')
                time.sleep(0.5)
                drive('drag', source_x + 60, py + 60, *point)
                time.sleep(2)
                # The drop highlight must be gone once the drag ends.
                hint = subprocess.run([str(driver), 'value', str(pid), 'quick-entry.drop-hint'],
                                      capture_output=True, text=True, timeout=60)
                highlight_cleared = hint.returncode != 0
            finally:
                try:
                    source.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    source.kill()
            task = submit_and_find(name)
            files = task['files'] if task else None
            if mode == 'text':
                # Dropped text goes into the text, not into a file.
                ok = task is not None and 'Dropped words' in task['text'] and files == []
            else:
                ok = bool(files) and len(files) == 1 and Path(files[0]).read_bytes()[:8] == b'\x89PNG\r\n\x1a\n'
            outcomes[name] = dict(ok=ok and highlight_cleared, mode=mode, target=target, point=point, files=files,
                                  highlight_cleared=highlight_cleared, task=task and task['taskID'],
                                  text=task and task['text'])
            step(f'drop {name}', **outcomes[name])

        dragged = root / 'dragged.png'
        shutil.copyfile(image, dragged)
        drop_case('drop file on text', 'file', dragged, 'text')
        drop_case('drop file on footer', 'file', dragged, 'footer')
        drop_case('drop promise on text', 'promise', image, 'text')
        drop_case('drop image data on text', 'image', image, 'text')
        drop_case('drop text on text', 'text', image, 'text')

        def paste_case(name, front):
            if front == 'toastty':
                drive('activate-pid', pid)
                wait_for('Toastty in front', lambda: drive('frontmost-pid') == str(pid), timeout=15)
            else:
                drive('activate', FINDER)
                wait_for('Finder in front', lambda: drive('frontmost') == FINDER, timeout=15)
            drive('key', KEY_T, 'ctrl,opt,shift')
            wait_for('the quick entry panel', panel_windows, timeout=15)
            time.sleep(0.5)
            drive('pasteboard-text', PASTE_TEXT)
            drive('key', KEY_V, 'cmd')
            time.sleep(1)
            value = drive('value', pid, 'quick-entry.text')
            outcomes[name] = dict(ok=value == PASTE_TEXT, value=value, focused=drive('focused', pid),
                                  frontmost=drive('frontmost'))
            step(name, **outcomes[name])
            drive('key', KEY_ESCAPE)
            wait_for('the panel to close', panel_closed, timeout=10)

        paste_case('paste text with Finder in front', 'finder')
        paste_case('paste text with Toastty in front', 'toastty')

        failed = {name: outcome for name, outcome in outcomes.items() if not outcome['ok']}
        require(not failed, f'Cases failed: {json.dumps(failed, default=str)}')

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
        # The evidence is in the artifacts; the remote Mac's disk has filled
        # with leftover run folders before.
        shutil.rmtree(root, ignore_errors=True)
    print('[quick-entry-check] passed', flush=True)


if __name__ == '__main__':
    main()
