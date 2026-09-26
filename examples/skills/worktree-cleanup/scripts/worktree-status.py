#!/usr/bin/env python3
"""Show each worktree's PR, checks, local state, and Toastty workspace; optionally
clean up worktrees whose PR has merged.

Usage: worktree-status.py [--json] [--cleanup-merged] [--repo PATH]

Run from any checkout of the repository, or pass --repo. Needs `git` and an
authenticated `gh`. Toastty workspaces are matched through TOASTTY_CLI_PATH and
the `workspace.list` query; --cleanup-merged requires them.

Verdicts:
  ready     open, not draft, GitHub reports it mergeable with required checks met,
            no check failing or still running, and the worktree is clean at
            exactly the PR head commit
  cleanup   merged, and the worktree is clean at exactly the merged PR head
  blocked   anything else; the reason says what is missing
Worktrees whose branch has no PR are listed separately and never touched.

--cleanup-merged acts only on "cleanup" rows. For each, it closes the matching
Toastty workspace, removes the worktree, and deletes the local and remote branch.
It refuses to run from a workspace-scoped session, whose workspace list is partial.
It skips a row, changing nothing, when the workspace match is ambiguous; when the
workspace is the caller's own, holds another worktree or another PR's chip, or has
an agent session, a busy terminal, or unsaved documents; or when the worktree is
locked. It rechecks the worktree just before removing it, and deletes each branch
only while it still points at the merged commit.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

PR_FIELDS = (
    "number,title,state,isDraft,headRefName,headRefOid,baseRefName,isCrossRepository,"
    "mergeable,mergeStateStatus,statusCheckRollup,url"
)
# GitHub computes these after branch protection: CLEAN means required checks are
# met and nothing blocks the merge; HAS_HOOKS is CLEAN with pre-receive hooks.
MERGEABLE_STATES = ("CLEAN", "HAS_HOOKS")


def run(args: list[str], cwd: str | None = None, check: bool = True) -> str:
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.exit(f"worktree-status: {' '.join(args[:3])} failed: {result.stderr.strip()}")
    return result.stdout


def succeeds(args: list[str], cwd: str | None = None) -> tuple[bool, str]:
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    return result.returncode == 0, (result.stdout or result.stderr).strip()


@dataclass
class Worktree:
    path: str
    branch: str | None
    head: str
    locked: bool = False


@dataclass
class Workspace:
    workspace_id: str
    title: str
    cwds: list[str]
    chips: list[dict]
    active_sessions: int
    busy_terminals: int
    unsaved_documents: int

    @property
    def label(self) -> str:
        return f"{self.title} ({self.workspace_id[:8]})"


@dataclass
class Row:
    worktree: str | None
    branch: str | None
    pr: int | None = None
    pr_state: str | None = None
    head: str | None = None
    title: str | None = None
    passed_checks: int = 0
    skipped_checks: list[str] = field(default_factory=list)
    failing_checks: list[str] = field(default_factory=list)
    pending_checks: list[str] = field(default_factory=list)
    local: str = ""
    workspace: str | None = None
    workspace_ids: list[str] = field(default_factory=list)
    verdict: str = "blocked"
    reason: str = ""
    cleanup: str | None = None


def real(path: str) -> str:
    """Canonical path, so /var and /private/var style aliases compare equal."""
    return os.path.realpath(path)


def inside(path: str, directory: str) -> bool:
    return path == directory or path.startswith(directory.rstrip("/") + "/")


def list_worktrees(repo: str) -> list[Worktree]:
    worktrees: list[Worktree] = []
    entry: dict[str, str] = {}
    for line in run(["git", "worktree", "list", "--porcelain"], cwd=repo).splitlines() + [""]:
        if not line:
            if "worktree" in entry and "prunable" not in entry:
                branch = entry.get("branch", "").removeprefix("refs/heads/") or None
                worktrees.append(Worktree(real(entry["worktree"]), branch, entry.get("HEAD", ""),
                                          "locked" in entry))
            entry = {}
            continue
        key, _, value = line.partition(" ")
        entry[key] = value
    return worktrees


def local_state(worktree: Worktree) -> tuple[str, bool]:
    """Returns a short description and whether the worktree has uncommitted work."""
    notes: list[str] = []
    dirty = run(["git", "status", "--porcelain"], cwd=worktree.path, check=False).splitlines()
    if dirty:
        notes.append(f"{len(dirty)} uncommitted")
    upstream = run(
        ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
        cwd=worktree.path, check=False,
    ).strip()
    if worktree.branch and upstream:
        counts = run(["git", "rev-list", "--left-right", "--count", f"HEAD...{upstream}"],
                     cwd=worktree.path, check=False).split()
        if len(counts) == 2 and counts[0] != "0":
            notes.append(f"{counts[0]} unpushed")
    elif worktree.branch:
        notes.append("no upstream")
    return (", ".join(notes) or "clean"), bool(dirty)


def head_mismatch(worktree: Worktree, pr_head: str) -> str | None:
    """Describes how the worktree HEAD differs from the PR head, or None if equal."""
    if worktree.head == pr_head:
        return None
    counts = run(["git", "rev-list", "--left-right", "--count", f"HEAD...{pr_head}"],
                 cwd=worktree.path, check=False).split()
    if len(counts) != 2:
        return f"worktree HEAD {worktree.head[:8]} is not the PR head {pr_head[:8]}"
    ahead, behind = counts
    return f"worktree HEAD is {ahead} ahead and {behind} behind the PR head {pr_head[:8]}"


def summarize_checks(row: Row, pr: dict) -> None:
    for check in pr.get("statusCheckRollup") or []:
        name = check.get("name") or check.get("context") or "?"
        conclusion = (check.get("conclusion") or check.get("state") or "").upper()
        status = (check.get("status") or "").upper()
        if (status and status != "COMPLETED") or not conclusion or conclusion in ("PENDING", "EXPECTED"):
            row.pending_checks.append(name)
        elif conclusion == "SKIPPED":
            row.skipped_checks.append(name)
        elif conclusion in ("SUCCESS", "NEUTRAL"):
            row.passed_checks += 1
        else:
            row.failing_checks.append(name)


def toastty_cli() -> str | None:
    return os.environ.get("TOASTTY_CLI_PATH") or None


def toastty_workspaces() -> tuple[list[dict] | None, bool]:
    """Returns the workspace list and whether it is complete (caller not scoped)."""
    cli = toastty_cli()
    if not cli:
        return None, False
    output = run([cli, "--json", "query", "run", "workspace.list"], check=False)
    try:
        response = json.loads(output)
    except json.JSONDecodeError:
        return None, False
    if not response.get("ok"):
        return None, False
    result = response.get("result", {})
    return result.get("workspaces", []), result.get("callerIsScoped") is False


def caller_workspace_id() -> str | None:
    cli, panel = toastty_cli(), os.environ.get("TOASTTY_PANEL_ID")
    if not cli or not panel:
        return None
    try:
        response = json.loads(run([cli, "--json", "query", "run", "terminal.state", "--panel", panel], check=False))
    except json.JSONDecodeError:
        return None
    return (response.get("result") or {}).get("workspaceID")


def match_workspaces(workspaces: list[dict] | None, path: str | None, pr: int | None,
                     repo_slug: str) -> list[Workspace]:
    """Matches by a terminal inside the worktree, then by a github-pr chip whose URL
    names this PR, then by chip text for chips without a URL. Returns every match
    at the first level that has any; more than one means the match is ambiguous."""
    if not workspaces:
        return []

    def chips(workspace: dict) -> list[dict]:
        return [a for a in workspace.get("annotations", []) if a.get("key") == "github-pr"]

    pr_url = re.compile(rf"github\.com/{re.escape(repo_slug)}/pull/{pr}/?$", re.IGNORECASE)
    pr_text = re.compile(rf"#{pr}\b")
    levels = [
        lambda w: bool(path) and any(inside(real(cwd), path) for cwd in w.get("terminalCwds", [])),
        lambda w: bool(pr) and any(pr_url.search(a.get("url") or "") for a in chips(w)),
        lambda w: bool(pr) and any(not a.get("url") and pr_text.search(a.get("text", "")) for a in chips(w)),
    ]
    for matches in levels:
        found = [
            Workspace(w["workspaceID"], w.get("title", ""), [real(c) for c in w.get("terminalCwds", [])],
                      chips(w), len(w.get("activeSessions", [])), w.get("busyTerminalCount", 0),
                      w.get("unsavedDocumentCount", 0))
            for w in workspaces if matches(w)
        ]
        if found:
            return found
    return []


def refresh_merge_state(pr: dict, repo: str) -> None:
    """`gh pr list` reports UNKNOWN until GitHub computes mergeability, which
    a single-PR request triggers; ask once more if it is still computing."""
    for _ in range(2):
        view = json.loads(run(["gh", "pr", "view", str(pr["number"]), "--json", "mergeable,mergeStateStatus"],
                              cwd=repo, check=False) or "{}")
        pr.update(view)
        if pr.get("mergeStateStatus") != "UNKNOWN":
            return


def verdict(row: Row, pr: dict, worktree: Worktree | None, dirty: bool, ambiguous: bool) -> None:
    reasons = []
    if ambiguous:
        reasons.append("several PRs use this branch name")
    mismatch = head_mismatch(worktree, pr["headRefOid"]) if worktree else None
    if mismatch:
        reasons.append(mismatch)
    if dirty:
        reasons.append("uncommitted changes")
    if pr["state"] == "MERGED":
        if reasons:
            row.reason = "; ".join(reasons)
        else:
            row.verdict = "cleanup"
        return
    if pr["state"] == "CLOSED":
        row.reason = "; ".join(["PR closed without merging"] + reasons)
        return
    if pr["isDraft"]:
        reasons.append("draft")
    if pr["mergeable"] == "CONFLICTING":
        reasons.append("merge conflicts")
    elif pr["mergeStateStatus"] == "BLOCKED" and not (row.failing_checks or row.pending_checks):
        reasons.append("GitHub blocks the merge: a required check has not reported for this head, "
                       "or a required review is missing")
    elif pr["mergeStateStatus"] not in MERGEABLE_STATES:
        reasons.append(f"GitHub merge state {pr['mergeStateStatus'].lower()}")
    if row.failing_checks:
        reasons.append("failing: " + ", ".join(row.failing_checks))
    if row.pending_checks:
        reasons.append("still running: " + ", ".join(row.pending_checks))
    if reasons:
        row.reason = "; ".join(reasons)
    else:
        row.verdict = "ready"


def recheck(worktree: Worktree, merged_head: str) -> str | None:
    """Rereads the worktree just before a change; returns why it is no longer safe."""
    head = run(["git", "rev-parse", "HEAD"], cwd=worktree.path, check=False).strip()
    if head != merged_head:
        return f"worktree HEAD moved to {head[:8]}"
    if run(["git", "status", "--porcelain"], cwd=worktree.path, check=False).strip():
        return "worktree has uncommitted changes"
    return None


def other_pr_chip(workspace: Workspace, pr: int, repo_slug: str) -> bool:
    pattern = re.compile(rf"github\.com/{re.escape(repo_slug)}/pull/(\d+)/?$", re.IGNORECASE)
    for chip in workspace.chips:
        found = pattern.search(chip.get("url") or "")
        if found and int(found.group(1)) != pr:
            return True
    return False


def clean_up(row: Row, worktree: Worktree, repo: str, repo_slug: str, own_workspace: str | None,
             workspaces: list[Workspace], other_worktrees: list[str]) -> str:
    """Closes the workspace, removes the worktree, and deletes both branches. Every
    guard runs before the first change; a failure after one reports what was done."""
    if len(workspaces) > 1:
        return "skipped: several workspaces match (" + ", ".join(w.label for w in workspaces) + ")"
    workspace = workspaces[0] if workspaces else None
    if workspace:
        if workspace.workspace_id == own_workspace:
            return "skipped: that is this session's own workspace"
        if workspace.active_sessions:
            return f"skipped: {workspace.label} has an active agent session"
        if workspace.busy_terminals:
            return f"skipped: {workspace.label} has a terminal running a command"
        if workspace.unsaved_documents:
            return f"skipped: {workspace.label} has unsaved document changes"
        if any(inside(cwd, other) for cwd in workspace.cwds for other in other_worktrees):
            return f"skipped: {workspace.label} also has a terminal in another worktree"
        if other_pr_chip(workspace, row.pr, repo_slug):
            return f"skipped: {workspace.label} carries a chip for a different PR"
    if worktree.locked:
        return "skipped: the worktree is locked"
    problem = recheck(worktree, row.head)
    if problem:
        return f"skipped: {problem}"

    done: list[str] = []

    def stop(message: str) -> str:
        return "partial: " + "; ".join(done + [message]) if done else f"stopped: {message}"

    if workspace:
        ok, output = succeeds([toastty_cli(), "--json", "action", "run", "workspace.close",
                               "--workspace", workspace.workspace_id])
        try:
            ok = ok and json.loads(output).get("ok") is True
        except json.JSONDecodeError:
            ok = False
        if not ok:
            return stop(f"could not close {workspace.label}: {output}")
        done.append(f"closed {workspace.label}")
    problem = recheck(worktree, row.head)
    if problem:
        return stop(f"{problem}; worktree kept")
    ok, output = succeeds(["git", "worktree", "remove", worktree.path], cwd=repo)
    if not ok:
        return stop(f"git worktree remove failed: {output}")
    done.append("removed worktree")
    # Compare-and-delete: the ref goes only if it still points at the merged head.
    # Squash merges leave it unmerged by ancestry, so `git branch -d` would refuse.
    ok, output = succeeds(["git", "update-ref", "-d", f"refs/heads/{row.branch}", row.head], cwd=repo)
    done.append("deleted local branch" if ok else f"local branch kept: {output}")
    remote = run(["git", "ls-remote", "--heads", "origin", row.branch], cwd=repo, check=False).split()
    if remote and remote[0] == row.head:
        ok, output = succeeds(["git", "push", f"--force-with-lease=refs/heads/{row.branch}:{row.head}",
                               "origin", f":refs/heads/{row.branch}"], cwd=repo)
        done.append("deleted remote branch" if ok else f"remote branch kept: {output}")
    elif remote:
        done.append(f"remote branch kept: it now points at {remote[0][:8]}")
    return "; ".join(done)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="print rows as JSON")
    parser.add_argument("--cleanup-merged", action="store_true",
                        help="close workspaces, remove worktrees, and delete branches for merged PRs")
    parser.add_argument("--repo", help="any checkout of the repository (default: current directory)")
    options = parser.parse_args()

    repo = run(["git", "rev-parse", "--show-toplevel"], cwd=options.repo).strip()
    fetched = subprocess.run(["git", "fetch", "--quiet", "--prune", "origin"], cwd=repo,
                             capture_output=True).returncode == 0
    repo_info = json.loads(run(["gh", "repo", "view", "--json", "nameWithOwner,defaultBranchRef"], cwd=repo))
    repo_slug, default_branch = repo_info["nameWithOwner"], repo_info["defaultBranchRef"]["name"]
    prs = json.loads(run(["gh", "pr", "list", "--state", "all", "--limit", "200", "--json", PR_FIELDS], cwd=repo))
    # Local branches track this repository, so fork PRs with the same branch name
    # never match. gh lists newest first; prefer an open PR, then the newest.
    prs_by_branch: dict[str, list[dict]] = {}
    for pr in prs:
        if not pr["isCrossRepository"]:
            prs_by_branch.setdefault(pr["headRefName"], []).append(pr)

    def branch_pr(branch: str | None) -> tuple[dict | None, bool]:
        candidates = prs_by_branch.get(branch or "", [])
        open_prs = [pr for pr in candidates if pr["state"] == "OPEN"]
        if open_prs:
            return open_prs[0], len(open_prs) > 1
        return (candidates[0] if candidates else None), False

    workspace_list, workspace_list_complete = toastty_workspaces()
    if options.cleanup_merged and workspace_list is None:
        sys.exit("worktree-status: --cleanup-merged needs TOASTTY_CLI_PATH and a Toastty with workspace.list, "
                 "so it can check each workspace before closing it")
    if options.cleanup_merged and not workspace_list_complete:
        sys.exit("worktree-status: this session is workspace-scoped, so its workspace list is partial and "
                 "cleanup could miss a live task workspace. Run it from an unscoped session.")

    worktrees = list_worktrees(repo)
    worktree_by_path = {worktree.path: worktree for worktree in worktrees}
    rows: list[Row] = []
    without_pr: list[Row] = []
    matches_by_pr: dict[int, list[Workspace]] = {}
    seen_prs: set[int] = set()

    def pr_row(pr: dict, worktree: Worktree | None, ambiguous: bool = False) -> Row:
        if worktree:
            local, dirty = local_state(worktree)
        else:
            local, dirty = "no local worktree", False
        if pr["state"] == "OPEN":
            refresh_merge_state(pr, repo)
        row = Row(worktree=worktree.path if worktree else None, branch=pr["headRefName"], local=local,
                  pr=pr["number"], pr_state=pr["state"], head=pr["headRefOid"], title=pr["title"])
        summarize_checks(row, pr)
        matches = match_workspaces(workspace_list, row.worktree, row.pr, repo_slug)
        matches_by_pr[pr["number"]] = matches
        if matches:
            row.workspace = " | ".join(w.label for w in matches) + (" (ambiguous)" if len(matches) > 1 else "")
        row.workspace_ids = [w.workspace_id for w in matches]
        verdict(row, pr, worktree, dirty, ambiguous)
        return row

    for worktree in worktrees:
        if worktree.branch == default_branch:
            continue
        pr, ambiguous = branch_pr(worktree.branch)
        if pr is None:
            local, _ = local_state(worktree)
            matches = match_workspaces(workspace_list, worktree.path, None, repo_slug)
            without_pr.append(Row(worktree=worktree.path, branch=worktree.branch, local=local,
                                  workspace=" | ".join(w.label for w in matches) or None))
            continue
        seen_prs.add(pr["number"])
        rows.append(pr_row(pr, worktree, ambiguous))
    for pr in prs:
        if pr["state"] == "OPEN" and pr["number"] not in seen_prs:
            rows.append(pr_row(pr, None))

    if options.cleanup_merged:
        own_workspace = caller_workspace_id()
        for row in rows:
            if row.verdict == "cleanup" and row.worktree:
                others = [w.path for w in worktrees if w.path != row.worktree]
                row.cleanup = clean_up(row, worktree_by_path[row.worktree], repo, repo_slug, own_workspace,
                                       matches_by_pr[row.pr], others)

    order = {"ready": 0, "cleanup": 1, "blocked": 2}
    rows.sort(key=lambda row: (order[row.verdict], row.pr or 0))
    if options.json:
        print(json.dumps({"repository": repo_slug, "fetched": fetched,
                          "prs": [asdict(row) for row in rows],
                          "worktreesWithoutPR": [asdict(row) for row in without_pr]}, indent=2))
        return
    if not fetched:
        print("(git fetch failed: local ahead/behind counts may be stale)\n")
    if workspace_list is None:
        print("(Toastty workspaces unavailable: set TOASTTY_CLI_PATH to a Toastty with workspace.list)\n")
    home = str(Path.home())
    for row in rows:
        label = f"#{row.pr} {row.pr_state.lower()}" if row.pr else "no PR"
        print(f"{row.verdict.upper():8} {label:14} {row.title or row.branch}")
        where = (row.worktree or "-").replace(home, "~")
        print(f"         worktree  {where}  [{row.branch}]  {row.local}")
        checks = f"{row.passed_checks} passed"
        for name, items in (("failing", row.failing_checks), ("running", row.pending_checks),
                            ("skipped", row.skipped_checks)):
            if items:
                checks += f"; {name}: " + ", ".join(items)
        print(f"         checks    {checks}")
        print(f"         workspace {row.workspace or '-'}")
        if row.reason:
            print(f"         reason    {row.reason}")
        if row.cleanup:
            print(f"         cleanup   {row.cleanup}")
        print()
    if without_pr:
        print("Worktrees without a PR:")
        for row in without_pr:
            workspace = f"  workspace {row.workspace}" if row.workspace else ""
            print(f"  {row.worktree.replace(home, '~')}  [{row.branch}]  {row.local}{workspace}")


if __name__ == "__main__":
    main()
