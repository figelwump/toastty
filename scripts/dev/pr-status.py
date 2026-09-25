#!/usr/bin/env python3
"""Show each worktree's PR, CI, local state, and Toastty workspace in one table.

Usage: scripts/dev/pr-status.py [--json]

Run from any worktree of the repository. Needs `git` and an authenticated `gh`.
Toastty workspaces are matched when TOASTTY_CLI_PATH points at a Toastty that
supports the `workspace.list` query; otherwise the workspace column is blank.

Verdicts:
  ready     open, not draft, mergeable, every check finished and the gate passed,
            and the worktree is clean at exactly the PR head commit
  cleanup   merged, and the worktree is clean at exactly the merged PR head
  blocked   anything else; the reason says what is missing
Worktrees whose branch has no PR are listed separately.
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

GATE_CHECK = "Mobile iOS gate"
PR_FIELDS = (
    "number,title,state,isDraft,headRefName,headRefOid,baseRefName,isCrossRepository,"
    "mergeable,mergeStateStatus,statusCheckRollup,url"
)


def run(args: list[str], cwd: str | None = None, check: bool = True) -> str:
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.exit(f"pr-status: {' '.join(args[:3])} failed: {result.stderr.strip()}")
    return result.stdout


@dataclass
class Worktree:
    path: str
    branch: str | None
    head: str


@dataclass
class Row:
    worktree: str | None
    branch: str | None
    pr: int | None = None
    pr_state: str | None = None
    title: str | None = None
    gate: str | None = None
    skipped_checks: list[str] = field(default_factory=list)
    failing_checks: list[str] = field(default_factory=list)
    pending_checks: list[str] = field(default_factory=list)
    local: str = ""
    workspace: str | None = None
    verdict: str = "blocked"
    reason: str = ""


def list_worktrees(repo: str) -> list[Worktree]:
    worktrees: list[Worktree] = []
    entry: dict[str, str] = {}
    for line in run(["git", "worktree", "list", "--porcelain"], cwd=repo).splitlines() + [""]:
        if not line:
            if "worktree" in entry and "prunable" not in entry:
                branch = entry.get("branch", "").removeprefix("refs/heads/") or None
                worktrees.append(Worktree(entry["worktree"], branch, entry.get("HEAD", "")))
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


def summarize_checks(pr: dict) -> tuple[str | None, list[str], list[str], list[str]]:
    gate, skipped, failing, pending = None, [], [], []
    for check in pr.get("statusCheckRollup") or []:
        name = check.get("name") or check.get("context") or "?"
        conclusion = (check.get("conclusion") or check.get("state") or "").upper()
        status = (check.get("status") or "").upper()
        outcome = conclusion or status or "PENDING"
        if status and status != "COMPLETED":
            outcome = "PENDING"
        if name == GATE_CHECK:
            gate = outcome
        elif outcome == "PENDING":
            pending.append(name)
        elif outcome == "SKIPPED":
            skipped.append(name)
        elif outcome not in ("SUCCESS", "NEUTRAL"):
            failing.append(name)
    # The gate job waits for the others, so it is absent while they run.
    if gate is None and pending:
        gate = "PENDING"
    return gate, skipped, failing, pending


def toastty_workspaces() -> list[dict] | None:
    cli = os.environ.get("TOASTTY_CLI_PATH")
    if not cli:
        return None
    output = run([cli, "--json", "query", "run", "workspace.list"], check=False)
    try:
        response = json.loads(output)
    except json.JSONDecodeError:
        return None
    if not response.get("ok"):
        return None
    return response.get("result", {}).get("workspaces", [])


def match_workspace(workspaces: list[dict] | None, path: str | None, pr: int | None,
                    repo_slug: str) -> str | None:
    """Matches by a terminal inside the worktree, then by a github-pr chip whose URL
    names this PR, then by chip text for chips without a URL. Several matches at
    the same level are reported together as ambiguous."""
    if not workspaces:
        return None

    def chips(workspace: dict) -> list[dict]:
        return [a for a in workspace.get("annotations", []) if a.get("key") == "github-pr"]

    pr_url = re.compile(rf"github\.com/{re.escape(repo_slug)}/pull/{pr}/?$", re.IGNORECASE)
    pr_text = re.compile(rf"#{pr}\b")
    levels = [
        lambda w: bool(path) and any(cwd == path or cwd.startswith(path + "/") for cwd in w.get("terminalCwds", [])),
        lambda w: bool(pr) and any(pr_url.search(a.get("url") or "") for a in chips(w)),
        lambda w: bool(pr) and any(not a.get("url") and pr_text.search(a.get("text", "")) for a in chips(w)),
    ]
    for matches in levels:
        found = [f"{w['title']} ({w['workspaceID'][:8]})" for w in workspaces if matches(w)]
        if found:
            return found[0] if len(found) == 1 else " | ".join(found) + " (ambiguous)"
    return None


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
    elif pr["mergeStateStatus"] not in ("CLEAN", "UNSTABLE", "HAS_HOOKS"):
        reasons.append(f"merge state {pr['mergeStateStatus'].lower()}")
    if row.gate != "SUCCESS":
        reasons.append(f"gate {(row.gate or 'missing').lower()}")
    if row.failing_checks:
        reasons.append("failing: " + ", ".join(row.failing_checks))
    if row.pending_checks:
        reasons.append("still running: " + ", ".join(row.pending_checks))
    if reasons:
        row.reason = "; ".join(reasons)
    else:
        row.verdict = "ready"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="print rows as JSON")
    options = parser.parse_args()

    repo = run(["git", "rev-parse", "--show-toplevel"]).strip()
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

    workspaces = toastty_workspaces()

    rows: list[Row] = []
    without_pr: list[Row] = []
    seen_prs: set[int] = set()

    def pr_row(pr: dict, worktree: Worktree | None, ambiguous: bool = False) -> Row:
        if worktree:
            local, dirty = local_state(worktree)
        else:
            local, dirty = "no local worktree", False
        if pr["state"] == "OPEN":
            refresh_merge_state(pr, repo)
        row = Row(worktree=worktree.path if worktree else None, branch=pr["headRefName"], local=local,
                  pr=pr["number"], pr_state=pr["state"], title=pr["title"])
        row.gate, row.skipped_checks, row.failing_checks, row.pending_checks = summarize_checks(pr)
        row.workspace = match_workspace(workspaces, row.worktree, row.pr, repo_slug)
        verdict(row, pr, worktree, dirty, ambiguous)
        return row

    for worktree in list_worktrees(repo):
        if worktree.branch == default_branch:
            continue
        pr, ambiguous = branch_pr(worktree.branch)
        if pr is None:
            local, _ = local_state(worktree)
            without_pr.append(Row(worktree=worktree.path, branch=worktree.branch, local=local,
                                  workspace=match_workspace(workspaces, worktree.path, None, repo_slug)))
            continue
        seen_prs.add(pr["number"])
        rows.append(pr_row(pr, worktree, ambiguous))
    for pr in prs:
        if pr["state"] == "OPEN" and pr["number"] not in seen_prs:
            rows.append(pr_row(pr, None))

    order = {"ready": 0, "cleanup": 1, "blocked": 2}
    rows.sort(key=lambda row: (order[row.verdict], row.pr or 0))
    if options.json:
        print(json.dumps({"fetched": fetched, "prs": [asdict(row) for row in rows],
                          "worktreesWithoutPR": [asdict(row) for row in without_pr]}, indent=2))
        return
    if not fetched:
        print("(git fetch failed: local ahead/behind counts may be stale)\n")
    if workspaces is None:
        print("(Toastty workspaces unavailable: set TOASTTY_CLI_PATH to a Toastty with workspace.list)\n")
    home = str(Path.home())
    for row in rows:
        pr = f"#{row.pr} {row.pr_state.lower()}" if row.pr else "no PR"
        print(f"{row.verdict.upper():8} {pr:14} {row.title or row.branch}")
        where = (row.worktree or "-").replace(home, "~")
        print(f"         worktree  {where}  [{row.branch}]  {row.local}")
        if row.pr:
            checks = f"gate {(row.gate or 'missing').lower()}"
            if row.skipped_checks:
                checks += "; skipped: " + ", ".join(row.skipped_checks)
            print(f"         checks    {checks}")
        print(f"         workspace {row.workspace or '-'}")
        if row.reason:
            print(f"         reason    {row.reason}")
        print()
    if without_pr:
        print("Worktrees without a PR:")
        for row in without_pr:
            workspace = f"  workspace {row.workspace}" if row.workspace else ""
            print(f"  {row.worktree.replace(home, '~')}  [{row.branch}]  {row.local}{workspace}")


if __name__ == "__main__":
    main()
