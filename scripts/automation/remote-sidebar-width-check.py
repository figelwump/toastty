#!/usr/bin/env python3
"""Check that a fresh install opens with the full-width sidebar.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-sidebar-width-check.py'. It needs an
unlocked screen: it reads its own app instance through Accessibility.

The check starts its own instance of the wrapper's build with a throwaway
runtime home and user home, so no agent has ever launched and no window has a
resized width. It checks that the sidebar's Tasks row, which spans the
sidebar, is as wide as the 280 pt default allows rather than the old 180 pt
first-launch width, and captures the window.
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
require, wait_for, Instance = base.require, base.wait_for, base.Instance

DEFAULT_SIDEBAR_WIDTH = 280
OLD_FIRST_LAUNCH_WIDTH = 180


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    require(binary.is_file(), f'No Toastty binary in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-sidebar-width-check-', dir='/tmp')).resolve()
    driver = root / 'quick-entry-ui-driver'
    subprocess.run(['swiftc', '-O', str(HERE / 'quick-entry-ui-driver.swift'), '-o', str(driver)], check=True)

    def drive(*arguments):
        result = subprocess.run([str(driver), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        require(result.returncode == 0, f'driver {arguments[0]} failed: {result.stderr.strip()}')
        return result.stdout.strip()

    require(drive('locked') == '0', 'The remote screen is locked; unlock it to read the window')

    runtime_home, user_home = root / 'runtime-home', root / 'user-home'
    for directory in (runtime_home, user_home / '.toastty'):
        directory.mkdir(parents=True)
    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_RUNTIME_LABEL='remote-sidebar-width-check',
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], root=str(root), captures=[])

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[sidebar-width-check] {name} {json.dumps(facts, default=str)}', flush=True)

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / 'remote-sidebar-width-check-app.log')
    pid = instance.process.pid
    try:
        instance.wait_until_ready()

        def tasks_row_frame():
            result = subprocess.run([str(driver), 'frame', str(pid), 'sidebar.coordinator.open'],
                                    capture_output=True, text=True, timeout=60)
            if result.returncode != 0:
                return None
            return [float(value) for value in result.stdout.split()]

        x, y, width, height = wait_for('the sidebar Coordinator row', tasks_row_frame, timeout=30, interval=0.5)
        step('tasks row', x=x, y=y, width=width, height=height)
        # The row spans the sidebar less its side padding. At the old 180 pt
        # width it could be at most 180 pt wide.
        require(width > OLD_FIRST_LAUNCH_WIDTH, f'The sidebar is still narrow: Coordinator row {width} pt')
        require(width <= DEFAULT_SIDEBAR_WIDTH, f'The Coordinator row is wider than the sidebar: {width} pt')

        time.sleep(0.6)
        response = instance.request('automation.capture_screenshot', dict(step='fresh-install-sidebar'))
        path = artifacts / 'fresh-install-sidebar.png'
        if response.get('ok'):
            shutil.copyfile(response['result']['path'], path)
            evidence['captures'].append(path.name)
        else:
            step('capture unavailable', error=response.get('error'))
        evidence['status'] = 'passed'
    finally:
        instance.kill()
        (artifacts / 'remote-sidebar-width-check.json').write_text(json.dumps(evidence, indent=2, default=str))
        print(json.dumps(dict(status=evidence['status'], captures=evidence['captures'])), flush=True)


if __name__ == '__main__':
    main()
