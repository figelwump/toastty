#!/usr/bin/env python3
"""Show each worktree's PR, checks, local state, and Toastty workspace; optionally
clean up worktrees whose PR has merged.

Usage: worktree-status.py [--json] [--cleanup-merged] [--pr NUMBER] [--repo PATH]
       worktree-status.py --close-unmerged --pr NUMBER --pr-url URL --workspace ID [--json] [--repo PATH]

Run from any checkout of the repository, or pass --repo. Git commands run in the
repository's main checkout, so a worktree being removed is never the current
directory. --pr limits the report, and so the cleanup, to that pull request.
--workspace, with --pr, names the one Toastty workspace cleanup may close; cleanup
skips the PR unless that exact workspace is the match and is still marked done. Needs `git` and an
authenticated `gh`. Toastty workspaces are matched through TOASTTY_CLI_PATH and
the `workspace.list` query; --cleanup-merged requires them.

Verdicts:
  ready     open, not draft, GitHub reports it mergeable with required checks met,
            no check failing or still running, the worktree is clean at exactly
            the PR head commit, and the description lists no merge prerequisites
  cleanup   merged, and the worktree is clean at exactly the merged PR head
  blocked   anything else; the reason says what is missing. A description with an
            "Activation order", "Merge order", "Rollout", or "Depends on" section,
            or a link to a PR in another repository, blocks until the user
            confirms those prerequisites are done
Worktrees whose branch has no PR are listed separately and never touched.

--cleanup-merged acts only on "cleanup" rows. For each, it closes the matching
Toastty workspace, removes the worktree, and deletes the local and remote branch.
Closing the workspace ends its agent sessions and terminal commands; the row's
cleanup report names the sessions and busy terminals it ended.
It refuses to run from a workspace-scoped session, whose workspace list is partial.
It skips a row, changing nothing, when the workspace match is ambiguous; when the
workspace is the caller's own, holds another worktree or another PR's chip, or has
unsaved documents; or when the worktree is locked.
Each cleaned-up row's cleanup_status is "cleaned" (workspace closed when there
was one, worktree removed, branches deleted), "partial" (some changes made and
something kept), "stopped" (a step failed before any change), or "skipped". It rereads the workspace list
just before closing each workspace, rechecks the worktree just before removing it,
and deletes each branch only while it still points at the merged commit.

--close-unmerged abandons one PR instead. --pr-url must be that PR's URL, so a
number from another repository is refused. After the same checks, with the worktree
clean at exactly the PR head and the remote branch also at that head, so no work
exists only locally, it closes the PR if it is open. It then rechecks the workspace,
closes it (done or not), removes the worktree, and deletes the local branch. It keeps
the remote branch, so the PR can be reopened. It refuses a merged PR. Toastty's
Close Without Merging runs it this way.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter
from dataclasses import asdict, dataclass, field
from pathlib import Path

PR_FIELDS = (
    "number,title,state,isDraft,headRefName,headRefOid,baseRefName,isCrossRepository,"
    "mergeable,mergeStateStatus,statusCheckRollup,url,body"
)
# GitHub computes these after branch protection: CLEAN means required checks are
# met and nothing blocks the merge; HAS_HOOKS is CLEAN with pre-receive hooks.
MERGEABLE_STATES = ("CLEAN", "HAS_HOOKS")
# Closing a workspace sends SIGHUP to its terminals without waiting for them to
# exit. When it ended live work, wait this long before rechecking the worktree so
# a final write from a dying command shows up as uncommitted changes.
CLOSE_GRACE_SECONDS = 2.0
# A PR description section or label line that orders this merge after other work.
PREREQUISITE_SECTION = re.compile(
    r"^\s{0,3}(?:[-*]\s+)?(?:#{1,6}\s*|\*\*)?(activation order|merge order|rollout|depends on)\b(?:\*\*)?\s*(?::|$|\*\*|(?=#\d|https?://|[\w.-]+/[\w.-]+#\d))",
    re.IGNORECASE | re.MULTILINE)
PR_URL = re.compile(r"github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)", re.IGNORECASE)
PR_REFERENCE = re.compile(r"(?<![\w./-])([\w.-]+/[\w.-]+)#(\d+)\b")


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
    session_agents: list[str]
    busy_terminals: int
    unsaved_documents: int
    done: bool = False

    @property
    def label(self) -> str:
        return f"{self.title} ({self.workspace_id[:8]})"

    def ended_by_close(self) -> str | None:
        """Describes the agent sessions and busy terminals that closing ends. An
        agent's own terminal usually counts as busy too, so the counts overlap."""
        parts: list[str] = []
        if self.session_agents:
            count = len(self.session_agents)
            kinds = ", ".join(f"{n} {agent}" for agent, n in sorted(Counter(self.session_agents).items()))
            parts.append(f"{count} agent session{'s' if count > 1 else ''} ({kinds})")
        if self.busy_terminals:
            busy = f"{self.busy_terminals} terminal{'s' if self.busy_terminals > 1 else ''} running a command"
            parts.append(busy + (", counting agent terminals" if self.session_agents else ""))
        return " and ".join(parts) or None


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
    cleanup_status: str | None = None


def real(path: str) -> str:
    """Canonical path, so /var and /private/var style aliases compare equal."""
    return os.path.realpath(path)


def inside(path: str, directory: str) -> bool:
    return path == directory or path.startswith(directory.rstrip("/") + "/")


def main_checkout(checkout: str) -> str:
    """The repository's main worktree, or `checkout` itself for a bare repository."""
    first = run(["git", "worktree", "list", "--porcelain"], cwd=checkout).split("\n\n")[0]
    entry = dict(line.partition(" ")[::2] for line in first.splitlines())
    if "bare" in entry or "worktree" not in entry:
        return checkout
    return real(entry["worktree"])


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
                      chips(w), [s.get("agent") or "unknown" for s in w.get("activeSessions", [])],
                      w.get("busyTerminalCount", 0),
                      w.get("unsavedDocumentCount", 0), w.get("done", False))
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


def merge_prerequisites(body: str, repo_slug: str) -> str | None:
    """Describes merge prerequisites the PR description lists, or None. Links to
    PRs in this repository alone do not count; stacked PRs are handled by base."""
    found: list[str] = []
    for match in PREREQUISITE_SECTION.finditer(body):
        name = match.group(1).capitalize()
        if f"{name} section" not in found:
            found.append(f"{name} section")
    links: list[str] = []
    for pattern in (PR_URL, PR_REFERENCE):
        for slug, number in pattern.findall(body):
            link = f"{slug}#{number}"
            if slug.lower() != repo_slug.lower() and link not in links:
                links.append(link)
    if links:
        found.append("links " + ", ".join(links))
    if not found:
        return None
    return ("merge prerequisites in the PR description (" + "; ".join(found) +
            "): merge only after the user confirms they are done")


def verdict(row: Row, pr: dict, worktree: Worktree | None, dirty: bool, ambiguous: bool,
            repo_slug: str) -> None:
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
    prerequisites = merge_prerequisites(pr.get("body") or "", repo_slug)
    if prerequisites:
        reasons.append(prerequisites)
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
             workspaces: list[Workspace], other_worktrees: list[str],
             expected_workspace: str | None = None, close_pr: bool = False) -> tuple[str, str]:
    """Closes the workspace, removes the worktree, and deletes both branches. Every
    guard runs before the first change; a failure after one reports what was done.
    With close_pr, the PR is unmerged: an open PR is closed first, the workspace
    need not be marked done, and the remote branch is kept so the PR can be reopened.
    Returns the cleanup status and a description."""
    def skip(reason: str) -> tuple[str, str]:
        return "skipped", f"skipped: {reason}"

    def workspace_problem(candidates: list[Workspace]) -> str | None:
        if len(candidates) > 1:
            return "several workspaces match (" + ", ".join(w.label for w in candidates) + ")"
        found = candidates[0] if candidates else None
        if expected_workspace:
            if found is None or found.workspace_id != expected_workspace:
                return f"the matching workspace is not {expected_workspace[:8]} (found {found.label if found else 'none'})"
            if not found.done and not close_pr:
                return f"{found.label} is no longer marked done"
        if found:
            if found.workspace_id == own_workspace:
                return "that is this session's own workspace"
            if found.unsaved_documents:
                return f"{found.label} has unsaved document changes"
            if any(inside(cwd, other) for cwd in found.cwds for other in other_worktrees):
                return f"{found.label} also has a terminal in another worktree"
            if other_pr_chip(found, row.pr, repo_slug):
                return f"{found.label} carries a chip for a different PR"
        return None

    problem = workspace_problem(workspaces)
    if problem:
        return skip(problem)
    workspace = workspaces[0] if workspaces else None
    if worktree.locked:
        return skip("the worktree is locked")
    problem = recheck(worktree, row.head)
    if problem:
        return skip(f"{problem}")
    if close_pr:
        # The local branch goes, so the work must survive on GitHub at exactly
        # this head; an already-closed PR may have lost its branch.
        ok, output = succeeds(["git", "ls-remote", "--heads", "origin", row.branch], cwd=repo)
        remote = output.split() if ok else []
        if not ok:
            return skip(f"could not query origin: {output}")
        if not remote or remote[0] != row.head:
            return skip("the PR's branch on GitHub is missing or at another commit, "
                        "so the local branch is the only copy of the work")

    done: list[str] = []

    def stop(message: str) -> tuple[str, str]:
        if done:
            return "partial", "partial: " + "; ".join(done + [message])
        return "stopped", f"stopped: {message}"

    if close_pr and row.pr_state == "OPEN":
        ok, output = succeeds(["gh", "pr", "close", str(row.pr)], cwd=repo)
        if not ok:
            return stop(f"could not close PR #{row.pr}: {output}")
        done.append(f"closed PR #{row.pr}")
        # The workspace may have changed during the network call.
        current, complete = toastty_workspaces()
        if current is None or not complete:
            return stop("could not reread the full Toastty workspace list; workspace kept")
        candidates = match_workspaces(current, worktree.path, row.pr, repo_slug)
        problem = workspace_problem(candidates)
        if problem:
            return stop(f"{problem}; workspace kept")
        workspace = candidates[0] if candidates else None
    if workspace:
        ok, output = succeeds([toastty_cli(), "--json", "action", "run", "workspace.close",
                               "--workspace", workspace.workspace_id])
        try:
            ok = ok and json.loads(output).get("ok") is True
        except json.JSONDecodeError:
            ok = False
        if not ok:
            return stop(f"could not close {workspace.label}: {output}")
        ended = workspace.ended_by_close()
        done.append(f"closed {workspace.label}" + (f", ending {ended}" if ended else ""))
        if ended:
            time.sleep(CLOSE_GRACE_SECONDS)
    problem = recheck(worktree, row.head)
    if problem:
        return stop(f"{problem}; worktree kept")
    ok, output = succeeds(["git", "worktree", "remove", worktree.path], cwd=repo)
    if not ok:
        return stop(f"git worktree remove failed: {output}")
    done.append("removed worktree")
    # Compare-and-delete: the ref goes only if it still points at the PR head.
    # Squash merges leave it unmerged by ancestry, so `git branch -d` would refuse.
    # An unmerged PR's commits stay on the remote branch, which equals this head.
    ok, output = succeeds(["git", "update-ref", "-d", f"refs/heads/{row.branch}", row.head], cwd=repo)
    complete = ok
    done.append("deleted local branch" if ok else f"local branch kept: {output}")
    if close_pr:
        done.append("kept the branch on GitHub")
        return ("cleaned" if complete else "partial"), "; ".join(done)
    ok, output = succeeds(["git", "ls-remote", "--heads", "origin", row.branch], cwd=repo)
    remote = output.split() if ok else []
    if not ok:
        complete = False
        done.append(f"remote branch kept: could not query origin: {output}")
    elif remote and remote[0] == row.head:
        ok, output = succeeds(["git", "push", f"--force-with-lease=refs/heads/{row.branch}:{row.head}",
                               "origin", f":refs/heads/{row.branch}"], cwd=repo)
        complete = complete and ok
        done.append("deleted remote branch" if ok else f"remote branch kept: {output}")
    elif remote:
        complete = False
        done.append(f"remote branch kept: it now points at {remote[0][:8]}")
    return ("cleaned" if complete else "partial"), "; ".join(done)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="print rows as JSON")
    parser.add_argument("--cleanup-merged", action="store_true",
                        help="close workspaces, remove worktrees, and delete branches for merged PRs")
    parser.add_argument("--repo", help="any checkout of the repository (default: current directory)")
    parser.add_argument("--pr", type=int, help="report and clean up only this pull request")
    parser.add_argument("--workspace", help="with --pr: the only Toastty workspace cleanup may close")
    parser.add_argument("--close-unmerged", action="store_true",
                        help="with --pr, --pr-url, and --workspace: close that PR without merging, then "
                             "clean up but keep the remote branch")
    parser.add_argument("--pr-url", help="with --close-unmerged: the PR's URL, which must match the PR "
                                         "this checkout's repository has under --pr")
    options = parser.parse_args()
    if options.workspace and options.pr is None:
        parser.error("--workspace needs --pr")
    if options.close_unmerged and (options.pr is None or not options.workspace or not options.pr_url):
        parser.error("--close-unmerged needs --pr, --pr-url, and --workspace")
    if options.close_unmerged and options.cleanup_merged:
        parser.error("use --close-unmerged or --cleanup-merged, not both")
    acting = options.cleanup_merged or options.close_unmerged

    repo = main_checkout(run(["git", "rev-parse", "--show-toplevel"], cwd=options.repo).strip())
    fetched = subprocess.run(["git", "fetch", "--quiet", "--prune", "origin"], cwd=repo,
                             capture_output=True).returncode == 0
    repo_info = json.loads(run(["gh", "repo", "view", "--json", "nameWithOwner,defaultBranchRef"], cwd=repo))
    repo_slug, default_branch = repo_info["nameWithOwner"], repo_info["defaultBranchRef"]["name"]
    if options.pr is not None:
        # Fetched directly, so a PR older than the list's window still has a row.
        prs = [json.loads(run(["gh", "pr", "view", str(options.pr), "--json", PR_FIELDS], cwd=repo))]
    else:
        prs = json.loads(run(["gh", "pr", "list", "--state", "all", "--limit", "200", "--json", PR_FIELDS],
                             cwd=repo))
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
    if acting and workspace_list is None:
        sys.exit("worktree-status: cleanup needs TOASTTY_CLI_PATH and a Toastty with workspace.list, "
                 "so it can check each workspace before closing it")
    if acting and not workspace_list_complete:
        sys.exit("worktree-status: this session is workspace-scoped, so its workspace list is partial and "
                 "cleanup could miss a live task workspace. Run it from an unscoped session.")

    worktrees = list_worktrees(repo)
    worktree_by_path = {worktree.path: worktree for worktree in worktrees}
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
                  pr=pr["number"], pr_state=pr["state"], head=pr["headRefOid"], title=pr["title"])
        summarize_checks(row, pr)
        matches = match_workspaces(workspace_list, row.worktree, row.pr, repo_slug)
        if matches:
            row.workspace = " | ".join(w.label for w in matches) + (" (ambiguous)" if len(matches) > 1 else "")
        row.workspace_ids = [w.workspace_id for w in matches]
        verdict(row, pr, worktree, dirty, ambiguous, repo_slug)
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

    def act_on(row: Row, own_workspace: str | None) -> None:
        # Reread the workspaces: sessions, documents, and terminals may have
        # changed while the PRs were queried or earlier rows were cleaned up.
        current, complete = toastty_workspaces()
        if current is None or not complete:
            row.cleanup_status = "skipped"
            row.cleanup = "skipped: could not reread the full Toastty workspace list"
            return
        others = [w.path for w in worktrees if w.path != row.worktree]
        row.cleanup_status, row.cleanup = clean_up(
            row, worktree_by_path[row.worktree], repo, repo_slug, own_workspace,
            match_workspaces(current, row.worktree, row.pr, repo_slug), others, options.workspace,
            close_pr=options.close_unmerged)

    if options.cleanup_merged:
        own_workspace = caller_workspace_id()
        for row in rows:
            if row.verdict == "cleanup" and row.worktree:
                act_on(row, own_workspace)
    if options.close_unmerged:
        def same_url(first: str, second: str) -> bool:
            return first.rstrip("/").lower() == second.rstrip("/").lower()

        pr_url = prs[0].get("url") or ""
        for row in rows:
            if row.pr != options.pr:
                continue
            if not same_url(pr_url, options.pr_url):
                # The number alone could name a PR in another repository.
                row.cleanup_status, row.cleanup = "skipped", (
                    f"skipped: {options.pr_url} is not this repository's PR #{row.pr} ({pr_url})")
            elif row.pr_state == "MERGED":
                row.cleanup_status, row.cleanup = "skipped", "skipped: the PR has merged; nothing to close"
            elif not row.worktree:
                row.cleanup_status, row.cleanup = "skipped", "skipped: no local worktree has the PR's branch"
            else:
                act_on(row, caller_workspace_id())

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
