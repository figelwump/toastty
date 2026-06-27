---
name: toastty-orchestrator-builder
description: Use this skill when the user explicitly wants to design, generate, or refine a custom Toastty orchestrator skill for a specific workflow, including workflow-specific coordination across Toastty workspaces, panels, managed agents, artifacts, and cooperative workspace scoping.
---

# Toastty Orchestrator Builder

Build a workflow-specific Toastty orchestration skill. The output is usually a new custom skill, not a long-running orchestrator process.

Use this skill to turn a user's workflow into repeatable agent instructions that drive Toastty through its CLI/app-control surface while respecting cooperative workspace scope.

## Core Flow

1. Understand the workflow.
   - Ask only the questions needed to shape a useful first draft.
   - If the user already gave enough context, proceed with explicit assumptions.
   - Prefer a narrow first orchestrator over a broad command center.
2. Inventory the relevant Toastty surface.
   - Read `references/capability-map.md`.
   - Use the live CLI when a running Toastty instance is available:
     - `"$TOASTTY_CLI_PATH" --json action list`
     - `"$TOASTTY_CLI_PATH" --json query list`
   - Fall back to repo docs when no live instance is available:
     - `docs/cli-reference.md`
     - `docs/agents/workspace-scope.md`
3. Define the scope policy before writing the generated skill.
   - Default to `session scope set-current` for the orchestrated session's own workspace.
   - Add workspaces only when the workflow says the user explicitly assigned them.
   - Treat `scope_denied` as an intentional stop-and-report signal.
4. Draft the generated orchestrator.
   - Use `assets/orchestrator-skill-template.md` as the starting structure.
   - Name it after the workflow, such as `toastty-pr-review-orchestrator` or `toastty-release-captain`.
   - Keep the generated skill trigger precise so agents do not invoke it for unrelated Toastty tasks.
5. Create or update the generated skill.
   - If creating a new skill, use the active runtime's skill-creation workflow when available.
   - Ask whether the generated skill should target Codex, Claude, or both.
   - For global generated skills, suggest Codex under `${CODEX_HOME:-$HOME/.codex}/skills` and Claude under `${CLAUDE_HOME:-$HOME/.claude}/skills`.
   - For repo-local generated skills, suggest Codex/agent skills under the repo's `.agents/skills/` and Claude skills under the repo's `.claude/skills/`.
6. Validate the generated skill.
   - Run the skill validator when available.
   - Check that `agents/openai.yaml` default prompt names the generated skill with `$skill-name`.
   - If the generated skill includes scripts, run representative script syntax or smoke checks.
   - Run mutation tests only in a throwaway workspace created for that validation and only after the user approves a live Toastty mutation check.

## Intake Questions

Ask a compact set. Use these as defaults:

- What workflow should the orchestrator handle?
- Which agents, tools, or roles should it coordinate?
- What workspace or panel layout should it create or assume?
- What outputs should it produce: terminal summary, Scratchpad, notifications, files, or child sessions?
- Should it create a Codex skill, a Claude skill, or both; and should it be global or repo-local?
- What should be scoped by default, and when may scope expand?
- What approval, stop, cleanup, and handoff rules should it follow?

If the user wants an example instead of an installed skill, create a short capability tour or draft skill text and stop before writing files.

## Required Generated-Skill Sections

Every generated Toastty orchestrator skill should include:

- Purpose and exact trigger scope.
- Prerequisites and instance targeting.
- Workspace/panel/session plan.
- Scope policy and `scope_denied` behavior.
- Capability discovery commands.
- Orchestration steps.
- Reporting and cleanup rules.
- Validation expectations.

## Boundaries

- Do not claim workspace scope is a security sandbox. It is cooperative orchestration guidance.
- Do not auto-clear scope unless the generated workflow explicitly requires returning to unrestricted automation.
- Do not auto-add out-of-scope workspaces after `scope_denied`; stop and ask or report unless the workflow pre-authorized that workspace.
- Do not hard-code a full action/query catalog in the generated skill. Teach the agent to discover live capabilities and use documented common examples.
- Do not use automation-only/debug commands to bypass app-control scope. Use them only for explicitly requested validation or disposable automation runs.
- Do not create a background daemon, scheduler, or persistent orchestrator service unless the user explicitly asks for an implementation beyond a skill.
