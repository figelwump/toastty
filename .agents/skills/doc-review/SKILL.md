---
name: doc-review
description: Use when code changes may need corresponding documentation updates — after features, refactors, workflow changes, new automation, or config/flag additions.
---

# Documentation Review

Review code changes and assess whether project documentation needs updating. This includes README.md, docs/ references, AGENTS.md, CLAUDE.md, and any other public-facing or agent-facing documentation.

Invoke this skill after completing a feature, refactor, workflow change, automation addition, or configuration change — or whenever the invoking agent judges that docs may have drifted from the codebase.

## Inputs

The invoker specifies one of:

- **Uncommitted changes** (default) — diff of the current working tree.
- **Commit range** — e.g. `abc123..HEAD`, `HEAD~5..HEAD`.
- **Date range** — e.g. `--since=2026-03-01 --until=2026-03-18`.

If no input is specified, default to uncommitted changes. If there are no uncommitted changes, fall back to the most recent commit.

## Core Flow

1. **Gather the change set.**
   - For uncommitted changes: read the staged and unstaged diff.
   - For a commit range or date range: read the log with diffs for the specified range.
   - Identify which files changed, what behavior was added/modified/removed, and any new flags, env vars, commands, config keys, or workflows introduced.

2. **Survey existing documentation.**
   Read the current contents of all documentation surfaces:
   - `README.md` (root and any subdirectory READMEs)
   - `AGENTS.md`
   - `CLAUDE.md`
   - Everything under `docs/`
   - Skill SKILL.md files under `.agents/skills/` if the changes touch skill-adjacent workflows

   Note which sections exist, what they cover, and their current level of detail.

3. **Analyze the gap.**
   For each change in the change set, determine whether existing docs:
   - Already cover the new behavior accurately — no update needed.
   - Cover the area but are now stale or incomplete — edit needed.
   - Don't cover the area and it warrants documentation — new content needed.
   - Cover something that was removed — deletion or simplification needed.

   Be conservative. Not every code change needs a doc update. Skip changes that are:
   - Pure internal refactors with no user/agent-visible behavior change.
   - Bug fixes that don't alter documented behavior.
   - Test-only changes.
   - Code style or formatting changes.

4. **Produce a proposal.**
   Present findings to the user as a structured proposal:

   ```
   ## Doc Review: [brief description of change set]

   ### Changes that need doc updates

   For each item:
   - **What changed:** [concrete description of the code/behavior change]
   - **Where to update:** [exact file and section]
   - **Proposed edit:** [what to add, modify, or remove — be specific enough to act on]

   ### No update needed

   [Brief explanation of why remaining changes don't need doc updates, or "All changes covered above."]
   ```

   If no documentation updates are needed, say so clearly and explain why. Do not suggest updates for the sake of having something to suggest.

5. **Wait for user review.**
   Stop after presenting the proposal. Do not make any file changes yet. The user will review, ask questions, adjust, or approve.

6. **Apply approved changes.**
   After the user approves (in whole or with modifications), make the documentation edits. Work through each approved item, editing the target files.

7. **Final check.**
   After applying changes, re-read each modified doc file to verify:
   - No broken markdown formatting.
   - No contradictions with other doc sections.
   - Consistent terminology and style with surrounding content.

## Invariants

- Never make doc changes without user approval of the proposal first.
- Never suggest doc updates that don't correspond to actual code/behavior changes.
- Prefer editing existing sections over creating new ones. Only suggest new files or sections when existing structure genuinely doesn't cover the topic.
- Keep AGENTS.md and CLAUDE.md in sync when both cover the same topic — if one needs an update, check whether the other does too.
- Match the voice and level of detail of surrounding documentation. Don't over-document simple things or under-document complex ones.
- Committed planning docs belong in `docs/plans/`, not under `artifacts/`.
- Don't touch auto-generated content or files that are populated by scripts.

## Scope boundaries

- This skill reviews and proposes documentation changes. It does not review code quality, suggest refactors, or run tests.
- If changes span multiple unrelated areas, group the proposal by topic rather than by file-changed order.
- For large change sets, prioritize: user-facing docs (README) > agent-facing docs (AGENTS.md, CLAUDE.md, skills) > reference docs (docs/).
