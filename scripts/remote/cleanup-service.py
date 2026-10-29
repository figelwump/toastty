#!/usr/bin/env python3
"""Install and inspect the mini's guarded cleanup job; no credentials on host."""

from __future__ import annotations

import argparse
import base64
import contextlib
import datetime
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from typing import Iterator


LABEL = "com.giantthings.toastty.remote-cleanup"
INTERVAL = 4 * 60 * 60
LOW_SPACE = 30 * 1024**3
LOG_LIMIT = 1024**2
PREVIEW_TIMEOUT = 120
HOST_PATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
HOST_PYTHON = "/usr/bin/python3"
FILES = ("cleanup-service.py", "cleanup-remote-runs.sh", "cleanup-simulators.sh", "cleanup-simulator-app.sh")
PREFIXES = ("remote-run-cleanup", "remote-simulator-cleanup", "remote-simulator-app-cleanup")


def stamp() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def command(args: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30, **kwargs)


def host_environment() -> dict[str, str]:
    # Neither shell startup hooks nor Git redirection may change the target.
    # Disable detached Git helpers that could inherit the cleanup lock.
    return {"HOME": str(Path.home()), "PATH": HOST_PATH, "LANG": "C", "LC_ALL": "C", "TZ": "UTC",
            "GIT_CONFIG_COUNT": "3", "GIT_CONFIG_KEY_0": "gc.auto", "GIT_CONFIG_VALUE_0": "0",
            "GIT_CONFIG_KEY_1": "core.fsmonitor", "GIT_CONFIG_VALUE_1": "false",
            "GIT_CONFIG_KEY_2": "maintenance.auto", "GIT_CONFIG_VALUE_2": "false"}


def owned(path: Path, *, directory: bool = False) -> None:
    mode = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(mode.st_mode) or mode.st_uid != os.getuid() or mode.st_mode & 0o022:
        raise ValueError(f"unsafe ownership, permissions or file type: {path}")


def identity(repo: Path, root: Path) -> None:
    if not repo.is_absolute() or not root.is_absolute() or repo.resolve() != repo or root.resolve() != root:
        raise ValueError("repository and validation roots must be canonical absolute paths")
    if root == repo or repo in root.parents or root in repo.parents or len(root.parts) < 4:
        raise ValueError("validation root is too broad or inside the repository")
    for path in (repo, root, root / "test-runs", root / "worktrees"):
        owned(path, directory=True)
    if not (repo / "Project.swift").is_file() or not (repo / "scripts/remote/test.sh").is_file():
        raise ValueError("repository markers are missing")
    if command(["git", "-C", str(repo), "rev-parse", "--show-toplevel"], env=host_environment()).stdout.strip() != str(repo):
        raise ValueError("repository is not the git top level")


def service_path(root: Path) -> Path:
    return root / ".cleanup-service"


def plist_path() -> Path:
    return Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")


def domain() -> str:
    return f"gui/{os.getuid()}"


def launchctl(*args: str) -> subprocess.CompletedProcess:
    return command(["launchctl", *args])


def loaded() -> bool:
    try:
        launchctl("print", domain() + "/" + LABEL)
        return True
    except subprocess.CalledProcessError as error:
        if "Could not find service" in error.stderr:
            return False
        raise


def disabled() -> bool:
    output = launchctl("print-disabled", domain()).stdout
    return re.search(r'"' + re.escape(LABEL) + r'"\s*=>\s*(?:true|disabled)\b', output) is not None


def atomic_json(path: Path, value: dict) -> None:
    if path.exists() or path.is_symlink():
        owned(path)
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def config_at(root: Path) -> dict:
    service = service_path(root)
    owned(service, directory=True)
    owned(service / "config.json")
    config = json.loads((service / "config.json").read_text())
    if (config.get("schemaVersion") != 1 or config.get("label") != LABEL
            or config.get("root") != str(root) or not isinstance(config.get("enabled"), bool)
            or not re.fullmatch(r"[a-f0-9]{40}", config.get("revision", ""))):
        raise ValueError("invalid cleanup service configuration")
    identity(Path(config["repo"]), root)
    owned(service / "versions", directory=True)
    return config


def bundle_at(version: Path) -> dict:
    owned(version, directory=True)
    owned(version / "bundle.json")
    bundle = json.loads((version / "bundle.json").read_text())
    if (bundle.get("schemaVersion") != 1 or set(bundle.get("sha256", {})) != set(FILES)
            or not re.fullmatch(r"[a-f0-9]{40}", bundle.get("revision", ""))):
        raise ValueError("invalid cleanup bundle manifest")
    for name in FILES:
        owned(version / name)
        if hashlib.sha256((version / name).read_bytes()).hexdigest() != bundle["sha256"][name]:
            raise ValueError(f"cleanup bundle hash mismatch: {name}")
    return bundle


@contextlib.contextmanager
def service_lock(service: Path) -> Iterator[int]:
    # Keep this inode for the installation lifetime. A child inherits this exact
    # open file description, so a crashed supervisor cannot admit another run.
    path = service / "run.lock"
    owned(path)
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield fd
    finally:
        os.close(fd)


def record(service: Path, status: dict) -> None:
    # ENOSPC must not prevent the cleaner from reclaiming space.
    try:
        atomic_json(service / "status.json", status)
    except OSError as error:
        try:
            print(f"warning: could not write cleanup status: {error}", file=sys.stderr)
        except OSError:
            pass


def disk(root: Path) -> dict:
    try:
        usage = shutil.disk_usage(root)
        return {"freeBytes": usage.free, "totalBytes": usage.total}
    except OSError as error:
        return {"error": str(error)}


def job_plist(config: dict) -> dict:
    service = service_path(Path(config["root"]))
    script = service / "versions" / config["revision"] / FILES[0]
    return {"Label": LABEL, "ProgramArguments": [HOST_PYTHON, "-I", str(script),
            "--on-host", "run", "--root", config["root"]], "StartInterval": INTERVAL,
            "RunAtLoad": False, "EnvironmentVariables": {"PATH": HOST_PATH, "LANG": "C", "LC_ALL": "C", "TZ": "UTC"},
            "WorkingDirectory": str(service), "StandardOutPath": "/dev/null",
            "StandardErrorPath": str(service / "launchd-error.log")}


def cleaner_args(index: int, mode: str, config: dict, epoch: int) -> list[str]:
    repo, root = (base64.b64encode(config[key].encode()).decode() for key in ("repo", "root"))
    if index == 0:
        return [mode, str(epoch), "24", "30", repo, root, FILES[1]]
    if index == 1:
        return [mode, str(epoch), "24", repo, root]
    return [mode, repo, root, FILES[3]]


def summary(text: str, index: int, mode: str) -> dict:
    prefix = f"[{PREFIXES[index]}] mode={mode} "
    lines = [line for line in text.splitlines() if line.startswith(prefix)]
    if len(lines) != 1:
        raise ValueError("missing or ambiguous cleaner summary")
    fields = dict(re.findall(r"(\w+)=([^=]+?)(?=\s+\w+=|$)", lines[0]))
    for key in ("eligible", "retained", "manual_review", "terminated" if index == 2 else "deleted",
                "terminate_failures" if index == 2 else "delete_failures"):
        if not re.fullmatch(r"\d+", fields.get(key, "")):
            raise ValueError(f"invalid cleaner summary field: {key}")
        fields[key] = int(fields[key])
    return fields


def bounded_log(path: Path) -> str:
    owned(path)
    with path.open("rb+") as stream:
        length = stream.seek(0, os.SEEK_END)
        stream.seek(max(0, length - LOG_LIMIT))
        content = stream.read(LOG_LIMIT)
        if length > LOG_LIMIT:
            stream.seek(0)
            stream.write(content)
            stream.truncate()
    return content.decode("utf-8", errors="replace")


def execute_step(version: Path, service: Path, config: dict, status: dict,
                 index: int, mode: str, epoch: int, lock_fd: int) -> dict:
    path = service / f"{index}-{mode}.log"
    if path.exists() or path.is_symlink():
        owned(path)
    result = {"group": PREFIXES[index], "mode": mode, "log": str(path)}
    status["currentStep"] = result
    record(service, status)
    argv = ["/bin/bash", str(version / FILES[index + 1]), "--remote-exec",
            *cleaner_args(index, mode, config, epoch)]
    # No pipe: cleaners can finish safely after the supervisor exits. Detached
    # sessions also avoid launchd's default process-group cleanup on parent exit.
    try:
        # When the disk is completely full, logging must not stop reclamation.
        if disk(Path(config["root"])).get("freeBytes", LOG_LIMIT) < LOG_LIMIT:
            raise OSError("less than 1 MiB available for step logs")
        output = path.open("w")
    except OSError as error:
        output = open(os.devnull, "w")
        result["summaryError"] = f"step logging unavailable: {error}"
        result["log"] = None
    with output:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                                   start_new_session=True, pass_fds=(lock_fd,),
                                   env=host_environment())
        result["pid"] = process.pid
        record(service, status)
        try:
            result["exitCode"] = process.wait(timeout=PREVIEW_TIMEOUT if mode == "dry-run" else None)
        except subprocess.TimeoutExpired:
            # This process group was created for this read-only preview. Never
            # send a timeout signal to an apply or to a run's app/test process.
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            result.update(exitCode=124, error="read-only preview exceeded 120 seconds")
    if "summaryError" in result:
        return result
    try:
        result["summary"] = summary(bounded_log(path), index, mode)
    except (OSError, ValueError) as error:
        result["summaryError"] = str(error)
    return result


def run_service(root: Path) -> int:
    config = config_at(root)
    service = service_path(root)
    with service_lock(service) as lock_fd:
        config = config_at(root)
        if not config["enabled"]:
            raise ValueError("cleanup service is disabled")
        version = service / "versions" / config["revision"]
        bundle = bundle_at(version)
        if Path(__file__).resolve().parent != version.resolve():
            raise ValueError("running supervisor does not match installed revision")
        if bundle["revision"] != config["revision"]:
            raise ValueError("configured revision does not match installed bundle")
        previous = service / "status.json"
        last_completed = None
        warnings = []
        if previous.exists():
            owned(previous)
            try:
                last = json.loads(previous.read_text())
                if not isinstance(last, dict):
                    raise ValueError("status must be an object")
                last_completed = last.get("completedEpoch", last.get("lastCompletedEpoch"))
                if last_completed is not None and not isinstance(last_completed, (int, float)):
                    raise ValueError("invalid completion timestamp")
            except (OSError, ValueError) as error:
                last_completed = None
                warnings.append(f"previous status unavailable: {error}")
        error_log = service / "launchd-error.log"
        if error_log.exists():
            owned(error_log)
            try:
                bounded_log(error_log)
            except OSError as error:
                warnings.append(f"startup log trim failed: {error}")
        status = {"schemaVersion": 1, "revision": config["revision"], "state": "running",
                  "startedAt": stamp(), "startedEpoch": time.time(), "pid": os.getpid(),
                  "lastCompletedEpoch": last_completed, "before": disk(root), "steps": [], "warnings": warnings}
        record(service, status)
        for index in range(3):
            epoch = int(time.time())
            for mode in ("dry-run", "apply"):
                try:
                    result = execute_step(version, service, config, status, index, mode, epoch, lock_fd)
                except (OSError, ValueError) as error:
                    result = {"group": PREFIXES[index], "mode": mode, "error": str(error)}
                status["steps"].append(result)
                if result.get("exitCode") != 0:
                    status["warnings"].append(f"{PREFIXES[index]} {mode} failed; inspect step log")
                    break
                if "summaryError" in result:
                    status["warnings"].append(f"{PREFIXES[index]} {mode}: {result['summaryError']}")
                    continue
                counts = result["summary"]
                if mode == "apply" and counts["manual_review"]:
                    status["warnings"].append(f"{PREFIXES[index]} manual review: {counts['manual_review']}")
                if mode == "apply" and index == 0 and counts["eligible"] > counts["deleted"]:
                    status["warnings"].append(f"eligible run backlog: {counts['eligible'] - counts['deleted']}")
        status["after"] = disk(root)
        if "error" in status["after"]:
            status["warnings"].append("disk measurement unavailable")
        elif status["after"]["freeBytes"] < LOW_SPACE:
            status["warnings"].append("free disk space is below 30 GiB")
        status.update(state="complete", completedAt=stamp(), completedEpoch=time.time(), currentStep=None)
        status["success"] = all(step.get("exitCode") == 0 and "summaryError" not in step for step in status["steps"])
        record(service, status)
        print(json.dumps(status, sort_keys=True))
        return 0 if status["success"] else 1


def install(bundle: Path, repo: Path, root: Path) -> dict:
    identity(repo, root)
    metadata = bundle_at(bundle)
    launchctl("print", domain())  # Require the existing GUI login session.
    if disabled():
        raise ValueError("the cleanup job is disabled in launchd; enable it before installation")
    for binary in ("git", "jq", "xcrun", "osascript"):
        if not shutil.which(binary, path=HOST_PATH):
            raise ValueError(f"missing cleanup dependency: {binary}")
    service = service_path(root)
    service.mkdir(mode=0o700, exist_ok=True)
    owned(service, directory=True)
    lock = service / "run.lock"
    if not lock.exists() and not lock.is_symlink():
        lock.touch(mode=0o600, exist_ok=False)
    with service_lock(service):
        destination = plist_path()
        if destination.exists() or destination.is_symlink() or loaded():
            raise ValueError("cleanup job already exists; disable it before installing a version")
        if (service / "config.json").exists() and config_at(root)["enabled"]:
            raise ValueError("cleanup installation is enabled; disable it before replacing it")
        versions = service / "versions"
        versions.mkdir(mode=0o700, exist_ok=True)
        owned(versions, directory=True)
        version = versions / metadata["revision"]
        if version.exists() or version.is_symlink():
            if bundle_at(version) != metadata:
                raise ValueError("existing revision has different contents")
        else:
            with tempfile.TemporaryDirectory(prefix=".stage-", dir=versions) as temporary:
                stage = Path(temporary) / "version"
                stage.mkdir(mode=0o700)
                for name in (*FILES, "bundle.json"):
                    shutil.copyfile(bundle / name, stage / name)
                    (stage / name).chmod(0o600)
                bundle_at(stage)
                stage.rename(version)
        config = {"schemaVersion": 1, "label": LABEL, "repo": str(repo), "root": str(root),
                  "revision": metadata["revision"], "enabled": True, "installedAt": stamp()}
        destination.parent.mkdir(parents=True, exist_ok=True)
        owned(destination.parent, directory=True)
        plist = job_plist(config)
        error_log = service / "launchd-error.log"
        if error_log.exists() or error_log.is_symlink():
            owned(error_log)
        else:
            error_log.touch(mode=0o600, exist_ok=False)
        atomic_json(service / "config.json", config)
        fd, temporary = tempfile.mkstemp(prefix=".toastty-cleanup-", dir=destination.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                plistlib.dump(plist, stream)
            os.replace(temporary, destination)
            launchctl("bootstrap", domain(), str(destination))
        except BaseException:
            config["enabled"] = False
            atomic_json(service / "config.json", config)
            # Preserve all installed files for diagnosis. No existing job was replaced.
            raise
        finally:
            Path(temporary).unlink(missing_ok=True)
    return health(root)


def health(root: Path) -> dict:
    service = service_path(root)
    if not service.exists() and not service.is_symlink():
        return {"installed": False, "warnings": ["cleanup service is not installed"]}
    owned(service, directory=True)
    if not (service / "config.json").exists():
        return {"installed": False, "warnings": ["cleanup installation is incomplete"]}
    config = config_at(root)
    metadata = bundle_at(service / "versions" / config["revision"])
    result = {"installed": True, "config": config, "sha256": metadata["sha256"], "loaded": loaded(),
              "disabledByLaunchd": disabled(), "disk": disk(root), "warnings": []}
    if "error" in result["disk"]:
        result["warnings"].append("current disk measurement unavailable")
    elif result["disk"]["freeBytes"] < LOW_SPACE:
        result["warnings"].append("current free disk space is below 30 GiB")
    if not config["enabled"] or not result["loaded"] or result["disabledByLaunchd"]:
        result["warnings"].append("cleanup service is not active")
    status_path = service / "status.json"
    if status_path.exists():
        owned(status_path)
        result["lastRun"] = json.loads(status_path.read_text())
        result["warnings"].extend(result["lastRun"].get("warnings", []))
        completed = result["lastRun"].get("completedEpoch") or result["lastRun"].get("lastCompletedEpoch") or 0
        if time.time() - completed > 2 * INTERVAL + 900:
            result["warnings"].append("no completed cleanup within 8 hours 15 minutes")
        if result["lastRun"].get("state") == "running":
            result["warnings"].append("cleanup is running or was interrupted; inspect recorded PID and logs")
    else:
        result["warnings"].append("cleanup has not completed a run")
    destination = plist_path()
    if destination.exists():
        owned(destination)
        result["plist"] = plistlib.loads(destination.read_bytes())
        if result["plist"] != job_plist(config):
            result["warnings"].append("LaunchAgent does not match the installed cleanup configuration")
    elif config["enabled"]:
        result["warnings"].append("cleanup LaunchAgent plist is missing")
    return result


def disable(root: Path) -> dict:
    service = service_path(root)
    with service_lock(service):
        config = config_at(root)
        destination = plist_path()
        if destination.exists() or destination.is_symlink():
            owned(destination)
            plist = plistlib.loads(destination.read_bytes())
            if plist != job_plist(config):
                raise ValueError("refusing to remove a conflicting LaunchAgent")
        config["enabled"] = False
        atomic_json(service / "config.json", config)
        if loaded():
            launchctl("bootout", domain() + "/" + LABEL)
        destination.unlink(missing_ok=True)
    return health(root)


def remote(action: str) -> int:
    host, repo, root = (os.environ.get(name, "") for name in (
        "TOASTTY_REMOTE_GUI_HOST", "TOASTTY_REMOTE_GUI_REPO_ROOT", "TOASTTY_REMOTE_GUI_ROOT"))
    if not host or host.startswith("-") or not repo.startswith("/") or not root.startswith("/"):
        raise ValueError("run through sv exec with the configured remote host and roots")
    ssh = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
           "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", host]
    source = Path(__file__).resolve()
    arguments = ["--on-host", action, "--repo", repo, "--root", root]
    if action != "install":
        arguments.append("--installed")
        return subprocess.run([*ssh, shlex.join([HOST_PYTHON, "-I", "-", *arguments])],
                              input=source.read_bytes()).returncode
    checkout = source.parents[2]
    revision = command(["git", "-C", str(checkout), "rev-parse", "HEAD"]).stdout.strip()
    content = {}
    for name in FILES:
        path = source.parent / name
        owned(path)
        data = path.read_bytes()
        tracked = subprocess.run(["git", "-C", str(checkout), "show", f"HEAD:scripts/remote/{name}"],
                                 check=True, capture_output=True).stdout
        if data != tracked:
            raise ValueError(f"commit the reviewed cleanup source before installation: {name}")
        content[name] = data
    content["bundle.json"] = json.dumps({"schemaVersion": 1, "revision": revision,
        "sha256": {name: hashlib.sha256(data).hexdigest() for name, data in content.items()}}).encode()
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w") as archive:
        for name, data in content.items():
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode = len(data), 0o600
            archive.addfile(entry, io.BytesIO(data))
    temporary = command([*ssh, "mktemp -d /tmp/toastty-cleanup-install.XXXXXXXX"]).stdout.strip()
    if not re.fullmatch(r"/tmp/toastty-cleanup-install\.[A-Za-z0-9]+", temporary):
        raise ValueError("unexpected remote staging directory")
    try:
        subprocess.run([*ssh, shlex.join(["tar", "-xf", "-", "-C", temporary])],
                       input=payload.getvalue(), check=True)
        return subprocess.run([*ssh, shlex.join([HOST_PYTHON, "-I", temporary + "/" + FILES[0],
            *arguments, "--bundle", temporary])]).returncode
    finally:
        subprocess.run([*ssh, shlex.join(["rm", "-rf", "--", temporary])], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "status", "run-now", "disable", "run"))
    parser.add_argument("--on-host", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--installed", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--root", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--repo", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--bundle", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    os.umask(0o077)
    if not args.on_host:
        if args.action == "run":
            parser.error("use run-now to trigger the installed launchd job")
        return remote(args.action)
    if args.root is None:
        parser.error("on-host actions require --root")
    if args.installed:
        # The local controller only locates and verifies the pinned host code.
        # Control semantics (notably disable's plist check) belong to that version.
        if args.action not in ("status", "disable", "run-now"):
            parser.error("invalid installed control action")
        if not (service_path(args.root) / "config.json").exists():
            if args.action != "status":
                raise ValueError("cleanup service is not installed")
            print(json.dumps(health(args.root), indent=2))
            return 0
        config = config_at(args.root)
        version = service_path(args.root) / "versions" / config["revision"]
        if bundle_at(version)["revision"] != config["revision"]:
            raise ValueError("configured revision does not match installed bundle")
        os.execv(HOST_PYTHON, [HOST_PYTHON, "-I", str(version / FILES[0]),
                             "--on-host", args.action, "--root", str(args.root)])
    if args.action == "run":
        return run_service(args.root)
    if args.action == "install":
        if args.repo is None or args.bundle is None:
            parser.error("installation requires --repo and --bundle")
        result = install(args.bundle, args.repo, args.root)
    elif args.action == "disable":
        result = disable(args.root)
    elif args.action == "run-now":
        result = health(args.root)
        if not result.get("loaded") or not result["config"]["enabled"] or result["disabledByLaunchd"]:
            raise ValueError("cleanup service is not active")
        launchctl("kickstart", domain() + "/" + LABEL)  # Never -k: do not interrupt cleanup.
        result = {"requested": True, "label": LABEL, "message": "Use status to check completion."}
    else:
        result = health(args.root)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BlockingIOError:
        print("cleanup service is busy; no changes made", file=sys.stderr)
        sys.exit(75)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
