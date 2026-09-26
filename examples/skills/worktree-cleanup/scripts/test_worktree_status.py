#!/usr/bin/env python3
"""Cleanup safety tests. Disposable Git repositories with a fake gh and a fake
Toastty CLI; never contacts GitHub or a running Toastty."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("worktree-status.py")
OWN_WORKSPACE = "00000000-0000-0000-0000-00000000000a"

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
state = json.load(open(os.environ["FAKE_STATE"]))
args = sys.argv[1:]
if args[:2] == ["repo", "view"]:
    print(json.dumps({"nameWithOwner": "test/repo", "defaultBranchRef": {"name": "main"}}))
elif args[:2] == ["pr", "list"]:
    print(json.dumps(state["prs"]))
elif args[:2] == ["pr", "view"]:
    pr = next(p for p in state["prs"] if p["number"] == int(args[2]))
    print(json.dumps({"mergeable": pr["mergeable"], "mergeStateStatus": pr["mergeStateStatus"]}))
else:
    sys.exit(f"unexpected gh call: {args}")
'''

FAKE_TOASTTY = r'''#!/usr/bin/env python3
import json, os, sys
state = json.load(open(os.environ["FAKE_STATE"]))
args = sys.argv[1:]
with open(os.environ["FAKE_TOASTTY_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
if "workspace.list" in args:
    print(json.dumps({"ok": True, "result": {"workspaces": state["workspaces"],
                                             "callerIsScoped": state.get("scoped", False)}}))
elif "terminal.state" in args:
    print(json.dumps({"ok": True, "result": {"workspaceID": state["own"]}}))
elif "workspace.close" in args:
    print(json.dumps({"ok": True, "result": {}}))
else:
    sys.exit(f"unexpected toastty call: {args}")
'''


class CleanupTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.origin = self.root / "origin.git"
        self.repo = self.root / "repo"
        subprocess.run(["git", "init", "--bare", "-b", "main", str(self.origin)], check=True, capture_output=True)
        subprocess.run(["git", "clone", "-q", str(self.origin), str(self.repo)], check=True, capture_output=True)
        self.git("config", "user.name", "Cleanup Test")
        self.git("config", "user.email", "cleanup@example.invalid")
        self.commit(self.repo, "base")
        self.git("push", "-q", "origin", "main")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, body in (("gh", FAKE_GH), ("toastty", FAKE_TOASTTY)):
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        self.state_file = self.root / "state.json"
        self.log = self.root / "toastty.log"
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_STATE=str(self.state_file),
                        FAKE_TOASTTY_LOG=str(self.log), TOASTTY_CLI_PATH=str(bin_dir / "toastty"),
                        TOASTTY_PANEL_ID="own-panel")
        self.prs, self.workspaces, self.scoped = [], [], False

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.repo, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, cwd, message):
        (Path(cwd) / "file.txt").write_text(message + "\n")
        self.git("add", "file.txt", cwd=cwd)
        self.git("commit", "-q", "-m", message, cwd=cwd)
        return self.git("rev-parse", "HEAD", cwd=cwd)

    def task(self, number, state="MERGED", session=False, busy=False):
        """A pushed task branch and worktree with a PR whose head is the pushed tip."""
        branch, path = f"task-{number}", self.root / f"task-{number}"
        self.git("worktree", "add", "-q", "-b", branch, str(path))
        head = self.commit(path, branch)
        self.git("push", "-q", "-u", "origin", branch, cwd=path)
        self.prs.append({
            "number": number, "title": branch, "state": state, "isDraft": False, "headRefName": branch,
            "headRefOid": head, "baseRefName": "main", "isCrossRepository": False,
            "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "url": f"https://github.com/test/repo/pull/{number}",
            "statusCheckRollup": [{"name": "CI gate", "status": "COMPLETED", "conclusion": "SUCCESS"}],
            "body": "",
        })
        self.workspaces.append({
            "workspaceID": f"00000000-0000-0000-0000-{number:012d}", "title": branch,
            "terminalCwds": [str(path)], "annotations": [],
            "activeSessions": [{"sessionID": "s", "agent": "claude", "panelID": "p"}] if session else [],
            "busyTerminalCount": 1 if busy else 0, "unsavedDocumentCount": 0,
        })
        return branch, path

    def status(self, *args, env=None):
        self.state_file.write_text(json.dumps({"prs": self.prs, "workspaces": self.workspaces,
                                               "own": OWN_WORKSPACE, "scoped": self.scoped}))
        result = subprocess.run([sys.executable, str(SCRIPT), "--json", "--repo", str(self.repo), *args],
                                env=env or self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return {row["pr"]: row for row in json.loads(result.stdout)["prs"]}

    def closed(self):
        return [line for line in self.log.read_text().splitlines() if "workspace.close" in line] \
            if self.log.exists() else []

    def remote_has(self, branch):
        return bool(self.git("ls-remote", "--heads", "origin", branch))

    def test_cleans_merged_worktree_at_pr_head(self):
        branch, path = self.task(1)
        row = self.status("--cleanup-merged")[1]
        self.assertEqual(row["verdict"], "cleanup")
        self.assertIn("removed worktree", row["cleanup"])
        self.assertFalse(path.exists())
        self.assertEqual(self.git("branch", "--list", branch), "")
        self.assertFalse(self.remote_has(branch))
        self.assertEqual(len(self.closed()), 1)

    def test_keeps_worktree_with_uncommitted_or_unpushed_work(self):
        _, dirty = self.task(1)
        (dirty / "notes.txt").write_text("unsaved\n")
        _, ahead = self.task(2)
        self.commit(ahead, "local only")
        rows = self.status("--cleanup-merged")
        self.assertIn("uncommitted", rows[1]["reason"])
        self.assertIn("ahead", rows[2]["reason"])
        self.assertTrue(dirty.exists() and ahead.exists())
        self.assertEqual(self.closed(), [])

    def test_skips_workspace_with_live_work_or_the_callers_own(self):
        _, with_session = self.task(1, session=True)
        _, busy = self.task(2, busy=True)
        _, own = self.task(3)
        self.workspaces[-1]["workspaceID"] = OWN_WORKSPACE
        rows = self.status("--cleanup-merged")
        self.assertIn("active agent session", rows[1]["cleanup"])
        self.assertIn("running a command", rows[2]["cleanup"])
        self.assertIn("own workspace", rows[3]["cleanup"])
        self.assertTrue(with_session.exists() and busy.exists() and own.exists())
        self.assertEqual(self.closed(), [])

    def test_skips_unsaved_documents_other_worktrees_and_other_pr_chips(self):
        _, unsaved = self.task(1)
        self.workspaces[-1]["unsavedDocumentCount"] = 1
        _, shared = self.task(2)
        self.workspaces[-1]["terminalCwds"].append(str(self.repo))
        _, chipped = self.task(3)
        self.workspaces[-1]["annotations"] = [
            {"key": "github-pr", "text": "PR #9", "url": "https://github.com/test/repo/pull/9"}]
        rows = self.status("--cleanup-merged")
        self.assertIn("unsaved document", rows[1]["cleanup"])
        self.assertIn("another worktree", rows[2]["cleanup"])
        self.assertIn("different PR", rows[3]["cleanup"])
        self.assertTrue(unsaved.exists() and shared.exists() and chipped.exists())
        self.assertEqual(self.closed(), [])

    def test_skips_locked_worktree_before_closing_its_workspace(self):
        _, path = self.task(1)
        self.git("worktree", "lock", str(path))
        row = self.status("--cleanup-merged")[1]
        self.assertIn("locked", row["cleanup"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_matches_workspace_through_a_path_alias(self):
        _, path = self.task(1)
        alias = self.root / "alias"
        alias.symlink_to(path)
        self.workspaces[-1]["terminalCwds"] = [str(alias)]
        row = self.status("--cleanup-merged")[1]
        self.assertIn("closed task-1", row["cleanup"])
        self.assertFalse(path.exists())

    def test_keeps_remote_branch_recreated_at_another_commit(self):
        branch, path = self.task(1)
        other = self.root / "other"
        self.git("worktree", "add", "-q", "--detach", str(other), "main")
        replacement = self.commit(other, "reused name")
        self.git("push", "-q", "-f", "origin", f"{replacement}:refs/heads/{branch}")
        row = self.status("--cleanup-merged")[1]
        self.assertIn("remote branch kept", row["cleanup"])
        self.assertEqual(self.git("ls-remote", "--heads", "origin", branch).split()[0], replacement)

    def test_refuses_cleanup_from_a_scoped_session(self):
        _, path = self.task(1)
        self.scoped = True
        self.state_file.write_text(json.dumps({"prs": self.prs, "workspaces": self.workspaces,
                                               "own": OWN_WORKSPACE, "scoped": True}))
        result = subprocess.run([sys.executable, str(SCRIPT), "--cleanup-merged", "--repo", str(self.repo)],
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("workspace-scoped", result.stderr)
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_skips_ambiguous_workspace_match(self):
        _, path = self.task(1)
        self.workspaces.append(dict(self.workspaces[0], workspaceID="00000000-0000-0000-0000-0000000000ff"))
        row = self.status("--cleanup-merged")[1]
        self.assertIn("several workspaces", row["cleanup"])
        self.assertTrue(path.exists())

    def test_open_pr_is_ready_only_when_checks_and_head_match(self):
        self.task(1, state="OPEN")
        self.task(2, state="OPEN")
        self.prs[-1]["statusCheckRollup"].append({"name": "slow", "status": "IN_PROGRESS", "conclusion": None})
        rows = self.status("--cleanup-merged")
        self.assertEqual(rows[1]["verdict"], "ready")
        self.assertIn("still running: slow", rows[2]["reason"])
        self.assertIsNone(rows[1]["cleanup"])
        self.assertEqual(self.closed(), [])

    def test_open_pr_with_merge_prerequisites_is_blocked(self):
        self.task(1, state="OPEN")
        self.prs[-1]["body"] = "## Summary\nFix.\n\n## Activation order\n1. Rebuild GhosttyKit.\n2. Merge this PR."
        self.task(2, state="OPEN")
        self.prs[-1]["body"] = "Needs https://github.com/other/fork/pull/1 merged first."
        self.task(4, state="OPEN")
        self.prs[-1]["body"] = "Depends on #1"
        self.task(3, state="OPEN")
        self.prs[-1]["body"] = "Follows #1 and https://github.com/test/repo/pull/2; see Test/Repo#2."
        rows = self.status()
        self.assertEqual(rows[1]["verdict"], "blocked")
        self.assertIn("Activation order section", rows[1]["reason"])
        self.assertEqual(rows[2]["verdict"], "blocked")
        self.assertIn("other/fork#1", rows[2]["reason"])
        self.assertIn("user confirms", rows[2]["reason"])
        self.assertEqual(rows[3]["verdict"], "ready")
        self.assertIn("Depends on section", rows[4]["reason"])

    def test_cleanup_refuses_without_toastty(self):
        _, path = self.task(1)
        self.state_file.write_text(json.dumps({"prs": self.prs, "workspaces": [], "own": OWN_WORKSPACE}))
        env = {k: v for k, v in self.env.items() if k != "TOASTTY_CLI_PATH"}
        result = subprocess.run([sys.executable, str(SCRIPT), "--cleanup-merged", "--repo", str(self.repo)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(path.exists())


if __name__ == "__main__":
    unittest.main()
