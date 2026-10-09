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
    if "--head" in args:
        if state.get("fail_branch_pr_query"):
            sys.exit("open PR lookup unavailable")
        if state.get("malformed_branch_pr_query"):
            print("not json")
        else:
            branch = args[args.index("--head") + 1]
            print(json.dumps([p for p in state.get("branch_query_prs", state["prs"])
                              if p["headRefName"] == branch and p["state"] == "OPEN"]))
    else:
        print(json.dumps(state["prs"]))
elif args[:2] == ["pr", "view"]:
    pr = next(p for p in state["prs"] if p["number"] == int(args[2]))
    print(json.dumps({"mergeable": pr["mergeable"], "mergeStateStatus": pr["mergeStateStatus"]}))
else:
    sys.exit(f"unexpected gh call: {args}")
'''

FAKE_TOASTTY = r'''#!/usr/bin/env python3
import json, os, sys, subprocess
state = json.load(open(os.environ["FAKE_STATE"]))
args = sys.argv[1:]
with open(os.environ["FAKE_TOASTTY_LOG"], "a+") as log:
    log.seek(0)
    earlier_lists = log.read().count("workspace.list")
    log.write(" ".join(args) + "\n")
if "workspace.list" in args:
    # "later_workspaces" replaces the list after the first read, as if the user
    # changed a workspace while the script was running.
    workspaces = state.get("later_workspaces") if earlier_lists else None
    if earlier_lists:
        for path, target in state.get("move_on_reread", {}).items():
            subprocess.run(["git", "checkout", "-q", "--detach", target], cwd=path, check=True)
        for path, branch in state.get("attach_on_reread", {}).items():
            subprocess.run(["git", "checkout", "-q", branch], cwd=path, check=True)
        for path in state.get("dirty_on_reread", []):
            open(os.path.join(path, "reread-write.txt"), "w").write("changed\n")
    print(json.dumps({"ok": True, "result": {"workspaces": workspaces if workspaces is not None else state["workspaces"],
                                             "callerIsScoped": state.get("scoped", False)}}))
elif "terminal.state" in args:
    print(json.dumps({"ok": True, "result": {"workspaceID": state["own"]}}))
elif "workspace.close" in args:
    # "dirty_on_close" maps a workspace to a path its dying command writes into.
    target = state.get("dirty_on_close", {}).get(args[args.index("--workspace") + 1])
    if target:
        open(os.path.join(target, "last-write.txt"), "w").write("written while closing\n")
    for path, target in state.get("move_on_close", {}).items():
        subprocess.run(["git", "checkout", "-q", "--detach", target], cwd=path, check=True)
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
        self.extra_state = {}

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
                                               "own": OWN_WORKSPACE, "scoped": self.scoped,
                                               **self.extra_state}))
        result = subprocess.run([sys.executable, str(SCRIPT), "--json", "--repo", str(self.repo), *args],
                                env=env or self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.report = json.loads(result.stdout)
        return {row["pr"]: row for row in self.report["prs"]}

    def closed(self):
        return [line for line in self.log.read_text().splitlines() if "workspace.close" in line] \
            if self.log.exists() else []

    def cleanup_workspace(self, workspace_id, cwd=None, env=None):
        """Runs the hook form from the task directory, as Toastty does, and returns
        (exit status, last line printed)."""
        self.state_file.write_text(json.dumps({"prs": self.prs, "workspaces": self.workspaces,
                                               "own": OWN_WORKSPACE, "scoped": self.scoped,
                                               **self.extra_state}))
        # Exactly what the recorded hook runs: the flag alone, with the ID in
        # the environment and no session identity.
        hook_env = dict(env or self.env, TOASTTY_WORKSPACE_ID=workspace_id)
        if env is None:
            hook_env.pop("TOASTTY_PANEL_ID", None)
        result = subprocess.run([sys.executable, str(SCRIPT), "--cleanup-workspace"],
                                cwd=cwd or self.repo, env=hook_env, capture_output=True, text=True)
        lines = [line for line in (result.stdout + result.stderr).splitlines() if line.strip()]
        return result.returncode, (lines[-1] if lines else "")

    def remote_has(self, branch):
        return bool(self.git("ls-remote", "--heads", "origin", branch))

    def detached_task(self, number, merge=False):
        branch, path = self.task(number)
        head = self.prs[-1]["headRefOid"]
        if merge:
            self.git("merge", "-q", "--no-ff", "-m", f"Merge PR {number}", branch)
            head = self.git("rev-parse", "HEAD")
            self.prs[-1]["mergeCommit"] = {"oid": head}
        self.git("checkout", "-q", "--detach", head, cwd=path)
        self.workspaces[-1]["annotations"] = [
            {"key": "github-pr", "text": f"PR #{number}", "url": self.prs[-1]["url"]}]
        return branch, path

    def test_cleans_detached_worktree_at_pr_head(self):
        branch, path = self.detached_task(1)
        row = self.status("--cleanup-merged")[1]
        self.assertEqual(row["cleanup_head"], row["head"])
        self.assertIn("removed worktree", row["cleanup"])
        self.assertFalse(path.exists())
        self.assertEqual(self.git("branch", "--list", branch), "")
        self.assertFalse(self.remote_has(branch))

    def test_cleans_detached_merge_commit_using_pr_head_for_branch_deletion(self):
        branch, path = self.detached_task(1, merge=True)
        row = self.status("--cleanup-merged")[1]
        self.assertNotEqual(row["cleanup_head"], row["head"])
        self.assertIn("removed worktree", row["cleanup"])
        self.assertFalse(path.exists())
        self.assertEqual(self.git("branch", "--list", branch), "")
        self.assertFalse(self.remote_has(branch))

    def test_detached_cleanup_succeeds_when_both_branches_are_already_absent(self):
        for number, merge in enumerate((False, True), 1):
            branch, path = self.detached_task(number, merge=merge)
            self.git("branch", "-D", branch)
            self.git("push", "-q", "origin", f":refs/heads/{branch}")
            self.log.unlink(missing_ok=True)
            row = self.status("--cleanup-merged")[number]
            self.assertIn("removed worktree", row["cleanup"])
            self.assertIn("local branch already absent", row["cleanup"])
            self.assertNotIn("deleted local branch", row["cleanup"])
            self.assertNotIn("partial:", row["cleanup"])
            self.assertFalse(path.exists())

    def test_branch_worktree_at_merge_commit_stays_blocked(self):
        branch, path = self.detached_task(1, merge=True)
        self.git("branch", "-f", branch, self.prs[-1]["mergeCommit"]["oid"])
        self.git("checkout", "-q", branch, cwd=path)
        row = self.status("--cleanup-merged")[1]
        self.assertEqual(row["verdict"], "blocked")
        self.assertIn("ahead", row["reason"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_detached_primary_checkout_is_never_cleaned(self):
        _, path = self.task(1)
        self.git("checkout", "-q", "--detach", self.prs[-1]["headRefOid"])
        self.workspaces[-1]["terminalCwds"] = [str(self.repo)]
        self.workspaces[-1]["annotations"] = [
            {"key": "github-pr", "url": self.prs[-1]["url"]}]
        self.status("--cleanup-merged")
        primary = next(row for row in self.report["worktreesWithoutPR"]
                       if row["worktree"] == str(self.repo))
        self.assertIn("primary checkout", primary["reason"])
        self.assertTrue(self.repo.exists() and path.exists())
        self.assertEqual(self.closed(), [])

    def test_detached_wrong_head_and_dirty_worktrees_stay_blocked(self):
        _, wrong = self.detached_task(1)
        self.git("checkout", "-q", "--detach", "main", cwd=wrong)
        _, dirty = self.detached_task(2)
        (dirty / "notes.txt").write_text("unsaved\n")
        rows = self.status("--cleanup-merged")
        self.assertEqual(rows[1]["verdict"], "blocked")
        self.assertIn("PR head", rows[1]["reason"])
        self.assertIn("uncommitted", rows[2]["reason"])
        self.assertTrue(wrong.exists() and dirty.exists())
        self.assertEqual(self.closed(), [])

    def test_detached_requires_one_exact_same_repo_chip_for_known_merged_pr(self):
        paths = []
        invalid = [[],
                   [{"key": "github-pr", "text": "PR #2"}],
                   [{"key": "github-pr", "url": "https://github.com/other/repo/pull/3"}],
                   [{"key": "github-pr", "url": "https://github.com/test/repo/pull/4/files"}],
                   [{"key": "github-pr", "url": "https://github.com/test/repo/pull/999"}],
                   [{"key": "github-pr", "url": "https://github.com/test/repo/pull/6"},
                    {"key": "github-pr", "url": "https://github.com/test/repo/pull/7"}],
                   [{"key": "github-pr", "url": "https://github.com/test/repo/pull/7"},
                    {"key": "github-pr", "url": "https://github.com/other/repo/pull/7"}]]
        for number, chips in enumerate(invalid, 1):
            _, path = self.detached_task(number)
            paths.append(path)
            self.workspaces[-1]["annotations"] = chips
        self.status("--cleanup-merged")
        self.assertEqual(len(self.report["worktreesWithoutPR"]), len(paths))
        self.assertTrue(all(row["reason"] for row in self.report["worktreesWithoutPR"]))
        self.assertTrue(all(path.exists() for path in paths))
        self.assertEqual(self.closed(), [])

    def test_detached_open_and_closed_prs_are_never_cleaned(self):
        paths = []
        for number, state in enumerate(("OPEN", "CLOSED"), 1):
            _, path = self.detached_task(number)
            self.prs[-1]["state"] = state
            paths.append(path)
        self.status("--cleanup-merged")
        self.assertEqual(len(self.report["worktreesWithoutPR"]), 2)
        self.assertTrue(all(path.exists() for path in paths))
        self.assertEqual(self.closed(), [])

    def test_detached_ambiguous_workspace_is_not_associated(self):
        _, path = self.detached_task(1)
        self.workspaces.append(dict(self.workspaces[-1], workspaceID="other"))
        self.status("--cleanup-merged")
        self.assertIn("several workspaces", self.report["worktreesWithoutPR"][0]["reason"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_detached_duplicate_pr_chip_in_another_workspace_blocks_association(self):
        _, path = self.detached_task(1)
        self.workspaces.append(dict(self.workspaces[-1], workspaceID="other", terminalCwds=[]))
        self.status("--cleanup-merged")
        self.assertIn("several workspaces", self.report["worktreesWithoutPR"][0]["reason"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_detached_duplicate_pr_chip_on_reread_keeps_worktree(self):
        _, path = self.detached_task(1)
        self.extra_state["later_workspaces"] = self.workspaces + [
            dict(self.workspaces[-1], workspaceID="other", terminalCwds=[])]
        row = self.status("--cleanup-merged")[1]
        self.assertIn("workspace or PR chip changed", row["cleanup"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_branch_worktree_still_accepts_a_text_only_pr_chip(self):
        _, path = self.task(1)
        self.workspaces[-1]["annotations"] = [{"key": "github-pr", "text": "PR #1"}]
        row = self.status("--cleanup-merged")[1]
        self.assertIn("removed worktree", row["cleanup"])
        self.assertFalse(path.exists())

    def test_detached_missing_changed_or_ambiguous_chip_on_reread_keeps_worktree(self):
        # Each scenario gets its own worktree. No scenario closes a workspace.
        for number, annotations in enumerate(([],
                [{"key": "github-pr", "url": "https://github.com/test/repo/pull/999"}],
                [{"key": "github-pr", "url": "https://github.com/test/repo/pull/3"},
                 {"key": "github-pr", "url": "https://github.com/other/repo/pull/3"}]), 1):
            with self.subTest(number=number):
                _, path = self.detached_task(number)
                self.extra_state["later_workspaces"] = [
                    dict(w, annotations=annotations) if w == self.workspaces[-1] else dict(w, annotations=[])
                    for w in self.workspaces]
                # Reset fake Toastty read count for the next complete invocation.
                self.log.unlink(missing_ok=True)
                row = self.status("--cleanup-merged")[number]
                self.assertIn("workspace or PR chip changed", row["cleanup"])
                self.assertTrue(path.exists())
                self.assertEqual(self.closed(), [])

    def test_detached_missing_workspace_on_reread_keeps_worktree(self):
        _, path = self.detached_task(1)
        self.extra_state["later_workspaces"] = []
        row = self.status("--cleanup-merged")[1]
        self.assertIn("workspace or PR chip changed", row["cleanup"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_detached_head_moved_before_close_keeps_workspace(self):
        _, path = self.detached_task(1)
        self.extra_state["move_on_reread"] = {str(path): "main"}
        row = self.status("--cleanup-merged")[1]
        self.assertIn("HEAD moved", row["cleanup"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_detached_state_changed_before_close_keeps_workspace(self):
        branch, path = self.detached_task(1)
        self.extra_state["attach_on_reread"] = {str(path): branch}
        row = self.status("--cleanup-merged")[1]
        self.assertIn("detached state changed", row["cleanup"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_detached_dirty_before_close_keeps_workspace(self):
        _, path = self.detached_task(1)
        self.extra_state["dirty_on_reread"] = [str(path)]
        row = self.status("--cleanup-merged")[1]
        self.assertIn("uncommitted changes", row["cleanup"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_detached_head_moved_after_close_keeps_worktree_and_branches(self):
        branch, path = self.detached_task(1)
        self.extra_state["move_on_close"] = {str(path): "main"}
        row = self.status("--cleanup-merged")[1]
        self.assertIn("partial:", row["cleanup"])
        self.assertIn("HEAD moved", row["cleanup"])
        self.assertTrue(path.exists())
        self.assertNotEqual(self.git("branch", "--list", branch), "")
        self.assertTrue(self.remote_has(branch))

    def test_detached_cleanup_preserves_branches_checked_out_elsewhere(self):
        branch, path = self.detached_task(1, merge=True)
        other = self.root / "other"
        self.git("worktree", "add", "-q", str(other), branch)
        row = self.status("--cleanup-merged")[1]
        self.assertIn("branches kept: branch is checked out", row["cleanup"])
        self.assertFalse(path.exists())
        self.assertEqual(self.git("rev-parse", f"refs/heads/{branch}"), self.prs[0]["headRefOid"])
        self.assertTrue(self.remote_has(branch))
        self.assertTrue(other.exists())

    def test_detached_default_pr_head_branch_is_kept(self):
        _, path = self.detached_task(1)
        self.prs[-1]["headRefName"] = "main"
        self.git("checkout", "-q", "--detach")
        self.git("branch", "-f", "main", self.prs[-1]["headRefOid"])
        self.git("push", "-q", "origin", "main")
        row = self.status("--cleanup-merged")[1]
        self.assertIn("PR head branch is the default branch", row["cleanup"])
        self.assertFalse(path.exists())
        self.assertEqual(self.git("rev-parse", "refs/heads/main"), self.prs[0]["headRefOid"])
        self.assertTrue(self.remote_has("main"))

    def test_detached_shared_head_branch_is_kept_after_fresh_open_pr_query(self):
        branch, path = self.detached_task(1)
        # This open PR is absent from the initial list and appears only on the
        # final branch query, as if it was opened while cleanup ran.
        other = dict(self.prs[-1], number=2, state="OPEN")
        self.extra_state["branch_query_prs"] = [other]
        row = self.status("--cleanup-merged")[1]
        self.assertIn("another open PR uses the head branch", row["cleanup"])
        self.assertFalse(path.exists())
        self.assertEqual(self.git("rev-parse", f"refs/heads/{branch}"), self.prs[0]["headRefOid"])
        self.assertTrue(self.remote_has(branch))

    def test_detached_open_pr_lookup_failure_keeps_branches(self):
        for number, failure in enumerate(("fail_branch_pr_query", "malformed_branch_pr_query"), 1):
            branch, path = self.detached_task(number)
            self.extra_state.pop("fail_branch_pr_query", None)
            self.extra_state[failure] = True
            self.log.unlink(missing_ok=True)
            row = self.status("--cleanup-merged")[number]
            self.assertIn("could not check open PRs", row["cleanup"])
            self.assertFalse(path.exists())
            self.assertNotEqual(self.git("branch", "--list", branch), "")
            self.assertTrue(self.remote_has(branch))

    def test_primary_feature_branch_still_reports_its_pr(self):
        branch, path = self.task(1, state="OPEN")
        self.git("checkout", "-q", "--detach", cwd=path)
        self.git("checkout", "-q", branch)
        self.workspaces[-1]["terminalCwds"] = [str(self.repo)]
        row = self.status()[1]
        self.assertEqual(row["worktree"], str(self.repo))
        self.assertEqual(row["verdict"], "ready")
        self.assertEqual(self.closed(), [])

    def test_branch_with_same_named_tag_still_cleans(self):
        branch, path = self.task(1)
        self.git("tag", branch)
        row = self.status("--cleanup-merged")[1]
        self.assertIn("removed worktree", row["cleanup"])
        self.assertFalse(path.exists())

    def test_branch_changed_to_detached_before_close_is_kept(self):
        branch, path = self.task(1)
        self.extra_state["move_on_reread"] = {str(path): f"refs/heads/{branch}"}
        row = self.status("--cleanup-merged")[1]
        self.assertIn("detached state changed", row["cleanup"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_other_pr_chips_block_cleanup_with_noncanonical_url_forms(self):
        forms = ("http://github.com/test/repo/pull/9",
                 "https://www.github.com/test/repo/pull/9",
                 "github.com/test/repo/pull/9",
                 "http://github.com/other/repo/pull/1")
        paths = []
        for number, url in enumerate(forms, 1):
            _, path = self.task(number)
            self.workspaces[-1]["annotations"] = [{"key": "github-pr", "url": url}]
            paths.append(path)
        rows = self.status("--cleanup-merged")
        self.assertTrue(all("different PR" in row["cleanup"] for row in rows.values()))
        self.assertTrue(all(path.exists() for path in paths))
        self.assertEqual(self.closed(), [])

    def test_local_branch_read_failure_keeps_both_branches(self):
        branch, path = self.detached_task(1)
        real_git = subprocess.run(["which", "git"], check=True, capture_output=True, text=True).stdout.strip()
        fake_git = self.root / "bin" / "git"
        fake_git.write_text("#!/usr/bin/env python3\nimport os, sys\n"
                            "if sys.argv[1:2] == ['for-each-ref']: sys.exit('ref read failed')\n"
                            f"os.execv({real_git!r}, [{real_git!r}] + sys.argv[1:])\n")
        fake_git.chmod(0o755)
        row = self.status("--cleanup-merged")[1]
        self.assertIn("could not read the local branch", row["cleanup"])
        self.assertFalse(path.exists())
        self.assertNotEqual(self.git("branch", "--list", branch), "")
        self.assertTrue(self.remote_has(branch))

    def test_cross_repo_chip_prevents_branch_worktree_cleanup(self):
        _, path = self.task(1)
        self.workspaces[-1]["annotations"] = [
            {"key": "github-pr", "url": "https://github.com/other/repo/pull/1"}]
        row = self.status("--cleanup-merged")[1]
        self.assertIn("different PR", row["cleanup"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

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

    def test_closes_workspace_with_live_sessions_and_reports_what_ended(self):
        branch, with_sessions = self.task(1, session=True, busy=True)
        self.workspaces[-1]["activeSessions"].append({"sessionID": "s2", "agent": "codex", "panelID": "p2"})
        _, busy = self.task(2, busy=True)
        rows = self.status("--cleanup-merged")
        self.assertIn("closed task-1", rows[1]["cleanup"])
        self.assertIn("ending 2 agent sessions (1 claude, 1 codex) and 1 terminal running a command, counting agent terminals",
                      rows[1]["cleanup"])
        self.assertIn("ending 1 terminal running a command", rows[2]["cleanup"])
        self.assertFalse(with_sessions.exists() or busy.exists())
        self.assertFalse(self.remote_has(branch))
        self.assertEqual(len(self.closed()), 2)

    def test_cleanup_workspace_cleans_one_merged_task_from_its_directory(self):
        branch, path = self.task(1, session=True)
        _, other = self.task(2)
        status, detail = self.cleanup_workspace(self.workspaces[0]["workspaceID"], cwd=path)
        self.assertEqual(status, 0, detail)
        self.assertIn("removed worktree", detail)
        self.assertFalse(path.exists())
        self.assertTrue(other.exists(), "only the named workspace is cleaned")
        self.assertEqual(self.git("branch", "--list", branch), "")
        self.assertFalse(self.remote_has(branch))
        self.assertEqual(len(self.closed()), 1)

    def test_cleanup_workspace_skips_unmerged_dirty_and_unknown_tasks_with_exit_3(self):
        _, open_path = self.task(1, state="OPEN")
        _, dirty = self.task(2)
        (dirty / "notes.txt").write_text("unsaved\n")
        status, detail = self.cleanup_workspace(self.workspaces[0]["workspaceID"], cwd=open_path)
        self.assertEqual(status, 3)
        self.assertIn("PR #1 is open", detail)
        status, detail = self.cleanup_workspace(self.workspaces[1]["workspaceID"], cwd=dirty)
        self.assertEqual(status, 3)
        self.assertIn("uncommitted", detail)
        status, detail = self.cleanup_workspace("00000000-0000-0000-0000-0000000000ff")
        self.assertEqual(status, 3)
        self.assertIn("no task worktree matches", detail)
        self.assertTrue(open_path.exists() and dirty.exists())
        self.assertEqual(self.closed(), [])

    def test_cleanup_workspace_reports_a_partial_as_failure(self):
        branch, path = self.task(1, session=True)
        self.extra_state["dirty_on_close"] = {self.workspaces[-1]["workspaceID"]: str(path)}
        status, detail = self.cleanup_workspace(self.workspaces[0]["workspaceID"], cwd=path)
        self.assertEqual(status, 1, detail)
        self.assertIn("closed task-1", detail)
        self.assertIn("worktree kept", detail)
        self.assertTrue(path.exists())

    def test_cleanup_workspace_keeps_the_cleanup_merged_guards_for_hand_runs(self):
        """An agent running the hook form itself gets the same refusals as
        --cleanup-merged: never its own workspace, never from a partial list."""
        _, path = self.task(1)
        own = self.workspaces[0]["workspaceID"]
        self.extra_state["own"] = own
        status, detail = self.cleanup_workspace(own, cwd=path, env=dict(self.env, TOASTTY_PANEL_ID="own-panel"))
        self.assertEqual(status, 3)
        self.assertIn("own workspace", detail)
        self.scoped = True
        status, detail = self.cleanup_workspace(own, cwd=path)
        self.assertEqual(status, 3)
        self.assertIn("workspace-scoped", detail)
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_cleanup_workspace_accepts_an_explicit_id_and_a_separate_git_dir(self):
        branch, path = self.task(1)
        # A clone with its Git directory elsewhere, as `git clone --separate-git-dir` makes.
        separate = self.root / "separate"
        subprocess.run(["git", "clone", "-q", "--separate-git-dir", str(self.root / "separate.git"),
                        str(self.origin), str(separate)], check=True, capture_output=True)
        self.git("config", "user.name", "Cleanup Test", cwd=separate)
        self.git("config", "user.email", "cleanup@example.invalid", cwd=separate)
        task_path = self.root / "separate-task"
        self.git("worktree", "add", "-q", "-b", "separate-task", str(task_path), cwd=separate)
        head = self.commit(task_path, "separate-task")
        self.git("push", "-q", "-u", "origin", "separate-task", cwd=task_path)
        self.prs.append(dict(self.prs[-1], number=2, title="separate-task", headRefName="separate-task", headRefOid=head,
                             url="https://github.com/test/repo/pull/2"))
        self.workspaces.append(dict(self.workspaces[-1], workspaceID="00000000-0000-0000-0000-000000000002",
                                    title="separate-task", terminalCwds=[str(task_path)]))
        self.state_file.write_text(json.dumps({"prs": self.prs, "workspaces": self.workspaces, "own": OWN_WORKSPACE,
                                               "scoped": False}))
        result = subprocess.run([sys.executable, str(SCRIPT), "--cleanup-workspace", "00000000-0000-0000-0000-000000000002"],
                                cwd=task_path, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(task_path.exists())
        self.assertTrue(path.exists(), "the other repository's task is untouched")

    def test_keeps_worktree_a_closed_session_dirtied(self):
        branch, path = self.task(1, session=True)
        self.extra_state["dirty_on_close"] = {self.workspaces[-1]["workspaceID"]: str(path)}
        row = self.status("--cleanup-merged")[1]
        self.assertTrue(row["cleanup"].startswith("partial: closed task-1"), row["cleanup"])
        self.assertIn("worktree kept", row["cleanup"])
        self.assertTrue((path / "last-write.txt").exists())
        self.assertNotEqual(self.git("branch", "--list", branch), "")
        self.assertTrue(self.remote_has(branch))

    def test_rereads_workspaces_before_closing(self):
        _, path = self.task(1)
        self.extra_state["later_workspaces"] = [dict(self.workspaces[-1], unsavedDocumentCount=1)]
        row = self.status("--cleanup-merged")[1]
        self.assertIn("unsaved document", row["cleanup"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_skips_the_callers_own_workspace(self):
        _, own = self.task(1, session=True)
        self.workspaces[-1]["workspaceID"] = OWN_WORKSPACE
        row = self.status("--cleanup-merged")[1]
        self.assertIn("own workspace", row["cleanup"])
        self.assertTrue(own.exists())
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
