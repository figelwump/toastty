#!/usr/bin/env python3
"""Tests for the Merge button's pull request script. Disposable Git repositories
with a fake gh and a fake Toastty CLI; never contacts GitHub or a running Toastty.

Run: python3 Tests/Scripts/test_workspace_pull_request.py
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).resolve().parents[2] / "Sources/App/Resources/workspace-pull-request.py"

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
state_path = os.environ["FAKE_STATE"]
state = json.load(open(state_path))
args = sys.argv[1:]

def log():
    # Logged with the Toastty calls, so tests can check the order of changes.
    with open(os.environ["FAKE_TOASTTY_LOG"], "a") as out:
        out.write("gh " + " ".join(args) + "\n")

def save():
    json.dump(state, open(state_path, "w"))

if args[:2] == ["repo", "view"]:
    print(json.dumps({"nameWithOwner": "test/repo", "defaultBranchRef": {"name": "main"},
                      "mergeCommitAllowed": state.get("merge_commit_allowed", True),
                      "squashMergeAllowed": True, "rebaseMergeAllowed": True}))
elif args[:2] == ["pr", "view"]:
    print(json.dumps(next(p for p in state["prs"] if p["number"] == int(args[2]))))
elif args[:2] == ["pr", "close"]:
    log()
    if state.get("fail_pr_close"):
        sys.exit("GraphQL: could not close pull request")
    # "after_pr_close" replaces the workspace list, as if the user changed a
    # workspace while gh was closing the PR.
    if "after_pr_close" in state:
        state["workspaces"] = state.pop("after_pr_close")
        save()
elif args[:2] == ["pr", "ready"]:
    log()
    next(p for p in state["prs"] if p["number"] == int(args[2]))["isDraft"] = False
    save()
elif args[:2] == ["pr", "merge"]:
    log()
    pr = next(p for p in state["prs"] if p["number"] == int(args[2]))
    if args[args.index("--match-head-commit") + 1] != pr["headRefOid"]:
        sys.exit("Head branch was modified")
    if "--auto" in args:
        if state.pop("clean_status_on_auto", False):
            save()
            sys.exit("GraphQL: Pull request Pull request is in clean status (enablePullRequestAutoMerge)")
        pr["autoMergeRequest"] = {"enabledAt": "now"}
    else:
        pr["state"] = "MERGED"
    save()
else:
    sys.exit(f"unexpected gh call: {args}")
'''

FAKE_TOASTTY = r'''#!/usr/bin/env python3
import json, os, sys
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
    print(json.dumps({"ok": True, "result": {"workspaces": workspaces or state["workspaces"],
                                             "callerIsScoped": state.get("scoped", False)}}))
elif "workspace.close" in args:
    # "dirty_on_close" maps a workspace to a path its dying command writes into.
    target = state.get("dirty_on_close", {}).get(args[args.index("--workspace") + 1])
    if target:
        open(os.path.join(target, "last-write.txt"), "w").write("written while closing\n")
    print(json.dumps({"ok": True, "result": {}}))
else:
    sys.exit(f"unexpected toastty call: {args}")
'''


def workspace_id(number):
    return f"00000000-0000-0000-0000-{number:012d}"


class WorkspacePullRequestTests(unittest.TestCase):
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
                        FAKE_TOASTTY_LOG=str(self.log), TOASTTY_CLI_PATH=str(bin_dir / "toastty"))
        self.prs, self.workspaces = [], []
        self.extra_state = {}

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.repo, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, cwd, message):
        (Path(cwd) / "file.txt").write_text(message + "\n")
        self.git("add", "file.txt", cwd=cwd)
        self.git("commit", "-q", "-m", message, cwd=cwd)
        return self.git("rev-parse", "HEAD", cwd=cwd)

    def task(self, number, state="MERGED", session=False, busy=False, done=True):
        """A pushed task branch and worktree with a PR whose head is the pushed tip,
        and a subspace whose terminal sits in the worktree."""
        branch, path = f"task-{number}", self.root / f"task-{number}"
        self.git("worktree", "add", "-q", "-b", branch, str(path))
        head = self.commit(path, branch)
        self.git("push", "-q", "-u", "origin", branch, cwd=path)
        self.prs.append({
            "number": number, "state": state, "isDraft": False, "headRefName": branch,
            "headRefOid": head, "baseRefName": "main", "isCrossRepository": False,
            "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "url": f"https://github.com/test/repo/pull/{number}",
            "statusCheckRollup": [{"name": "CI gate", "status": "COMPLETED", "conclusion": "SUCCESS"}],
            "body": "", "autoMergeRequest": None,
        })
        self.workspaces.append({
            "workspaceID": workspace_id(number), "title": branch,
            "terminalCwds": [str(path)], "annotations": [], "done": done,
            "activeSessions": [{"sessionID": "s", "agent": "claude", "panelID": "p"}] if session else [],
            "busyTerminalCount": 1 if busy else 0, "unsavedDocumentCount": 0,
        })
        return branch, path

    def run_script(self, action, number, url=None, workspace=None, repo=None, env=None):
        """Runs the script as Toastty does, from the workspace's checkout: the
        task's worktree unless `repo` says otherwise."""
        self.state_file.write_text(json.dumps({"prs": self.prs, "workspaces": self.workspaces,
                                               **self.extra_state}))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), action, "--pr", str(number),
             "--pr-url", url or f"https://github.com/test/repo/pull/{number}",
             "--workspace", workspace or workspace_id(number), "--repo", str(repo or self.root / f"task-{number}")],
            env=env or self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def gh_state(self, number):
        return next(p for p in json.loads(self.state_file.read_text())["prs"] if p["number"] == number)

    def actions(self):
        """Every change the script made, in order: gh writes and workspace closes."""
        return [line for line in self.log.read_text().splitlines() if "workspace.list" not in line] \
            if self.log.exists() else []

    def closed(self):
        return [line for line in self.actions() if "workspace.close" in line]

    def remote_has(self, branch):
        return bool(self.git("ls-remote", "--heads", "origin", branch))

    # MARK: - Merge

    def test_merge_merges_a_clean_pr_at_the_worktree_head(self):
        _, path = self.task(1, state="OPEN")
        result = self.run_script("merge", 1)
        self.assertEqual(result["status"], "merged", result)
        head = self.prs[0]["headRefOid"]
        self.assertEqual(self.actions(), [f"gh pr merge 1 --merge --match-head-commit {head}"])
        self.assertTrue(path.exists())

    def test_merge_turns_on_auto_merge_while_checks_run(self):
        self.task(1, state="OPEN")
        self.prs[0]["statusCheckRollup"].append({"name": "slow", "status": "IN_PROGRESS", "conclusion": None})
        self.prs[0]["mergeStateStatus"] = "BLOCKED"
        result = self.run_script("merge", 1)
        self.assertEqual(result["status"], "queued", result)
        self.assertIn("--auto", self.actions()[0])
        self.assertEqual(self.gh_state(1)["state"], "OPEN")

    def test_merge_merges_directly_when_github_will_not_queue_a_clean_pr(self):
        self.task(1, state="OPEN")
        self.prs[0]["mergeStateStatus"] = "BLOCKED"
        self.extra_state["clean_status_on_auto"] = True
        result = self.run_script("merge", 1)
        self.assertEqual(result["status"], "merged", result)
        self.assertEqual(len(self.actions()), 2)
        self.assertNotIn("--auto", self.actions()[1])

    def test_merge_marks_a_draft_ready_and_uses_an_allowed_method(self):
        self.task(1, state="OPEN")
        self.prs[0]["isDraft"] = True
        self.prs[0]["mergeStateStatus"] = "DRAFT"
        self.extra_state["merge_commit_allowed"] = False
        result = self.run_script("merge", 1)
        self.assertEqual(result["status"], "queued", result)
        actions = self.actions()
        self.assertEqual(actions[0], "gh pr ready 1")
        self.assertIn("--squash", actions[1])

    def test_merge_refuses_without_changes_when_the_pr_is_not_the_accepted_version(self):
        _, dirty = self.task(1, state="OPEN")
        (dirty / "notes.txt").write_text("unsaved\n")
        _, ahead = self.task(2, state="OPEN")
        self.commit(ahead, "local only")
        self.task(3, state="OPEN")
        self.prs[-1]["statusCheckRollup"].append({"name": "lint", "status": "COMPLETED", "conclusion": "FAILURE"})
        self.task(4, state="OPEN")
        self.prs[-1]["mergeable"] = "CONFLICTING"
        self.task(5, state="OPEN")
        self.prs[-1]["baseRefName"] = "task-1"
        expected = {1: "uncommitted changes", 2: "1 commits ahead", 3: "failing checks: lint",
                    4: "merge conflicts", 5: "targets task-1, not main"}
        for number, reason in expected.items():
            result = self.run_script("merge", number)
            self.assertEqual(result["status"], "refused", result)
            self.assertIn(reason, result["detail"])
        result = self.run_script("merge", 3, url="https://github.com/other/repo/pull/3")
        self.assertIn("is not this repository's PR #3", result["detail"])
        self.assertEqual(self.actions(), [])

    def test_merge_refuses_a_pr_whose_description_lists_prerequisites(self):
        self.task(1, state="OPEN")
        self.prs[-1]["body"] = "## Summary\nFix.\n\n## Activation order\n1. Rebuild GhosttyKit.\n2. Merge this PR."
        self.task(2, state="OPEN")
        self.prs[-1]["body"] = "Needs https://github.com/other/fork/pull/1 merged first."
        self.task(3, state="OPEN")
        self.prs[-1]["body"] = "Follows #1 and https://github.com/test/repo/pull/2; see Test/Repo#2."
        self.assertIn("Activation order section", self.run_script("merge", 1)["detail"])
        self.assertIn("other/fork#1", self.run_script("merge", 2)["detail"])
        self.assertEqual(self.run_script("merge", 3)["status"], "merged")

    def test_merge_reports_an_already_merged_pr_only_at_the_worktree_head(self):
        self.task(1)
        self.assertEqual(self.run_script("merge", 1)["status"], "merged")
        _, ahead = self.task(2)
        self.commit(ahead, "new work")
        result = self.run_script("merge", 2)
        self.assertEqual(result["status"], "refused", result)
        self.assertIn("ahead", result["detail"])
        self.assertEqual(self.actions(), [])

    def test_merge_refuses_from_another_tasks_checkout(self):
        self.task(1, state="OPEN")
        _, other = self.task(2, state="OPEN")
        # The workspace in task-2's worktree carries a stale annotation for PR #1.
        result = self.run_script("merge", 1, repo=other)
        self.assertEqual(result["status"], "refused", result)
        self.assertIn("not the worktree of PR #1", result["detail"])
        self.assertEqual(self.actions(), [])

    def test_merge_refuses_when_git_cannot_read_the_worktree_status(self):
        _, path = self.task(1, state="OPEN")
        index = self.repo / ".git" / "worktrees" / "task-1" / "index"
        index.chmod(0)
        self.addCleanup(index.chmod, 0o644)
        result = self.run_script("merge", 1)
        self.assertEqual(result["status"], "refused", result)
        self.assertIn("could not read the worktree status", result["detail"])
        self.assertEqual(self.actions(), [])

    # MARK: - Clean up

    def test_cleanup_closes_the_workspace_and_removes_the_worktree_and_branches(self):
        branch, path = self.task(1)
        result = self.run_script("clean-up", 1)
        self.assertEqual(result["status"], "cleaned", result)
        self.assertIn("removed worktree", result["detail"])
        self.assertFalse(path.exists())
        self.assertEqual(self.git("branch", "--list", branch), "")
        self.assertFalse(self.remote_has(branch))
        self.assertEqual(len(self.closed()), 1)

    def test_cleanup_refuses_an_unmerged_pr_or_a_worktree_with_local_work(self):
        _, open_pr = self.task(1, state="OPEN")
        _, dirty = self.task(2)
        (dirty / "notes.txt").write_text("unsaved\n")
        _, ahead = self.task(3)
        self.commit(ahead, "local only")
        self.assertIn("has not merged", self.run_script("clean-up", 1)["detail"])
        self.assertIn("uncommitted", self.run_script("clean-up", 2)["detail"])
        self.assertIn("ahead", self.run_script("clean-up", 3)["detail"])
        self.assertTrue(open_pr.exists() and dirty.exists() and ahead.exists())
        self.assertEqual(self.actions(), [])

    def test_cleanup_reports_the_sessions_and_commands_it_ended(self):
        _, path = self.task(1, session=True, busy=True)
        self.workspaces[-1]["activeSessions"].append({"sessionID": "s2", "agent": "codex", "panelID": "p2"})
        result = self.run_script("clean-up", 1)
        self.assertIn("ending 2 agent sessions (1 claude, 1 codex) and 1 terminal running a command, "
                      "counting agent terminals", result["detail"])
        self.assertFalse(path.exists())

    def test_cleanup_keeps_a_worktree_a_closed_session_dirtied(self):
        branch, path = self.task(1, session=True)
        self.extra_state["dirty_on_close"] = {workspace_id(1): str(path)}
        result = self.run_script("clean-up", 1)
        self.assertEqual(result["status"], "partial", result)
        self.assertIn("worktree kept", result["detail"])
        self.assertTrue((path / "last-write.txt").exists())
        self.assertNotEqual(self.git("branch", "--list", branch), "")
        self.assertTrue(self.remote_has(branch))

    def test_cleanup_rereads_the_workspace_before_closing_it(self):
        _, path = self.task(1)
        self.extra_state["later_workspaces"] = [dict(self.workspaces[-1], unsavedDocumentCount=1)]
        result = self.run_script("clean-up", 1)
        self.assertEqual(result["status"], "stopped", result)
        self.assertIn("unsaved document", result["detail"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_cleanup_needs_the_named_workspace_still_marked_done(self):
        _, path = self.task(1, done=False)
        self.assertIn("no longer marked done", self.run_script("clean-up", 1)["detail"])
        self.workspaces[-1]["done"] = True
        result = self.run_script("clean-up", 1, workspace=workspace_id(99))
        self.assertIn("matching workspace is not", result["detail"])
        self.extra_state["later_workspaces"] = [dict(self.workspaces[-1], done=False)]
        self.assertIn("no longer marked done", self.run_script("clean-up", 1)["detail"])
        self.assertTrue(path.exists())
        self.assertEqual(self.closed(), [])

    def test_cleanup_skips_unsafe_workspaces(self):
        _, unsaved = self.task(1)
        self.workspaces[-1]["unsavedDocumentCount"] = 1
        _, shared = self.task(2)
        self.workspaces[-1]["terminalCwds"].append(str(self.repo))
        _, chipped = self.task(3)
        self.workspaces[-1]["annotations"] = [
            {"key": "github-pr", "text": "PR #9", "url": "https://github.com/test/repo/pull/9/files"}]
        _, other_repo = self.task(6)
        self.workspaces[-1]["annotations"] = [
            {"key": "github-pr", "text": "PR #6", "url": "https://github.com/other/repo/pull/6"}]
        _, locked = self.task(4)
        self.git("worktree", "lock", str(locked))
        _, ambiguous = self.task(5)
        self.workspaces.append(dict(self.workspaces[-1], workspaceID=workspace_id(55)))
        expected = {1: "unsaved document", 2: "another worktree", 3: "different PR", 4: "locked",
                    5: "several workspaces", 6: "different PR"}
        for number, reason in expected.items():
            result = self.run_script("clean-up", number)
            self.assertEqual(result["status"], "skipped", result)
            self.assertIn(reason, result["detail"])
        self.assertTrue(all(p.exists() for p in (unsaved, shared, chipped, locked, ambiguous, other_repo)))
        self.assertEqual(self.closed(), [])

    def test_cleanup_refuses_a_partial_workspace_list(self):
        _, path = self.task(1)
        self.extra_state["scoped"] = True
        self.assertIn("full Toastty workspace list", self.run_script("clean-up", 1)["detail"])
        env = {k: v for k, v in self.env.items() if k != "TOASTTY_CLI_PATH"}
        self.assertIn("TOASTTY_CLI_PATH", self.run_script("clean-up", 1, env=env)["detail"])
        self.assertTrue(path.exists())

    def test_cleanup_matches_a_workspace_through_a_path_alias(self):
        _, path = self.task(1)
        alias = self.root / "alias"
        alias.symlink_to(path)
        self.workspaces[-1]["terminalCwds"] = [str(alias)]
        self.assertEqual(self.run_script("clean-up", 1)["status"], "cleaned")
        self.assertFalse(path.exists())

    def test_cleanup_keeps_a_remote_branch_recreated_at_another_commit(self):
        branch, _ = self.task(1)
        other = self.root / "other"
        self.git("worktree", "add", "-q", "--detach", str(other), "main")
        replacement = self.commit(other, "reused name")
        self.git("push", "-q", "-f", "origin", f"{replacement}:refs/heads/{branch}")
        result = self.run_script("clean-up", 1)
        self.assertEqual(result["status"], "partial", result)
        self.assertIn("remote branch kept", result["detail"])
        self.assertEqual(self.git("ls-remote", "--heads", "origin", branch).split()[0], replacement)

    def test_cleanup_with_an_unreachable_origin_is_partial(self):
        branch, path = self.task(1)
        self.git("remote", "set-url", "origin", str(self.root / "missing.git"))
        result = self.run_script("clean-up", 1)
        self.assertEqual(result["status"], "partial", result)
        self.assertIn("could not query origin", result["detail"])
        self.assertFalse(path.exists())
        self.git("remote", "set-url", "origin", str(self.origin))
        self.assertTrue(self.remote_has(branch))

    def test_cleanup_runs_from_the_worktree_being_removed(self):
        branch, path = self.task(1)
        result = self.run_script("clean-up", 1, repo=path)
        self.assertEqual(result["status"], "cleaned", result)
        self.assertFalse(path.exists())
        self.assertEqual(self.git("branch", "--list", branch), "")

    # MARK: - Close

    def test_close_closes_the_pr_then_cleans_up_but_keeps_the_remote_branch(self):
        branch, path = self.task(1, state="OPEN", session=True, done=False)
        result = self.run_script("close", 1)
        self.assertEqual(result["status"], "cleaned", result)
        self.assertIn("closed PR #1", result["detail"])
        self.assertIn("kept the branch on GitHub", result["detail"])
        actions = self.actions()
        self.assertEqual(actions[0], "gh pr close 1")
        self.assertIn("workspace.close", actions[1])
        self.assertFalse(path.exists())
        self.assertEqual(self.git("branch", "--list", branch), "")
        self.assertTrue(self.remote_has(branch))

    def test_close_changes_nothing_when_work_exists_only_locally(self):
        _, dirty = self.task(1, state="OPEN")
        (dirty / "notes.txt").write_text("unsaved\n")
        _, ahead = self.task(2, state="OPEN")
        self.commit(ahead, "local only")
        for number in (1, 2):
            self.assertEqual(self.run_script("close", number)["status"], "skipped")
        self.assertEqual(self.actions(), [])
        self.assertTrue(dirty.exists() and ahead.exists())

    def test_close_checks_the_workspace_before_closing_the_pr(self):
        _, path = self.task(1, state="OPEN")
        self.workspaces[-1]["unsavedDocumentCount"] = 1
        self.assertIn("unsaved document changes", self.run_script("close", 1)["detail"])
        self.workspaces[-1]["unsavedDocumentCount"] = 0
        result = self.run_script("close", 1, workspace=workspace_id(99))
        self.assertIn("matching workspace is not", result["detail"])
        self.assertEqual(self.actions(), [])
        self.assertTrue(path.exists())

    def test_close_keeps_a_workspace_that_changed_while_the_pr_closed(self):
        _, path = self.task(1, state="OPEN")
        self.extra_state["after_pr_close"] = [dict(self.workspaces[-1], unsavedDocumentCount=1)]
        result = self.run_script("close", 1)
        self.assertEqual(result["status"], "partial", result)
        self.assertIn("closed PR #1", result["detail"])
        self.assertIn("unsaved document changes; workspace kept", result["detail"])
        self.assertEqual(self.closed(), [])
        self.assertTrue(path.exists())

    def test_close_refuses_a_pr_url_from_another_repository(self):
        _, path = self.task(1, state="OPEN")
        result = self.run_script("close", 1, url="https://github.com/other/repo/pull/1")
        self.assertEqual(result["status"], "skipped")
        self.assertIn("is not this repository's PR #1", result["detail"])
        self.assertEqual(self.actions(), [])
        self.assertTrue(path.exists())

    def test_close_keeps_the_local_branch_when_github_lost_it(self):
        branch, path = self.task(1, state="CLOSED")
        self.git("push", "-q", "origin", "--delete", branch)
        result = self.run_script("close", 1)
        self.assertEqual(result["status"], "skipped")
        self.assertIn("only copy of the work", result["detail"])
        self.assertEqual(self.actions(), [])
        self.assertTrue(path.exists())
        self.assertNotEqual(self.git("branch", "--list", branch), "")

    def test_close_stops_when_gh_cannot_close_the_pr(self):
        _, path = self.task(1, state="OPEN")
        self.extra_state["fail_pr_close"] = True
        result = self.run_script("close", 1)
        self.assertEqual(result["status"], "stopped")
        self.assertIn("could not close PR #1", result["detail"])
        self.assertEqual(self.closed(), [])
        self.assertTrue(path.exists())

    def test_close_refuses_a_merged_pr_and_cleans_up_an_already_closed_one(self):
        _, merged = self.task(1)
        self.assertIn("has merged", self.run_script("close", 1)["detail"])
        self.assertTrue(merged.exists())
        branch, closed = self.task(2, state="CLOSED")
        result = self.run_script("close", 2)
        self.assertEqual(result["status"], "cleaned", result)
        self.assertNotIn("closed PR", result["detail"])
        self.assertFalse(closed.exists())
        self.assertTrue(self.remote_has(branch))
        self.assertFalse(any(line.startswith("gh pr close") for line in self.actions()))


if __name__ == "__main__":
    unittest.main()
