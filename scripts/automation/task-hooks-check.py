#!/usr/bin/env python3
"""Live check of task lifecycle hooks against the wrapper's isolated Toastty.

Run through `scripts/remote/validate.sh --validation-command 'python3
scripts/automation/task-hooks-check.py'`. It installs a throwaway user skill
in the run's runtime home, creates a background workspace with one subspace,
sets the subspace's hooks through the CLI, moves the task through its stages
with workspace.set-task-stage, and runs the close and cleanup actions over the
automation socket. The fake hook script records the environment it got and
exits 3 the first time it runs with a given marker, then closes its workspace
and exits 0. The check verifies the stage reported by workspace.snapshot, the
skipped close outcome and the skipped and cleaned cleanup outcomes, the
recorded environment (workspace ID and CLI path present, no session
identity), and that the subspace is gone afterwards. It never selects a
workspace or moves focus, and it does not launch an agent, so Finish Task is
covered by the app tests only. Writes task-hooks-check.json under the run's
artifacts directory.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path


class CheckFailure(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailure(message)


class Toastty:
    def __init__(self) -> None:
        self.socket_path = os.environ["TOASTTY_SOCKET_PATH"]
        instance = json.loads(Path(os.environ["TOASTTY_INSTANCE_JSON"]).read_text())
        require(instance["socketPath"] == self.socket_path, "Socket does not match instance.json")
        bundle = Path(os.environ["TOASTTY_APP_BUNDLE"])
        candidates = (bundle / "Contents/Helpers/toastty", bundle / "Contents/MacOS/toastty", bundle.parent / "toastty")
        cli = next((path for path in candidates if path.is_file() and os.access(path, os.X_OK)), None)
        require(cli is not None, "Validation build has no Toastty CLI")
        self.cli = str(cli)
        self.runtime_home = Path(os.environ["TOASTTY_RUNTIME_HOME"])
        # This disposable app owns no managed caller from the launching session.
        self.environment = dict(os.environ)
        for key in ("TOASTTY_SESSION_ID", "TOASTTY_PANEL_ID"):
            self.environment.pop(key, None)

    def run(self, kind: str, command: str, *args: str, expect_ok: bool = True) -> dict:
        result = subprocess.run(
            [self.cli, "--json", "--socket-path", self.socket_path, kind, "run", command, *args],
            capture_output=True, text=True, env=self.environment,
        )
        try:
            response = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise CheckFailure(f"{command}: no JSON response: {result.stdout!r} {result.stderr!r}")
        if expect_ok:
            require(response.get("ok") is True, f"{command} failed: {response}")
        return response

    def wait_for_socket(self, timeout: float = 30.0) -> dict:
        """instance.json lands before the socket listens; give the app a moment."""
        deadline = time.monotonic() + timeout
        while True:
            try:
                return self.query("workspace.list")
            except CheckFailure:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.5)

    def action(self, command: str, *args: str, expect_ok: bool = True) -> dict:
        return self.run("action", command, *args, expect_ok=expect_ok)

    def query(self, command: str, *args: str) -> dict:
        return self.run("query", command, *args)["result"]


SKILL_NAME = "hook-check"
CLEANUP_SCRIPT = r'''#!/bin/sh
# Records what Toastty handed the hook, then skips once and cleans the next time.
marker="$1"
{
  echo "cwd=$(pwd)"
  echo "workspace=${TOASTTY_WORKSPACE_ID:-}"
  echo "cli=${TOASTTY_CLI_PATH:-}"
  echo "session=${TOASTTY_SESSION_ID:-}"
  echo "panel=${TOASTTY_PANEL_ID:-}"
} > "$marker.env"
if [ ! -f "$marker.cleaned" ]; then
  touch "$marker.cleaned"
  echo "first run: pretending the merge has not landed"
  exit 3
fi
"$TOASTTY_CLI_PATH" --json action run workspace.close --workspace "$TOASTTY_WORKSPACE_ID" >/dev/null
echo "closed the workspace and removed nothing else"
exit 0
'''


def main() -> int:
    artifacts = Path(os.environ["TOASTTY_ARTIFACTS_DIR"])
    report: dict = {"status": "fail", "steps": []}
    try:
        app = Toastty()
        skill_dir = app.runtime_home / "skills" / SKILL_NAME
        (skill_dir / "scripts").mkdir(parents=True, exist_ok=True)
        (skill_dir / "SKILL.md").write_text(f"---\nname: {SKILL_NAME}\ndescription: Live check of task hooks\n---\n# {SKILL_NAME}\n")
        script = skill_dir / "scripts" / "cleanup.sh"
        script.write_text(CLEANUP_SCRIPT)
        script.chmod(0o755)
        marker = artifacts / "hook-check-marker"

        windows = app.wait_for_socket()["workspaces"]
        require(bool(windows), "workspace.list returned nothing")
        window_id = windows[0]["windowID"]
        parent = app.action("workspace.create", "--window", window_id, "title=hook-check-parent", "activate=false")["result"]
        parent_id = parent["workspaceID"]
        child = app.action("workspace.create", "--window", window_id, "title=hook-check-task", "activate=false",
                           f"parent={parent_id}")["result"]
        child_id = child["workspaceID"]
        report["steps"].append({"created": {"parent": parent_id, "child": child_id}})

        close_marker = artifacts / "hook-check-close-marker"
        hooks = app.action("workspace.task.set-hooks", "--workspace", child_id, "finishSkill=worktree-done",
                           f"cleanupSkill={SKILL_NAME}", "cleanupScript=scripts/cleanup.sh",
                           f"cleanupArgs={marker}",
                           f"closeSkill={SKILL_NAME}", "closeScript=scripts/cleanup.sh",
                           f"closeArgs={close_marker}")["result"]
        require(hooks["cleanup"]["skill"] == SKILL_NAME, f"hooks not recorded: {hooks}")
        require(hooks["close"]["args"] == [str(close_marker)], f"close hook not recorded: {hooks}")
        snapshot = app.query("workspace.snapshot", "--workspace", child_id)
        require(snapshot["taskHooks"]["cleanup"]["script"] == "scripts/cleanup.sh", f"snapshot lacks hooks: {snapshot}")
        require(snapshot["taskStage"] == "open", f"a new task is open: {snapshot}")
        report["steps"].append({"hooks": hooks})

        # A top-level workspace cannot hold hooks or leave the open stage.
        refused = app.action("workspace.task.set-hooks", "--workspace", parent_id, "finishSkill=worktree-done", expect_ok=False)
        require(refused.get("ok") is False, f"top-level set-hooks was accepted: {refused}")
        refused = app.action("workspace.set-task-stage", "--workspace", parent_id, "stage=review", expect_ok=False)
        require(refused.get("ok") is False, f"top-level set-task-stage was accepted: {refused}")

        # open -> review -> done, and back to open, as an agent would move it.
        def stage() -> str:
            return app.query("workspace.snapshot", "--workspace", child_id)["taskStage"]

        app.action("workspace.set-task-stage", "--workspace", child_id, "stage=review")
        require(stage() == "review", "set-task-stage review did not take")
        app.action("workspace.set-task-stage", "--workspace", child_id, "stage=done")
        require(stage() == "done", "set-task-stage done did not take")
        require(app.query("workspace.snapshot", "--workspace", child_id)["done"] is True, "done keeps the done flag")
        app.action("workspace.set-task-stage", "--workspace", child_id, "stage=open")
        require(stage() == "open", "set-task-stage open did not reopen the task")
        report["steps"].append({"stages": "open -> review -> done -> open"})

        # Close Task runs at any stage; the script skips the first time.
        closed = app.action("workspace.task.close", "--workspace", child_id)["result"]
        require(closed["outcome"] == "skipped", f"first close should skip: {closed}")
        close_env = dict(line.split("=", 1) for line in Path(f"{close_marker}.env").read_text().splitlines())
        require(close_env["workspace"] == child_id, f"close script saw workspace {close_env['workspace']!r}")
        require(child_id in {w["workspaceID"] for w in app.query("workspace.list")["workspaces"]}, "a skipped close keeps the workspace")
        report["steps"].append({"close": closed, "closeEnv": close_env})

        app.action("workspace.set-done", "--workspace", child_id)
        require(stage() == "done", "set-done is the done stage")
        first = app.action("workspace.task.cleanup", "--workspace", child_id)["result"]
        require(first["outcome"] == "skipped", f"first cleanup should skip: {first}")
        require(first["detail"] == "first run: pretending the merge has not landed", f"detail is not the last line: {first}")
        env = dict(line.split("=", 1) for line in Path(f"{marker}.env").read_text().splitlines())
        require(env["workspace"] == child_id, f"script saw workspace {env['workspace']!r}")
        require(env["cli"] and Path(env["cli"]).exists(), f"script saw no CLI: {env}")
        require(env["session"] == "" and env["panel"] == "", f"script inherited a session identity: {env}")
        require(app.query("workspace.snapshot", "--workspace", child_id)["done"] is True, "skip must leave the done mark")
        report["steps"].append({"first": first, "env": env})

        second = app.action("workspace.task.cleanup-finished", "--workspace", parent_id)["result"]
        require(second["workspaceID"] == parent_id, f"batch reported another parent: {second}")
        require([r["outcome"] for r in second["results"]] == ["cleaned"], f"batch should clean once: {second}")
        remaining = {w["workspaceID"] for w in app.query("workspace.list")["workspaces"]}
        require(child_id not in remaining, "the cleanup script's workspace.close did not take")
        require(parent_id in remaining, "the parent must stay open")
        report["steps"].append({"second": second})

        app.action("workspace.close", "--workspace", parent_id)
        report["status"] = "pass"
        return 0
    except CheckFailure as failure:
        report["failure"] = str(failure)
        print(f"task-hooks-check: {failure}", file=sys.stderr)
        return 1
    finally:
        (artifacts / "task-hooks-check.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    sys.exit(main())
