#!/usr/bin/env python3
"""Local disposable Git repositories and a fake gh; never contacts GitHub."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name("tasks.py")


class TaskQueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Queue Test")
        self.git("config", "user.email", "queue@example.invalid")
        (self.repo / "product.txt").write_text("base\n")
        self.git("add", "product.txt")
        self.git("commit", "-m", "base")
        self.base = self.git("rev-parse", "HEAD")
        self.git("remote", "add", "origin", "https://github.com/test/repo.git")
        self.state = self.root / "state"
        self.worktree = self.root / "child"
        self.git("worktree", "add", "-b", "task-one", str(self.worktree))
        (self.worktree / "product.txt").write_text("task\n")
        self.git("add", "product.txt", cwd=self.worktree)
        self.git("commit", "-m", "task", cwd=self.worktree)
        self.tip = self.git("rev-parse", "HEAD", cwd=self.worktree)
        self.prfile = self.root / "pr.json"
        self.pr = {"url": "https://github.com/test/repo/pull/1", "number": 1,
                   "state": "OPEN", "isDraft": False, "headRefOid": self.tip,
                   "headRefName": "task-one", "baseRefName": "main", "baseRefOid": self.base,
                   "mergeCommit": None, "statusCheckRollup": [], "reviewDecision": "APPROVED",
                   "mergeStateStatus": "CLEAN"}
        self.write_pr()
        fakebin = self.root / "bin"
        fakebin.mkdir()
        gh = fakebin / "gh"
        gh.write_text(f"#!{sys.executable}\nimport os,sys,time,json\nfrom pathlib import Path\n"
                      "if os.environ.get('QUEUE_GH_FAIL'): sys.exit(7)\n"
                      "if os.environ.get('QUEUE_GH_FAIL_PR') == sys.argv[3]: sys.exit(7)\n"
                      "if os.environ.get('QUEUE_GH_SLEEP'): time.sleep(5)\n"
                      "assert sys.argv[1:3] == ['pr', 'view']\n"
                      "assert sys.argv[sys.argv.index('--repo')+1] == 'github.com/test/repo'\n"
                      "if os.environ.get('QUEUE_GH_CALL_LOG'):\n"
                      " with Path(os.environ['QUEUE_GH_CALL_LOG']).open('a') as log: log.write('called\\n')\n"
                      "value=json.loads(Path(os.environ['QUEUE_PR_FIXTURE']).read_text())\n"
                      "print(json.dumps(value.get('_prs', {}).get(sys.argv[3], value)))\n")
        gh.chmod(0o700)
        git = fakebin / "git"
        git.write_text(f"#!{sys.executable}\nimport os,sys,subprocess\nreal_git={shutil.which('git')!r}\n"
                       "if sys.argv[1] == 'ls-remote':\n"
                       " ref=sys.argv[-1]\n"
                       " value=os.environ.get('QUEUE_REMOTE_SHA') or subprocess.check_output([real_git,'rev-parse',ref],text=True).strip()\n"
                       " print(value+'\\t'+ref)\n sys.exit(0)\n"
                       "if sys.argv[1:] == ['worktree','list','--porcelain','-z'] and 'QUEUE_WORKTREE_LIST' in os.environ:\n"
                       " print(os.environ['QUEUE_WORKTREE_LIST'].replace('\\\\0','\\0'),end='')\n sys.exit(0)\n"
                       "os.execv(real_git,[real_git,*sys.argv[1:]])\n")
        git.chmod(0o700)
        self.environment = {**os.environ, "PATH": str(fakebin) + os.pathsep + os.environ["PATH"],
                            "QUEUE_PR_FIXTURE": str(self.prfile)}

    def git(self, *args, cwd=None):
        result = subprocess.run(["git", *args], cwd=cwd or self.repo, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=10)
        return result.stdout.strip()

    def call(self, *args, ok=True, repo=None, environment=None):
        result = subprocess.run([sys.executable, str(SCRIPT), "--repo", str(repo or self.repo),
                                 "--state-root", str(self.state), *args], env=environment or self.environment,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        return json.loads(result.stderr)

    def write_pr(self):
        self.prfile.write_text(json.dumps(self.pr))

    def register(self, task="one"):
        return self.call("register", "--task", task, "--worktree", str(self.worktree),
                         "--branch", "task-one", "--base", self.base, "--landing", "main",
                         "--remote", "origin", "--workspace", "workspace-one")

    def ready(self, task="one"):
        return self.call("ready", "--task", task, "--pr", "1", "--validated-sha", self.tip,
                         "--evidence", "disposable test suite passed")

    def accept(self, task="one", *extra):
        return self.call("accept", "--task", task, *extra)

    def begin(self, task="one"):
        return self.call("begin", "--task", task, "--owner", "coordinator", "--expected-base", self.base)

    def prepare(self):
        self.register()
        self.ready()
        self.accept()
        self.call("owner", "acquire", "--owner", "coordinator")

    def land(self):
        self.begin()
        self.git("merge", "--ff-only", "task-one")
        self.pr.update(state="MERGED", mergeCommit={"oid": self.tip})
        self.write_pr()
        return self.call("landed", "--task", "one", "--owner", "coordinator", "--landing-sha", self.tip)

    def test_repository_identity_is_shared_across_worktrees(self):
        parent = self.call("paths")
        child = self.call("paths", repo=self.worktree)
        self.assertEqual(parent, child)
        self.assertEqual(Path(parent["repo_state_dir"]).parent, self.state)

    def test_attach_does_not_reset_state_and_identity_is_immutable(self):
        self.register()
        self.ready()
        value = self.call("attach", "--task", "one", "--session", "child-session")
        self.assertEqual(value["task"]["status"], "ready")
        self.call("attach", "--task", "one", "--session", "replacement", ok=False)
        self.call("register", "--task", "one", "--worktree", str(self.worktree), "--branch", "task-one",
                  "--base", self.base, "--landing", "main", "--remote", "origin", ok=False)

    def test_rebind_checks_previous_session_workspace_socket_and_acceptance(self):
        self.register()
        socket = str(self.root / "toastty.sock")
        self.call("attach", "--task", "one", "--session", "old-session", "--socket", socket)
        self.call("rebind", "--task", "one", "--previous-session", "wrong", "--session", "new",
                  "--workspace", "workspace-one", "--socket", socket, ok=False)
        self.call("rebind", "--task", "one", "--previous-session", "old-session", "--session", "new",
                  "--workspace", "workspace-one", ok=False)
        value = self.call("rebind", "--task", "one", "--previous-session", "old-session", "--session", "new",
                          "--workspace", "workspace-one", "--socket", socket)
        self.assertEqual(value["task"]["session"], "new")
        self.ready()
        self.accept()
        self.call("rebind", "--task", "one", "--previous-session", "new", "--session", "later",
                  "--workspace", "workspace-one", "--socket", socket, ok=False)

    def test_register_requires_full_existing_base_commit(self):
        for base in ["HEAD", "f" * 40, self.git("rev-parse", "HEAD:product.txt")]:
            self.call("register", "--task", "one", "--worktree", str(self.worktree), "--branch", "task-one",
                      "--base", base, "--landing", "main", "--remote", "origin", ok=False)

    def test_stale_pr_sha_rejects_acceptance(self):
        self.register()
        self.ready()
        self.pr["headRefOid"] = self.base
        self.write_pr()
        result = self.call("accept", "--task", "one", ok=False)
        self.assertIn("SHA differ", result["error"])
        self.assertEqual(self.call("show", "--task", "one")["task"]["status"], "ready")

    def test_stale_local_sha_requires_reopen_and_fresh_ready(self):
        self.prepare()
        self.git("commit", "--allow-empty", "-m", "new tip", cwd=self.worktree)
        self.pr["headRefOid"] = self.git("rev-parse", "HEAD", cwd=self.worktree)
        self.write_pr()
        self.call("begin", "--task", "one", "--owner", "coordinator", "--expected-base", self.base, ok=False)
        self.call("ready", "--task", "one", "--validated-sha", self.pr["headRefOid"], "--evidence", "new checks", ok=False)
        self.call("reopen", "--task", "one")
        self.assertIsNone(self.call("show", "--task", "one")["task"]["accepted_sha"])

    def test_acceptance_exempts_only_untracked_exact_handoff_files(self):
        self.register()
        (self.worktree / "WORKTREE_HANDOFF.md").write_text("instructions")
        (self.worktree / "WORKTREE_STATUS.md").write_text("status")
        self.ready()
        (self.worktree / "unexpected.txt").write_text("preserve me")
        self.call("accept", "--task", "one", ok=False)
        (self.worktree / "unexpected.txt").unlink()
        self.accept()
        self.call("reopen", "--task", "one")
        self.git("add", "WORKTREE_HANDOFF.md", cwd=self.worktree)
        self.call("ready", "--task", "one", "--validated-sha", self.tip, "--evidence", "checks", ok=False)

    def test_duplicate_accept_is_idempotent(self):
        self.register()
        self.ready()
        first = self.accept()
        again = self.accept()
        self.assertTrue(again["unchanged"])
        self.assertEqual(first["cursor"], again["cursor"])
        self.assertEqual(first["task"]["accepted_at"], again["task"]["accepted_at"])

    def test_concurrent_registers_do_not_lose_records(self):
        with ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(lambda index: self.register(f"task-{index}"), range(12)))
        listing = self.call("list")
        self.assertEqual(len(listing["tasks"]), 12)
        self.assertEqual(listing["cursor"], 12)
        self.assertEqual(len({result["cursor"] for result in results}), 12)

    def test_competing_owners_have_one_winner_and_explicit_takeover(self):
        def acquire(owner):
            result = subprocess.run([sys.executable, str(SCRIPT), "--repo", str(self.repo), "--state-root", str(self.state),
                                     "owner", "acquire", "--owner", owner], env=self.environment, capture_output=True, timeout=15)
            return result.returncode
        with ThreadPoolExecutor(max_workers=2) as executor:
            codes = list(executor.map(acquire, ["first", "second"]))
        self.assertEqual(sorted(codes), [0, 1])
        self.call("owner", "acquire", "--owner", "replacement", "--takeover")
        self.call("owner", "release", "--owner", "first", ok=False)
        self.call("owner", "release", "--owner", "replacement")

    def test_lost_notification_resumes_from_durable_cursor(self):
        cursor = self.register()["cursor"]
        self.ready()
        self.accept()
        result = self.call("wait", "--cursor", str(cursor), "--timeout", "2")
        self.assertTrue(result["changed"])
        self.assertEqual(result["tasks"][0]["status"], "accepted")
        resumed = self.call("wait", "--cursor", str(result["cursor"]), "--timeout", "0.3")
        self.assertFalse(resumed["changed"])
        self.assertTrue(resumed["timed_out"])

    def test_wait_observes_pr_checks_and_head_but_never_accepts(self):
        self.register()
        self.ready()
        initial = self.call("wait", "--now", "--timeout", "2")
        self.pr["statusCheckRollup"] = [{"name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS"}]
        self.write_pr()
        updated = self.call("wait", "--cursor", str(initial["cursor"]), "--timeout", "2")
        self.assertTrue(updated["changed"])
        self.assertEqual(updated["tasks"][0]["status"], "ready")
        self.pr["headRefOid"] = self.base
        self.write_pr()
        changed = self.call("wait", "--cursor", str(updated["cursor"]), "--timeout", "2")
        self.assertEqual(changed["tasks"][0]["pr_snapshot"]["headRefOid"], self.base)

    def test_gh_errors_are_explicit_without_erasing_state(self):
        self.register()
        self.ready()
        result = self.call("wait", "--now", "--timeout", "2",
                           environment={**self.environment, "QUEUE_GH_FAIL": "yes"})
        self.assertFalse(result["refresh_complete"])
        self.assertIn("exit 7", result["refresh_errors"][0]["error"])
        self.assertEqual(self.call("show", "--task", "one")["task"]["status"], "ready")

    def test_wait_subprocess_timeout_is_explicit_and_bounded(self):
        self.register()
        self.ready()
        started = time.monotonic()
        result = self.call("wait", "--now", "--timeout", "1",
                           environment={**self.environment, "QUEUE_GH_SLEEP": "yes"})
        self.assertTrue(result["timed_out"])
        self.assertFalse(result["refresh_complete"])
        self.assertEqual(result["refresh_pending"], ["one"])
        self.assertLess(time.monotonic() - started, 2)

    def test_one_unavailable_pr_does_not_discard_other_refreshes(self):
        self.register()
        self.ready()
        self.register("two")
        self.call("ready", "--task", "two", "--pr", "2", "--validated-sha", self.tip, "--evidence", "checks")
        result = self.call("wait", "--now", "--timeout", "3",
                           environment={**self.environment, "QUEUE_GH_FAIL_PR": "1"})
        self.assertFalse(result["refresh_complete"])
        self.assertEqual(result["refresh_errors"][0]["task"], "one")
        self.assertEqual(result["refreshed_tasks"], ["two"])
        self.assertIsNotNone(result["tasks"][1]["pr_snapshot"])

    def test_wait_polls_local_changes_without_repeating_remote_calls(self):
        self.register()
        self.ready()
        initial = self.call("wait", "--now", "--timeout", "3")
        log = self.root / "gh-calls"
        process = subprocess.Popen([sys.executable, str(SCRIPT), "--repo", str(self.repo),
                                    "--state-root", str(self.state), "wait", "--cursor", str(initial["cursor"]),
                                    "--timeout", "4"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env={**self.environment, "QUEUE_GH_CALL_LOG": str(log)})
        try:
            deadline = time.monotonic() + 2
            while not log.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(log.exists())
            self.call("reopen", "--task", "one")
            changed = time.monotonic()
            output, error = process.communicate(timeout=2)
            self.assertEqual(process.returncode, 0, error)
            self.assertLess(time.monotonic() - changed, 1.5)
            self.assertEqual(json.loads(output)["tasks"][0]["status"], "working")
            self.assertEqual(log.read_text().splitlines(), ["called"])
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_wait_normalizes_check_order_and_volatile_timestamps(self):
        self.register()
        self.ready()
        self.pr["statusCheckRollup"] = [
            {"name": "B", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "before"},
            {"name": "A", "status": "COMPLETED", "conclusion": "SUCCESS", "completedAt": "before"}]
        self.write_pr()
        initial = self.call("wait", "--now", "--timeout", "3")
        self.pr["statusCheckRollup"].reverse()
        for check in self.pr["statusCheckRollup"]:
            check.update(startedAt="after", completedAt="after")
        self.write_pr()
        result = self.call("wait", "--now", "--cursor", str(initial["cursor"]), "--timeout", "3")
        self.assertFalse(result["changed"])

    def test_wait_skips_remote_for_landed_and_verified_tasks(self):
        self.prepare()
        self.land()
        for status in ("landed", "verified"):
            if status == "verified":
                self.call("verified", "--task", "one", "--owner", "coordinator", "--evidence", "landing checks")
            result = self.call("wait", "--now", "--timeout", "2",
                               environment={**self.environment, "QUEUE_GH_FAIL": "yes"})
            self.assertTrue(result["refresh_complete"])
            self.assertEqual(result["refreshed_tasks"], [])

    def test_git_routing_environment_cannot_override_repo(self):
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"):
            with self.subTest(name=name):
                result = self.call("paths", ok=False, environment={**self.environment, name: str(self.root / "other")})
                self.assertIn(name, result["error"])

    def test_dependency_blocks_until_verified_not_merely_accepted(self):
        self.register("prerequisite")
        self.ready("prerequisite")
        self.accept("prerequisite")
        self.register()
        self.ready()
        self.accept("one", "--depends-on", "prerequisite")
        self.call("owner", "acquire", "--owner", "coordinator")
        result = self.call("begin", "--task", "one", "--owner", "coordinator", "--expected-base", self.base, ok=False)
        self.assertIn("has not been accepted", result["error"])

    def stacked_task(self):
        self.register()
        self.ready()
        next_worktree = self.root / "child-two"
        self.git("worktree", "add", "-b", "task-two", str(next_worktree), self.tip)
        self.git("commit", "--allow-empty", "-m", "stacked task", cwd=next_worktree)
        next_tip = self.git("rev-parse", "HEAD", cwd=next_worktree)
        self.call("register", "--task", "two", "--worktree", str(next_worktree), "--branch", "task-two",
                  "--base", self.tip, "--landing", "main", "--remote", "origin")
        self.call("ready", "--task", "two", "--pr", "2", "--validated-sha", next_tip, "--evidence", "stacked checks")
        self.pr.update(headRefName="task-two", headRefOid=next_tip, baseRefName="task-one", baseRefOid=self.tip)
        self.write_pr()
        return next_tip

    def test_stacked_acceptance_remains_pending_until_dependency_lands_and_pr_retargets(self):
        next_tip = self.stacked_task()
        acceptance = self.accept("two", "--depends-on", "one")["task"]
        self.assertEqual(acceptance["status"], "accepted")
        self.call("owner", "acquire", "--owner", "coordinator")
        blocked = self.call("begin", "--task", "two", "--owner", "coordinator", "--expected-base", self.base, ok=False)
        self.assertIn("has not been accepted", blocked["error"])
        self.pr.update(headRefName="task-one", headRefOid=self.tip, baseRefName="main", baseRefOid=self.base)
        self.write_pr()
        self.accept()
        self.land()
        self.call("verified", "--task", "one", "--owner", "coordinator", "--evidence", "landing checks")
        self.pr.update(state="OPEN", headRefName="task-two", headRefOid=next_tip, baseRefName="task-one",
                       baseRefOid=self.tip, mergeCommit=None)
        self.write_pr()
        blocked = self.call("begin", "--task", "two", "--owner", "coordinator", "--expected-base", self.tip, ok=False)
        self.assertIn("PR base", blocked["error"])
        self.pr["baseRefName"] = "main"
        self.write_pr()
        result = self.call("begin", "--task", "two", "--owner", "coordinator", "--expected-base", self.tip)["task"]
        self.assertEqual(result["accepted_sha"], acceptance["accepted_sha"])
        self.assertEqual(result["accepted_at"], acceptance["accepted_at"])
        self.assertEqual(result["validated_sha"], next_tip)
        self.assertEqual(result["status"], "integrating")

    def test_stacked_acceptance_requires_explicit_matching_dependency(self):
        self.stacked_task()
        self.call("accept", "--task", "two", ok=False)
        self.pr["baseRefName"] = "unrelated-branch"
        self.write_pr()
        self.call("accept", "--task", "two", "--depends-on", "one", ok=False)
        self.assertEqual(self.call("show", "--task", "two")["task"]["status"], "ready")

    def test_dependency_pin_records_working_source_and_rejects_changed_verified_source(self):
        next_tip = self.stacked_task()
        self.call("reopen", "--task", "one")
        acceptance = self.accept("two", "--depends-on", "one")["task"]
        self.assertEqual(acceptance["dependency_shas"], {"one": self.tip})
        self.git("commit", "--allow-empty", "-m", "changed prerequisite", cwd=self.worktree)
        changed_tip = self.git("rev-parse", "HEAD", cwd=self.worktree)
        self.call("ready", "--task", "one", "--validated-sha", changed_tip, "--evidence", "changed checks")
        self.pr.update(headRefName="task-one", headRefOid=changed_tip, baseRefName="main", baseRefOid=self.base)
        self.write_pr()
        self.accept()
        self.call("owner", "acquire", "--owner", "coordinator")
        self.begin()
        self.git("merge", "--ff-only", "task-one")
        self.pr.update(state="MERGED", mergeCommit={"oid": changed_tip})
        self.write_pr()
        self.call("landed", "--task", "one", "--owner", "coordinator", "--landing-sha", changed_tip)
        self.call("verified", "--task", "one", "--owner", "coordinator", "--evidence", "landing checks")
        self.pr.update(state="OPEN", headRefName="task-two", headRefOid=next_tip, baseRefName="main",
                       baseRefOid=changed_tip, mergeCommit=None)
        self.write_pr()
        result = self.call("begin", "--task", "two", "--owner", "coordinator", "--expected-base", changed_tip, ok=False)
        self.assertIn("source pin", result["error"])
        self.call("reopen", "--task", "two")
        self.call("ready", "--task", "two", "--validated-sha", next_tip, "--evidence", "review against changed prerequisite")
        renewed = self.accept("two", "--depends-on", "one")["task"]
        self.assertEqual(renewed["dependency_shas"], {"one": changed_tip})
        self.call("begin", "--task", "two", "--owner", "coordinator", "--expected-base", changed_tip)

    def test_acceptance_can_precede_review_and_ci_but_begin_requires_both(self):
        self.register()
        self.ready()
        self.pr.update(reviewDecision="REVIEW_REQUIRED", mergeStateStatus="BLOCKED",
                       statusCheckRollup=[{"status": "IN_PROGRESS", "conclusion": ""}])
        self.write_pr()
        accepted = self.accept()["task"]
        self.call("owner", "acquire", "--owner", "coordinator")
        self.call("begin", "--task", "one", "--owner", "coordinator", "--expected-base", self.base, ok=False)
        self.pr["reviewDecision"] = "APPROVED"
        self.write_pr()
        self.call("begin", "--task", "one", "--owner", "coordinator", "--expected-base", self.base, ok=False)
        self.pr["statusCheckRollup"] = [{"status": "COMPLETED", "conclusion": "SUCCESS"}]
        self.write_pr()
        self.call("begin", "--task", "one", "--owner", "coordinator", "--expected-base", self.base, ok=False)
        self.pr["mergeStateStatus"] = "CLEAN"
        self.write_pr()
        result = self.begin()["task"]
        self.assertEqual(result["accepted_at"], accepted["accepted_at"])

    def test_begin_rejects_review_ci_and_merge_metadata_blockers(self):
        self.prepare()
        cases = [
            {"reviewDecision": "CHANGES_REQUESTED"}, {"reviewDecision": None}, {"reviewDecision": {}},
            {"mergeStateStatus": "UNKNOWN"}, {"mergeStateStatus": None},
            {"mergeStateStatus": "BEHIND"}, {"mergeStateStatus": "DIRTY"},
            {"statusCheckRollup": [{"status": "COMPLETED", "conclusion": "FAILURE"}]},
            {"statusCheckRollup": [{"status": "COMPLETED", "conclusion": "CANCELLED"}]},
            {"statusCheckRollup": [{"status": "QUEUED", "conclusion": ""}]},
            {"statusCheckRollup": [{"state": "PENDING"}]},
            {"statusCheckRollup": [{"state": "ERROR"}]},
            {"statusCheckRollup": [{}]}, {"statusCheckRollup": [None]},
        ]
        baseline = dict(self.pr)
        for changes in cases:
            with self.subTest(changes=changes):
                self.pr = {**baseline, **changes}
                self.write_pr()
                self.call("begin", "--task", "one", "--owner", "coordinator", "--expected-base", self.base, ok=False)
                self.assertEqual(self.call("show", "--task", "one")["task"]["status"], "accepted")
        self.pr = {**baseline, "reviewDecision": "", "statusCheckRollup": [
            {"status": "COMPLETED", "conclusion": "NEUTRAL"},
            {"status": "COMPLETED", "conclusion": "SKIPPED"}, {"state": "SUCCESS"}]}
        self.write_pr()
        self.begin()

    def test_missing_dependencies_and_cycles_rejected(self):
        self.register()
        self.ready()
        self.call("accept", "--task", "one", "--depends-on", "missing", ok=False)
        self.register("two")
        self.ready("two")
        self.accept("one", "--depends-on", "two")
        result = self.call("accept", "--task", "two", "--depends-on", "one", ok=False)
        self.assertIn("cycle", result["error"])

    def test_verified_dependency_allows_next_integration(self):
        self.prepare()
        self.land()
        self.call("verified", "--task", "one", "--owner", "coordinator", "--evidence", "landing checks")
        next_worktree = self.root / "child-two"
        self.git("worktree", "add", "-b", "task-two", str(next_worktree))
        self.git("commit", "--allow-empty", "-m", "second task", cwd=next_worktree)
        next_tip = self.git("rev-parse", "HEAD", cwd=next_worktree)
        self.call("register", "--task", "two", "--worktree", str(next_worktree), "--branch", "task-two",
                  "--base", self.tip, "--landing", "main", "--remote", "origin")
        self.call("ready", "--task", "two", "--pr", "2", "--validated-sha", next_tip, "--evidence", "second task checks")
        self.pr.update(state="OPEN", headRefOid=next_tip, headRefName="task-two", baseRefOid=self.tip, mergeCommit=None)
        self.write_pr()
        self.accept("two", "--depends-on", "one")
        result = self.call("begin", "--task", "two", "--owner", "coordinator", "--expected-base", self.tip)
        self.assertEqual(result["task"]["status"], "integrating")

    def test_dependency_receipt_for_another_destination_does_not_release(self):
        self.prepare()
        self.land()
        self.call("verified", "--task", "one", "--owner", "coordinator", "--evidence", "landing checks")
        self.git("branch", "release", self.tip)
        next_worktree = self.root / "child-two"
        self.git("worktree", "add", "-b", "task-two", str(next_worktree))
        self.git("commit", "--allow-empty", "-m", "second task", cwd=next_worktree)
        next_tip = self.git("rev-parse", "HEAD", cwd=next_worktree)
        self.call("register", "--task", "two", "--worktree", str(next_worktree), "--branch", "task-two",
                  "--base", self.tip, "--landing", "release", "--remote", "origin")
        self.call("ready", "--task", "two", "--pr", "2", "--validated-sha", next_tip, "--evidence", "second task checks")
        self.pr.update(state="OPEN", headRefOid=next_tip, headRefName="task-two", baseRefName="release",
                       baseRefOid=self.tip, mergeCommit=None)
        self.write_pr()
        result = self.call("accept", "--task", "two", "--depends-on", "one", ok=False)
        self.assertIn("different landing branch", result["error"])

    def test_dependency_receipt_must_still_be_on_destination(self):
        self.prepare()
        self.land()
        self.call("verified", "--task", "one", "--owner", "coordinator", "--evidence", "landing checks")
        next_worktree = self.root / "child-two"
        self.git("worktree", "add", "-b", "task-two", str(next_worktree))
        self.git("commit", "--allow-empty", "-m", "second task", cwd=next_worktree)
        next_tip = self.git("rev-parse", "HEAD", cwd=next_worktree)
        self.call("register", "--task", "two", "--worktree", str(next_worktree), "--branch", "task-two",
                  "--base", self.tip, "--landing", "main", "--remote", "origin")
        self.call("ready", "--task", "two", "--pr", "2", "--validated-sha", next_tip, "--evidence", "second task checks")
        self.pr.update(state="OPEN", headRefOid=next_tip, headRefName="task-two", baseRefOid=self.base, mergeCommit=None)
        self.write_pr()
        self.accept("two", "--depends-on", "one")
        # Simulate an independently rewritten destination in this disposable repo.
        self.git("update-ref", "refs/heads/main", self.base)
        self.call("begin", "--task", "two", "--owner", "coordinator", "--expected-base", self.base, ok=False)

    def test_changed_base_blocks_begin(self):
        self.prepare()
        self.pr["baseRefOid"] = self.tip
        self.write_pr()
        result = self.call("begin", "--task", "one", "--owner", "coordinator", "--expected-base", self.base, ok=False)
        self.assertIn("base changed", result["error"])

    def test_live_remote_drift_blocks_begin_with_stale_pr_metadata(self):
        self.prepare()
        result = self.call("begin", "--task", "one", "--owner", "coordinator", "--expected-base", self.base,
                           ok=False, environment={**self.environment, "QUEUE_REMOTE_SHA": self.tip})
        self.assertIn("live remote", result["error"])
        self.assertEqual(self.call("show", "--task", "one")["task"]["status"], "accepted")

    def test_remote_retargeting_rejects_acceptance(self):
        self.register()
        self.ready()
        self.git("remote", "set-url", "origin", "https://github.com/other/repo.git")
        result = self.call("accept", "--task", "one", ok=False)
        self.assertIn("different repository", result["error"])

    def test_uncertain_merge_is_reconciled_without_merging_again(self):
        self.prepare()
        intent = self.begin()
        self.assertEqual(intent["task"]["status"], "integrating")
        self.call("begin", "--task", "one", "--owner", "coordinator", "--expected-base", self.base, ok=False)
        self.call("owner", "release", "--owner", "coordinator", ok=False)
        self.call("reopen", "--task", "one", ok=False)
        self.git("merge", "--ff-only", "task-one")
        self.pr.update(state="MERGED", mergeCommit={"oid": self.tip})
        self.write_pr()
        self.call("owner", "acquire", "--owner", "resumed", "--takeover")
        result = self.call("landed", "--task", "one", "--owner", "resumed", "--landing-sha", self.tip)
        self.assertEqual(result["task"]["status"], "landed")

    def test_cancel_requires_open_unchanged_pr_and_explicit_assertion(self):
        self.prepare()
        self.begin()
        self.call("cancel-begin", "--task", "one", "--owner", "coordinator", "--no-merge-in-flight")
        self.assertEqual(self.call("show", "--task", "one")["task"]["status"], "accepted")

    def test_cancel_closed_draft_or_changed_pr_clears_stale_acceptance(self):
        self.prepare()
        baseline = dict(self.pr)
        for change in ({"state": "CLOSED"}, {"isDraft": True}, {"headRefOid": self.base}):
            with self.subTest(change=change):
                self.begin()
                self.pr = {**baseline, **change}
                self.write_pr()
                result = self.call("cancel-begin", "--task", "one", "--owner", "coordinator", "--no-merge-in-flight")["task"]
                self.assertEqual(result["status"], "working")
                self.assertIsNone(result["accepted_sha"])
                self.assertIsNone(result["validated_sha"])
                self.assertEqual(result["evidence"], [])
                self.pr = dict(baseline)
                self.write_pr()
                self.ready()
                self.accept()

    def test_cancel_handles_dirty_or_deleted_checkout_without_claiming_merge(self):
        self.prepare()
        self.begin()
        dirty = self.worktree / "in-progress.txt"
        dirty.write_text("keep user changes")
        result = self.call("cancel-begin", "--task", "one", "--owner", "coordinator", "--no-merge-in-flight")
        self.assertEqual(result["task"]["status"], "accepted")
        self.call("begin", "--task", "one", "--owner", "coordinator", "--expected-base", self.base, ok=False)
        dirty.unlink()
        self.begin()
        self.git("worktree", "remove", str(self.worktree))
        result = self.call("cancel-begin", "--task", "one", "--owner", "coordinator", "--no-merge-in-flight")
        self.assertEqual(result["task"]["status"], "working")

    def test_cancel_cannot_discard_unknown_merged_head(self):
        self.prepare()
        self.begin()
        self.pr.update(state="MERGED", headRefOid=self.base, mergeCommit={"oid": self.base})
        self.write_pr()
        self.call("cancel-begin", "--task", "one", "--owner", "coordinator", "--no-merge-in-flight", ok=False)
        self.assertEqual(self.call("show", "--task", "one")["task"]["status"], "integrating")

    def test_record_landing_receipt_but_reject_verification_on_rewritten_base(self):
        self.prepare()
        self.begin()
        tree = self.git("rev-parse", "HEAD^{tree}")
        disconnected = self.git("commit-tree", tree, "-m", "merge after destination rewrite")
        self.pr.update(state="MERGED", mergeCommit={"oid": disconnected})
        self.write_pr()
        self.call("landed", "--task", "one", "--owner", "coordinator", "--landing-sha", disconnected)
        self.git("update-ref", "refs/heads/main", disconnected)
        self.call("verified", "--task", "one", "--owner", "coordinator", "--evidence", "checks", ok=False)
        self.assertEqual(self.call("show", "--task", "one")["task"]["status"], "landed")

    def test_unverified_landing_blocks_independent_integration(self):
        self.prepare()
        self.land()
        self.register("two")
        self.ready("two")
        self.pr.update(state="OPEN", baseRefOid=self.tip, mergeCommit=None)
        self.write_pr()
        self.accept("two")
        result = self.call("begin", "--task", "two", "--owner", "coordinator", "--expected-base", self.tip, ok=False)
        self.assertIn("verify its landing", result["error"])
        self.call("verified", "--task", "one", "--owner", "coordinator", "--evidence", "landing checks")
        self.call("begin", "--task", "two", "--owner", "coordinator", "--expected-base", self.tip)

    def test_cleaned_rejects_symlink_alias_or_same_branch_registered_elsewhere(self):
        self.prepare()
        self.land()
        self.call("verified", "--task", "one", "--owner", "coordinator", "--evidence", "landing checks")
        self.git("worktree", "remove", str(self.worktree))
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        args = ["cleaned", "--task", "one", "--owner", "coordinator", "--workspace-closed",
                "--branch-retained", "keep branch", "--evidence", "archive saved"]
        listing = f"worktree {alias / 'child'}\\0HEAD {self.tip}\\0detached\\0\\0"
        result = self.call(*args, ok=False, environment={**self.environment, "QUEUE_WORKTREE_LIST": listing})
        self.assertIn("worktree remains registered", result["error"])
        alternate = self.root / "alternate-checkout"
        self.git("worktree", "add", str(alternate), "task-one")
        result = self.call(*args, ok=False)
        self.assertIn("branch remains checked out", result["error"])

    def test_incomplete_cleanup_does_not_claim_cleaned_and_retention_supported(self):
        self.prepare()
        self.land()
        self.call("verified", "--task", "one", "--owner", "coordinator", "--evidence", "landing checks passed")
        args = ["cleaned", "--task", "one", "--owner", "coordinator", "--workspace-closed",
                "--branch-retained", "squash branch retained without forcing deletion", "--evidence", "archive saved"]
        self.call(*args, ok=False)
        self.assertEqual(self.call("show", "--task", "one")["task"]["status"], "verified")
        self.git("worktree", "remove", str(self.worktree))
        self.call("cleaned", "--task", "one", "--owner", "coordinator", "--branch-retained", "keep branch",
                  "--evidence", "archive saved", ok=False)
        result = self.call(*args)
        self.assertEqual(result["task"]["status"], "cleaned")
        self.assertTrue(result["task"]["branch_retained"])

    def test_invalid_ids_and_corrupt_schema_fail_closed(self):
        self.call("show", "--task", "../escape", ok=False)
        self.register()
        state_file = Path(self.call("paths")["repo_state_dir"]) / "queue.json"
        state = json.loads(state_file.read_text())
        state["tasks"]["one"]["accepted_sha"] = 123
        state_file.write_text(json.dumps(state))
        self.call("list", ok=False)

    def test_wrong_remote_pr_and_draft_pr_reject_acceptance(self):
        self.register()
        self.call("ready", "--task", "one", "--pr", "https://github.com/other/repo/pull/1",
                  "--validated-sha", self.tip, "--evidence", "checks")
        self.call("accept", "--task", "one", ok=False)
        self.register("draft")
        self.ready("draft")
        self.pr["isDraft"] = True
        self.write_pr()
        self.call("accept", "--task", "draft", ok=False)


if __name__ == "__main__":
    unittest.main()
