#!/usr/bin/env python3
"""Check real Claude foreground/idle states while a bounded background task runs.

Run via scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-background-idle-check.py'.
Uses the GUI session's Claude subscription and an unlocked screen. The app,
project and worker are disposable. Claude stores its normal session transcript
in the host account. No task agents run.
"""

import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).parent
PREFIX = 'remote-coordinator-background-idle'


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


create = load('remote_task_create_check', 'remote-task-create-check.py')
queue = load('remote_queue_steer_check', 'remote-queue-steer-check.py')
start = load('remote_task_start_work_check', 'remote-task-start-work-check.py')
require, wait_for = create.require, create.wait_for


def main():
    if '--in-gui-session' not in sys.argv[1:]:
        queue.run_in_gui_session(PREFIX, __file__, ['--in-gui-session'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = Path(os.environ['TOASTTY_APP_BUNDLE']) / 'Contents/MacOS/Toastty'
    root = project = instance = transcript = None
    coordinator, trusted = {}, []
    evidence = dict(status='failed', steps=[], captures=[])

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[{PREFIX}] {name} {json.dumps(facts, default=str)}', flush=True)

    def request(command, payload):
        response = instance.request(command, payload)
        require(response.get('ok'), f'{command} failed: {response}')
        return response.get('result') or {}

    def action(name):
        request('app_control.run_action', dict(id=name, args={}))

    def rendered():
        pages = request('automation.coordinator_page_state', {})['pages']
        return next((page for page in pages if page['view'] == 'chat'), None)

    def state():
        current = instance.query('coordinator.chat.state')
        require('waiting' in current, 'Build lacks coordinator.chat.state waiting field')
        # Fail at a provider rejection instead of waiting for a marker timeout.
        if coordinator.get('panelID'):
            screen = instance.query('terminal.visible-text', panelID=coordinator['panelID'], tail=25).get('text', '')
            require(not any(error in screen for error in ('Invalid API key', 'Not logged in', 'Credit balance is too low',
                                                         'authentication_error', 'API Error: 401', 'API Error: 403')),
                    f'Claude rejected this run: {screen}')
        return current

    def capture(label):
        result = request('automation.capture_screenshot', dict(step=f'{PREFIX}-{label}'))
        target = artifacts / f'{PREFIX}-{label}.png'
        if Path(result['path']).resolve() != target.resolve():
            shutil.copyfile(result['path'], target)
        evidence['captures'].append(target.name)

    def send(text):
        request('automation.coordinator_chat_action', dict(action='type', elementID='composer-input', text=text))

    def idle(marker):
        current, page = state(), rendered()
        seen = any(item.get('role') == 'assistant' and item.get('text') == marker for item in current['items'])
        if seen and current['inputState'] == 'openPrompt' and current['waiting'] is True and current['working'] is False:
            if page and page['activityText'] is None and not any(strip['live'] for strip in page['workStrips']):
                require(started.exists() and not finished.exists() and not release.exists(), 'Background task is no longer running')
                return dict(native=current, dom=page)
        return None

    def bash_proof(command, background, marker):
        """Select only this coordinator's transcript, by its assistant reply."""
        nonlocal transcript
        paths = [transcript] if transcript else queue.claude_project_directory(coordinator_dir).glob('*.jsonl')
        for path in paths:
            records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
            if not any(row.get('type') == 'assistant' and queue.claude_content_text(
                    row.get('message', {}).get('content')).strip() == marker for row in records):
                continue
            require(all(row.get('cwd', str(coordinator_dir)) == str(coordinator_dir) for row in records),
                    'Claude transcript contains another working directory')
            calls = [block['input'] for row in records if row.get('type') == 'assistant'
                     for block in row.get('message', {}).get('content', []) if isinstance(block, dict)
                     and block.get('type') == 'tool_use' and block.get('name') == 'Bash'
                     and block.get('input', {}).get('command') == command]
            require(any(call.get('run_in_background', False) is background for call in calls),
                    f'No exact Bash command with run_in_background={background}: {calls}')
            transcript = path
            return dict(transcript=str(path), command=command, run_in_background=background)
        return None

    def cleanup(label, operation):
        try:
            operation()
        except Exception as error:
            evidence.setdefault('cleanupErrors', []).append(f'{label}: {error}')
            evidence['status'] = 'failed'

    try:
        artifacts.mkdir(parents=True, exist_ok=True)
        require(binary.is_file(), f'No Toastty binary at {binary}')
        root = Path(tempfile.mkdtemp(prefix='toastty-background-idle-', dir='/tmp')).resolve()
        evidence['root'] = str(root)
        runtime = root / 'runtime-home'
        runtime.mkdir()
        project = Path.home() / 'toastty-queue-steer-checks' / f'background-idle-{uuid.uuid4().hex[:8]}'
        project.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        (project / '.toastty').mkdir()
        if (Path.home() / '.claude').exists():
            (project / '.claude').symlink_to(Path.home() / '.claude')
        environment = {k: v for k, v in os.environ.items()
                       if not k.startswith('TOASTTY_') and k not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
        coordinator_dir, socket_path = runtime / 'coordinator', str(root / 'socket.sock')
        environment.update(TOASTTY_RUNTIME_HOME=str(runtime), TOASTTY_USER_SKILLS_ROOT=str(runtime / 'skills'),
                           TOASTTY_RUNTIME_LABEL=PREFIX, TOASTTY_SOCKET_PATH=socket_path,
                           TOASTTY_COORDINATOR_AUTOSTART='1', TOASTTY_AUTOMATION='1',
                           TOASTTY_ARTIFACTS_DIR=str(artifacts), CFFIXED_USER_HOME=str(project), DISABLE_AUTOUPDATER='1')
        release, started, finished = (root / name for name in ('release', 'background-started', 'background-finished'))
        foreground_started, foreground_finished = (root / name for name in ('foreground-started', 'foreground-finished'))
        worker = root / 'bounded-worker.py'
        worker.write_text(
            'from pathlib import Path\nimport sys, time\nroot = Path(__file__).parent\n'
            'if not root.exists() or (root / "release").exists():\n    sys.exit(0)\n'
            'if sys.argv[1] == "foreground":\n'
            '    (root / "foreground-started").touch()\n    time.sleep(8)\n'
            '    if root.exists():\n        (root / "foreground-finished").touch()\n'
            'else:\n    (root / "background-started").touch()\n    deadline = time.monotonic() + 600\n'
            '    while root.exists() and not (root / "release").exists() and time.monotonic() < deadline:\n        time.sleep(0.2)\n'
            '    if root.exists():\n        (root / "background-finished").touch()\n')
        version, argv = start.provider_profile('claude', environment, project)
        evidence['claude'] = version
        argv += ['--allowedTools', 'Bash,Read,Glob,Grep,Skill', '--verbose']
        (project / '.toastty/agents.toml').write_text(
            f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps(argv)}\ninitialPromptPlacement = "trailing"\n')
        (project / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n\n[coordinator]\nagent = "claude"\n')
        for directory in (project, coordinator_dir):
            trusted.append(directory)
            queue.set_directory_trust(directory, True)
        instance = create.Instance(binary, environment, socket_path, runtime, artifacts / f'{PREFIX}-app.log')
        instance.wait_until_ready()
        coordinator = wait_for('real Claude coordinator', lambda: (lambda s: s if s['state'] == 'running' else None)(
            instance.query('coordinator.status')), timeout=90, interval=1)
        require(coordinator.get('panelID'), 'Coordinator has no terminal panel for provider checks')
        action('coordinator.chat.show')
        wait_for('chat ready', lambda: (lambda s: s['canSend'] and s['inputState'] == 'openPrompt' and rendered())(state()),
                 timeout=180, interval=1)
        step('real coordinator ready', coordinator=coordinator)
        first, second = (f'{name}-{uuid.uuid4().hex}' for name in ('BACKGROUND-IDLE', 'FOREGROUND-DONE'))
        command = f'python3 {shlex.quote(str(worker))} background'
        send('Diagnostic request: do this yourself in this coordinator, without delegating or creating a task. '
             f'Use Bash with command {json.dumps(command)} and run_in_background=true. '
             'It is a run-owned bounded process that waits for a release file, with a 600-second deadline. '
             f'After Bash returns its background task ID, reply with exactly {first} and end your turn. '
             'Do not wait for, inspect, or stop the background process. Do not start another watch.')
        proof = wait_for('idle chat while the real background process runs', lambda: idle(first), timeout=120, interval=0.4)
        proof['bash'] = wait_for('exact background Bash input', lambda: bash_proof(command, True, first), timeout=10)
        capture('background-idle-chat')
        step('background process running; coordinator idle', **proof)
        action('coordinator.show-terminal')
        # The supported action selects the native terminal. Its header and tab
        # are checked visually in this capture; no query exposes that view.
        time.sleep(0.5)
        require(started.exists() and not finished.exists() and not release.exists(), 'Background ended before terminal capture')
        capture('background-idle-terminal')
        current = state()
        require(current['waiting'] is True and current['working'] is False and current['inputState'] == 'openPrompt',
                'Idle state changed while showing the native terminal header and tab')
        step('native terminal capture for visual review', waiting=True, working=False, backgroundPending=not finished.exists())
        action('coordinator.chat.show')
        wait_for('idle chat restored', lambda: idle(first), timeout=15)
        command = f'python3 {shlex.quote(str(worker))} foreground'
        send('Diagnostic request: do this yourself without delegating. '
             f'Use Bash with command {json.dumps(command)} and run_in_background=false. '
             f'It sleeps for eight seconds. When it returns, reply with exactly {second} and end your turn. '
             'Leave the earlier background process running.')

        def foreground():
            current, page = state(), rendered()
            if foreground_started.exists() and not foreground_finished.exists() and current['working'] is True and current['waiting'] is False:
                if page and (page['activityText'] or any(strip['live'] for strip in page['workStrips'])):
                    return dict(native=current, dom=page)
            return None

        proof = wait_for('foreground Bash with native and DOM activity', foreground, timeout=90, interval=0.2)
        capture('foreground-working')
        step('foreground work visible', **proof)
        proof = wait_for('foreground finished and background still running', lambda: idle(second), timeout=90, interval=0.4)
        require(foreground_finished.exists(), 'Foreground command did not complete')
        proof['bash'] = wait_for('exact foreground Bash input', lambda: bash_proof(command, False, second), timeout=10)
        capture('foreground-finished-idle')
        step('foreground finished; coordinator idle again', **proof)
        evidence['status'] = 'passed'
    except Exception as error:
        evidence['status'] = 'failed'
        evidence['error'] = str(error)
        if instance:
            try:
                evidence['lastNative'] = instance.query('coordinator.chat.state')
                evidence['lastDOM'] = rendered()
                capture('failure')
            except Exception as capture_error:
                evidence['captureError'] = str(capture_error)
        raise
    finally:
        if root:
            cleanup('release worker', lambda: (root / 'release').touch())
            if (root / 'background-started').exists():
                cleanup('worker completion', lambda: wait_for('run-owned background process release',
                                                              (root / 'background-finished').exists, timeout=5))
        if instance:
            cleanup('disposable app', instance.kill)
        for directory in trusted:
            cleanup(f'trust {directory}', lambda d=directory: queue.set_directory_trust(d, False))
        if transcript:
            cleanup('copy provider transcript', lambda: shutil.copyfile(transcript, artifacts / f'{PREFIX}-transcript.jsonl'))
        for directory in (project, root):
            if directory:
                cleanup(f'remove {directory}', lambda d=directory: shutil.rmtree(d) if d.exists() else None)
                cleanup(f'verify removal {directory}', lambda d=directory: require(not d.exists(), f'{d} remains'))
        cleanup('write evidence', lambda: (artifacts / f'{PREFIX}-check.json').write_text(json.dumps(evidence, indent=2, default=str)))
        if evidence.get('cleanupErrors'):
            print(f'[{PREFIX}] cleanup errors: {evidence["cleanupErrors"]}', flush=True)
    require(evidence['status'] == 'passed', f'Check or cleanup failed: {evidence.get("error")} {evidence.get("cleanupErrors", [])}')


if __name__ == '__main__':
    main()
