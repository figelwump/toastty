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
2. Capture scenario-specific contracts.
   - Identify the target app, repo, domain, or workflow environment the generated skill is for.
   - Ask for or inspect local instructions, existing workflow docs, validation commands, repo-local skills, and approval rules that should be reflected in the generated skill.
   - Capture required agent profiles, models, reasoning levels, roles, and allowed fallbacks. Treat hard requirements as stop conditions; treat preferences as defaults the generated skill may override with user approval.
   - Capture how required agent capabilities can be verified, such as a user-provided profile ID, a known profile config, discovered `agent.launch` support, or a documented command. If model or reasoning level cannot be verified from available sources, make the generated skill stop or ask instead of claiming verification.
   - If validation requirements are unclear and the generated skill will be installed rather than shown as an example, ask a focused question instead of inventing generic validation rules.
3. Inventory the relevant Toastty surface.
   - Read `references/capability-map.md`.
   - Use the live CLI when a running Toastty instance is available:
     - `"$TOASTTY_CLI_PATH" --json action list`
     - `"$TOASTTY_CLI_PATH" --json query list`
   - Fall back to repo docs when no live instance is available:
     - `docs/cli-reference.md`
     - `docs/agents/workspace-scope.md`
4. Define the scope policy before writing the generated skill.
   - Default to `session scope set-current` for the orchestrated session's own workspace.
   - Add user-assigned workspaces only when explicitly assigned.
   - Add workflow-created workspaces only when the orchestrator's workflow contract explicitly authorizes it to create and manage child workspaces for the task.
   - Make generated skills record created or assigned workspace IDs, add them to scope when needed, and verify the resulting scope before acting through them.
   - Treat `scope_denied` as an intentional stop-and-report signal.
5. Define instance targeting.
   - Prefer the managed session's injected `TOASTTY_CLI_PATH`, `TOASTTY_SOCKET_PATH`, `TOASTTY_SESSION_ID`, and `TOASTTY_PANEL_ID`.
   - If the generated skill supports targeting by `instance.json`, tell it to read the recorded socket path and pass `--socket-path <path>` to every subsequent live Toastty CLI command, or explicitly set `TOASTTY_SOCKET_PATH` for those commands. Do not leave target selection implicit after asking for an `instance.json`.
   - If multiple Toastty instances may be running and no target is explicit, make that a stop-and-ask condition.
6. Draft the generated orchestrator.
   - Use `assets/orchestrator-skill-template.md` as the starting structure.
   - Name it after the workflow, such as `toastty-pr-review-orchestrator` or `toastty-release-captain`.
   - Keep the generated skill trigger precise so agents do not invoke it for unrelated Toastty tasks.
   - Encode workflow-specific validation sources and commands when known. For example, only generated skills that target this Toastty app repo should name `.agents/skills/toastty-verify/SKILL.md`; other workflows should name their own validation source or ask when it is unknown.
   - Encode required agent profiles, models, reasoning levels, and fallback behavior from the scenario. Do not hard-code a model or profile requirement unless the workflow explicitly requires it.
7. Create or update the generated skill.
   - If creating a new skill, use the active runtime's skill-creation workflow when available.
   - Ask whether the generated skill should target Codex, Claude, or both.
   - For global generated skills, suggest Codex under `${CODEX_HOME:-$HOME/.codex}/skills` and Claude under `${CLAUDE_HOME:-$HOME/.claude}/skills`.
   - For repo-local generated skills, suggest Codex/agent skills under the repo's `.agents/skills/` and Claude skills under the repo's `.claude/skills/`.
8. Validate the generated skill.
   - Run the skill validator when available.
   - For repo-local Codex/agent skills, check that `agents/openai.yaml` default prompt names the generated skill with `$skill-name` when that file exists and the repo uses it.
   - If the generated skill includes scripts, run representative script syntax or smoke checks.
   - Run mutation tests only in a throwaway workspace created for that validation and only after the user approves a live Toastty mutation check.

## Intake Questions

Ask a compact set. Use these as defaults:

- What workflow should the orchestrator handle?
- What app, repo, or domain is the orchestrator for, and what local instructions or validation workflows should it follow?
- Which agents, tools, or roles should it coordinate?
- Are any agent profiles, models, reasoning levels, or role capabilities required; if unavailable, should the workflow stop or fall back?
- What workspace or panel layout should it create or assume?
- What outputs should it produce: terminal summary, Scratchpad, notifications, files, or child sessions?
- Should it create a Codex skill, a Claude skill, or both; and should it be global or repo-local?
- What should be scoped by default, and when may scope expand?
- How should the generated skill target a Toastty instance outside a managed session: explicit socket path, `instance.json`, or user confirmation?
- What approval, stop, cleanup, and handoff rules should it follow?
- What validation is required for the generated workflow itself, and what validation should the generated skill require when it performs the real workflow?

If the user wants an example instead of an installed skill, create a short capability tour or draft skill text and stop before writing files.

## Required Generated-Skill Sections

Every generated Toastty orchestrator skill should include:

- Purpose and exact trigger scope.
- Prerequisites and instance targeting.
- Workspace/panel/session plan.
- Scope policy and `scope_denied` behavior.
- Capability discovery commands.
- Required agent profiles, models, roles, and fallback or stop behavior.
- Orchestration steps.
- Reporting and cleanup rules.
- Workflow-specific validation expectations tied to the target repo, app, domain, or user-provided acceptance checks.

## Boundaries

- Do not claim workspace scope is a security sandbox. It is cooperative orchestration guidance.
- Do not auto-clear scope unless the generated workflow explicitly requires returning to unrestricted automation.
- Do not auto-add out-of-scope workspaces after `scope_denied`; stop and ask or report unless the workflow pre-authorized that workspace.
- Do not hard-code a full action/query catalog in the generated skill. Teach the agent to discover live capabilities and use documented common examples.
- Do not hard-code repo-specific validation workflows into generic generated skills. Include them only when the target scenario, repo instructions, or user explicitly supplies them.
- Do not hard-code agent profile or model requirements unless the workflow needs that exact capability. Otherwise make profile selection explicit and describe fallback or stop behavior.
- Do not use automation-only/debug commands to bypass app-control scope. Use them only for explicitly requested validation or disposable automation runs.
- Do not create a background daemon, scheduler, or persistent orchestrator service unless the user explicitly asks for an implementation beyond a skill.
