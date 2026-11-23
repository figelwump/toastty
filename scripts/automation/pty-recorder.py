#!/usr/bin/env python3
"""Runs a command in its own pty and records every byte that the outer
terminal sends to it, with the time: the keys, pastes, mouse reports and
focus reports that the program receives. The program's output passes
through unchanged. Usage: pty-recorder.py LOG COMMAND...

While a file named LOG + '.drop-focus-in' exists, the recorder holds back
the report that the terminal has the focus again, for a check of a program
that never hears it.
"""
import fcntl
import json
import os
import select
import signal
import sys
import termios
import time
import tty

log_path, argv = sys.argv[1], sys.argv[2:]
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8))
pid = os.fork()
if pid == 0:
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for descriptor in (0, 1, 2):
        os.dup2(slave, descriptor)
    os.close(master)
    if slave > 2:
        os.close(slave)
    os.execvp(argv[0], argv)
os.close(slave)


def resize(*_):
    fcntl.ioctl(master, termios.TIOCSWINSZ, fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8))


signal.signal(signal.SIGWINCH, resize)
saved = termios.tcgetattr(0)
tty.setraw(0)
log = open(log_path, 'a', buffering=1)
try:
    while True:
        try:
            readable, _, _ = select.select([0, master], [], [])
        except InterruptedError:
            continue
        if 0 in readable:
            data = os.read(0, 65536)
            if not data:
                break
            dropped = None
            if os.path.exists(log_path + '.drop-focus-in') and b'\x1b[I' in data:
                # Probe: the program never learns that its terminal has the focus again.
                data, dropped = data.replace(b'\x1b[I', b''), 'focus-in'
            log.write(json.dumps(dict(at=time.time(), bytes=data.decode('latin-1'), dropped=dropped)) + '\n')
            while data:
                data = data[os.write(master, data):]
        if master in readable:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            while data:
                data = data[os.write(1, data):]
finally:
    termios.tcsetattr(0, termios.TCSADRAIN, saved)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status) if hasattr(os, 'waitstatus_to_exitcode') else status >> 8)
