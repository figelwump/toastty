"""Run an automation check in the logged-in macOS GUI session."""

from contextlib import contextmanager
import os
from pathlib import Path
import shlex
import signal
import subprocess
import time
import uuid


OPEN_WINDOW = '''
on run argv
    set ownerTag to item 1 of argv
    tell application id "com.apple.Terminal"
        set ownedTab to do script ""
        set custom title of ownedTab to ownerTag
        set title displays custom title of ownedTab to true
        set windowID to id of first window whose name contains ownerTag
        return (windowID as text) & "|" & (tty of ownedTab)
    end tell
end run
'''

START_CHECK = '''
on run argv
    set windowID to (item 1 of argv) as integer
    set ownedTTY to item 2 of argv
    tell application id "com.apple.Terminal"
        if (count tabs of window id windowID) is not 1 then error "Terminal window ownership changed"
        set ownedTab to tab 1 of window id windowID
        if (tty of ownedTab) is not ownedTTY then error "Terminal tab ownership changed"
        do script (item 3 of argv) in ownedTab
    end tell
end run
'''

CLOSE_WINDOW = '''
on run argv
    set windowID to (item 1 of argv) as integer
    set ownedTTY to item 2 of argv
    set ownerTag to item 3 of argv
    if application id "com.apple.Terminal" is not running then return ""
    tell application id "com.apple.Terminal"
        if not (exists window id windowID) then return ""
        try
            set tabCount to count tabs of window id windowID
            -- Terminal can retain a closed window record with no tabs.
            if tabCount is 0 then return ""
            if tabCount is not 1 then error "Terminal window ownership changed"
            set ownedTab to tab 1 of window id windowID
            if (tty of ownedTab) is not ownedTTY then error "Terminal tab ownership changed"
            -- A busy window would open a confirmation sheet instead of closing.
            if busy of ownedTab then return ownedTTY
            -- A command can change the title. Only close an untagged tab
            -- when its shell has exited.
            if (custom title of ownedTab) is not ownerTag and (count processes of ownedTab) > 0 then return ownedTTY
            close window id windowID
            if exists window id windowID then
                if (count tabs of window id windowID) is not 0 then error "Terminal window did not close"
            end if
        on error errorText number errorNumber
            -- Some Terminal profiles close the window as soon as the shell exits.
            if errorNumber is -1728 or errorNumber is -1719 then
                if not (exists window id windowID) then return ""
                if (count tabs of window id windowID) is 0 then return ""
            end if
            error errorText number errorNumber
        end try
    end tell
    return ""
end run
'''


def terminal_script(source, *arguments):
    result = subprocess.run(
        ['/usr/bin/osascript', '-', *arguments], input=source,
        text=True, capture_output=True, timeout=15,
    )
    if result.returncode != 0:
        raise RuntimeError(f'Terminal AppleScript failed: {result.stderr.strip()}')
    return result.stdout.strip()


def interrupt_check(tty, launcher, owner_tag):
    """Interrupt the window's login group only while it owns this command."""
    result = subprocess.run(
        ['/bin/ps', '-axww', '-o', 'pid=,pgid=,tty=,command='],
        text=True, capture_output=True, check=True, timeout=5,
    )
    processes = [line.split(None, 3) for line in result.stdout.splitlines()]
    device = tty.removeprefix('/dev/')
    leaders = {pid for pid, group, terminal, _ in processes if pid == group and terminal == device}
    expected = f'/bin/zsh {launcher} {owner_tag}'
    for _, group, terminal, command in processes:
        if group in leaders and terminal == device and command == expected:
            try:
                os.killpg(int(group), signal.SIGINT)
            except ProcessLookupError:
                return False
            return True
    return False


def close_window(window_id, owned_tty, owner_tag, launcher):
    # The exit marker can arrive before the login shell leaves its PTY.
    started = time.monotonic()
    interrupted = False
    while True:
        tty = terminal_script(CLOSE_WINDOW, window_id, owned_tty, owner_tag)
        if not tty:
            return
        elapsed = time.monotonic() - started
        if elapsed >= 25:
            break
        if elapsed >= 1 and not interrupted:
            interrupted = interrupt_check(tty, launcher, owner_tag)
        time.sleep(0.1)
    raise RuntimeError(f'Terminal window {window_id} is still busy ({tty})')


def cancel(signum, _frame):
    raise SystemExit(128 + signum)


@contextmanager
def gui_session(name, script, arguments=(), extra_environment=None):
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR']).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    launcher = artifacts / f'{name}-gui.command'
    done = artifacts / f'{name}-gui.exit'
    output = artifacts / f'{name}-gui.log'
    pending = done.with_suffix('.writing')
    done.unlink(missing_ok=True)

    environment = {
        'TOASTTY_APP_BUNDLE': os.environ['TOASTTY_APP_BUNDLE'],
        'TOASTTY_ARTIFACTS_DIR': str(artifacts),
        **(extra_environment or {}),
    }
    command = ' '.join([
        'cd', shlex.quote(os.getcwd()), '&&',
        *(f'{key}={shlex.quote(str(value))}' for key, value in environment.items()),
        shlex.join(['python3', str(Path(script).resolve()), *arguments]),
        '>', shlex.quote(str(output)), '2>&1',
    ])
    launcher.write_text(
        # Let the Python check handle SIGINT and run its finally blocks.
        # The shell should still record the exit code after the child returns.
        "trap ':' INT\n"
        f'{command}\n'
        'exit_code=$?\n'
        f'printf "%s\\n" "$exit_code" > {shlex.quote(str(pending))}\n'
        f'/bin/mv -f {shlex.quote(str(pending))} {shlex.quote(str(done))}\n'
        'exit "$exit_code"\n'
    )
    # Terminal types into a login shell that may still be starting up. Send a
    # short command so the input buffer cannot drop a long argument list.
    owner_tag = f'Toastty validation {uuid.uuid4().hex}'
    window_id, owned_tty = terminal_script(OPEN_WINDOW, owner_tag).split('|', 1)
    previous_handler = signal.signal(signal.SIGTERM, cancel)
    try:
        terminal_script(START_CHECK, window_id, owned_tty,
                        'exec ' + shlex.join(['/bin/zsh', str(launcher), owner_tag]))
        yield done, output
    finally:
        try:
            close_window(window_id, owned_tty, owner_tag, launcher)
        finally:
            signal.signal(signal.SIGTERM, previous_handler)
