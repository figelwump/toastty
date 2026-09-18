## Child model and reasoning

The launching agent selects the child's model and reasoning effort before launch.
Do not defer this decision to the child or silently inherit the parent's model.
Preserve Codex versus Claude Code by default; honor explicit user selections and
repository requirements, choosing only the fields they leave unspecified.

- For autonomous choices, use the target provider's available model identifiers
  and supported effort levels from current runtime information or its model
  selector/catalog. A
  subagent-only model list is not proof that the standalone CLI supports it.
  Do not guess identifiers from display names or keep a fixed model catalog in
  this skill. If no suitable option can be identified, explain what is missing
  and ask for a selection before launch. Pass an explicitly requested identifier
  unchanged for provider validation; do not ask the user to reconfirm it.
- Weigh how settled the plan is, implementation complexity, uncertainty, impact
  of mistakes, and testing/verification difficulty. Prefer faster models for
  clear, bounded work; a well-defined but complex implementation can warrant
  higher reasoning effort on that model. Use a more capable model when discovery,
  design judgment, or difficult verification dominates. A small diff can still
  require substantial reasoning. These are decision criteria, not a fixed matrix.
- Choose exact values and assign `WORKTREE_AGENT_MODEL` and
  `WORKTREE_AGENT_REASONING` for the helper example. Record one short explanation
  tied to this task in the handoff and launch summary. Choose autonomously when
  the available options and task scope are clear; no routine confirmation is needed.
- Use the built-in `toastty-capabilities` skill to check the live `agent.launch`
  descriptor supports `model` and `reasoningEffort` for the selected profile.
  This checks Toastty's ability to pass overrides, not upstream model availability.
  The helper repeats that capability check before creating a workspace or changing
  session scope. Unsupported selections stop the launch; do not drop the flags,
  substitute defaults, or bypass the managed launch through raw terminal input.
- Codex and Claude launches through this skill require both explicit values.
  If the user requests another provider that has no configurable effort, select
  its model explicitly and record reasoning as unsupported rather than inventing
  an equivalent flag. Custom `--startup-command` launches do not use these flags.
- The helper reports requested `model` and `reasoning_effort` separately from
  session IDs. Treat successful launch as command delivery, not proof the provider
  accepted a model or started successfully. Check available session/runtime evidence
  and report any rejection or unverified setting without claiming it took effect.

When a later callback must send text to a managed session created by this
workflow, retain the returned `panel_id` and `session_id` and call
`terminal.send-text` with both `--panel "$panel_id"` and
`expectedSessionID="$session_id"`. This conditional send works for a panel in
an unselected workspace tab and fails before delivery if the session ended or
the panel was reused. Do not rediscover the target through a selected-tab
`workspace.snapshot`, and do not fall back to an unchecked send. The explicit
`--startup-command` fallback has no managed session ID, so this condition is
available only after a successful structured `agent.launch`.

## Base selection

Choose the base before creating the task branch or worktree. The parent checkout is the worktree this workflow was invoked from; the landing branch may be checked out elsewhere. Uncommitted parent changes are not included in a Git base, regardless of how it is selected. Do not automatically stash, commit, or transfer those changes.

- Honor an explicit base or an agreed continuation of an existing feature branch. Do not replace that choice with the landing branch just because it is newer.
- Otherwise, identify the intended landing branch and its remote from the user's instructions, repository guidance, and Git tracking/default-branch metadata. Do not hardcode `main` or `origin`, or assume the current feature branch's upstream is the landing branch. Ask if the intended branch or remote remains ambiguous.
- Fetch the identified remote branch before selecting its tip. Use the commit obtained by that successful fetch, for example by reading `FETCH_HEAD` immediately after fetching that single branch. Do not rely on a remote-tracking ref that the fetch may not update, or require its SHA to change to prove success. Do not use a fetch refspec that writes to a local branch. Fetching may update local remote-tracking refs, but base selection must leave the parent checkout's branch, files, and local landing branch unchanged.
- Compare the fetched tip with the local landing branch using commit ancestry. If the local branch is absent, equal to, or behind the fetched branch, select the fetched tip without pulling into or updating the local landing branch.
- If the local landing branch has unpublished commits or has diverged, explain the relationship and relevant commits. Use the agreed task intent to determine whether those commits belong in the new task; if intent does not settle that choice, ask before creating the worktree. Do not automatically merge, rebase, reset, or discard commits to reconcile the branches.
- For a local-only repository with no remote base, select the identified local base and record that remote freshness does not apply. If fetching fails, report that freshness could not be verified. Use a cached or local fallback only when the user has explicitly allowed that fallback in the task or accepts it now. If the remote reports that the branch does not exist, resolve the intended branch before continuing; offline permission does not settle a missing or renamed branch.
- Verify that the selected ref resolves to a locally available commit, then resolve its full SHA and assign it to `WORKTREE_BASE_COMMIT` for the helper invocation. Record in `WORKTREE_HANDOFF.md` the source ref, intended landing branch and remote when applicable, selected SHA, local/remote relationship, selection reason, and whether fetching succeeded, failed, or was skipped. An explicit base or continuation that skips fetching must not be described as the latest remote state.
