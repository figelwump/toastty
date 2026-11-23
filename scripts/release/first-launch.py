#!/usr/bin/env python3
"""Check the app inside one release DMG on an admitted macOS desktop."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


EXCEPTIONS = (
    "NSInternalInconsistencyException",
    "Update Constraints in Window",
    "uncaught exception",
)
EXCEPTION_PATTERN = re.compile("|".join(map(re.escape, EXCEPTIONS)), re.IGNORECASE)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open("rb") as image:
        for chunk in iter(lambda: image.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def read_json(path):
    return json.loads(path.read_text())


def confirmed_cleanup(root):
    admission = read_json(root / "evidence/admission.json")
    require(admission["state"] == "finished" and not (root / "desktop-active").exists(),
            f"Desktop cleanup is unconfirmed. Retaining {root}")
    require(not os.path.ismount(root / "image"), f"DMG is still mounted. Retaining {root}")


def verify(dmg, commit, evidence, sparkle_digest=None, sparkle_length=None):
    result = read_json(evidence / "result.json")
    admission = read_json(evidence / "admission.json")
    require(admission["state"] == "finished" and admission["exitCode"] == 0
            and admission["resource"] == "desktop" and result["status"] == "pass",
            "Candidate has no successful desktop first-launch check")
    actual_digest = digest(dmg)
    require(result["sourceCommit"] == commit and result["dmgSHA256"] == actual_digest,
            "First-launch evidence does not match the candidate DMG and source commit")
    if sparkle_digest is not None:
        require(sparkle_digest == actual_digest and int(sparkle_length) == Path(dmg).stat().st_size,
                "Sparkle metadata does not match the candidate DMG")


def run(*args, timeout=10, check=True):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=check)


def stop(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def preference_suite(runtime):
    # Same path hash as ToasttyRuntimePaths.userDefaultsSuiteName. Derive it
    # here so a crash before instance.json still gets its own suite cleaned up.
    hashed = 0xcbf29ce484222325
    for byte in os.fsencode(runtime):
        hashed = ((hashed ^ byte) * 0x100000001b3) & 0xffffffffffffffff
    return f"com.GiantThings.toastty.runtime.{hashed:016x}"


def preference_file(suite):
    return Path.home() / "Library/Preferences" / f"{suite}.plist"


def clear_preferences(suite):
    # cfprefsd can write suites to the login account even with a separate HOME.
    result = run("/usr/bin/defaults", "delete", suite, check=False)
    require(result.returncode == 0 or f"Domain ({suite}) not found." in result.stderr,
            f"Could not remove disposable preferences {suite}: {result.stderr.strip()}")
    require(not preference_file(suite).exists(), f"Disposable preferences still exist: {suite}")
    print(f"Confirmed disposable preferences removed: {suite}", flush=True)


def check_process(root, bundle, isolated, evidence):
    runtime = root / "runtime-home"
    user_home = root / "user-home"
    socket = isolated / "app.sock"
    runtime.mkdir()
    user_home.mkdir()
    binary = bundle / "Contents/MacOS/Toastty"
    cli = bundle / "Contents/Helpers/toastty"
    require(binary.is_file() and cli.is_file(), "DMG is missing the app or bundled CLI")
    suite = preference_suite(runtime)
    require(not preference_file(suite).exists(), f"Disposable preferences already exist: {suite}")

    # Keep persistent app behavior, including the offer, within a new runtime
    # and preferences home. The quit-confirmation bypass also keeps Toastty
    # from starting Sparkle, without enabling the automation session.
    home = str(user_home)
    environment = dict(HOME=home, CFFIXED_USER_HOME=home, PATH="/usr/bin:/bin:/usr/sbin:/sbin",
                       TMPDIR=str(isolated), TOASTTY_RUNTIME_HOME=str(runtime),
                       TOASTTY_USER_SKILLS_ROOT=str(runtime / "skills"),
                       TOASTTY_SOCKET_PATH=str(socket), TOASTTY_LOG_STDERR="1",
                       TOASTTY_SKIP_QUIT_CONFIRMATION="1")
    started = time.strftime("%Y-%m-%d %H:%M:%S")
    marker = root / "desktop-active"
    with (evidence / "app.log").open("w") as log:
        app = None
        marker.touch(exist_ok=False)
        try:
            app = subprocess.Popen([binary], cwd=user_home, env=environment,
                                   stdout=log, stderr=subprocess.STDOUT)
            print(f"Launched candidate PID {app.pid}", flush=True)
            exercise(root / "ax-drive", app, binary, cli, runtime, socket, environment, evidence)
        finally:
            if app is not None:
                stop(app)
            # Keep admission's marker if process cleanup cannot be confirmed.
            marker.unlink()
            clear_preferences(suite)
            if app is not None:
                scan_exceptions(app.pid, started, evidence)
        require(app.returncode == -signal.SIGTERM, f"Candidate exited unexpectedly ({app.returncode})")


def scan_exceptions(pid, started, evidence):
    # Preserve stderr and matching unified log entries, including exceptions
    # that AppKit caught without terminating the app.
    predicate = " OR ".join(f'eventMessage CONTAINS[c] "{item}"' for item in EXCEPTIONS)
    unified = run("/usr/bin/log", "show", "--start", started, "--style", "json",
                  "--predicate", f"processID == {pid} AND ({predicate})", timeout=20)
    (evidence / "appkit.log").write_text(unified.stdout)
    for file, messages in (
        ("app.log", [(evidence / "app.log").read_text(errors="replace")]),
        ("appkit.log", [entry["eventMessage"] for entry in json.loads(unified.stdout)]),
    ):
        match = EXCEPTION_PATTERN.search("\n".join(messages))
        if match:
            raise RuntimeError(f"Candidate logged a startup exception in {file}: {match[0]}")


def exercise(driver, app, binary, cli, runtime, socket, environment, evidence):
    def alive():
        code = app.poll()
        require(code is None, f"Candidate exited unexpectedly ({code})")

    def wait_for(description, probe, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            alive()
            value = probe()
            if value:
                alive()
                return value
            time.sleep(0.25)
        raise RuntimeError(f"Timed out waiting for {description}")

    def ax(command, *args, check=True):
        return run(driver, str(app.pid), command, *args, timeout=8, check=check)

    instance_path = runtime / "instance.json"
    wait_for("the clean runtime instance record", instance_path.is_file, 15)
    instance = read_json(instance_path)
    require(instance["pid"] == app.pid
            and Path(instance["executablePath"]).resolve() == binary.resolve()
            and Path(instance["runtimeHomePath"]).resolve() == runtime
            and Path(instance["socketPath"]).resolve() == socket
            and instance["userDefaultsSuiteName"] == preference_suite(runtime),
            "Runtime record does not identify the candidate process and isolated paths")
    shutil.copyfile(instance_path, evidence / "instance.json")

    def sheet_text():
        output = ax("sheet-texts", check=False)
        require(output.returncode in (0, 2), f"Cannot read candidate sheet: {output.stderr}")
        return output.stdout if output.returncode == 0 else None

    frontmost = f"frontmost {app.pid}"
    wait_for("the candidate to become active", lambda: ax("activate").stdout.strip() == frontmost, 10)
    sheet = wait_for("the first-launch sheet", sheet_text, 20)
    (evidence / "sheet.txt").write_text(sheet)
    frame = ax("frame", "whats-new.sheet").stdout.strip()
    _, _, width, height = map(int, frame.split())
    require(width > 0 and height > 0, "The first-launch sheet has no visible frame")
    ax("frame", "whats-new.start")
    print(f"Found the first-launch sheet at {frame}", flush=True)
    # The accessibility tree is the assertion. Retain a picture when the
    # validation desktop also grants Screen Recording.
    try:
        capture = run("/usr/sbin/screencapture", "-x", "-R" + ",".join(frame.split()),
                      evidence / "sheet.png", check=False)
        if capture.returncode:
            print(f"Screenshot unavailable: {capture.stderr.strip()}", flush=True)
    except subprocess.TimeoutExpired:
        print("Screenshot timed out", flush=True)
    ax("press", "whats-new.not-now")
    wait_for("Not Now to dismiss the sheet", lambda: sheet_text() is None, 10)
    print("Dismissed the sheet with Not Now", flush=True)

    # Require a fresh main-actor query after dismissal. A live PID or an
    # Accessibility call that returns no sheet cannot establish responsiveness.
    alive()
    ax("window-frame")
    response = subprocess.run([cli, "--socket-path", socket, "query", "run", "workspace.list", "--json"],
                              env=environment, text=True, capture_output=True, timeout=8, check=True)
    (evidence / "workspace.json").write_text(response.stdout)
    workspace = json.loads(response.stdout)
    require(workspace["ok"] is True and workspace["result"]["workspaces"],
            "Candidate did not return a workspace after dismissal")
    alive()
    print("Candidate workspace responded after dismissal", flush=True)


def interrupted_mount(number, _frame):
    # Let the mount's finally block detach the image before exiting.
    signal.signal(number, signal.SIG_IGN)
    raise RuntimeError(f"Candidate DMG preparation was interrupted (signal {number})")


def extract_bundle(root, image, dmg):
    handlers = {number: signal.signal(number, interrupted_mount)
                for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
    try:
        image.mkdir()
        run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", image, dmg, timeout=45)
        bundle = root / "candidate/Toastty.app"
        bundle.parent.mkdir()
        run("/usr/bin/ditto", image / "Toastty.app", bundle, timeout=45)
        return bundle
    finally:
        try:
            if os.path.ismount(image):
                run("/usr/bin/hdiutil", "detach", image, timeout=20)
        finally:
            for number, handler in handlers.items():
                signal.signal(number, handler)


def check(root, commit, expected_digest):
    evidence = root / "evidence"
    image = root / "image"
    dmg = root / "candidate.dmg"
    admission = root / "admission.py"
    result = dict(status="fail", sourceCommit=commit, dmgSHA256=None)
    try:
        result["dmgSHA256"] = digest(dmg)
        require(result["dmgSHA256"] == expected_digest, "Candidate DMG changed during transfer")
        run("/usr/bin/xcrun", "swiftc", "-O", root / "ax-drive.swift",
            "-o", root / "ax-drive", timeout=120)
        bundle = extract_bundle(root, image, dmg)
        subprocess.run([sys.executable, admission, "acquire-desktop", "--root",
                        os.environ["TOASTTY_ADMISSION_ROOT"]], check=True)
        status = run(root / "ax-drive", str(os.getpid()), "status").stdout.strip()
        require(status == "trusted=true locked=false", f"Desktop is unavailable: {status}")
        wake = subprocess.Popen(["/usr/bin/caffeinate", "-dis", "-t", "180"])
        try:
            with tempfile.TemporaryDirectory(prefix="tt-rc-", dir="/private/tmp") as isolated:
                check_process(root, bundle, Path(isolated), evidence)
        finally:
            stop(wake)
        result["status"] = "pass"
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        result["error"] = str(error)
        if isinstance(error, subprocess.CalledProcessError):
            result["commandOutput"] = "\n".join(
                output.strip() for output in (error.stdout, error.stderr) if output)
        raise
    finally:
        (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")


def main():
    command, *args = sys.argv[1:]
    if command == "digest":
        print(digest(args[0]))
    elif command == "verify":
        verify(args[0], args[1], Path(args[2]), *args[3:])
    elif command == "check":
        check(Path(args[0]).resolve(), args[1], args[2])
    elif command == "cleanup":
        root = Path(args[0]).resolve()
        confirmed_cleanup(root)
        shutil.rmtree(root)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(f"error: {error}")
