#!/usr/bin/env python3
"""Run the cleanup supervisor against disposable repositories and shell cleaners."""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "scripts/remote/cleanup-service.py"
FILES = ("cleanup-service.py", "cleanup-remote-runs.sh", "cleanup-simulators.sh", "cleanup-simulator-app.sh")
PREFIXES = ("remote-run-cleanup", "remote-simulator-cleanup", "remote-simulator-app-cleanup")
LABEL = "com.giantthings.toastty.remote-cleanup"
REVISION = "a" * 40

# Only launchctl is replaced. The fake persists the relevant launchd state and
# rejects bootstrapping a loaded service, as the real command does.
HOST_HARNESS = r'''
import importlib.util, json, os, pathlib, subprocess, sys
spec = importlib.util.spec_from_file_location("cleanup_service", sys.argv[1])
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)
# Use this disposable host's PATH for dependency checks and its generated plist.
service.HOST_PATH = os.environ["PATH"]
state_path = pathlib.Path(os.environ["FAKE_LAUNCHD_STATE"])
def launchctl(*args):
    state = json.loads(state_path.read_text())
    state["calls"].append(list(args))
    output = ""
    error = None
    if args[0] == "print":
        if args[1].count("/") == 2 and not state["loaded"]:
            error = "Could not find service"
    elif args[0] == "print-disabled":
        output = '"' + service.LABEL + '" => ' + str(state.get("disabledWord", state["disabled"])).lower()
    elif args[0] == "bootstrap":
        if state["loaded"]:
            error = "Service already loaded"
        else:
            state["loaded"] = True
    elif args[0] == "bootout":
        state["loaded"] = False
    elif args[0] != "kickstart":
        raise AssertionError(args)
    state_path.write_text(json.dumps(state))
    if error:
        raise subprocess.CalledProcessError(113, ["launchctl", *args], "", error)
    return subprocess.CompletedProcess(["launchctl", *args], 0, output, "")
service.launchctl = launchctl
sys.argv = [sys.argv[1], *sys.argv[2:]]
try:
    sys.exit(service.main())
except BlockingIOError:
    print("cleanup service is busy; no changes made", file=sys.stderr)
    sys.exit(75)
except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
'''

# Replace only the disk measurement boundary, to make the warning independent
# of the CI machine's disk size. The run and all cleanup subprocesses are real.
LOW_DISK_HARNESS = r'''
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cleanup_service", sys.argv[1])
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)
service.shutil.disk_usage = lambda root: type("Usage", (), {"free": 29 * 1024**3, "total": 100 * 1024**3})()
sys.argv = [sys.argv[1], *sys.argv[2:]]
sys.exit(service.main())
'''

STATUS_ENOSPC_HARNESS = r'''
import errno, importlib.util, sys
spec = importlib.util.spec_from_file_location("cleanup_service", sys.argv[1])
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)
atomic_json = service.atomic_json
def write(path, value):
    if path.name == "status.json":
        raise OSError(errno.ENOSPC, "fixture disk full")
    return atomic_json(path, value)
service.atomic_json = write
sys.argv = [sys.argv[1], *sys.argv[2:]]
sys.exit(service.main())
'''

TIMEOUT_HARNESS = r'''
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cleanup_service", sys.argv[1])
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)
service.PREVIEW_TIMEOUT = 0.2
sys.argv = [sys.argv[1], *sys.argv[2:]]
sys.exit(service.main())
'''

ERROR_LOG_ENOSPC_HARNESS = r'''
import errno, importlib.util, sys
spec = importlib.util.spec_from_file_location("cleanup_service", sys.argv[1])
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)
bounded_log = service.bounded_log
def read_log(path):
    if path.name == "launchd-error.log":
        raise OSError(errno.ENOSPC, "fixture disk full during log trim")
    return bounded_log(path)
service.bounded_log = read_log
sys.argv = [sys.argv[1], *sys.argv[2:]]
sys.exit(service.main())
'''


class CleanupServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="toastty-cleanup-service-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.repo = self.base / "repo"
        self.root = self.base / "validation"
        self.home = self.base / "home"
        self.bin = self.base / "bin"
        for directory in (self.repo, self.root, self.home, self.bin):
            directory.mkdir(mode=0o700)
        for name in ("test-runs", "worktrees"):
            (self.root / name).mkdir(mode=0o700)
        (self.repo / "scripts/remote").mkdir(parents=True)
        (self.repo / "Project.swift").write_text("// disposable repository\n")
        (self.repo / "scripts/remote/test.sh").write_text("#!/bin/sh\n")
        self.env = {"PATH": str(self.bin) + os.pathsep + os.defpath,
                    "HOME": str(self.home), "LANG": "C", "LC_ALL": "C",
                    "PYTHONDONTWRITEBYTECODE": "1"}
        subprocess.run(["git", "init", "--quiet", str(self.repo)], env=self.env, check=True, capture_output=True)
        self.service = self.root / ".cleanup-service"
        self.version = self.service / "versions" / REVISION
        self.version.mkdir(parents=True, mode=0o700)
        self.events = self.root / "events"
        self.plist = self.home / "Library/LaunchAgents" / (LABEL + ".plist")
        self.state = self.base / "launchd.json"
        self.set_launchd(loaded=True)
        self.env["FAKE_LAUNCHD_STATE"] = str(self.state)
        self.write_bundle(self.version)
        self.config = {"schemaVersion": 1, "label": LABEL, "repo": str(self.repo),
                       "root": str(self.root), "revision": REVISION, "enabled": True}
        self.write_config()
        (self.service / "run.lock").touch(mode=0o600)

    def set_launchd(self, loaded=False, disabled=False):
        self.state.write_text(json.dumps({"loaded": loaded, "disabled": disabled, "calls": []}))

    def write_config(self):
        (self.service / "config.json").write_text(json.dumps(self.config))
        (self.service / "config.json").chmod(0o600)

    def write_bundle(self, directory, behaviors=None):
        directory.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SOURCE, directory / FILES[0])
        behaviors = behaviors or {}
        for index, name in enumerate(FILES[1:]):
            # Each script receives the real runner's --remote-exec argument list.
            # Record invocation order before running any configured failure/hold.
            body = "#!/bin/bash\nset -eu\nmode=$2\n"
            body += 'printf "%s:%s\\n" ' + str(index) + ' "$mode" >> ' + shlex.quote(str(self.events)) + "\n"
            body += behaviors.get(index, "") + "\n"
            deleted = "terminated" if index == 2 else "deleted"
            failures = "terminate_failures" if index == 2 else "delete_failures"
            body += ('printf "[%s] mode=%%s eligible=4 retained=2 manual_review=0 %s=4 %s=0\\n" "$mode"\n'
                     % (PREFIXES[index], deleted, failures))
            (directory / name).write_text(body)
        for name in FILES:
            (directory / name).chmod(0o600)
        metadata = {"schemaVersion": 1, "revision": REVISION,
                    "sha256": {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in FILES}}
        (directory / "bundle.json").write_text(json.dumps(metadata))
        (directory / "bundle.json").chmod(0o600)

    def argv(self, action="run", harness=None, extra=()):
        source = SOURCE if action == "install" else self.version / FILES[0]
        arguments = [str(source), "--on-host", action, "--root", str(self.root), *extra]
        return [sys.executable, "-I", *(["-c", harness] if harness else []), *arguments]

    def invoke(self, action="run", harness=None, extra=()):
        return subprocess.run(self.argv(action, harness, extra), env=self.env,
                              capture_output=True, text=True, timeout=15)

    def status(self):
        return json.loads((self.service / "status.json").read_text())

    def sequence(self):
        return self.events.read_text().splitlines() if self.events.exists() else []

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def wait_for(self, path, process=None):
        deadline = time.monotonic() + 10
        while not path.exists():
            if process is not None and process.poll() is not None:
                self.fail("supervisor exited before cleaner started")
            if time.monotonic() > deadline:
                self.fail("timeout waiting for " + str(path))
            time.sleep(0.02)

    def test_each_group_previews_before_apply(self):
        result = self.invoke()
        self.assert_ok(result)
        self.assertEqual(self.sequence(), [f"{group}:{mode}" for group in range(3) for mode in ("dry-run", "apply")])
        status = self.status()
        self.assertTrue(status["success"])
        self.assertEqual(status["state"], "complete")
        self.assertEqual(status["revision"], REVISION)
        self.assertEqual(len(status["steps"]), 6)
        self.assertTrue(all(step["exitCode"] == 0 for step in status["steps"]))

    def test_failed_preview_skips_only_its_apply(self):
        self.write_bundle(self.version, {0: 'if [ "$mode" = dry-run ]; then exit 7; fi'})
        result = self.invoke()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.sequence(), ["0:dry-run", "1:dry-run", "1:apply", "2:dry-run", "2:apply"])
        self.assertEqual(self.status()["steps"][0]["exitCode"], 7)
        self.assertFalse(self.status()["success"])

    def test_apply_failure_is_recorded_and_next_group_continues(self):
        self.write_bundle(self.version, {1: 'if [ "$mode" = apply ]; then exit 9; fi'})
        self.assertEqual(self.invoke().returncode, 1)
        status = self.status()
        self.assertEqual(status["steps"][3]["exitCode"], 9)
        self.assertEqual(self.sequence()[-2:], ["2:dry-run", "2:apply"])
        self.assertTrue(any("remote-simulator-cleanup apply failed" in warning for warning in status["warnings"]))

    def test_missing_summary_is_reported_without_suppressing_successful_apply(self):
        self.write_bundle(self.version, {0: 'if [ "$mode" = dry-run ]; then echo "fixture has no summary"; exit 0; fi'})
        self.assertEqual(self.invoke().returncode, 1)
        status = self.status()
        self.assertIn("summaryError", status["steps"][0])
        self.assertEqual(status["steps"][0]["exitCode"], 0)
        self.assertIn("0:apply", self.sequence())
        self.assertEqual(len(status["steps"]), 6)

    def test_backlog_manual_review_and_low_disk_warnings(self):
        body = ('if [ "$mode" = apply ]; then\n'
                'echo "[remote-run-cleanup] mode=apply eligible=37 retained=8 manual_review=2 deleted=30 delete_failures=0"\n'
                'exit 0\nfi')
        self.write_bundle(self.version, {0: body})
        result = self.invoke(harness=LOW_DISK_HARNESS)
        self.assert_ok(result)
        warnings = self.status()["warnings"]
        self.assertIn("eligible run backlog: 7", warnings)
        self.assertIn("remote-run-cleanup manual review: 2", warnings)
        self.assertIn("free disk space is below 30 GiB", warnings)

    def test_busy_run_preserves_status_and_does_not_start_cleaners(self):
        status = self.service / "status.json"
        status.write_text('{"sentinel":"existing status"}')
        with (self.service / "run.lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.invoke()
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual(status.read_text(), '{"sentinel":"existing status"}')
        self.assertEqual(self.sequence(), [])

    def test_bundle_tampering_fails_before_status_or_cleaner_mutation(self):
        status = self.service / "status.json"
        status.write_text('{"sentinel":true}')
        with (self.version / FILES[1]).open("a") as stream:
            stream.write("# changed after review\n")
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertIn("hash mismatch", result.stderr)
        self.assertEqual(status.read_text(), '{"sentinel":true}')
        self.assertEqual(self.sequence(), [])

    def test_hostile_inherited_shell_and_git_environment_is_removed(self):
        sentinel = self.root / "bash-env-executed"
        startup = self.base / "hostile-bash-env.sh"
        startup.write_text("touch " + shlex.quote(str(sentinel)) + "\n")
        self.env.update(BASH_ENV=str(startup), GIT_DIR=str(self.base / "missing.git"),
                        UNRELATED_CLEANUP_SECRET="fixture-not-a-secret")
        body = ('test "${HOME}" = ' + shlex.quote(str(self.home)) + '\n'
                'test -z "${BASH_ENV+x}${GIT_DIR+x}${UNRELATED_CLEANUP_SECRET+x}"\n'
                'test "$(git -C ' + shlex.quote(str(self.repo)) + ' config --get gc.auto)" = 0\n'
                'test "$(git -C ' + shlex.quote(str(self.repo)) + ' config --get core.fsmonitor)" = false\n'
                'test "$(git -C ' + shlex.quote(str(self.repo)) + ' config --get maintenance.auto)" = false')
        self.write_bundle(self.version, {0: body})
        result = self.invoke()
        self.assert_ok(result)
        self.assertFalse(sentinel.exists())
        self.assertEqual(len(self.sequence()), 6)

    def test_corrupt_previous_status_does_not_block_cleanup(self):
        for contents in ("", "[]", '"not an object"', "null"):
            with self.subTest(contents=contents):
                (self.service / "status.json").write_text(contents)
                self.events.unlink(missing_ok=True)
                result = self.invoke()
                self.assert_ok(result)
                self.assertEqual(len(self.sequence()), 6)
                self.assertTrue(self.status()["success"])

    def test_launchd_error_log_trim_failure_does_not_block_cleanup(self):
        (self.service / "launchd-error.log").write_text("previous launch error\n")
        result = self.invoke(harness=ERROR_LOG_ENOSPC_HARNESS)
        self.assert_ok(result)
        self.assertEqual(len(self.sequence()), 6)
        self.assertTrue(self.status()["success"])

    def test_running_snapshot_must_match_configured_revision(self):
        other_revision = "b" * 40
        other_version = self.version.parent / other_revision
        shutil.copytree(self.version, other_version)
        metadata_path = other_version / "bundle.json"
        metadata = json.loads(metadata_path.read_text())
        metadata["revision"] = other_revision
        metadata_path.write_text(json.dumps(metadata))
        self.config["revision"] = other_revision
        self.write_config()
        status = self.service / "status.json"
        status.write_text('{"sentinel":true}')
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertIn("running supervisor does not match installed revision", result.stderr)
        self.assertEqual(self.sequence(), [])
        self.assertEqual(status.read_text(), '{"sentinel":true}')

    def test_status_disk_full_does_not_prevent_cleanup(self):
        result = self.invoke(harness=STATUS_ENOSPC_HARNESS)
        self.assert_ok(result)
        self.assertTrue(json.loads(result.stdout)["success"])
        self.assertIn("could not write cleanup status", result.stderr)
        self.assertEqual(len(self.sequence()), 6)
        self.assertFalse((self.service / "status.json").exists())

    def test_preview_timeout_skips_its_apply_and_continues_other_groups(self):
        self.write_bundle(self.version, {0: 'if [ "$mode" = dry-run ]; then /bin/sleep 10; fi'})
        result = self.invoke(harness=TIMEOUT_HARNESS)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.sequence(), ["0:dry-run", "1:dry-run", "1:apply", "2:dry-run", "2:apply"])
        self.assertFalse(self.status()["success"])

    def test_cleaner_survives_supervisor_death_and_keeps_shared_lock(self):
        started, release, finished = [self.root / name for name in ("started", "release", "finished")]
        body = ('if [ "$mode" = dry-run ]; then\n'
                'echo $$ > ' + shlex.quote(str(started)) + '\n'
                'while [ ! -e ' + shlex.quote(str(release)) + ' ]; do /bin/sleep 0.05; done\n'
                'echo "cleaner completed after supervisor death"\n'
                'touch ' + shlex.quote(str(finished)) + '\nfi')
        self.write_bundle(self.version, {0: body})
        output_path = self.base / "supervisor.log"
        with output_path.open("w") as output:
            process = subprocess.Popen(self.argv(), env=self.env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=output)
        try:
            self.wait_for(started, process)
            process.kill()
            process.wait(timeout=5)
            before = (self.service / "status.json").read_bytes()
            self.assertEqual(self.invoke().returncode, 75)
            self.assertEqual((self.service / "status.json").read_bytes(), before)
            self.assertEqual(self.sequence(), ["0:dry-run"])
            release.touch()
            self.wait_for(finished)
            # The child can still write its log after the supervisor closes.
            deadline = time.monotonic() + 5
            with (self.service / "run.lock").open("r+") as lock:
                while True:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() > deadline:
                            self.fail("cleaner did not release the shared lock")
                        time.sleep(0.02)
            self.assertIn("cleaner completed after supervisor death", (self.service / "0-dry-run.log").read_text())
        finally:
            release.touch(exist_ok=True)
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if started.exists() and not finished.exists():
                self.wait_for(finished)

    def write_plist(self, script=None):
        self.plist.parent.mkdir(parents=True, exist_ok=True)
        self.plist.write_bytes(plistlib.dumps({
            "Label": LABEL,
            "ProgramArguments": ["/usr/bin/python3", "-I", str(script or self.version / FILES[0]),
                                 "--on-host", "run", "--root", str(self.root)],
            "StartInterval": 14400,
            "RunAtLoad": False,
            "EnvironmentVariables": {"PATH": self.env["PATH"],
                                     "LANG": "C", "LC_ALL": "C", "TZ": "UTC"},
            "WorkingDirectory": str(self.service),
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": str(self.service / "launchd-error.log"),
        }))
        self.plist.chmod(0o600)

    def test_status_is_readable_while_busy_and_disable_refuses_mutation(self):
        self.write_plist()
        before = (self.service / "config.json").read_bytes()
        with (self.service / "run.lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            status = self.invoke("status", HOST_HARNESS)
            self.assert_ok(status)
            self.assertTrue(json.loads(status.stdout)["loaded"])
            result = self.invoke("disable", HOST_HARNESS)
        self.assertEqual(result.returncode, 75)
        self.assertEqual((self.service / "config.json").read_bytes(), before)
        self.assertTrue(self.plist.exists())
        self.assertFalse(any(call[0] == "bootout" for call in json.loads(self.state.read_text())["calls"]))

    def test_disable_refuses_conflicting_agent_and_preserves_config(self):
        self.write_plist(self.base / "another-service.py")
        before = (self.service / "config.json").read_bytes()
        status = self.invoke("status", HOST_HARNESS)
        self.assert_ok(status)
        self.assertIn("LaunchAgent does not match the installed cleanup configuration",
                      json.loads(status.stdout)["warnings"])
        result = self.invoke("disable", HOST_HARNESS)
        self.assertEqual(result.returncode, 1)
        self.assertIn("conflicting LaunchAgent", result.stderr)
        self.assertEqual((self.service / "config.json").read_bytes(), before)
        self.assertTrue(self.plist.exists())
        self.assertTrue(json.loads(self.state.read_text())["loaded"])

    def test_disable_unloads_and_preserves_snapshot_for_status(self):
        self.write_plist()
        result = self.invoke("disable", HOST_HARNESS)
        self.assert_ok(result)
        health = json.loads(result.stdout)
        self.assertFalse(health["loaded"])
        self.assertFalse(health["config"]["enabled"])
        self.assertFalse(self.plist.exists())
        self.assertTrue((self.version / FILES[0]).exists())

    def install_fixture(self):
        bundle = self.base / "upload"
        self.write_bundle(bundle)
        # Existence checks for macOS-only dependencies stay local. These are
        # never called; actual cleaners are the controlled shell scripts above.
        for name in ("jq", "xcrun", "osascript"):
            binary = self.bin / name
            binary.write_text("#!/bin/sh\nexit 99\n")
            binary.chmod(0o700)
        self.set_launchd(loaded=False)
        self.config["enabled"] = False
        self.write_config()
        return bundle

    def install(self, bundle):
        return self.invoke("install", HOST_HARNESS,
                           ("--repo", str(self.repo), "--bundle", str(bundle)))

    def test_install_pins_snapshot_interval_and_refuses_conflicting_replacement(self):
        bundle = self.install_fixture()
        # Simulate a disabled previous installation without an installed version.
        shutil.rmtree(self.version)
        result = self.install(bundle)
        self.assert_ok(result)
        plist = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(plist["StartInterval"], 14400)
        self.assertFalse(plist["RunAtLoad"])
        self.assertEqual(plist["ProgramArguments"][0], "/usr/bin/python3")
        self.assertEqual(plist["ProgramArguments"][2], str(self.version / FILES[0]))
        self.assertNotIn(str(self.repo), plist["ProgramArguments"])
        original = (self.version / FILES[1]).read_bytes()
        (bundle / FILES[1]).write_text("upload changed\n")
        self.assertEqual((self.version / FILES[1]).read_bytes(), original)
        before = self.plist.read_bytes()
        # Use a valid upload to reach the existing-job conflict check.
        self.write_bundle(bundle)
        conflict = self.install(bundle)
        self.assertEqual(conflict.returncode, 1)
        self.assertIn("already exists", conflict.stderr)
        self.assertEqual(self.plist.read_bytes(), before)
        self.assert_ok(self.invoke("disable", HOST_HARNESS))
        self.assert_ok(self.install(bundle))

    def test_install_refuses_launchd_disabled_override(self):
        bundle = self.install_fixture()
        self.set_launchd(loaded=False, disabled=True)
        result = self.install(bundle)
        self.assertEqual(result.returncode, 1)
        self.assertIn("disabled in launchd", result.stderr)
        self.assertFalse(self.plist.exists())
        self.assertFalse(json.loads((self.service / "config.json").read_text())["enabled"])

    def test_status_and_run_now_recognize_launchd_disabled_word(self):
        state = json.loads(self.state.read_text())
        state["disabledWord"] = "disabled"
        self.state.write_text(json.dumps(state))
        result = self.invoke("status", HOST_HARNESS)
        self.assert_ok(result)
        self.assertTrue(json.loads(result.stdout)["disabledByLaunchd"])
        result = self.invoke("run-now", HOST_HARNESS)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any(call[0] == "kickstart" for call in json.loads(self.state.read_text())["calls"]))

    def test_install_refuses_unsafe_bundle_before_launchd_mutation(self):
        bundle = self.install_fixture()
        (bundle / FILES[1]).chmod(0o622)
        result = self.install(bundle)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsafe ownership, permissions or file type", result.stderr)
        self.assertFalse(self.plist.exists())
        self.assertEqual(json.loads(self.state.read_text())["calls"], [])

    def test_install_busy_preserves_disabled_configuration(self):
        bundle = self.install_fixture()
        before = (self.service / "config.json").read_bytes()
        with (self.service / "run.lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.install(bundle)
        self.assertEqual(result.returncode, 75)
        self.assertEqual((self.service / "config.json").read_bytes(), before)
        self.assertFalse(self.plist.exists())
        self.assertFalse(json.loads(self.state.read_text())["loaded"])

    def test_run_now_requests_launchd_without_restarting_running_cleanup(self):
        result = self.invoke("run-now", HOST_HARNESS)
        self.assert_ok(result)
        self.assertTrue(json.loads(result.stdout)["requested"])
        calls = json.loads(self.state.read_text())["calls"]
        self.assertEqual([call for call in calls if call[0] == "kickstart"],
                         [["kickstart", f"gui/{os.getuid()}/{LABEL}"]])
        self.assertEqual(self.sequence(), [])
        self.set_launchd(loaded=True, disabled=True)
        result = self.invoke("run-now", HOST_HARNESS)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any(call[0] == "kickstart" for call in json.loads(self.state.read_text())["calls"]))


if __name__ == "__main__":
    unittest.main()
