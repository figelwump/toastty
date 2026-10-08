#!/usr/bin/env python3
"""Merge, clean up, or close one task pull request for a Toastty subspace.

Usage: workspace-pull-request.py ACTION --pr NUMBER --pr-url URL --workspace ID --repo PATH [--head SHA]

Toastty runs this for a subspace's Merge button; it is not a user command.
ACTION is one of:

  merge     Merges the PR at exactly the accepted commit, or reports "waiting" while
            checks are running or GitHub still blocks the merge, for example on a
            required review. It merges through GitHub's merge API with that commit,
            so it never turns on auto-merge or joins a merge queue, and it refuses
            a PR that already has auto-merge on: GitHub would also merge commits
            pushed later. Toastty runs it again with --head until it merges.
            Without --head, the accepted commit is the clicked checkout's HEAD,
            read first; the checkout must be the PR's worktree, clean at that
            commit, and the PR head must be that commit. With --head, the PR head
            must still be that commit, and the workspace must still be marked
            done, which is how the user cancels a waiting merge. Either way it
            refuses, changing nothing, unless the PR targets the default branch,
            has no conflicts or failing checks, and its description lists no merge
            prerequisites: an "Activation order", "Merge order", "Rollout", or
            "Depends on" section, or a link to a PR in another repository. A draft
            is marked ready first. The merge method is the first one the
            repository allows: merge commit, squash, then rebase.
  clean-up  After the PR merged: closes the workspace, removes the worktree, and
            deletes the local and remote branch. The workspace must be marked done.
            A detached task checkout must have one exact PR URL chip and be at
            the PR head or GitHub's merge commit. Merge and close still require
            the PR branch at its head.
  close     Closes the PR without merging, then cleans up as above, except that the
            workspace need not be done and the remote branch is kept so the PR can
            be reopened. The remote branch must be at the PR head before anything
            changes, so no work exists only locally.

--pr-url must be the PR's URL, so a number from another repository is refused.
--workspace is the one Toastty workspace clean-up and close may close. They skip,
changing nothing, when that workspace is not the one whose terminals are in the
worktree (or whose github-pr chip names the PR), when it has unsaved documents,
a terminal in another worktree, or another PR's chip, or when the worktree is
locked. They reread the workspace just before closing it, recheck the worktree
just before removing it, and delete each branch only while it still points at the
PR head. Closing a workspace ends its agent sessions and terminal commands.

Needs `git` and an authenticated `gh`. clean-up and close also need
TOASTTY_CLI_PATH pointing at a Toastty with `workspace.list`. Git commands run in
the repository's main checkout, so a worktree being removed is never the current
directory.

Prints one JSON object, {"status": ..., "detail": ...}. merge reports "merged",
"waiting" (nothing changed yet; run again with --head), "refused" (nothing
changed), or "failed", and adds "head", the accepted commit. clean-up
and close report "cleaned", "partial" (some changes made and something kept),
"stopped" (a step failed before any change), or "skipped" (nothing changed).
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
from dataclasses import dataclass

PR_FIELDS = (
    "number,state,isDraft,headRefName,headRefOid,baseRefName,isCrossRepository,"
    "mergeable,mergeStateStatus,statusCheckRollup,url,body,mergeCommit,autoMergeRequest"
)
# The order to pick a merge method in, among the ones the repository allows.
MERGE_METHODS = (("mergeCommitAllowed", "merge"), ("squashMergeAllowed", "squash"),
                 ("rebaseMergeAllowed", "rebase"))
# GitHub computes these after branch protection: CLEAN means required checks are
# met and nothing blocks the merge; HAS_HOOKS is CLEAN with pre-receive hooks.
MERGEABLE_STATES = ("CLEAN", "HAS_HOOKS", "UNSTABLE")
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


class Refusal(Exception):
    """A check failed before any change; the message says which."""


def run(args: list[str], cwd: str | None = None, check: bool = True) -> str:
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.exit(f"workspace-pull-request: {' '.join(args[:3])} failed: {result.stderr.strip()}")
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
    done: bool

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
class Context:
    repo: str
    repo_slug: str
    default_branch: str
    repo_info: dict
    pr: dict
    worktree: Worktree | None
    other_worktrees: list[str]
    workspace_id: str
    # The --repo directory: the clicked workspace's checkout.
    checkout: str
    # The checkout's HEAD, read before any network call, for a merge click.
    clicked_head: str | None = None


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


def worktree_problem(worktree: Worktree, pr_head: str, head_label: str = "PR head") -> str | None:
    """Rereads the worktree; returns why it is not clean at the pinned commit."""
    ok, head = succeeds(["git", "rev-parse", "HEAD"], cwd=worktree.path)
    if not ok:
        return f"could not read the worktree HEAD: {head}"
    if head != pr_head:
        counts = run(["git", "rev-list", "--left-right", "--count", f"HEAD...{pr_head}"],
                     cwd=worktree.path, check=False).split()
        if len(counts) == 2:
            return f"the worktree is {counts[0]} commits ahead and {counts[1]} behind the {head_label} {pr_head[:8]}"
        return f"the worktree HEAD {head[:8]} is not the {head_label} {pr_head[:8]}"
    if worktree.branch is None:
        # A branch attached at the same commit is also a changed selection.
        result = subprocess.run(["git", "symbolic-ref", "--quiet", "HEAD"], cwd=worktree.path,
                                capture_output=True, text=True)
        if result.returncode == 0:
            return "the selected detached worktree now has a checked-out branch"
        if result.returncode != 1:
            return f"could not read the detached worktree state: {result.stderr.strip()}"
    result = subprocess.run(["git", "status", "--porcelain"], cwd=worktree.path, capture_output=True, text=True)
    if result.returncode != 0:
        return f"could not read the worktree status: {result.stderr.strip()}"
    if result.stdout.strip():
        return "the worktree has uncommitted changes"
    return None


def check_summary(pr: dict) -> tuple[list[str], list[str]]:
    """The names of failing checks and of checks still running."""
    failing: list[str] = []
    pending: list[str] = []
    for check in pr.get("statusCheckRollup") or []:
        name = check.get("name") or check.get("context") or "?"
        conclusion = (check.get("conclusion") or check.get("state") or "").upper()
        status = (check.get("status") or "").upper()
        if (status and status != "COMPLETED") or not conclusion or conclusion in ("PENDING", "EXPECTED"):
            pending.append(name)
        elif conclusion not in ("SUCCESS", "NEUTRAL", "SKIPPED"):
            failing.append(name)
    return failing, pending


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
    return "its description lists merge prerequisites (" + "; ".join(found) + ")"


def refresh_merge_state(ctx: Context) -> None:
    """`gh` reports UNKNOWN until GitHub computes mergeability, which a request
    triggers; ask once more if it is still computing."""
    for _ in range(2):
        if ctx.pr.get("mergeStateStatus") != "UNKNOWN":
            return
        view = run(["gh", "pr", "view", str(ctx.pr["number"]), "--json", "mergeable,mergeStateStatus"],
                   cwd=ctx.repo, check=False)
        ctx.pr.update(json.loads(view or "{}"))


# MARK: - Merge

def merge(ctx: Context, accepted: str | None) -> tuple[str, str, str]:
    """Returns the status, a description, and the accepted commit."""
    pr, number = ctx.pr, ctx.pr["number"]
    if accepted is None:
        # The click: what merges is the version in the clicked workspace, as
        # it was before this script fetched or asked GitHub anything.
        if ctx.worktree is None:
            raise Refusal(f"no worktree has the PR's branch {pr['headRefName']}")
        if not inside(ctx.checkout, ctx.worktree.path):
            # The annotation could name another task's PR.
            raise Refusal(f"this workspace's checkout is not the worktree of PR #{number} ({ctx.worktree.path})")
        accepted = ctx.clicked_head
        if not accepted:
            raise Refusal("could not read the commit in this workspace's checkout")
        problem = worktree_problem(ctx.worktree, accepted)
        if problem:
            raise Refusal(problem + "; the merge would not be the version in this workspace")
        if pr["headRefOid"] != accepted:
            raise Refusal(f"the PR head {pr['headRefOid'][:8]} is not the commit in this workspace "
                          f"{accepted[:8]}; the merge would not be the version in this workspace")

    if pr["headRefOid"] != accepted:
        raise Refusal(f"new commits were pushed after the merge was accepted: the PR head is now "
                      f"{pr['headRefOid'][:8]}, not {accepted[:8]}")
    if pr["state"] == "MERGED":
        return "merged", f"PR #{number} has merged", accepted
    if pr["state"] != "OPEN":
        raise Refusal(f"PR #{number} is closed")
    if pr.get("autoMergeRequest"):
        raise Refusal(f"auto-merge is on for PR #{number}, so GitHub would also merge commits pushed later; "
                      "turn it off on GitHub, then merge again")
    if pr["baseRefName"] != ctx.default_branch:
        raise Refusal(f"it targets {pr['baseRefName']}, not {ctx.default_branch}; merge that pull request "
                      "first, and GitHub then retargets this one")
    refresh_merge_state(ctx)
    failing, pending = check_summary(pr)
    reasons: list[str] = []
    if pr.get("mergeable") == "CONFLICTING" or pr.get("mergeStateStatus") == "DIRTY":
        reasons.append("it has merge conflicts")
    if pr.get("mergeStateStatus") == "BEHIND":
        reasons.append(f"its branch is behind {ctx.default_branch} and must be updated")
    if failing:
        reasons.append("failing checks: " + ", ".join(failing))
    prerequisites = merge_prerequisites(pr.get("body") or "", ctx.repo_slug)
    if prerequisites:
        reasons.append(prerequisites + "; merge it yourself once they are done")
    if reasons:
        raise Refusal("; ".join(reasons))
    method = next((flag for key, flag in MERGE_METHODS if ctx.repo_info.get(key)), None)
    if method is None:
        raise Refusal("the repository allows no merge method")

    if pr["isDraft"]:
        ok, output = succeeds(["gh", "pr", "ready", str(number)], cwd=ctx.repo)
        if not ok:
            return "failed", f"could not mark draft PR #{number} ready: {output}", accepted
        return "waiting", f"marked draft PR #{number} ready; waiting for GitHub to allow the merge", accepted
    if pending:
        return "waiting", "waiting for checks: " + ", ".join(pending), accepted
    if pr.get("mergeStateStatus") not in MERGEABLE_STATES:
        # BLOCKED with no check running: a required review or a required check
        # that has not reported. UNKNOWN: GitHub is still computing.
        state = (pr.get("mergeStateStatus") or "unknown").lower()
        return "waiting", f"waiting for GitHub to allow the merge (merge state {state})", accepted
    if ctx.clicked_head is None:
        # A waiting merge: the user may have cancelled it by clearing the done
        # mark since Toastty started this run.
        workspace = next((w for w in toastty_workspaces() if w.get("workspaceID") == ctx.workspace_id), None)
        if workspace is None or not workspace.get("done"):
            raise Refusal("the workspace is no longer marked done, so the merge was cancelled")
    # GitHub's merge API merges now or fails; unlike `gh pr merge`, it never
    # turns on auto-merge or adds the PR to a merge queue. `sha` makes GitHub
    # refuse if the head is no longer the accepted commit.
    ok, output = succeeds(["gh", "api", "--method", "PUT", f"repos/{ctx.repo_slug}/pulls/{number}/merge",
                           "-f", f"sha={accepted}", "-f", f"merge_method={method}"], cwd=ctx.repo)
    if not ok:
        return "failed", f"GitHub did not merge PR #{number}: {output}", accepted
    view = json.loads(run(["gh", "pr", "view", str(number), "--json", "state"], cwd=ctx.repo, check=False) or "{}")
    if view.get("state") == "MERGED":
        return "merged", f"merged PR #{number}", accepted
    return "failed", f"GitHub reported the merge, but PR #{number} is {view.get('state', 'unknown').lower()}", accepted


# MARK: - Clean up and close

def toastty_workspaces() -> list[dict]:
    """The full workspace list; refuses when it is unavailable or partial."""
    cli = os.environ.get("TOASTTY_CLI_PATH")
    if not cli:
        raise Refusal("TOASTTY_CLI_PATH is not set")
    output = run([cli, "--json", "query", "run", "workspace.list"], check=False)
    try:
        response = json.loads(output)
    except json.JSONDecodeError:
        response = {}
    result = response.get("result") or {}
    if not response.get("ok") or result.get("callerIsScoped") is not False:
        raise Refusal("could not read the full Toastty workspace list")
    return result.get("workspaces", [])


def match_workspaces(workspaces: list[dict], ctx: Context) -> list[Workspace]:
    """Matches by a terminal inside the worktree, then by a github-pr chip whose URL
    names this PR. Returns every match at the first level that has any; more than
    one means the match is ambiguous."""
    def chips(workspace: dict) -> list[dict]:
        return [a for a in workspace.get("annotations", []) if a.get("key") == "github-pr"]

    pr_url = re.compile(rf"github\.com/{re.escape(ctx.repo_slug)}/pull/{ctx.pr['number']}/?$", re.IGNORECASE)
    levels = [
        lambda w: any(inside(real(cwd), ctx.worktree.path) for cwd in w.get("terminalCwds", [])),
        lambda w: any(pr_url.search(a.get("url") or "") for a in chips(w)),
    ]
    if ctx.worktree.branch is None:
        # load() associates this detached worktree with the clicked checkout.
        # The exact PR chip is required separately below. Count chip matches
        # elsewhere too, rather than hiding ambiguity behind a terminal match.
        expected_url = (ctx.pr.get("url") or "").rstrip("/").lower()
        def detached_match(workspace: dict) -> bool:
            has_terminal = any(inside(real(cwd), ctx.worktree.path)
                               for cwd in workspace.get("terminalCwds", []))
            has_chip = any((chip.get("url") or "").rstrip("/").lower() == expected_url
                           for chip in chips(workspace))
            return has_terminal or has_chip
        levels = [detached_match]
    for matches in levels:
        found = [
            Workspace(w["workspaceID"], w.get("title", ""), [real(c) for c in w.get("terminalCwds", [])],
                      chips(w), [s.get("agent") or "unknown" for s in w.get("activeSessions", [])],
                      w.get("busyTerminalCount", 0), w.get("unsavedDocumentCount", 0), w.get("done", False))
            for w in workspaces if matches(w)
        ]
        if found:
            return found
    return []


def workspace_problem(ctx: Context, require_done: bool) -> tuple[Workspace | None, str | None]:
    """Rereads the workspaces; returns the one to close, or why it is not safe to."""
    candidates = match_workspaces(toastty_workspaces(), ctx)
    if len(candidates) > 1:
        return None, "several workspaces match (" + ", ".join(w.label for w in candidates) + ")"
    found = candidates[0] if candidates else None
    if found is None or found.workspace_id != ctx.workspace_id:
        return None, f"the matching workspace is not {ctx.workspace_id[:8]} (found {found.label if found else 'none'})"
    if ctx.worktree.branch is None:
        expected_url = (ctx.pr.get("url") or "").rstrip("/").lower()
        if (len(found.chips) != 1 or
                (found.chips[0].get("url") or "").rstrip("/").lower() != expected_url):
            return None, f"{found.label} needs exactly one github-pr chip with this PR's exact URL for detached cleanup"
    if require_done and not found.done:
        return None, f"{found.label} is no longer marked done"
    if found.unsaved_documents:
        return None, f"{found.label} has unsaved document changes"
    if any(inside(cwd, other) for cwd in found.cwds for other in ctx.other_worktrees):
        return None, f"{found.label} also has a terminal in another worktree"
    for chip in found.chips:
        match = PR_URL.search(chip.get("url") or "")
        if match and (match.group(1).lower(), int(match.group(2))) != (ctx.repo_slug.lower(), ctx.pr["number"]):
            return None, f"{found.label} carries a chip for a different PR"
    return found, None


def clean_up(ctx: Context, close_pr: bool) -> tuple[str, str]:
    """Closes the workspace, removes the worktree, and deletes both branches. Every
    guard runs before the first change; a failure after one reports what was done.
    With close_pr, an open PR is closed first, the workspace need not be marked
    done, and the remote branch is kept so the PR can be reopened."""
    pr, number = ctx.pr, ctx.pr["number"]
    if close_pr and pr["state"] == "MERGED":
        raise Refusal(f"PR #{number} has merged; nothing to close")
    if not close_pr and pr["state"] != "MERGED":
        raise Refusal(f"PR #{number} has not merged")
    worktree = ctx.worktree
    if worktree is None:
        raise Refusal(f"no worktree has the PR's branch {pr['headRefName']}")
    head, branch = pr["headRefOid"], pr["headRefName"]
    # A detached release checkout can be at the PR head or the commit GitHub
    # created while merging. Keep the selected commit fixed for every reread;
    # branch deletion below still compares only against the PR head.
    cleanup_head = head
    head_label = "PR head"
    if worktree.branch is None:
        merge_head = (pr.get("mergeCommit") or {}).get("oid")
        if close_pr or worktree.head not in {head, merge_head}:
            raise Refusal("the detached worktree HEAD is neither the PR head nor its merge commit")
        cleanup_head = worktree.head
        head_label = "selected cleanup HEAD"
    workspace, problem = workspace_problem(ctx, require_done=not close_pr)
    if problem:
        raise Refusal(problem)
    if worktree.locked:
        raise Refusal("the worktree is locked")
    problem = worktree_problem(worktree, cleanup_head, head_label)
    if problem:
        raise Refusal(problem)
    if close_pr:
        # The local branch goes, so the work must survive on GitHub at exactly
        # this head; an already-closed PR may have lost its branch.
        ok, output = succeeds(["git", "ls-remote", "--heads", "origin", branch], cwd=ctx.repo)
        if not ok:
            raise Refusal(f"could not query origin: {output}")
        remote = output.split()
        if not remote or remote[0] != head:
            raise Refusal("the PR's branch on GitHub is missing or at another commit, "
                          "so the local branch is the only copy of the work")

    done: list[str] = []

    def stop(message: str) -> tuple[str, str]:
        if done:
            return "partial", "; ".join(done + [message])
        return "stopped", message

    if close_pr and pr["state"] == "OPEN":
        ok, output = succeeds(["gh", "pr", "close", str(number)], cwd=ctx.repo)
        if not ok:
            return stop(f"could not close PR #{number}: {output}")
        done.append(f"closed PR #{number}")
    # Reread the workspace just before closing it: sessions, documents, and
    # terminals may have changed while the PR was queried or closed.
    try:
        workspace, problem = workspace_problem(ctx, require_done=not close_pr)
    except Refusal as refusal:
        problem = str(refusal)
    if problem:
        return stop(f"{problem}; workspace kept")
    problem = worktree_problem(worktree, cleanup_head, head_label)
    if problem:
        return stop(f"{problem}; workspace kept")
    ok, output = succeeds([os.environ["TOASTTY_CLI_PATH"], "--json", "action", "run", "workspace.close",
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
    problem = worktree_problem(worktree, cleanup_head, head_label)
    if problem:
        return stop(f"{problem}; worktree kept")
    ok, output = succeeds(["git", "worktree", "remove", worktree.path], cwd=ctx.repo)
    if not ok:
        return stop(f"git worktree remove failed: {output}")
    done.append("removed worktree")
    # Compare-and-delete: the ref goes only if it still points at the PR head.
    # Squash merges leave it unmerged by ancestry, so `git branch -d` would refuse.
    checked_out = [w.path for w in list_worktrees(ctx.repo) if w.branch == branch]
    keep_branches = None
    if checked_out:
        keep_branches = "it is checked out in " + ", ".join(checked_out)
    elif worktree.branch is None:
        if branch == ctx.default_branch:
            keep_branches = "it is the repository's default branch"
        else:
            ok, output = succeeds(["gh", "pr", "list", "--head", branch, "--state", "open", "--json",
                                   "number,isCrossRepository,headRefName"], cwd=ctx.repo)
            try:
                open_prs = json.loads(output) if ok else None
            except json.JSONDecodeError:
                open_prs = None
            valid_prs = isinstance(open_prs, list) and all(
                isinstance(p, dict) and type(p.get("number")) is int
                and isinstance(p.get("isCrossRepository"), bool)
                and isinstance(p.get("headRefName"), str) for p in open_prs)
            if not valid_prs:
                keep_branches = "could not verify other open PRs using it"
            else:
                shared = [p["number"] for p in open_prs if p.get("headRefName") == branch
                          and p.get("isCrossRepository") is False and p.get("number") != number]
                if shared:
                    keep_branches = "another open PR uses it (" + ", ".join(f"#{n}" for n in shared) + ")"
    if keep_branches:
        complete = False
        done.append("local branch kept: " + keep_branches)
    else:
        ok, output = succeeds(["git", "for-each-ref", "--format=%(refname)", f"refs/heads/{branch}"],
                               cwd=ctx.repo)
        if not ok:
            complete = False
            keep_branches = f"could not read it: {output}"
            done.append("local branch kept: " + keep_branches)
        elif f"refs/heads/{branch}" not in output.splitlines():
            complete = True
            done.append("local branch already absent")
        else:
            ok, output = succeeds(["git", "update-ref", "-d", f"refs/heads/{branch}", head], cwd=ctx.repo)
            complete = ok
            done.append("deleted local branch" if ok else f"local branch kept: {output}")
    if close_pr or keep_branches:
        done.append("kept the branch on GitHub")
        return ("cleaned" if complete else "partial"), "; ".join(done)
    ok, output = succeeds(["git", "ls-remote", "--heads", "origin", branch], cwd=ctx.repo)
    remote = output.split() if ok else []
    if not ok:
        complete = False
        done.append(f"remote branch kept: could not query origin: {output}")
    elif remote and remote[0] == head:
        ok, output = succeeds(["git", "push", f"--force-with-lease=refs/heads/{branch}:{head}",
                               "origin", f":refs/heads/{branch}"], cwd=ctx.repo)
        complete = complete and ok
        done.append("deleted remote branch" if ok else f"remote branch kept: {output}")
    elif remote:
        complete = False
        done.append(f"remote branch kept: it now points at {remote[0][:8]}")
    return ("cleaned" if complete else "partial"), "; ".join(done)


# MARK: - Main

def load(options: argparse.Namespace) -> Context:
    checkout = real(run(["git", "rev-parse", "--show-toplevel"], cwd=options.repo).strip())
    repo = main_checkout(checkout)
    clicked_head = None
    if options.action == "merge" and not options.head:
        ok, head = succeeds(["git", "rev-parse", "HEAD"], cwd=checkout)
        clicked_head = head if ok else ""
    if not options.head:
        # A merge that is waiting reads only GitHub; it runs every 30 seconds.
        subprocess.run(["git", "fetch", "--quiet", "--prune", "origin"], cwd=repo, capture_output=True)
    repo_info = json.loads(run(["gh", "repo", "view", "--json",
                                "nameWithOwner,defaultBranchRef,mergeCommitAllowed,squashMergeAllowed,"
                                "rebaseMergeAllowed"], cwd=repo))
    pr = json.loads(run(["gh", "pr", "view", str(options.pr), "--json", PR_FIELDS], cwd=repo))
    if (pr.get("url") or "").rstrip("/").lower() != options.pr_url.rstrip("/").lower():
        # The number alone could name a PR in another repository.
        raise Refusal(f"{options.pr_url} is not this repository's PR #{options.pr} ({pr.get('url')})")
    if pr["isCrossRepository"]:
        raise Refusal(f"PR #{options.pr} comes from a fork")
    worktrees = list_worktrees(repo)
    clicked = next((w for w in worktrees if w.path == checkout), None)
    if (options.action == "clean-up" and pr["state"] == "MERGED" and checkout == repo
            and clicked is not None and clicked.branch is None):
        raise Refusal("the detached primary checkout cannot be cleaned up")
    worktree = next((w for w in worktrees if w.branch == pr["headRefName"]), None)
    if options.action == "clean-up" and pr["state"] == "MERGED":
        detached = next((w for w in worktrees if w.branch is None and w.path != repo
                         and w.path == checkout), None)
        if detached is not None:
            worktree = detached
    return Context(
        repo=repo, repo_slug=repo_info["nameWithOwner"], default_branch=repo_info["defaultBranchRef"]["name"],
        repo_info=repo_info, pr=pr, worktree=worktree,
        other_worktrees=[w.path for w in worktrees if worktree is None or w.path != worktree.path],
        workspace_id=options.workspace, checkout=checkout, clicked_head=clicked_head)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("action", choices=("merge", "clean-up", "close"))
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--pr-url", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--repo", required=True, help="any checkout of the repository")
    parser.add_argument("--head", help="with merge: the commit the user accepted, from an earlier waiting report")
    options = parser.parse_args()
    if options.head and options.action != "merge":
        parser.error("--head is only for merge")
    report: dict = {}
    try:
        ctx = load(options)
        if options.action == "merge":
            status, detail, report["head"] = merge(ctx, options.head)
        else:
            status, detail = clean_up(ctx, close_pr=options.action == "close")
    except Refusal as refusal:
        status = "refused" if options.action == "merge" else "skipped"
        detail = str(refusal)
    print(json.dumps({"status": status, "detail": detail, **report}))


if __name__ == "__main__":
    main()
