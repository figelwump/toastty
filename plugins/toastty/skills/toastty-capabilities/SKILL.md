---
name: toastty-capabilities
description: Use this skill when a user asks an agent to orchestrate, inspect, automate, control, coordinate, or present work inside Toastty, including setting or clearing Toastty workspace annotations, creating workspaces or panels, launching agents, opening browser or local-document panels, using Scratchpad, checking terminal state, managing workspace scope, or notifying the user. Prefer this over document or code-review annotation tools when the target is a Toastty workspace.
---

# Toastty Capabilities

Use this skill to drive Toastty from an agent session. Toastty provides a bundled CLI that talks to the running app over its automation socket. Prefer live discovery and typed descriptors over copied command catalogs.

## Environment Contract

In a Toastty-launched agent terminal, expect:

- `TOASTTY_SKILLS_ROOT`: stable absolute path to the delivered Toastty plugin's
  `skills` directory when the runtime uses launch-scoped delivery. Read-only;
  never write into it. Project discovery may load this skill without setting
  this variable, so it is not proof of a managed session.
- `TOASTTY_USER_SKILLS_ROOT`: absolute path to the user's Toastty skill-package
  source directory. It may not exist yet.
- `TOASTTY_CLI_PATH`: absolute path to the bundled `toastty` CLI.
- `TOASTTY_PANEL_ID`: current terminal panel ID.
- `TOASTTY_SESSION_ID`: current managed session ID when the agent was launched by Toastty.
- `TOASTTY_SOCKET_PATH`: resolved socket path for the owning app instance.
- `TOASTTY_CWD`: launch working directory when Toastty knows it.
- `TOASTTY_REPO_ROOT`: repository root when Toastty inferred one.

Before using this skill, require the injected CLI and current panel identity. Do
not guess a repository checkout, global skill directory, versioned Codex cache,
or Toastty instance:

```bash
if [[ -z "${TOASTTY_CLI_PATH:-}" || ! -x "$TOASTTY_CLI_PATH" || -z "${TOASTTY_PANEL_ID:-}" ]]; then
  echo "error: toastty-capabilities must run inside a Toastty-managed agent session" >&2
  exit 1
fi
```

Always invoke the injected CLI:

```bash
"$TOASTTY_CLI_PATH" --json query run terminal.state --panel "$TOASTTY_PANEL_ID"
```

If `TOASTTY_CLI_PATH` is missing, not executable, or the probe fails, do not guess which Toastty instance to target. Ask the user to run you from a Toastty pane or provide an explicit socket path.

## Discovery Loop

Discover the live app-control surface before composing a workflow:

```bash
"$TOASTTY_CLI_PATH" --json action list
"$TOASTTY_CLI_PATH" --json query list
```

Use the returned descriptors for canonical IDs, selectors, parameters, aliases, summaries, repeatability, and allowed values. Do not duplicate the whole catalog in your prompt or skill output. For every JSON response, check `.ok == true` before reading `.result`; if `.ok` is false, branch on `.error.code` and preserve the message in your report.

## Workspace, Panel, And Session Model

Toastty has windows, workspaces, workspace tabs, and panels. A terminal panel can host a managed agent session. App-control selectors target `windowID`, `workspaceID`, and `panelID`; many commands can infer a target, but robust workflows should pass explicit IDs from `terminal.state`, `workspace.snapshot`, or action results.

To find an already-open browser, local document, or Scratchpad in the current
workspace, query `terminal.state` to obtain the `workspaceID`, then query
`workspace.snapshot` for that workspace. The snapshot's `rightPanel.tabs`
describes the selected workspace tab's right-panel tabs and includes `panelID`,
`title`, `webDefinition`, plus model-backed identity where applicable:
`filePath` for local documents, `url` for browsers, and
`scratchpadDocumentID`/`scratchpadRevision`/`scratchpadSessionID` for
Scratchpads. Match the strongest identity available (path or URL before title),
then use the returned `panelID` for the next action or query. Do not assume this
list includes right-panel tabs belonging to unselected workspace tabs.

Common workflow families:

- Workspaces and tabs: `workspace.create`, `workspace.select`, `workspace.rename`, `workspace.set-annotation`, `workspace.clear-annotation`, `workspace.tab.create`, `workspace.tab.select`.
- Panels: `panel.create.browser`, `panel.create.local-document`, `panel.close`, `panel.focus-mode.toggle`.
- Terminal control: `terminal.send-text`, `terminal.visible-text`, `terminal.state`.
- Agents: `agent.launch`.
- Scratchpad: `panel.scratchpad.set-content`, `panel.scratchpad.patch-content`, `panel.scratchpad.export`, `panel.scratchpad.state`.
- Notifications: `toastty notify`.

## Workspace Annotations

Treat requests to annotate, label, tag, or mark a Toastty workspace as workspace
annotation actions. Do not turn them into document annotation or code review
flows. A user-supplied identifier is enough to set the annotation text. A
remote lookup may provide a canonical URL, but a missing or unverifiable remote
record must not block the annotation; omit the URL instead.

The caller chooses the annotation `key`; Toastty does not derive it from the
displayed `text`. Use a stable semantic identity for the kind of annotation,
not its current value. The same exact key updates one chip within a workspace
and shares one claimed color across workspaces. The first use records either
the supplied color or an automatic color. While any annotation with that key
exists, omit color or repeat the claim; attempting to replace it fails. Examples:

- Linear issue: `key=linear`, `text=LIN-030`, and
  `url=<verified canonical Linear issue URL>` when available.
- GitHub pull request: `key=github-pr`, `text="PR #1931"`, and
  `url=<verified GitHub pull URL>` when available.
- GitHub issue: `key=github-issue`, `text="Issue #482"`, and
  `url=<verified GitHub issue URL>` when available.
- Git branch: `key=git-branch`, `text=feat/hooks-chips`; omit `url` unless a
  canonical branch URL is already known.

Include a URL only when the user supplied it or available context verified it;
never construct one by guessing from the label. Query `workspace.snapshot`
when existing annotations may need to be preserved or updated. One exact key
represents one chip per workspace, so multiple annotations of the same kind
need distinct stable keys.

## Scope Semantics

Workspace scope is cooperative guidance, not a security sandbox. A scoped session may automate its current workspace and explicitly assigned workspaces. Requests from a managed session carry caller identity from `TOASTTY_SESSION_ID`.

Default to scoped operation when an orchestration workflow is meant to stay inside assigned workspaces. The `--workspace` selector on `agent.launch` chooses where the child is placed; it does not assign the child's exact workspace scope. A child launched by a scoped parent initially inherits a snapshot of the parent's effective scope, while a child launched by an unrestricted parent starts unrestricted.

Exact child scoping is necessarily a post-launch narrowing step because `agent.launch` returns the new `sessionID`. The child may begin executing with its inherited scope before that narrowing completes, so this is not pre-execution isolation. Do not put child-scoping commands in `initialCommands`: those commands run before the final agent command's managed `TOASTTY_SESSION_ID`, `TOASTTY_PANEL_ID`, and CLI environment assignments.

Use scope intentionally:

```bash
"$TOASTTY_CLI_PATH" --json session scope set-current
"$TOASTTY_CLI_PATH" --json session scope show
"$TOASTTY_CLI_PATH" --json session scope add --workspace "<workspace-id>"
"$TOASTTY_CLI_PATH" --json session scope clear
```

Treat `scope_denied` as a boundary signal. Do not retry with broader targets unless the user explicitly assigned that workspace or the workflow already authorized scope expansion. Explain what was denied and ask before expanding.

When launching a workspace-bounded child:

1. Require `TOASTTY_SESSION_ID` and `TOASTTY_PANEL_ID`, then inspect the current parent session with `session scope show --session "$TOASTTY_SESSION_ID"`. Stop if the managed parent identity is unavailable.
2. If the parent is unrestricted, fence it to its current workspace with `session scope set-current --session "$TOASTTY_SESSION_ID"`. Preserve an already-scoped parent rather than resetting it.
3. Create the workflow-authorized workspace. Because the parent is now scoped, `workspace.create` adds that new workspace to the parent's explicit scope. For an existing workspace, first verify it is in the parent's effective scope; use `session scope add` only when the user explicitly assigned it.
4. Launch the child into the target workspace and validate the returned `workspaceID`, `panelID`, and `sessionID`.
5. Set the returned child session's explicit scope to exactly the target with `session scope set --session <child-session-id> --workspace <workspace-id>`.
6. Show and verify the child scope. Require `isScoped == true`, `workspaceIDs == [<workspace-id>]`, and `effectiveWorkspaceIDs == [<workspace-id>]`. Stop and report if any step fails.

If the parent began unrestricted and step 2 succeeds, it remains scoped after a successful handoff. On failure, report whether the parent was changed and whether a workspace or child session may already exist. A transactional helper may restore a previously unrestricted parent with `session scope clear` as a recorded failure rollback; never clear a parent that was already scoped, and do not silently broaden scope.

## Worked Examples

### Launch A Workspace-Bounded Child Agent

This example creates a new authorized workspace. Check every response before using its result; the Python snippets below fail if Toastty reports an error or omits a required field.

```bash
set -e

if [ -z "${TOASTTY_SESSION_ID:-}" ] || [ -z "${TOASTTY_PANEL_ID:-}" ]; then
  echo "A managed parent session and panel are required" >&2
  exit 1
fi

run_json() {
  local label="$1"
  shift
  local response
  if ! response="$("$@")"; then
    echo "$label failed" >&2
    printf '%s\n' "$response" >&2
    return 1
  fi
  if ! printf '%s\n' "$response" \
    | python3 -c 'import json, sys; r=json.load(sys.stdin); raise SystemExit(0 if r.get("ok") is True else 1)'
  then
    echo "$label returned an error" >&2
    printf '%s\n' "$response" >&2
    return 1
  fi
  printf '%s\n' "$response"
}

result_field() {
  python3 -c 'import json, sys; r=json.load(sys.stdin); v=r["result"][sys.argv[1]]; assert (isinstance(v, bool) or isinstance(v, str)) and (not isinstance(v, str) or v), r; print(str(v).lower() if isinstance(v, bool) else v)' "$1"
}

parent_began_unrestricted="false"
workspace_id=""
child_session_id=""
child_panel_id=""
launch_attempted="false"
last_successful_response=""

report_launch_failure() {
  local status="$?"
  trap - EXIT
  if [ "$status" -eq 0 ]; then
    return
  fi

  echo "Stopped workspace-bounded child launch" >&2
  if [ -n "$last_successful_response" ]; then
    echo "Last successful Toastty response:" >&2
    printf '%s\n' "$last_successful_response" >&2
  fi
  if [ "$launch_attempted" = "true" ]; then
    echo "The workspace and child may already exist; the child may be running with broader inherited scope" >&2
  elif [ -n "$workspace_id" ]; then
    echo "Workspace $workspace_id was already created" >&2
  fi

  if [ "$parent_began_unrestricted" = "true" ]; then
    if "$TOASTTY_CLI_PATH" --json session scope clear \
      --session "$TOASTTY_SESSION_ID" >/dev/null
    then
      echo "Restored the parent session to its previous unrestricted state" >&2
    else
      echo "The parent session remains scoped; restore it only after reviewing this failure" >&2
    fi
  fi
  exit "$status"
}

trap report_launch_failure EXIT

parent_scope_json="$(
  run_json "inspect parent scope" "$TOASTTY_CLI_PATH" --json session scope show \
    --session "$TOASTTY_SESSION_ID"
)"
last_successful_response="$parent_scope_json"

parent_is_scoped="$(
  printf '%s\n' "$parent_scope_json" \
    | result_field isScoped
)"

if [ "$parent_is_scoped" = "false" ]; then
  parent_began_unrestricted="true"
  parent_scope_set_json="$(
    run_json "scope parent session" "$TOASTTY_CLI_PATH" --json session scope set-current \
      --session "$TOASTTY_SESSION_ID"
  )"
  last_successful_response="$parent_scope_set_json"
fi

terminal_state_json="$(
  run_json "resolve parent window" "$TOASTTY_CLI_PATH" --json query run terminal.state \
    --panel "$TOASTTY_PANEL_ID"
)"
last_successful_response="$terminal_state_json"
window_id="$(printf '%s\n' "$terminal_state_json" | result_field windowID)"

workspace_json="$(
  run_json "create workspace" "$TOASTTY_CLI_PATH" --json action run workspace.create \
    --window "$window_id" \
    title="Review" \
    activate=false
)"
last_successful_response="$workspace_json"
workspace_id="$(printf '%s\n' "$workspace_json" | result_field workspaceID)"

launch_attempted="true"
launch_json="$(
  run_json "launch child agent" "$TOASTTY_CLI_PATH" --json action run agent.launch \
    --workspace "$workspace_id" \
    profileID=codex \
    cwd="$PWD" \
    initialPrompt="Review this change and report findings only."
)"
last_successful_response="$launch_json"

child_session_id="$(printf '%s\n' "$launch_json" | result_field sessionID)"
child_workspace_id="$(printf '%s\n' "$launch_json" | result_field workspaceID)"
child_panel_id="$(printf '%s\n' "$launch_json" | result_field panelID)"

if [ "$child_workspace_id" != "$workspace_id" ] || [ -z "$child_panel_id" ]; then
  echo "agent.launch returned an unexpected child placement" >&2
  exit 1
fi

child_scope_set_json="$(
  run_json "scope child session" "$TOASTTY_CLI_PATH" --json session scope set \
    --session "$child_session_id" \
    --workspace "$workspace_id"
)"
last_successful_response="$child_scope_set_json"

child_scope_json="$(
  run_json "verify child scope" "$TOASTTY_CLI_PATH" --json session scope show \
    --session "$child_session_id"
)"
last_successful_response="$child_scope_json"

printf '%s\n' "$child_scope_json" \
  | python3 -c 'import json, sys; r=json.load(sys.stdin); w=sys.argv[1]; x=r.get("result", {}); assert r.get("ok") is True and x.get("isScoped") is True and x.get("workspaceIDs") == [w] and x.get("effectiveWorkspaceIDs") == [w], r' \
      "$workspace_id"

trap - EXIT
printf 'Launched child session %s in workspace %s, panel %s\n' \
  "$child_session_id" "$workspace_id" "$child_panel_id"
```

If launch, child scoping, or verification fails after `agent.launch` returns, stop and report that the workspace and child may already exist and the child may be running with broader inherited scope. Do not continue orchestrating through that child.

### Open Browser And Local Document Panels

```bash
"$TOASTTY_CLI_PATH" --json action run panel.create.browser \
  --workspace "$workspace_id" \
  url="https://example.com"

"$TOASTTY_CLI_PATH" --json action run panel.create.local-document \
  --workspace "$workspace_id" \
  filePath="$PWD/docs/plan.md"
```

Omit `placement` unless the workflow has a reason to override Toastty's default placement.

### Publish To Scratchpad

Use Scratchpad for visual summaries, diagrams, QA packets, comparisons, or dashboards. Prefer a complete HTML document for first publish or major rewrites:

```bash
"$TOASTTY_CLI_PATH" --json action run panel.scratchpad.set-content \
  --stdin content \
  "sessionID=$TOASTTY_SESSION_ID" \
  title="Review Summary" < /tmp/review-summary.html
```

For small exact updates, export or query state first and then use `panel.scratchpad.patch-content` with the current revision.

### Notify The User

Use notifications for ready, needs-approval, or error states:

```bash
"$TOASTTY_CLI_PATH" notify "Review ready" "The background review is complete." \
  --workspace "$workspace_id" \
  --panel "$panel_id"
```

## Creating User Skills

Toastty delivers user-created skill packages to managed agent sessions. Create
one only when the user explicitly asks for a new skill; do not author skills
proactively.

- Write `$TOASTTY_USER_SKILLS_ROOT/<name>/SKILL.md` with YAML frontmatter
  containing `name` and a non-empty `description`. The directory name must
  match the frontmatter name exactly: lowercase letters, digits, and hyphens
  only, at most 64 characters. Supporting files may sit next to `SKILL.md`.
- Outside a managed session, where `TOASTTY_USER_SKILLS_ROOT` is absent, the
  production location is `~/.toastty/skills`.
- Never write into `$TOASTTY_SKILLS_ROOT`; it is the delivered read-only
  Toastty plugin snapshot.
- Hidden package directories (names starting with `.`) are ignored, and
  symlinks are rejected.
- New or changed skills reach subsequently launched managed sessions, not the
  current one. Tell the user the skill takes effect on the next managed agent
  launch and can be inspected under `Toastty > Manage Toastty Skills`.

## When To Create Another Skill

If the user asks for a recurring Toastty workflow, write a narrow, workflow-specific skill that extends these general capabilities instead of creating another general Toastty orchestration or capability skill. Describe the workflow intent, required Toastty context, scope policy, live discovery steps, actions and queries to use, validation, and failure handling.
