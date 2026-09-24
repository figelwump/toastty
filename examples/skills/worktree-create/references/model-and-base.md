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
- Apply the model preferences in the global instructions to this agent's actual
  assignment. Resolve preference names against current available provider
  identifiers.
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

Where the runtime allows model and effort overrides, configure them explicitly.
Prefer a concise task handoff over full-history inheritance when inheritance
would force an unsuitable model or effort. If a role or runtime fixes those
settings, respect that constraint and report the limitation rather than claiming
that the preferred configuration was applied.

## Base selection

Follow the global instructions for choosing and pinning a base commit. This
section covers only what is specific to creating a worktree.

The parent checkout is the worktree this workflow was invoked from; the landing
branch may be checked out elsewhere. Uncommitted parent changes are not included
in a Git base, regardless of how it is selected. Do not automatically stash,
commit, or transfer those changes, and leave the parent checkout's branch, files,
and local landing branch unchanged.

Creating a worktree does not by itself authorize publishing unrelated local
commits, bypassing reviews, or force-pushing the landing branch. An independent
task can proceed from the fetched remote tip while such publication is pending.

Assign the resolved full SHA to `WORKTREE_BASE_COMMIT` for the helper invocation.
Record in `WORKTREE_HANDOFF.md` the source ref, intended landing branch and remote
when applicable, selected SHA, local/remote relationship, selection reason, and
whether fetching succeeded, failed, or was skipped.
