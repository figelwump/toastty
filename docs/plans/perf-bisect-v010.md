# Perf Bisect From v0.1.0

This is the first isolation pass for the Ghostty-backed input and scrolling regression reported on `main`.

Baseline:
- Good: `v0.1.0` (`f5275612c69e0d42875ad07678eed322dfcd07e9`)
- Bad: `0684989d0b7f48654a0ee49886d67157bccd9f67` (`main` on 2026-03-19)
- Known-good worktree example: `../toastty-0.1.0` from the stable main worktree

Classification rule:
- `skip`: commits that touched no `Sources/`, `Project.swift`, or `Tuist/`
- `test`: everything else

Counts:
- 92 commits in range
- 25 `skip` commits
- 67 `test` commits left in the bisect search space

Artifacts:
- Commit classification: [perf-bisect-v010-commits.tsv](/Users/vishal/GiantThings/repos/toastty/docs/plans/perf-bisect-v010-commits.tsv)
- Bisect bootstrap helper: [start-perf-bisect-v010.sh](/Users/vishal/GiantThings/repos/toastty/scripts/dev/start-perf-bisect-v010.sh)

Recommended flow:
1. Keep `/Users/vishal/GiantThings/repos/toastty` on this commit so the helper script and TSV stay available.
2. From the stable main worktree, run the helper against the bisect target worktree:

```bash
./scripts/dev/start-perf-bisect-v010.sh ../toastty-0.1.0
```

3. For each bisect stop, do the smallest repeatable check that still gives you a clear answer:
   - build the app the same way each time
   - type a short fixed burst in the same terminal app/session
   - scroll the same screenful a few times
   - drag-select the same block of terminal text
4. Mark only confident results:

```bash
git -C ../toastty-0.1.0 bisect good
git -C ../toastty-0.1.0 bisect bad
git -C ../toastty-0.1.0 bisect skip
```

5. When the run finishes, record the culprit commit and the neighboring cluster before deciding what to replay into the next release branch.

Practical notes:
- If a commit does not build or the result is ambiguous, use `git bisect skip`.
- The bisect result is the first bad commit in history, not necessarily the whole explanation. If the culprit lands inside a revert/reapply cluster, inspect the few commits on both sides before deciding what to carry forward.
- Do not run bisect in the stable main worktree. Use the `toastty-0.1.0` worktree as the disposable bisect target and leave the main worktree parked on this runbook commit.
