#!/usr/bin/env python3
"""Durable, cooperative task queue. Only local state is mutated; never merges/deletes.

The advisory lock serializes state transactions. The durable owner separately
reserves integration across tool calls. Takeover requires the caller to establish
that the former owner stopped; this is not fencing for external GitHub commands.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import asdict, dataclass, field, fields
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from typing import Iterator
from urllib.parse import urlparse

SCHEMA = 1
STATUSES = {"working", "ready", "accepted", "integrating", "landed", "verified", "cleaned"}
HANDOFFS = {"WORKTREE_HANDOFF.md", "WORKTREE_STATUS.md"}
PR_FIELDS = "url,number,state,isDraft,headRefOid,headRefName,baseRefName,baseRefOid,mergeCommit,statusCheckRollup,reviewDecision,mergeStateStatus"


class QueueError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise QueueError(message)


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def identifier(value: str) -> str:
    require(bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", value)), "invalid task or owner ID")
    return value


def sha(value: str) -> str:
    require(bool(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value)), "a full lowercase commit SHA is required")
    return value


def strings(value: object) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) and bool(item) for item in value)


@dataclass
class Task:
    task: str
    worktree: str
    branch: str
    base: str
    landing: str
    remote: str
    created_at: str
    updated_at: str
    status: str = "working"
    remote_repository: str | None = None
    pr: str | None = None
    workspace: str | None = None
    panel: str | None = None
    session: str | None = None
    socket: str | None = None
    validated_sha: str | None = None
    evidence: list[str] = field(default_factory=list)
    accepted_sha: str | None = None
    accepted_at: str | None = None
    dependencies: list[str] = field(default_factory=list)
    dependency_shas: dict[str, str] = field(default_factory=dict)
    intent_base: str | None = None
    integration_owner: str | None = None
    landed_sha: str | None = None
    verification_evidence: list[str] = field(default_factory=list)
    cleanup_evidence: list[str] = field(default_factory=list)
    branch_retained: str | None = None
    pr_snapshot: dict[str, object] | None = None

    @classmethod
    def parse(cls, value: object) -> Task:
        require(isinstance(value, dict), "task record must be an object")
        require(set(value) == {item.name for item in fields(cls)}, "unknown or missing task fields")
        required = {"task", "worktree", "branch", "base", "landing", "remote", "created_at", "updated_at", "status"}
        lists = {"evidence", "dependencies", "verification_evidence", "cleanup_evidence"}
        for key, item in value.items():
            if key in lists:
                require(strings(item), f"invalid task {key}")
            elif key == "pr_snapshot":
                require(item is None or isinstance(item, dict), "invalid PR snapshot")
            elif key == "dependency_shas":
                require(isinstance(item, dict) and all(isinstance(k, str) and isinstance(v, str) for k, v in item.items()),
                        "invalid dependency SHA map")
            else:
                require((item is None and key not in required) or (isinstance(item, str) and bool(item)), f"invalid task {key}")
        record = cls(**value)
        identifier(record.task)
        require(record.status in STATUSES, "unknown task status")
        require(bool(record.remote_repository), "task is missing remote repository identity")
        require(Path(record.worktree).is_absolute(), "task worktree must be absolute")
        if record.socket is not None:
            require(Path(record.socket).is_absolute(), "Toastty socket path must be absolute")
        sha(record.base)
        for dependency in record.dependencies:
            identifier(dependency)
        require(len(set(record.dependencies)) == len(record.dependencies), "duplicate dependencies")
        require(set(record.dependency_shas) == set(record.dependencies), "dependency SHA pins must match dependencies")
        for value in record.dependency_shas.values():
            sha(value)
        for value in (record.validated_sha, record.accepted_sha, record.intent_base, record.landed_sha):
            if value is not None:
                sha(value)
        if record.status != "working":
            require(bool(record.validated_sha and record.evidence), "task is missing readiness evidence")
        if record.status in {"accepted", "integrating", "landed", "verified", "cleaned"}:
            require(record.accepted_sha == record.validated_sha and bool(record.accepted_at), "task is missing exact acceptance")
        if record.status in {"integrating", "landed", "verified", "cleaned"}:
            require(bool(record.intent_base and record.integration_owner), "task is missing integration intent")
        if record.status in {"landed", "verified", "cleaned"}:
            require(bool(record.landed_sha), "task is missing landing receipt")
        if record.status in {"verified", "cleaned"}:
            require(bool(record.verification_evidence), "task is missing post-landing verification")
        if record.status == "cleaned":
            require(bool(record.cleanup_evidence), "task is missing cleanup evidence")
        return record


class Commands:
    def __init__(self, deadline: float | None = None):
        self.deadline = deadline

    def run(self, args: list[str], cwd: str | Path, allowed: tuple[int, ...] = (0,)) -> str:
        timeout = 10.0 if self.deadline is None else min(10.0, self.deadline - time.monotonic())
        require(timeout > 0, "command deadline expired")
        try:
            result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as error:
            raise QueueError(f"{args[0]} timed out") from error
        except OSError as error:
            raise QueueError(f"cannot run {args[0]}: {error.strerror}") from error
        # External stderr can contain credentials from remote URLs. Do not echo it.
        require(result.returncode in allowed, f"{args[0]} {args[1]} failed (exit {result.returncode}); inspect it separately")
        return result.stdout.strip()

    def git(self, repo: str | Path, *args: str) -> str:
        return self.run(["git", *args], repo)

    def common_dir(self, repo: str | Path) -> Path:
        value = self.git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
        return Path(value).resolve()


class Store:
    def __init__(self, repo: str, root: str | None, commands: Commands):
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"):
            require(name not in os.environ, f"unset {name}; Git routing overrides conflict with --repo")
        self.commands = commands
        self.repo = Path(repo).resolve()
        self.common = commands.common_dir(self.repo)
        self.key = hashlib.sha256(str(self.common).encode()).hexdigest()
        self.path = (Path(root).expanduser() if root else Path.home() / ".toastty/task-state") / self.key
        self.path.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.file = self.path / "queue.json"

    @contextmanager
    def locked(self) -> Iterator[dict[str, object]]:
        with (self.path / "queue.lock").open("a+") as lock:
            deadline = time.monotonic() + 10
            if self.commands.deadline is not None:
                deadline = min(deadline, self.commands.deadline)
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    require(time.monotonic() < deadline, "queue lock timed out")
                    time.sleep(0.05)
            try:
                state = self.read()
                before = json.dumps(state, sort_keys=True)
                yield state
                if before != json.dumps(state, sort_keys=True):
                    state["cursor"] += 1
                    self.validate(state)
                    self.write(state)
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def read(self) -> dict[str, object]:
        if not self.file.exists():
            return {"schema": SCHEMA, "repository": str(self.common), "cursor": 0, "owner": None, "tasks": {}}
        try:
            value = json.loads(self.file.read_text())
        except (OSError, ValueError) as error:
            raise QueueError("cannot read queue state; preserve it and repair explicitly") from error
        self.validate(value)
        return value

    def validate(self, state: object) -> None:
        require(isinstance(state, dict) and set(state) == {"schema", "repository", "cursor", "owner", "tasks"}, "invalid queue schema")
        require(state["schema"] == SCHEMA and state["repository"] == str(self.common), "queue schema or repository mismatch")
        require(type(state["cursor"]) is int and state["cursor"] >= 0, "invalid queue cursor")
        owner = state["owner"]
        require(owner is None or (isinstance(owner, dict) and set(owner) == {"id", "acquired_at"}
                and all(isinstance(item, str) and item for item in owner.values())), "invalid owner record")
        if owner:
            identifier(owner["id"])
        require(isinstance(state["tasks"], dict), "invalid tasks map")
        for key, value in state["tasks"].items():
            record = Task.parse(value)
            require(key == record.task, "task key mismatch")

    def write(self, state: dict[str, object]) -> None:
        descriptor, name = tempfile.mkstemp(prefix=".queue-", dir=self.path)
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump(state, stream, separators=(",", ":"), sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.file)
            directory = os.open(self.path, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def get(self, state: dict[str, object], task: str) -> Task:
        identifier(task)
        require(task in state["tasks"], f"unknown task: {task}")
        return Task.parse(state["tasks"][task])

    def save(self, state: dict[str, object], task: Task) -> None:
        task.updated_at = timestamp()
        state["tasks"][task.task] = asdict(task)

    def local_tip(self, task: Task, allow_handoffs: bool = True, require_clean: bool = True) -> str:
        require(self.commands.common_dir(task.worktree) == self.common, "task worktree belongs to another repository")
        branch = self.commands.git(task.worktree, "symbolic-ref", "--short", "HEAD")
        require(branch == task.branch, "worktree branch changed")
        if not require_clean:
            return sha(self.commands.git(task.worktree, "rev-parse", "HEAD"))
        # Only exact untracked handoff names are exempt. Tracked edits, renames,
        # arbitrary untracked files, and handoff directories still block.
        status = self.commands.git(task.worktree, "status", "--porcelain=v1", "-z", "--untracked-files=all")
        for entry in status.split("\0"):
            if not entry:
                continue
            allowed = allow_handoffs and entry[:3] == "?? " and entry[3:] in HANDOFFS
            require(allowed, "task worktree has uncommitted changes outside untracked handoff files")
        return sha(self.commands.git(task.worktree, "rev-parse", "HEAD"))

    def remote_repo(self, task: Task) -> str:
        remote = self.commands.git(self.repo, "remote", "get-url", "--", task.remote)
        if re.fullmatch(r"git@[^:]+:[^\s]+", remote):
            host, path = remote[4:].split(":", 1)
        else:
            parsed = urlparse(remote)
            require(parsed.scheme in {"https", "ssh"} and bool(parsed.hostname), "remote must identify a GitHub repository")
            host, path = parsed.hostname, parsed.path.lstrip("/")
        if path.endswith(".git"):
            path = path[:-4]
        require(bool(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", path)), "invalid remote repository path")
        repository = f"{host}/{path}"
        require(task.remote_repository is None or repository.lower() == task.remote_repository.lower(),
                "registered Git remote now points to a different repository")
        return repository

    def pr(self, task: Task, require_head: bool = True) -> dict[str, object]:
        require(bool(task.pr), "task has no PR; attach it with ready --pr or attach --pr")
        repository = self.remote_repo(task)
        reference = task.pr
        if reference.isdigit():
            require(int(reference) > 0, "invalid PR number")
        else:
            parsed = urlparse(reference)
            require(parsed.scheme == "https" and parsed.username is None and parsed.password is None,
                    "PR must be a number or an https GitHub PR URL")
            parts = parsed.path.strip("/").split("/")
            require(len(parts) == 4 and parts[2] == "pull" and parts[3].isdigit()
                    and f"{parsed.hostname}/{parts[0]}/{parts[1]}".lower() == repository.lower(),
                    "PR URL does not belong to the registered remote")
            reference = parts[3]
        raw = self.commands.run(["gh", "pr", "view", reference, "--repo", repository, "--json", PR_FIELDS], self.repo)
        try:
            value = json.loads(raw)
        except ValueError as error:
            raise QueueError("gh returned invalid PR JSON") from error
        require(isinstance(value, dict), "gh returned invalid PR metadata")
        for key in ("url", "state", "headRefOid", "headRefName", "baseRefName", "baseRefOid"):
            require(isinstance(value.get(key), str) and bool(value[key]), f"gh omitted {key}")
        require(type(value.get("isDraft")) is bool and isinstance(value.get("statusCheckRollup"), list), "gh omitted draft/check metadata")
        sha(value["headRefOid"])
        sha(value["baseRefOid"])
        if require_head:
            require(value["headRefName"] == task.branch, "PR head branch differs from registered task")
        checks = [{key: item for key, item in check.items() if key not in {"startedAt", "completedAt"}}
                  if isinstance(check, dict) else check for check in value["statusCheckRollup"]]
        value["statusCheckRollup"] = sorted(checks, key=lambda item: json.dumps(item, sort_keys=True))
        # Keep only the requested metadata, never command stderr or environment.
        return {key: value.get(key) for key in PR_FIELDS.split(",")}

    def exact_head(self, task: Task, expected: str, allowed_bases: set[str] | None = None) -> dict[str, object]:
        snapshot = self.pr(task)
        require(snapshot["state"] == "OPEN" and not snapshot["isDraft"], "PR must be open and ready for review")
        require(snapshot["baseRefName"] in (allowed_bases or {task.landing}),
                "PR base must be the landing branch or, at acceptance, a declared dependency branch")
        require(self.local_tip(task) == expected == snapshot["headRefOid"], "PR head, local tip, and validated/accepted SHA differ; reopen and revalidate")
        return snapshot

    def integration_checks(self, snapshot: dict[str, object]) -> None:
        # These gates are intentionally stricter than required-only CI: an
        # optional failing check still needs assessment before integration.
        # gh's required-check command reports no required checks as an error,
        # so do not infer branch policy from that command's exit status/stderr.
        review = snapshot["reviewDecision"]
        require(review in ("", "APPROVED"), "PR review decision is blocked or unavailable")
        for check in snapshot["statusCheckRollup"]:
            require(isinstance(check, dict), "invalid CI check metadata")
            if "status" in check:
                require(check.get("status") == "COMPLETED" and check.get("conclusion") in ("SUCCESS", "NEUTRAL", "SKIPPED"),
                        "CI check is pending, failing, or has unknown metadata")
            else:
                require(check.get("state") == "SUCCESS", "CI status is pending, failing, or has unknown metadata")
        require(snapshot["mergeStateStatus"] in ("CLEAN", "HAS_HOOKS"),
                "GitHub merge requirements are blocked, pending, or unavailable")

    def dependencies(self, state: dict[str, object], task: Task, verified: bool) -> None:
        def visit(name: str, trail: set[str]) -> None:
            require(name not in trail, "task dependency cycle")
            record = self.get(state, name)
            for child in record.dependencies:
                visit(child, trail | {name})
        visit(task.task, set())
        for name in task.dependencies:
            prerequisite = self.get(state, name)
            require(prerequisite.landing == task.landing and prerequisite.remote == task.remote
                    and prerequisite.remote_repository == task.remote_repository,
                    f"dependency {name} targets a different landing branch or remote")
            if verified:
                require(prerequisite.accepted_sha is not None and prerequisite.status in {"verified", "cleaned"},
                        f"dependency {name} has not been accepted, landed, and verified")
                require(prerequisite.accepted_sha == task.dependency_shas[name],
                        f"dependency {name} changed from its accepted source pin; reopen and reaccept the dependent task")
                self.commands.git(self.repo, "merge-base", "--is-ancestor", prerequisite.landed_sha,
                                  f"refs/heads/{task.landing}")

    def require_owner(self, state: dict[str, object], owner: str) -> None:
        identifier(owner)
        require(state["owner"] is not None and state["owner"]["id"] == owner, "integration owner mismatch; acquire ownership first")


def mutate(store: Store, args: argparse.Namespace) -> dict[str, object]:
    with store.locked() as state:
        if args.command == "owner":
            identifier(args.owner)
            if args.owner_command == "acquire":
                current = state["owner"]
                require(current is None or current["id"] == args.owner or args.takeover,
                        "another session owns integration; explicit takeover requires confirming that session stopped")
                if current is None or current["id"] != args.owner:
                    state["owner"] = {"id": args.owner, "acquired_at": timestamp()}
            else:
                store.require_owner(state, args.owner)
                require(not any(item["status"] == "integrating" for item in state["tasks"].values()),
                        "unreconciled integration intent; record its outcome before releasing ownership")
                state["owner"] = None
            result = {"owner": state["owner"]}
        else:
            identifier(args.task)
            if args.command == "register":
                require(args.task not in state["tasks"], "task already registered; use attach for launch IDs")
                for ref in (args.branch, args.landing):
                    store.commands.git(store.repo, "check-ref-format", "--branch", ref)
                require(args.remote in store.commands.git(store.repo, "remote").splitlines(), "remote must name a configured Git remote")
                sha(args.base)
                require(store.commands.git(store.repo, "cat-file", "-t", args.base) == "commit", "base must identify a local commit")
                task = Task(args.task, str(Path(args.worktree).resolve()), args.branch, args.base,
                            args.landing, args.remote, timestamp(), timestamp(), pr=args.pr,
                            workspace=args.workspace, panel=args.panel, session=args.session,
                            socket=str(Path(args.socket).resolve()) if args.socket else None)
                task.remote_repository = store.remote_repo(task)
                require(task.branch != task.landing, "task and landing branches must differ")
                require(store.commands.common_dir(task.worktree) == store.common, "worktree belongs to another repository")
                require(store.commands.git(task.worktree, "symbolic-ref", "--short", "HEAD") == task.branch,
                        "registered branch is not checked out in task worktree")
            else:
                task = store.get(state, args.task)
                if args.command == "attach":
                    require(task.status in {"working", "ready"}, "resource identity is frozen after acceptance; reopen first")
                    for key in ("pr", "workspace", "panel", "session", "socket"):
                        value = getattr(args, key)
                        if value is not None:
                            if key == "socket":
                                value = str(Path(value).resolve())
                            existing = getattr(task, key)
                            require(existing is None or existing == value, f"{key} identity already assigned")
                            setattr(task, key, value)
                elif args.command == "rebind":
                    require(task.status in {"working", "ready"}, "reopen acceptance before rebinding a session")
                    require(task.session == args.previous_session and task.workspace == args.workspace,
                            "previous session or workspace differs from registered identity")
                    expected_socket = str(Path(args.socket).resolve()) if args.socket else None
                    require(task.socket == expected_socket, "socket differs from registered identity; supply its exact path")
                    require(store.commands.common_dir(task.worktree) == store.common and
                            store.commands.git(task.worktree, "symbolic-ref", "--short", "HEAD") == task.branch,
                            "task checkout identity changed")
                    task.session = args.session
                    if args.panel is not None:
                        task.panel = args.panel
                elif args.command == "ready":
                    require(task.status in {"working", "ready"}, "reopen accepted work before replacing readiness evidence")
                    task.validated_sha = sha(args.validated_sha)
                    require(store.local_tip(task) == task.validated_sha, "validated SHA differs from local task tip")
                    if args.pr is not None:
                        require(task.pr is None or task.pr == args.pr, "PR identity already assigned")
                        task.pr = args.pr
                    task.evidence = args.evidence
                    task.status = "ready"
                elif args.command == "accept":
                    require(task.status in {"ready", "accepted"}, "task must be ready before acceptance")
                    deps = sorted(set(args.depends_on))
                    if task.status == "accepted":
                        require(task.dependencies == deps, "duplicate acceptance cannot change dependencies; reopen first")
                    task.dependencies = deps
                    if task.status == "ready":
                        task.dependency_shas = {}
                        for name in deps:
                            prerequisite = store.get(state, name)
                            # A still-working prerequisite is pinned to its
                            # current committed source, without accepting it.
                            # Completed cleanup can legitimately remove its tip.
                            task.dependency_shas[name] = (prerequisite.accepted_sha
                                if prerequisite.status in {"verified", "cleaned"}
                                else store.local_tip(prerequisite, require_clean=False))
                    # Validate the proposed graph, including its newly assigned edges.
                    state["tasks"][task.task] = asdict(task)
                    store.dependencies(state, task, verified=False)
                    allowed_bases = {task.landing} | {store.get(state, name).branch for name in task.dependencies}
                    snapshot = store.exact_head(task, task.validated_sha, allowed_bases)
                    if task.status == "accepted":
                        return {"task": asdict(task), "cursor": state["cursor"], "unchanged": True}
                    task.accepted_sha = task.validated_sha
                    task.accepted_at = timestamp()
                    task.pr_snapshot = snapshot
                    task.status = "accepted"
                elif args.command == "reopen":
                    require(task.status in {"working", "ready", "accepted"}, "landed or uncertain integration cannot be reopened; reconcile the merge intent first")
                    task.status = "working"
                    task.validated_sha = task.accepted_sha = task.accepted_at = None
                    task.evidence = []
                    task.dependencies = []
                    task.dependency_shas = {}
                elif args.command == "begin":
                    store.require_owner(state, args.owner)
                    require(task.status == "accepted", "only accepted tasks may begin; reconcile an existing intent before retrying")
                    require(not any(item["status"] in {"integrating", "landed"} and name != task.task
                                    for name, item in state["tasks"].items()),
                            "reconcile existing integration and verify its landing before another merge")
                    store.dependencies(state, task, verified=True)
                    snapshot = store.exact_head(task, task.accepted_sha)
                    store.integration_checks(snapshot)
                    expected = sha(args.expected_base)
                    require(snapshot["baseRefOid"] == expected, "PR base changed since assessment")
                    require(store.commands.git(store.repo, "rev-parse", f"refs/heads/{task.landing}") == expected,
                            "local landing branch differs from assessed PR base")
                    remote_ref = f"refs/heads/{task.landing}"
                    remote_tip = store.commands.git(store.repo, "ls-remote", "--exit-code", task.remote, remote_ref)
                    require(remote_tip.splitlines() == [f"{expected}\t{remote_ref}"],
                            "live remote landing branch differs from assessed PR base")
                    task.intent_base = expected
                    task.integration_owner = args.owner
                    task.pr_snapshot = snapshot
                    task.status = "integrating"
                elif args.command == "cancel-begin":
                    store.require_owner(state, args.owner)
                    require(task.status == "integrating", "task has no integration intent")
                    snapshot = store.pr(task, require_head=False)
                    require(snapshot["state"] in {"OPEN", "CLOSED"},
                            "PR may have merged; retain intent and reconcile the merge receipt")
                    # Caller confirms no external merge is in flight. GitHub OPEN
                    # alone cannot prove that a previously started merge stopped.
                    require(args.no_merge_in_flight, "explicit no-merge-in-flight assertion required")
                    current = snapshot["state"] == "OPEN" and not snapshot["isDraft"] and (
                        snapshot["headRefName"] == task.branch and snapshot["baseRefName"] == task.landing
                        and snapshot["headRefOid"] == task.accepted_sha)
                    if current:
                        try:
                            current = store.local_tip(task, require_clean=False) == task.accepted_sha
                        except QueueError:
                            current = False
                    task.status = "accepted" if current else "working"
                    if not current:
                        task.validated_sha = task.accepted_sha = task.accepted_at = None
                        task.evidence = []
                        task.dependencies = []
                        task.dependency_shas = {}
                    task.pr_snapshot = snapshot
                    task.intent_base = task.integration_owner = None
                elif args.command == "landed":
                    store.require_owner(state, args.owner)
                    require(task.status in {"integrating", "landed"}, "persist begin before recording a merge")
                    snapshot = store.pr(task)
                    merge = snapshot.get("mergeCommit")
                    require(snapshot["state"] == "MERGED" and snapshot["headRefOid"] == task.accepted_sha,
                            "GitHub does not report the accepted head merged; retain intent and reconcile")
                    require(snapshot["baseRefName"] == task.landing, "PR merged into a different landing branch")
                    landed = sha(args.landing_sha)
                    require(isinstance(merge, dict) and merge.get("oid") == landed, "landing SHA differs from GitHub merge receipt")
                    task.landed_sha = landed
                    task.pr_snapshot = snapshot
                    task.status = "landed"
                elif args.command == "verified":
                    store.require_owner(state, args.owner)
                    require(task.status == "landed", "record landing before verification")
                    store.commands.git(store.repo, "merge-base", "--is-ancestor", task.intent_base, task.landed_sha)
                    store.commands.git(store.repo, "merge-base", "--is-ancestor", task.landed_sha, f"refs/heads/{task.landing}")
                    task.verification_evidence = args.evidence
                    task.status = "verified"
                elif args.command == "cleaned":
                    store.require_owner(state, args.owner)
                    require(task.status == "verified", "post-landing verification must precede cleanup")
                    require(args.workspace_closed or task.workspace is None, "confirm task workspace is closed")
                    require(not Path(task.worktree).exists(), "task worktree still exists")
                    worktrees = store.commands.git(store.repo, "worktree", "list", "--porcelain", "-z")
                    for entry in worktrees.split("\0"):
                        if entry.startswith("worktree "):
                            require(Path(entry[9:]).resolve() != Path(task.worktree).resolve(), "task worktree remains registered")
                        elif entry == f"branch refs/heads/{task.branch}":
                            raise QueueError("task branch remains checked out in a registered worktree")
                    branches = store.commands.git(store.repo, "for-each-ref", "--format=%(refname)", f"refs/heads/{task.branch}")
                    branch_exists = f"refs/heads/{task.branch}" in branches.splitlines()
                    require(bool(args.branch_retained) if branch_exists else args.branch_removed,
                            "record --branch-retained REASON for an existing branch or --branch-removed for an absent branch")
                    task.branch_retained = args.branch_retained
                    task.cleanup_evidence = args.evidence
                    task.status = "cleaned"
            store.save(state, task)
            result = {"task": asdict(task)}
    result["cursor"] = state["cursor"]
    return result


def snapshot(store: Store, args: argparse.Namespace, refresh: bool = False) -> dict[str, object]:
    # Network calls occur outside the state lock, and are applied only if the
    # task did not change meanwhile. Concurrent ready/accept writes are retained.
    with store.locked() as state:
        records = list(state["tasks"].values())
    observations = []
    errors = []
    pending = []
    if refresh:
        for value in records:
            task = Task.parse(value)
            if not task.pr or task.status not in {"ready", "accepted", "integrating"}:
                continue
            if store.commands.deadline is not None and time.monotonic() >= store.commands.deadline:
                pending.append(task.task)
                continue
            try:
                observations.append((task.task, value, store.pr(task)))
            except QueueError as error:
                if store.commands.deadline is not None and time.monotonic() >= store.commands.deadline:
                    pending.append(task.task)
                else:
                    errors.append({"task": task.task, "error": str(error)})
    with store.locked() as state:
        refreshed = []
        for name, original, observation in observations:
            if state["tasks"].get(name) != original:
                pending.append(name)
                continue
            refreshed.append(name)
            if original["pr_snapshot"] != observation:
                record = store.get(state, name)
                record.pr_snapshot = observation
                store.save(state, record)
        tasks = [state["tasks"][name] for name in sorted(state["tasks"])]
        result = {"tasks": tasks, "owner": state["owner"], "repo_state_dir": str(store.path)}
        if refresh:
            result.update(refresh_errors=errors, refresh_pending=pending,
                          refreshed_tasks=refreshed,
                          refresh_complete=not errors and not pending)
    result["cursor"] = state["cursor"]
    return result


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo", required=True)
    result.add_argument("--state-root", help="parent directory; repository hash is appended")
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("paths")
    commands.add_parser("list")
    for name in ("show", "register", "attach", "rebind", "ready", "accept", "reopen", "begin", "cancel-begin", "landed", "verified", "cleaned"):
        command = commands.add_parser(name)
        command.add_argument("--task", required=True)
        if name in {"register", "attach"}:
            for key in ("pr", "workspace", "panel", "session", "socket"):
                command.add_argument(f"--{key}")
        if name == "rebind":
            for key in ("previous-session", "session", "workspace"):
                command.add_argument(f"--{key}", required=True)
            command.add_argument("--panel")
            command.add_argument("--socket")
        if name == "register":
            for key in ("worktree", "branch", "base", "landing", "remote"):
                command.add_argument(f"--{key}", required=True)
        if name == "ready":
            command.add_argument("--pr")
            command.add_argument("--validated-sha", required=True)
        if name in {"ready", "verified", "cleaned"}:
            command.add_argument("--evidence", action="append", required=True)
        if name == "accept":
            command.add_argument("--depends-on", action="append", default=[])
        if name in {"begin", "cancel-begin", "landed", "verified", "cleaned"}:
            command.add_argument("--owner", required=True)
        if name == "begin":
            command.add_argument("--expected-base", required=True)
        if name == "cancel-begin":
            command.add_argument("--no-merge-in-flight", action="store_true", required=True)
        if name == "landed":
            command.add_argument("--landing-sha", required=True)
        if name == "cleaned":
            command.add_argument("--workspace-closed", action="store_true")
            branch = command.add_mutually_exclusive_group(required=True)
            branch.add_argument("--branch-removed", action="store_true")
            branch.add_argument("--branch-retained")
    owner = commands.add_parser("owner").add_subparsers(dest="owner_command", required=True)
    for name in ("acquire", "release"):
        command = owner.add_parser(name)
        command.add_argument("--owner", required=True)
        if name == "acquire":
            command.add_argument("--takeover", action="store_true")
    wait = commands.add_parser("wait")
    wait.add_argument("--cursor", type=int, default=0)
    wait.add_argument("--timeout", type=float, default=60)
    wait.add_argument("--now", action="store_true")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "wait":
            require(0 < args.timeout <= 60 and args.cursor >= 0, "wait requires 0 < timeout <= 60 and a nonnegative cursor")
        deadline = time.monotonic() + args.timeout if args.command == "wait" else None
        store = Store(args.repo, args.state_root, Commands(deadline))
        if args.command == "paths":
            result = {"repository": str(store.common), "repository_key": store.key, "repo_state_dir": str(store.path)}
        elif args.command == "show":
            with store.locked() as state:
                result = {"task": asdict(store.get(state, args.task)), "cursor": state["cursor"]}
        elif args.command == "list":
            result = snapshot(store, args)
        elif args.command == "wait":
            # One remote pass per foreground wait. Its subprocesses share the
            # wait deadline. Then poll local state cheaply without repeatedly
            # requesting every PR; callers retain their cursor across waits.
            result = snapshot(store, args, refresh=True)
            refresh_report = {key: result[key] for key in
                              ("refresh_errors", "refresh_pending", "refreshed_tasks", "refresh_complete")}
            while True:
                require(args.cursor <= result["cursor"], "cursor is ahead of queue; inspect state before restarting from cursor 0")
                result["changed"] = result["cursor"] > args.cursor
                remaining = deadline - time.monotonic()
                result["timed_out"] = remaining <= 0.05
                if args.now or result["changed"] or result["timed_out"] or result["refresh_errors"]:
                    break
                time.sleep(min(0.5, remaining))
                try:
                    result = {**snapshot(store, args), **refresh_report}
                except QueueError:
                    if time.monotonic() < deadline:
                        raise
                    result["timed_out"] = True
                    break
        else:
            result = mutate(store, args)
        print(json.dumps({"ok": True, **result}, separators=(",", ":"), sort_keys=True))
        return 0
    except (QueueError, OSError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, separators=(",", ":")), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
