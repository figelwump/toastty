#!/usr/bin/env python3
"""Bound remote workers independently from the shared macOS desktop.

An open flock lease, inherited by the command, proves a request is alive.
An owner-created release marker keeps ambiguous GUI cleanup fail-closed even
after the lease closes. No command arguments or environment are persisted.

A run can be detached from its SSH session (`detach`); `follow` streams its
output and can reconnect after the session closes, and `cancel` stops it on
purpose. A waiting run that nobody follows gives up after an orphan timeout.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
import uuid

WORKERS = 2
# A blocked desktop reservation is released only after this settle time, and
# only when no process refers to the run's folders.
REAP_GRACE_SECONDS = 120
ABANDONED_EXIT = 76
# The root as the caller wrote it. Command lines use this spelling, which can
# differ from the resolved path when the root contains a symbolic link.
ROOT_ARGUMENT: str | None = None
NOT_DETACHED_EXIT = 69


def safe_open(path: Path, flags: int) -> int:
    fd = os.open(path, flags | os.O_NOFOLLOW, 0o600)
    mode = os.fstat(fd)
    if not stat.S_ISREG(mode.st_mode) or mode.st_uid != os.getuid() or mode.st_mode & 0o022:
        os.close(fd)
        raise ValueError(f"unsafe admission file: {path}")
    return fd


def directory(path: Path) -> None:
    path.mkdir(mode=0o700, exist_ok=True)
    mode = path.lstat()
    if not stat.S_ISDIR(mode.st_mode) or mode.st_uid != os.getuid() or mode.st_mode & 0o022:
        raise ValueError(f"unsafe admission directory: {path}")


@contextlib.contextmanager
def guard(state: Path):
    fd = safe_open(state / "state.lock", os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def write_request(path: Path, value: dict) -> None:
    # Metadata is published atomically; the lease has a separate stable inode.
    # Killing a writer cannot expose an empty or half-written request to readers.
    temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    fd = safe_open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def contained(root: Path, value: str | None) -> Path | None:
    if not value:
        return None
    path = Path(value).resolve()
    if not path.is_relative_to(root) or path == root:
        raise ValueError("report and release marker must be inside the remote validation root")
    return path


def paths_in_use(paths: list[Path]) -> bool:
    """Whether a live process command line refers to one of these folders.

    The wrappers confirm their own cleanup with the same rule. A failed
    process inventory counts as in use: unknown ownership is not idle.
    """
    try:
        output = subprocess.run(["ps", "-axww", "-o", "pid=,command="],
                                check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return True
    own = os.getpid()
    spellings = [str(path) for path in paths]
    if ROOT_ARGUMENT:
        raw = os.path.abspath(ROOT_ARGUMENT)
        resolved = str(Path(ROOT_ARGUMENT).resolve())
        if raw != resolved:
            spellings += [raw + text[len(resolved):] for text in spellings if text.startswith(resolved + "/")]
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit() or int(fields[0]) == own:
            continue
        for text in spellings:
            if re.search(re.escape(text) + r"(?:/|\s|$)", fields[1]):
                return True
    return False


def release_dead_reservation(root: Path, path: Path, value: dict, marker: Path) -> bool:
    """Free a desktop kept only by a leftover marker of a run that has ended.

    The lease is already closed, so neither the supervisor nor a command that
    inherited the lease is alive. Release needs a settle time and no process
    that refers to the run folder or its worktree. A run that owns a simulator
    clone stays blocked for a person to inspect.
    """
    blocked_at = value.get("blockedAt")
    if not isinstance(blocked_at, (int, float)):
        blocked_at = path.stat().st_mtime
    if time.time() - blocked_at < REAP_GRACE_SECONDS:
        return False
    run_dir = marker.parent
    if run_dir == root or (run_dir / "simulator-ownership.json").exists():
        return False
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", str(value.get("label", ""))):
        return False
    if paths_in_use([run_dir, root / "worktrees" / value["label"]]):
        return False
    note = {"releasedAt": time.time(), "requestId": value["id"], "label": value["label"],
            "reason": "lease closed and no process refers to the run folder or worktree"}
    temporary = run_dir / f"DESKTOP_RELEASED.tmp-{uuid.uuid4().hex}"
    temporary.write_text(json.dumps(note, indent=2) + "\n")
    temporary.replace(run_dir / "DESKTOP_RELEASED")
    marker.unlink(missing_ok=True)
    path.unlink(missing_ok=True)
    path.with_suffix(".lease").unlink(missing_ok=True)
    print(f"[admission] released the desktop kept by ended run {value['label']}", file=sys.stderr, flush=True)
    return True


def inventory(state: Path, reap: bool = False) -> list[dict]:
    result = []
    for path in sorted((state / "requests").glob("*.json")):
        fd = safe_open(path.with_suffix(".lease"), os.O_RDWR)
        try:
            alive = True
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                alive = False
            except BlockingIOError:
                pass
            metadata_fd = safe_open(path, os.O_RDONLY)
            try:
                value = json.loads(os.read(metadata_fd, 65536))
            finally:
                os.close(metadata_fd)
            if (value.get("id") != path.stem or value.get("resource") not in ("compute", "desktop")
                    or value.get("state") not in ("waiting", "running", "blocked")
                    or not isinstance(value.get("queuedAt"), (int, float))):
                raise ValueError(f"invalid admission request: {path}")
            marker = contained(state.parent, value.get("releaseMarker"))
            if not alive:
                if marker is None or not marker.exists():
                    continue
                if reap and release_dead_reservation(state.parent, path, value, marker):
                    continue
                value["state"] = "blocked"
            result.append(value)
        finally:
            os.close(fd)
    return sorted(result, key=lambda row: (row["queuedAt"], row["id"]))


def legacy_activity(root: Path, managed: list[dict]) -> list[dict]:
    """Retain capacity for older wrappers until their run-owned native jobs exit.

    This migration check only recognizes native executables whose command names
    or DerivedData arguments reference this validation root. It never kills or
    adopts those jobs and cannot discover arbitrary jobs outside that root.
    """
    output = subprocess.run(["ps", "-axww", "-o", "pid=,command="],
                            check=True, capture_output=True, text=True).stdout
    labels = {r["label"] for r in managed}
    paths = re.compile(re.escape(str(root)) + r"/(?:test-runs|runs|worktrees)/([^/\s]+)/")
    jobs = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        pid, command = fields
        native = re.match(r"^/Applications/.*?/usr/bin/xcodebuild(?:\s|$)", command)
        native = native or re.match(re.escape(str(root)) + r"/.*?\.app/Contents/MacOS/Toastty(?:\s|$)", command)
        if not native:
            continue
        match = paths.search(command)
        if match and match[1] not in labels:
            label = match[1]
            jobs[label] = {"id": f"legacy-{pid}", "label": label, "pid": int(pid),
                           "resource": "desktop", "state": "running", "queuedAt": time.time(),
                           "unmanaged": True}
    return list(jobs.values())


def snapshot(rows: list[dict]) -> dict:
    now = time.time()
    result = {"workerLimit": WORKERS, "desktopLimit": 1, "running": [], "waiting": [], "blocked": []}
    for row in rows:
        value = {k: row[k] for k in ("id", "label", "resource", "phase", "pid", "queuedAt", "startedAt", "releaseMarker", "unmanaged") if k in row}
        value["elapsedSeconds"] = None if row.get("unmanaged") else round(max(0, now - row.get("startedAt", row["queuedAt"])), 2)
        if row["state"] == "waiting":
            value["queuePosition"] = len(result["waiting"]) + 1
        result[row["state"]].append(value)
    return result


def eligible(rows: list[dict], own_id: str) -> bool:
    active = [r for r in rows if r["state"] in ("running", "blocked")]
    slots = WORKERS - len(active)
    desktop = not any(r["resource"] == "desktop" for r in active)
    # Earlier feasible work reserves the next available slot. While the
    # desktop is free and desktop work waits, compute work leaves the last
    # free slot to that desktop work: otherwise long compute runs can hold
    # every slot and keep the desktop idle.
    desktop_waiting = desktop and any(r["state"] == "waiting" and r["resource"] == "desktop" for r in rows)
    for row in rows:
        if row["state"] != "waiting" or slots <= 0:
            continue
        if row["resource"] == "desktop":
            if not desktop:
                continue
        elif desktop_waiting and slots <= 1:
            continue
        if row["id"] == own_id:
            return True
        slots -= 1
        if row["resource"] == "desktop":
            desktop = False
            desktop_waiting = False
    return False


def read_request(path: Path) -> dict:
    fd = safe_open(path, os.O_RDONLY)
    try:
        return json.loads(os.read(fd, 65536))
    finally:
        os.close(fd)


def process_start(pid: int) -> str | None:
    """Start time of a process, to tell it from a later process with its PID."""
    try:
        output = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                                capture_output=True, text=True).stdout.strip()
    except OSError:
        return None
    return output or None


def followed(run_dir: Path) -> bool:
    """Whether a `follow` process holds this run's follower lock now."""
    lock = run_dir / "follower.lock"
    if not lock.exists():
        return False
    fd = safe_open(lock, os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)


class OrphanCheck:
    """Gives up waiting when a detached run has had no follower for too long.

    Only a detached run (TOASTTY_DETACHED_DIR) is checked. A run that already
    runs is never stopped for this; its evidence stays for a later follower.
    """

    def __init__(self, root: Path, limit: float):
        value = os.environ.get("TOASTTY_DETACHED_DIR")
        self.run_dir = contained(root, value) if value else None
        self.limit = limit
        self.since = None

    def abandoned(self) -> bool:
        if self.run_dir is None:
            return False
        if followed(self.run_dir):
            self.since = None
            return False
        now = time.monotonic()
        self.since = self.since if self.since is not None else now
        return now - self.since >= self.limit


class Interrupted(Exception):
    def __init__(self, number):
        self.number = number


def interrupt(number, _frame):
    raise Interrupted(number)


def stop(child: subprocess.Popen) -> None:
    # Own process group only. Allow the wrapper's existing cleanup traps to run.
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=30)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()


def execute(args, root: Path, state: Path) -> int:
    marker = contained(root, args.release_marker)
    report = contained(root, args.report)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", args.label):
        raise ValueError("invalid run label")
    for value in (args.timeout, args.runtime_timeout, args.orphan_timeout):
        if not math.isfinite(value) or value < 0:
            raise ValueError("timeouts must be finite, nonnegative seconds")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise ValueError("a command is required")
    directory(state)
    directory(state / "requests")
    request_id = uuid.uuid4().hex
    path = state / "requests" / f"{request_id}.json"
    lease = path.with_suffix(".lease")
    row = {"id": request_id, "label": args.label, "resource": args.resource,
           "pid": os.getpid(), "queuedAt": time.time(), "state": "waiting"}
    if marker:
        row["releaseMarker"] = str(marker)
    fd = None
    child = None
    rc = 1
    begun = time.monotonic()
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, interrupt)
    try:
        with guard(state):
            fd = safe_open(lease, os.O_CREAT | os.O_EXCL | os.O_RDWR)
            fcntl.flock(fd, fcntl.LOCK_EX)
            write_request(path, row)
        next_log = 0
        orphan = OrphanCheck(root, args.orphan_timeout)
        while True:
            with guard(state):
                rows = inventory(state, reap=True)
                rows += legacy_activity(root, rows)
                if eligible(rows, request_id):
                    row.update(state="running", startedAt=time.time(), queueSeconds=time.monotonic() - begun)
                    write_request(path, row)
                    break
                if time.monotonic() >= next_log:
                    owners = ", ".join(r["label"] for r in rows if r["state"] != "waiting")
                    print(f"[admission] {args.label} waiting for {args.resource}; owners: {owners or 'earlier waiting work'}", file=sys.stderr, flush=True)
                    next_log = time.monotonic() + 15
            elapsed = time.monotonic() - begun
            if elapsed >= args.timeout:
                print(f"[admission] queue timeout after {elapsed:.1f}s; no command started", file=sys.stderr)
                rc = 75
                return rc
            if orphan.abandoned():
                print(f"[admission] nobody followed this detached run for {args.orphan_timeout:.0f}s; no command started", file=sys.stderr)
                rc = ABANDONED_EXIT
                return rc
            time.sleep(min(1, args.timeout - elapsed))
        print(f"[admission] {args.label} admitted as {args.resource} after {row['queueSeconds']:.2f}s", file=sys.stderr, flush=True)
        environment = dict(os.environ, TOASTTY_ADMISSION_SUPERVISOR_PID=str(os.getpid()),
                           TOASTTY_ADMISSION_REQUEST_ID=request_id,
                           TOASTTY_ADMISSION_ROOT=str(root),
                           TOASTTY_ADMISSION_QUEUE_TIMEOUT=str(args.timeout),
                           TOASTTY_ADMISSION_ORPHAN_TIMEOUT=str(args.orphan_timeout))
        child = subprocess.Popen(command, pass_fds=(fd,), start_new_session=True, env=environment)
        running_since = time.monotonic()
        while True:
            remaining = args.runtime_timeout - (time.monotonic() - running_since) if args.runtime_timeout else 5
            try:
                rc = child.wait(timeout=max(0, min(5, remaining)))
                break
            except subprocess.TimeoutExpired:
                if args.runtime_timeout and time.monotonic() - running_since >= args.runtime_timeout:
                    raise
                # Non-PTY SSH does not guarantee HUP on disconnect. A periodic
                # write detects the closed SSH channel even during a quiet build.
                print(f"[admission] {args.label} running ({args.resource})", file=sys.stderr, flush=True)
        rc = rc if rc >= 0 else 128 - rc
    except subprocess.TimeoutExpired:
        stop(child)
        rc = 124
    except Interrupted as error:
        # Do not let a second signal interrupt owned-process cleanup.
        for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        if child is not None:
            stop(child)
        rc = 128 + error.number
    except BrokenPipeError:
        with open(os.devnull, "w") as sink:
            os.dup2(sink.fileno(), sys.stderr.fileno())
        if child is not None:
            stop(child)
        rc = 141
    finally:
        if fd is not None:
            with guard(state):
                # The command can move the request to the desktop after its
                # build (acquire-desktop). Keep those fields in the report.
                with contextlib.suppress(OSError, ValueError):
                    current = read_request(path)
                    row.update({k: current[k] for k in ("resource", "phase", "buildSeconds", "desktopQueuedAt",
                                                        "desktopStartedAt", "desktopQueueSeconds") if k in current})
                if marker is not None and marker.exists():
                    row.update(state="blocked", blockedAt=time.time())
                    write_request(path, row)
                    rc = rc or 78
                    print(f"[admission] GUI cleanup unconfirmed; reservation retained: {marker}", file=sys.stderr)
                # Close our copy before checking for a surviving command's copy.
                # Unlinking first would hide an inherited lease held by a child
                # that survived its wrapper, allowing a conflicting admission.
                os.close(fd)
                probe = safe_open(lease, os.O_RDWR)
                try:
                    try:
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        if row["state"] != "blocked":
                            path.unlink()
                            lease.unlink()
                            row["state"] = "finished"
                    except BlockingIOError:
                        rc = rc or 78
                        print("[admission] surviving command retains its worker lease", file=sys.stderr)
                finally:
                    os.close(probe)
        if report is not None:
            row.update(exitCode=rc, endedAt=time.time())
            temporary = report.with_name(report.name + f".tmp-{request_id}")
            temporary.write_text(json.dumps(row, indent=2) + "\n")
            temporary.replace(report)
    return rc


def acquire_desktop(root: Path, state: Path) -> int:
    """Move the caller's admitted compute request to the desktop.

    A desktop run builds as compute work, then calls this before its first
    GUI step. The worker slot is released while it waits; the request keeps
    its first queue time, so it comes before work queued after it.
    """
    request_id = os.environ.get("TOASTTY_ADMISSION_REQUEST_ID", "")
    if not re.fullmatch(r"[0-9a-f]{32}", request_id):
        raise ValueError("acquire-desktop must run inside an admitted command")
    timeout = float(os.environ.get("TOASTTY_ADMISSION_QUEUE_TIMEOUT", "3600"))
    orphan = OrphanCheck(root, float(os.environ.get("TOASTTY_ADMISSION_ORPHAN_TIMEOUT", "900")))
    path = state / "requests" / f"{request_id}.json"
    with guard(state):
        row = read_request(path)
        if row.get("resource") == "desktop" and row.get("state") == "running":
            return 0
        now = time.time()
        row.update(resource="desktop", phase="desktop", state="waiting", desktopQueuedAt=now,
                   buildSeconds=round(now - row.get("startedAt", now), 2))
        write_request(path, row)
    begun = time.monotonic()
    next_log = 0
    while True:
        with guard(state):
            rows = inventory(state, reap=True)
            rows += legacy_activity(root, rows)
            if eligible(rows, request_id):
                row.update(state="running", desktopStartedAt=time.time(),
                           desktopQueueSeconds=round(time.monotonic() - begun, 2))
                write_request(path, row)
                break
            if time.monotonic() >= next_log:
                owners = ", ".join(r["label"] for r in rows if r["state"] != "waiting")
                print(f"[admission] {row['label']} built; waiting for desktop; owners: {owners or 'earlier waiting work'}", file=sys.stderr, flush=True)
                next_log = time.monotonic() + 15
        elapsed = time.monotonic() - begun
        if elapsed >= timeout:
            print(f"[admission] desktop queue timeout after {elapsed:.1f}s", file=sys.stderr)
            return 75
        if orphan.abandoned():
            print("[admission] nobody followed this detached run; gave up waiting for the desktop", file=sys.stderr)
            return ABANDONED_EXIT
        time.sleep(min(1, timeout - elapsed))
    print(f"[admission] {row['label']} admitted to the desktop after {row['desktopQueueSeconds']:.2f}s", file=sys.stderr, flush=True)
    return 0


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    fd = safe_open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    with os.fdopen(fd, "w") as output:
        json.dump(value, output)
    temporary.replace(path)


def run_directory(root: Path, value: str) -> Path:
    run_dir = contained(root, value)
    mode = run_dir.lstat()
    if not stat.S_ISDIR(mode.st_mode) or mode.st_uid != os.getuid():
        raise ValueError(f"unsafe run directory: {run_dir}")
    return run_dir


def keeper_alive(record: dict) -> bool:
    pid = record.get("pid")
    return isinstance(pid, int) and pid > 1 and record.get("start") is not None and process_start(pid) == record["start"]


def detach(args, root: Path) -> int:
    """Start a command that outlives the caller's SSH session.

    A keeper process in its own session runs the command with output in the
    run directory and records the exit status when the command ends. The
    keeper ignores signals so that a TERM to its process group reaches the
    command and the keeper still records the result.
    """
    run_dir = run_directory(root, args.dir)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise ValueError("a command is required")
    out = safe_open(run_dir / "detached.stdout", os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_APPEND)
    err = safe_open(run_dir / "detached.stderr", os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_APPEND)
    ready_read, ready_write = os.pipe()
    pid = os.fork()
    if pid == 0:
        code = 70
        try:
            os.close(ready_read)
            os.setsid()
            null = os.open(os.devnull, os.O_RDONLY)
            os.dup2(null, 0)
            os.dup2(out, 1)
            os.dup2(err, 2)
            for fd in (null, out, err):
                os.close(fd)
            for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                # A Python handler, not SIG_IGN: exec resets it to the default,
                # so the command still receives these signals.
                signal.signal(number, lambda *_: None)
            child = subprocess.Popen(command, env=dict(os.environ, TOASTTY_DETACHED_DIR=str(run_dir)))
            write_json(run_dir / "detached.json", {"pid": os.getpid(), "start": process_start(os.getpid()),
                                                   "childPid": child.pid, "startedAt": time.time()})
            os.write(ready_write, b"1")
            os.close(ready_write)
            rc = child.wait()
            rc = rc if rc >= 0 else 128 - rc
            write_json(run_dir / "detached-exit.json", {"exitCode": rc, "endedAt": time.time()})
            code = 0
        finally:
            os._exit(code)
    os.close(ready_write)
    os.close(out)
    os.close(err)
    started = os.read(ready_read, 1) == b"1"
    os.close(ready_read)
    if not started:
        print("[admission] detached run did not start", file=sys.stderr)
        return 70
    return 0


def follow(args, root: Path) -> int:
    """Stream a detached run's output from the start and return its exit code."""
    run_dir = run_directory(root, args.dir)
    record_path = run_dir / "detached.json"
    if not record_path.exists():
        print(f"[admission] no detached run in {run_dir}", file=sys.stderr)
        return NOT_DETACHED_EXIT
    record = read_request(record_path)
    lock = safe_open(run_dir / "follower.lock", os.O_CREAT | os.O_RDWR)
    deadline = time.monotonic() + args.lock_timeout
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                print("[admission] another session still follows this run", file=sys.stderr)
                return NOT_DETACHED_EXIT
            time.sleep(0.2)
    streams = [(safe_open(run_dir / "detached.stdout", os.O_RDONLY), sys.stdout.buffer),
               (safe_open(run_dir / "detached.stderr", os.O_RDONLY), sys.stderr.buffer)]

    def pump() -> bool:
        moved = False
        for source, sink in streams:
            while chunk := os.read(source, 65536):
                sink.write(chunk)
                sink.flush()
                moved = True
        return moved

    exit_path = run_dir / "detached-exit.json"
    try:
        while True:
            moved = pump()
            if exit_path.exists():
                pump()
                return int(read_request(exit_path)["exitCode"])
            if not moved and not keeper_alive(record):
                if exit_path.exists():
                    continue
                print("[admission] detached run ended without an exit status", file=sys.stderr)
                return 70
            time.sleep(0.2)
    except BrokenPipeError:
        with open(os.devnull, "w") as sink:
            os.dup2(sink.fileno(), sys.stdout.fileno())
            os.dup2(sink.fileno(), sys.stderr.fileno())
        return 141


def probe(args, root: Path) -> int:
    """Read-only state of a detached run, for a wrapper deciding to reattach."""
    value = {"detached": False}
    run_dir = contained(root, args.dir)
    record_path = run_dir / "detached.json"
    if run_dir.is_dir() and record_path.exists():
        record = read_request(record_path)
        exit_path = run_dir / "detached-exit.json"
        value = {"detached": True, "finished": exit_path.exists(), "running": keeper_alive(record),
                 "followed": followed(run_dir)}
        if value["finished"]:
            value["exitCode"] = read_request(exit_path).get("exitCode")
    print(json.dumps(value))
    return 0


def cancel(args, root: Path) -> int:
    """Stop a detached run on purpose. Its own cleanup still runs."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", args.label):
        raise ValueError("invalid run label")
    for parent in ("test-runs", "runs"):
        run_dir = root / parent / args.label
        record_path = run_dir / "detached.json"
        if not record_path.exists():
            continue
        record = read_request(record_path)
        if (run_dir / "detached-exit.json").exists() or not keeper_alive(record):
            print(f"[admission] {args.label} has already ended")
            return 0
        os.killpg(record["pid"], signal.SIGTERM)
        print(f"[admission] asked {args.label} to stop; its cleanup runs before it ends")
        return 0
    print(f"[admission] no detached run named {args.label}", file=sys.stderr)
    return NOT_DETACHED_EXIT


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    status = sub.add_parser("status")
    status.add_argument("--root", required=True)
    run = sub.add_parser("run")
    run.add_argument("--root", required=True)
    run.add_argument("--label", required=True)
    run.add_argument("--resource", choices=("compute", "desktop"), required=True)
    run.add_argument("--timeout", type=float, default=3600)
    run.add_argument("--runtime-timeout", type=float, default=0)
    run.add_argument("--orphan-timeout", type=float, default=900)
    run.add_argument("--release-marker")
    run.add_argument("--report")
    run.add_argument("command", nargs=argparse.REMAINDER)
    acquire = sub.add_parser("acquire-desktop")
    acquire.add_argument("--root", required=True)
    detached = sub.add_parser("detach")
    detached.add_argument("--root", required=True)
    detached.add_argument("--dir", required=True)
    detached.add_argument("command", nargs=argparse.REMAINDER)
    following = sub.add_parser("follow")
    following.add_argument("--root", required=True)
    following.add_argument("--dir", required=True)
    following.add_argument("--lock-timeout", type=float, default=30)
    probing = sub.add_parser("probe")
    probing.add_argument("--root", required=True)
    probing.add_argument("--dir", required=True)
    cancelling = sub.add_parser("cancel")
    cancelling.add_argument("--root", required=True)
    cancelling.add_argument("--label", required=True)
    args = parser.parse_args()
    global ROOT_ARGUMENT
    ROOT_ARGUMENT = args.root
    root = Path(args.root).resolve(strict=True)
    state = root / ".admission"
    if args.action == "acquire-desktop":
        return acquire_desktop(root, state)
    if args.action == "detach":
        return detach(args, root)
    if args.action == "follow":
        return follow(args, root)
    if args.action == "probe":
        return probe(args, root)
    if args.action == "cancel":
        return cancel(args, root)
    if args.action == "status":
        if state.exists() or state.is_symlink():
            # Status must not create state, directories, or a lock file.
            # The first writer creates directories before publishing its lock.
            if not (state / "state.lock").exists():
                value = snapshot(legacy_activity(root, []))
                value["initializing"] = True
                print(json.dumps(value, indent=2))
                return 0
            fd = safe_open(state / "state.lock", os.O_RDONLY)
            try:
                # Serialize lease probes too: concurrent shared-lock readers
                # could otherwise mistake each other's probe for a live owner.
                fcntl.flock(fd, fcntl.LOCK_EX)
                rows = inventory(state)
                value = snapshot(rows + legacy_activity(root, rows))
            finally:
                os.close(fd)
        else:
            value = snapshot(legacy_activity(root, []))
        print(json.dumps(value, indent=2))
        return 0
    return execute(args, root, state)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"[admission] {error}", file=sys.stderr)
        sys.exit(78)
