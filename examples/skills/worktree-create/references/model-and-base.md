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
- Apply the personal model preferences below to this agent's actual assignment.
  Consider decisions still to be made and verification difficulty, not only diff
  size. Resolve preference names against current available provider identifiers.
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

### Personal model preferences

Use these preferences for both the launched worktree agent and its subagents.
They describe the user's preferred task fit, not a provider capability ranking
or a list of guaranteed launch identifiers. Preserve the selected provider and
resolve the preferred model against its available options before launch.

| Assigned work | Codex preference | Claude preference |
| --- | --- | --- |
| Complex work with decisions along the way, substantial uncertainty, or nontrivial verification | Astra / high | Opus 5.5 / xhigh |
| Involved but well-defined implementation | GPT-6 Astra / high | Opus 5 / xhigh |
| Scoped, well-defined implementation | GPT-6 Astra / medium | Opus 5 / high |
| Work needing intelligence and judgment, without substantial complexity or heavy implementation | Astra / medium | Opus 5.5 / xhigh |

Size each subagent independently for its bounded assignment. Do not inherit the
parent's model and effort merely because it owns a complex task. Astra / xhigh
is not a default in these preferences; a departure needs a concrete task-specific
reason or an explicit user request. Record a brief reason for each selection.
For work without a specified preference, use task fit and available options;
do not invent a user-endorsed equivalent or switch providers implicitly.

Where the runtime allows model and effort overrides, configure them explicitly.
Prefer a concise task handoff over full-history inheritance when inheritance
would force an unsuitable model or effort. If a role or runtime fixes those
settings, respect that constraint and report the limitation rather than claiming
that the preferred configuration was applied.

## Base selection

Choose the base before creating the task branch or worktree. The parent checkout is the worktree this workflow was invoked from; the landing branch may be checked out elsewhere. Uncommitted parent changes are not included in a Git base, regardless of how it is selected. Do not automatically stash, commit, or transfer those changes.

- Honor an explicit base or an agreed continuation of an existing feature branch. A bare landing-branch name such as `main` means its fetched remote tip unless the user explicitly selects the local branch. Do not replace an intentional feature-branch base just because the landing branch is newer.
- Otherwise, identify the intended landing branch and its remote from the user's instructions, repository guidance, and Git tracking/default-branch metadata. Do not hardcode `main` or `origin`, or assume the current feature branch's upstream is the landing branch. Ask if the intended branch or remote remains ambiguous.
- Fetch the identified remote branch before selecting its tip. Use the commit obtained by that successful fetch, for example by reading `FETCH_HEAD` immediately after fetching that single branch. Do not rely on a remote-tracking ref that the fetch may not update, or require its SHA to change to prove success. Do not use a fetch refspec that writes to a local branch. Fetching may update local remote-tracking refs, but base selection must leave the parent checkout's branch, files, and local landing branch unchanged.
- For an independent task, select the fetched remote landing-branch tip even when the local landing branch is ahead or has diverged. Report local commits excluded by ancestry, accounting for equivalent changes already published through squash or rebase; their presence alone does not block creation. Preserve the parent checkout and local branch.
- When local work is accepted, validated, and authorized for publication, publish it through the repository's normal integration rules first when possible. After it lands, fetch again and pin the remote tip. Creating a worktree does not itself authorize publishing unrelated commits, bypassing reviews, or force-pushing the landing branch. Independent tasks can proceed from the fetched remote tip while publication is pending.
- Inherit unpublished work only for an intentional dependency established by the user or agreed task scope. If that dependency cannot land first, use the narrowest branch or commit containing the dependency without unrelated work. Record its publication order and any required rebase or PR retargeting after it lands. Ask when the dependency cannot be isolated or its scope is unresolved; do not automatically use the entire local landing branch.
- For a local-only repository with no remote base, select the identified local base and record that remote freshness does not apply. If fetching fails, report that freshness could not be verified. Use a cached fallback only when the user has explicitly allowed it in the task or accepts it now; prefer the cached remote tip. A local fallback must also satisfy the dependency rules above. If the remote reports that the branch does not exist, resolve the intended branch before continuing; offline permission does not settle a missing or renamed branch.
- Verify that the selected ref resolves to a locally available commit, then resolve its full SHA and assign it to `WORKTREE_BASE_COMMIT` for the helper invocation. Record in `WORKTREE_HANDOFF.md` the source ref, intended landing branch and remote when applicable, selected SHA, local/remote relationship, selection reason, and whether fetching succeeded, failed, or was skipped. An explicit base or continuation that skips fetching must not be described as the latest remote state.

Before publishing a task PR, check its commits and diff against the intended remote destination. They must contain only the task and recorded intentional dependencies; resolve unrelated inherited work before marking the PR ready.
