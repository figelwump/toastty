#!/usr/bin/env python3
"""Run through remote/validate.sh on the dedicated validation Mac."""

import json
import os
from pathlib import Path
import signal
import sys
import time

from terminal_gui_session import gui_session, terminal_script


def open_windows():
    result = terminal_script('''
tell application id "com.apple.Terminal"
    set ids to id of windows
    set tabGroups to tabs of windows
    set occupied to {}
    repeat with i from 1 to count ids
        if (count item i of tabGroups) > 0 then set end of occupied to (item i of ids)
    end repeat
    return occupied
end tell
''')
    return {int(value) for value in result.split(',') if value.strip()}


def wait_for(description, condition):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(f'Timed out waiting for {description}')


def child(mode, gate, payload):
    wait_for('the window to be recorded', Path(gate).is_file)
    with open('/dev/tty', 'w') as terminal:
        terminal.write('\033]0;Toastty test command title\a')
    print(json.dumps([payload, os.environ['TOASTTY_GUI_TEST_VALUE']]), flush=True)
    if mode == 'cancel':
        try:
            time.sleep(60)
        finally:
            time.sleep(2)
            Path(gate).with_suffix('.cleaned').touch()
    return 7 if mode == 'failure' else 0


def check(mode, baseline):
    payload = 'a long argument with spaces, "quotes", and a dollar sign $ ' * 30
    value = "broker's path with spaces"
    gate = Path(os.environ['TOASTTY_ARTIFACTS_DIR']) / f'terminal-self-test-{mode}.go'
    gate.unlink(missing_ok=True)
    cleaned = gate.with_suffix('.cleaned')
    cleaned.unlink(missing_ok=True)
    try:
        with gui_session(f'terminal-self-test-{mode}', __file__, ('--child', mode, str(gate), payload),
                         {'TOASTTY_GUI_TEST_VALUE': value}) as (done, output):
            added = open_windows() - baseline
            assert len(added) == 1, added
            window_id = added.pop()
            tty = terminal_script(f'tell application id "com.apple.Terminal" to get tty of tab 1 of window id {window_id}')
            assert tty.startswith('/dev/tty'), tty
            gate.touch()
            if mode == 'cancel':
                wait_for('the child to start', lambda: output.is_file() and output.stat().st_size > 0)
                signal.raise_signal(signal.SIGTERM)
            wait_for('the exit marker', done.is_file)
            assert int(done.read_text()) == (7 if mode == 'failure' else 0)
            assert json.loads(output.read_text()) == [payload, value]
    except SystemExit as error:
        if mode != 'cancel' or error.code != 128 + signal.SIGTERM:
            raise
        assert cleaned.is_file(), 'the child could not finish its cleanup'
        assert int(done.read_text()) == 128 + signal.SIGINT
    else:
        assert mode != 'cancel', 'SIGTERM did not cancel the check'
    assert open_windows() == baseline, f'{mode} changed the baseline window set'
    wait_for(f'{tty} to be released', lambda: not Path(tty).exists())
    print(f'PASS {mode}: window {window_id} closed, {tty} released, {len(baseline)} existing windows preserved', flush=True)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--child':
        raise SystemExit(child(*sys.argv[2:]))
    baseline = open_windows()
    for mode in ('success', 'failure', 'cancel', 'success'):
        check(mode, baseline)
