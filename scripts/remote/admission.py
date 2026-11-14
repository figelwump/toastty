#!/usr/bin/env python3
"""Bound remote workers independently from the shared macOS desktop.

An open flock lease, inherited by the command, proves a request is alive.
An owner-created release marker keeps ambiguous GUI cleanup fail-closed even
after the lease closes. No command arguments or environment are persisted.
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


def write_request(fd: int, value: dict) -> None:
    payload = json.dumps(value).encode()
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, payload)


def contained(root: Path, value: str | None) -> Path | None:
    if not value:
        return None
    path = Path(value).resolve()
    if not path.is_relative_to(root) or path == root:
        raise ValueError("report and release marker must be inside the remote validation root")
    return path


def inventory(state: Path) -> list[dict]:
    result = []
    for path in sorted((state / "requests").glob("*.json")):
        fd = safe_open(path, os.O_RDWR)
        try:
            alive = True
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                alive = False
            except BlockingIOError:
                pass
            value = json.loads(os.read(fd, 65536))
            if (value.get("id") != path.stem or value.get("resource") not in ("compute", "desktop")
                    or value.get("state") not in ("waiting", "running", "blocked")
                    or not isinstance(value.get("queuedAt"), (int, float))):
                raise ValueError(f"invalid admission request: {path}")
            marker = contained(state.parent, value.get("releaseMarker"))
            if not alive:
                if marker is None or not marker.exists():
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
        value = {k: row[k] for k in ("id", "label", "resource", "pid", "queuedAt", "startedAt", "releaseMarker", "unmanaged") if k in row}
        value["elapsedSeconds"] = None if row.get("unmanaged") else round(max(0, now - row.get("startedAt", row["queuedAt"])), 2)
        if row["state"] == "waiting":
            value["queuePosition"] = len(result["waiting"]) + 1
        result[row["state"]].append(value)
    return result


def eligible(rows: list[dict], own_id: str) -> bool:
    active = [r for r in rows if r["state"] in ("running", "blocked")]
    slots = WORKERS - len(active)
    desktop = not any(r["resource"] == "desktop" for r in active)
    # Earlier feasible work reserves the next available slot, while a waiting
    # desktop never prevents compute work from using otherwise free capacity.
    for row in rows:
        if row["state"] != "waiting" or slots <= 0:
            continue
        if row["resource"] == "desktop" and not desktop:
            continue
        if row["id"] == own_id:
            return True
        slots -= 1
        if row["resource"] == "desktop":
            desktop = False
    return False


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
    for value in (args.timeout, args.runtime_timeout):
        if not math.isfinite(value) or value < 0:
            raise ValueError("timeouts must be finite, nonnegative seconds")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise ValueError("a command is required")
    directory(state)
    directory(state / "requests")
    request_id = uuid.uuid4().hex
    path = state / "requests" / f"{request_id}.json"
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
            fd = safe_open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR)
            fcntl.flock(fd, fcntl.LOCK_EX)
            write_request(fd, row)
        next_log = 0
        while True:
            with guard(state):
                rows = inventory(state)
                rows += legacy_activity(root, rows)
                if eligible(rows, request_id):
                    row.update(state="running", startedAt=time.time(), queueSeconds=time.monotonic() - begun)
                    write_request(fd, row)
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
            time.sleep(min(0.2, args.timeout - elapsed))
        print(f"[admission] {args.label} admitted as {args.resource} after {row['queueSeconds']:.2f}s", file=sys.stderr, flush=True)
        child = subprocess.Popen(command, pass_fds=(fd,), start_new_session=True)
        rc = child.wait(timeout=args.runtime_timeout or None)
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
    finally:
        if fd is not None:
            with guard(state):
                if marker is not None and marker.exists():
                    row["state"] = "blocked"
                    write_request(fd, row)
                    rc = rc or 78
                    print(f"[admission] GUI cleanup unconfirmed; reservation retained: {marker}", file=sys.stderr)
                # Close our copy before checking for a surviving command's copy.
                # Unlinking first would hide an inherited lease held by a child
                # that survived its wrapper, allowing a conflicting admission.
                os.close(fd)
                probe = safe_open(path, os.O_RDWR)
                try:
                    try:
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        if row["state"] != "blocked":
                            path.unlink()
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
    run.add_argument("--release-marker")
    run.add_argument("--report")
    run.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = Path(args.root).resolve(strict=True)
    state = root / ".admission"
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
                fcntl.flock(fd, fcntl.LOCK_SH)
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
