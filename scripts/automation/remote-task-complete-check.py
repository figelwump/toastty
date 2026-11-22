#!/usr/bin/env python3
"""Check Complete Task in the top bar of a real app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-complete-check.py'. It needs an
unlocked screen: it clicks the top bar and the alert through Accessibility
and real mouse events.

The check starts its own instance of the wrapper's build, as
remote-task-context-menu-check.py does, with a fake agent and four tasks in
sidebar order: one ready for review, one with nothing to do, one ready for
review after it, and one an agent marked done. It checks that:
- the first task's top bar offers Complete Task; a click opens the Complete
  alert, which names what closes; Cancel keeps the task and its task space;
- Complete Task in the alert moves the task to Done, closes its task space,
  and moves focus past the quiet neighbor to the next task ready for review,
  the one Jump to Next Active picks;
- a done task whose task space stays open shows Done in its top bar, not a
  bare Archive Task button.
The alert's text and each step go to remote-task-complete-check.json in the
artifacts directory.
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


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-task-complete-check-', dir='/tmp')).resolve()
    driver, helper = root / 'quick-entry-ui-driver', root / 'task-stages-ui-helper'
    for source, output in ((HERE / 'quick-entry-ui-driver.swift', driver), (HERE / 'task-stages-ui-helper.swift', helper)):
        subprocess.run(['swiftc', '-O', str(source), '-o', str(output)], check=True)

    def run(tool, *arguments, check=True):
        result = subprocess.run([str(tool), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        if check:
            require(result.returncode == 0, f'{tool.name} {arguments[0]} failed: {result.stderr.strip()}')
        return result

    require(run(driver, 'locked').stdout.strip() == '0', 'The remote screen is locked; unlock it to click the top bar')

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
        TOASTTY_RUNTIME_LABEL='remote-task-complete-check',
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[task-complete-check] {name} {json.dumps(facts, default=str, ensure_ascii=False)}', flush=True)

    def cli_json(*arguments):
        result = subprocess.run([str(cli), '--json', *arguments], env=environment,
                                capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    def stage(task_id):
        return cli_json('task', 'get', task_id)['stage']

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / 'remote-task-complete-check-app.log')
    pid = instance.process.pid

    def workspaces():
        return instance.query('workspace.list')['workspaces']

    def selected():
        return next((w for w in workspaces() if w['isSelected']), None)

    def capture(name):
        """Evidence only: `automation.capture_screenshot` needs automation
        mode, which skips the alert, so this instance captures only in an
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

    def top_bar(role, title):
        """Frames of the top bar's elements with this role and title. SwiftUI
        gives top bar controls the bar's own identifier, so they are found
        by what they say."""
        frames = []
        for line in run(helper, 'dump', pid).stdout.splitlines():
            parts = line.split(' id=', 1)
            if len(parts) < 2 or not parts[0].endswith(' ' + role) or 'id=topbar.' not in ' id=' + parts[1]:
                continue
            rest = parts[1].split(' title=', 1)[1]
            label, frame = rest.rsplit(' frame=', 1)
            if label == title:
                origin, size = frame.split(' ')
                x, y = map(float, origin.split(','))
                width, height = map(float, size.split('x'))
                frames.append((x, y, width, height))
        return frames

    def click(role, title):
        """A real click in the middle of the element, with the app in front."""
        run(helper, 'activate', pid)
        time.sleep(0.4)
        frames = top_bar(role, title)
        require(frames, f'No {role} {title} in the top bar')
        x, y, width, height = max(frames, key=lambda f: f[2] * f[3])
        run(driver, 'click', x + width / 2, y + height / 2)

    def alert():
        return wait_for('the Complete alert', lambda: (d := json.loads(run(driver, 'dialog', pid).stdout)) and d)

    try:
        listed = instance.wait_until_ready()
        workspace_id = listed[0]['workspaceID']
        wait_for('the first terminal in the user home', lambda: str(user_home) in [
            os.path.realpath(cwd) for w in workspaces()
            if w['workspaceID'] == workspace_id for cwd in w['terminalCwds']], interval=1)

        def started(title):
            task = cli_json('task', 'create', title, '--workspace', workspace_id, '--wait', '--timeout', '90')
            return task['taskID'], task['setup']['taskSpaceWorkspaceID']

        def ready(task_id):
            cli_json('task', 'ready-for-review', task_id)
            wait_for('the ready for review stage', lambda: stage(task_id).get('attention') == 'readyForReview')

        answer, answer_space = started('Answer the release question')
        quiet, quiet_space = started('Nothing to do here')
        review, review_space = started('Review the session list')
        agent_done, agent_done_space = started('Agent finished this one')
        ready(answer)
        ready(review)
        cli_json('task', 'mark-done', agent_done)
        wait_for('the agent-marked done stage', lambda: stage(agent_done)['group'] == 'done')
        order = [w['workspaceID'] for w in workspaces()]
        require(order.index(quiet_space) == order.index(answer_space) + 1,
                f'The quiet task space should follow the first one: {order}')
        step('tasks created', answer=answer, quiet=quiet, review=review, agentDone=agent_done,
             stages={name: stage(task) for name, task in
                     (('answer', answer), ('quiet', quiet), ('review', review), ('agentDone', agent_done))})

        # 1. A done task space that stays open says Done.
        cli_json('action', 'run', 'workspace.select', '--workspace', agent_done_space)
        wait_for('the Done label', lambda: top_bar('AXMenuButton', 'Done'))
        require(not top_bar('AXButton', 'Archive Task…'), 'A done task space should not show a bare Archive Task button')
        step('done task shows Done')
        capture('done-header')

        # 2. Complete Task asks first; Cancel changes nothing.
        cli_json('action', 'run', 'workspace.select', '--workspace', answer_space)
        wait_for('Complete Task', lambda: top_bar('AXButton', 'Complete Task'))
        capture('ready-header')
        click('AXButton', 'Complete Task')
        dialog = alert()
        evidence['completeAlert'] = dialog
        step('complete alert', **dialog)
        capture('complete-alert')
        require('Complete “Answer the release question”?' in dialog['texts'], f'Unexpected alert: {dialog}')
        require(any('Closes the task space' in text for text in dialog['texts']), f'The alert should say what closes: {dialog}')
        require(dialog['buttons'][:2] == ['Complete Task', 'Cancel'], f'Unexpected buttons: {dialog}')
        run(driver, 'dialog-press', pid, 'Cancel')
        time.sleep(1)
        require(stage(answer).get('attention') == 'readyForReview', f'Cancel should keep the task: {stage(answer)}')
        require(selected()['workspaceID'] == answer_space, 'Cancel should keep the task space open and selected')
        step('complete cancelled')

        # 3. Complete Task closes the task space and moves to the next task
        # ready for review, past the quiet neighbor.
        click('AXButton', 'Complete Task')
        alert()
        run(driver, 'dialog-press', pid, 'Complete Task')
        wait_for('the done task', lambda: stage(answer)['group'] == 'done')
        wait_for('the closed task space', lambda: answer_space not in [w['workspaceID'] for w in workspaces()])
        now_selected = wait_for('a selected workspace', selected)
        step('completed', selected=now_selected['title'], stage=stage(answer))
        require(now_selected['workspaceID'] == review_space,
                f'Focus should move to the next task ready for review, not {now_selected["title"]}')
        capture('after-complete')

        evidence['status'] = 'passed'
    except Exception:
        dump = subprocess.run([str(helper), 'dump', str(pid)], capture_output=True, text=True, timeout=60)
        (artifacts / 'remote-task-complete-check-ax.txt').write_text(dump.stdout)
        raise
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / 'remote-task-complete-check.json').write_text(
            json.dumps(evidence, indent=2, default=str, ensure_ascii=False))
    print('[task-complete-check] passed', flush=True)


if __name__ == '__main__':
    main()
