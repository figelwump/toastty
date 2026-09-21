---
name: toastty-capabilities
description: Use this skill when a user asks an agent to orchestrate, inspect, automate, control, coordinate, or present work inside Toastty, including setting or clearing Toastty workspace annotations, creating workspaces or panels, launching agents, opening browser or local-document panels, using Scratchpad, checking terminal state, managing workspace scope, or notifying the user.
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

Use the returned descriptors for canonical IDs, selectors, parameters, aliases,
summaries, repeatability, allowed values, and parameter-specific
`supportedProfileIDs`. Do not duplicate the whole catalog in your prompt or
skill output. For every JSON response, check `.ok == true` before reading
`.result`; if `.ok` is false, branch on `.error.code` and preserve the message
in your report.

## Workspace, Panel, And Session Model

Toastty has windows, workspaces, workspace tabs, and panels. A terminal panel can host a managed agent session. App-control selectors target `windowID`, `workspaceID`, and `panelID`; many commands can infer a target, but robust workflows should pass explicit IDs from `terminal.state`, `workspace.snapshot`, or action results.

Discovery, inspection, status reporting, and verification must preserve the
user's visible workspace, tab, and keyboard focus. Query explicit workspace or
panel IDs; do not select a workspace/tab or focus a panel to inspect it.
`workspace.select` changes the user's visible workspace. Selection and focus
actions are appropriate only for user-authorized navigation.

Current split actions return the target `workspaceID` and the newly created
terminal `panelID`. Check both fields before composing a follow-up
`agent.launch`; never pass placeholders such as `undefined` or `null` through
`--panel`. When controlling an older running Toastty version whose successful
split response omits `panelID`, resolve the newly focused or newly added
`slotPanelIDs` entry from `workspace.snapshot` before launching. A newly split
terminal surface may take a moment to mount, so preserve a launch error rather
than falling back to raw terminal input or another panel.

To find an already-open browser, local document, or Scratchpad in the current
workspace, query `terminal.state` to obtain the `workspaceID`, then query
`workspace.snapshot` for that workspace. The snapshot's `rightPanel.tabs`
describes the selected workspace tab's right-panel tabs and includes `panelID`,
`title`, `webDefinition`, plus model-backed identity where applicable:
`filePath` for local documents, `url` for browsers, and
`scratchpadDocumentID`/`scratchpadRevision`/`scratchpadSessionID` for
Scratchpads. Match the strongest identity available (path or URL before title),
then use the returned `panelID` for the next action or query. Do not assume this
list includes right-panel tabs belonging to unselected workspace tabs. Use a
known panel ID from creation or task records for those panels; do not select a
tab merely to discover its contents. Report a discovery limit if no supported
query supplies the missing identity.

Common workflow families:

- Annotation discovery: `annotation.keys`.
- Workspaces and tabs: `workspace.create`, `workspace.select`, `workspace.rename`, `workspace.set-annotation`, `workspace.clear-annotation`, `workspace.tab.create`, `workspace.tab.select`.
- Panels: `panel.create.browser`, `panel.create.local-document`, `panel.close`, `panel.focus-mode.toggle`.
- Terminal control: `terminal.send-text`, `terminal.visible-text`, `terminal.state`. To read another terminal's output in the same workspace, use the toastty-read-terminal skill. When sending a follow-up to a known managed session, pass its exact `expectedSessionID` together with the target `panelID`; Toastty then rejects delivery if that panel no longer hosts that session, without requiring a selected-tab snapshot. Do not use `allowUnavailable` to hide an expected-session mismatch.
- Agents: `agent.launch`.
- Scratchpad: `panel.scratchpad.set-content`, `panel.scratchpad.patch-content`, `panel.scratchpad.export`, `panel.scratchpad.state`.
- Notifications: `toastty notify`.

## Background Browser Verification

Reload an existing browser by its explicit panel ID without selecting its
workspace/tab or changing focus:

```bash
"$TOASTTY_CLI_PATH" --json action run panel.browser.reload --panel "$PANEL_ID"
```

This starts loading even for an unmounted browser and restarts any in-progress
navigation. It revalidates cached resources for an already loaded page. A browser
with no URL (the start page) returns an error. Success means the reload was
requested; use `panel.browser.state` below to check completion or failure.

Query a browser by its explicit panel ID without selecting its workspace or tab:

```bash
"$TOASTTY_CLI_PATH" --json query run panel.browser.state --panel "$PANEL_ID"
```

This query can create the browser runtime and start loading its configured
destination in the background. Panel creation alone does not eagerly load a
hidden panel, and restored panels are not all loaded at startup. Repeating the
query for an unchanged destination does not restart navigation. Background
pages still use memory and can perform ongoing work; query only needed panels.

- `stateRestorableURL` is the configured/persisted destination, not proof that
  the page reached it. `observedURL` is WebKit's actual URL, or null; during a
  pending or failed load it can still describe the previous document.
- `navigationState` is `idle`, `loading`, `finished`, or `failed`. `idle` means
  no observed document-navigation result, including the internal start page
  and same-document history changes that produce no navigation callbacks.
  `finished` requires WebKit's completion callback for the current navigation;
  it does not prove HTTP success, application/SPA readiness, visual correctness,
  or video playback. An invalid destination reports `failed`.
- `title` is the current WebKit title or null. `isLoading` reports WebKit loading
  activity; false alone is not success. `navigationError` is null or
  `{domain, code, message}` for the current failed navigation. A new navigation
  clears the previous error.
- `hostLifecycleState` describes UI attachment: `detached`, `attached`, or
  `ready`. `ready` means attached to a window, not a successfully loaded page.
  A detached browser can finish navigation, but detached screenshot requests
  remain unsupported.

Choose a bounded deadline before polling, for example one query per second for
up to 30 seconds. Check `.ok` each time and stop on an error, `finished`, or
`failed`. Compare the observed destination with the expected page, allowing
known redirects. At the deadline, or when an older app omits navigation fields,
report verification as incomplete with the last available state. Do not select
a workspace/tab or move focus to force a stronger result. Report visual or
application readiness separately when the available evidence cannot establish it.

## Closing Panels

`panel.close` is non-interactive on the app-control path: it returns an error
instead of presenting confirmation UI. Invoke it without a termination override
first unless the request already authorizes terminating a running terminal
process. Resolve the target workspace first and pass it explicitly.

- On `CONFIRMATION_REQUIRED`, preserve the error message. If it identifies a
  running terminal and process termination is authorized, retry with
  `terminateRunningProcess=true`. That parameter is terminal-only; never use it
  as permission to discard unsaved local-document changes.
- On `CLOSE_BLOCKED`, preserve the error message and do not retry in a loop. An
  unavailable terminal assessment may be overridden once when process
  termination is authorized; a document save in progress cannot be forced.

```bash
"$TOASTTY_CLI_PATH" --json action run panel.close \
  --workspace "<workspace-id>"
```

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

Before setting an annotation, query `annotation.keys`. It returns every key
previously registered in the current Toastty runtime, including historical
keys and keys created outside the caller's workspace scope. Reuse an exact key
when its semantic meaning clearly matches the requested annotation kind; do
not fuzzy-match or infer meaning from an ambiguous key. Omit `color` when
reusing a key so its existing global claim remains authoritative.

Also query `workspace.snapshot` for the target workspace before setting the
annotation. Because one exact key represents one chip per workspace, setting a
key already present there replaces that chip's text and URL. Do so only when
the request intends to update that same semantic annotation; otherwise choose
a distinct stable key. If no catalog key is a clear match, use the established
canonical key for the annotation kind, such as the examples above.

Include a URL only when the user supplied it or available context verified it;
never construct one by guessing from the label. Multiple annotations of the
same kind need distinct stable keys.

## Agent Model And Reasoning Selection

Treat `model` and `reasoningEffort` on `agent.launch` as explicit, action-local
selections, not changes to `agents.toml` or durable provider defaults. Omit a
parameter when the configured profile/provider default is intended. When the
user requests either selection:

1. Read the live `agent.launch` descriptor from `--json action list`.
2. Require the requested parameter to exist and require the target `profileID`
   to appear in that parameter's `supportedProfileIDs`.
3. If the parameter or support metadata is absent, stop cleanly and report that
   the running Toastty version does not support that selection.
   Do not fall back to `terminal.send-text`; that would bypass managed launch
   validation and instrumentation.

Current provider translations are:

- `model`: Codex, Claude Code, Cursor, OpenCode, MiMo Code, and Pi (`--model`).
- `reasoningEffort`: Codex (`--config model_reasoning_effort=<TOML string>`),
  Claude Code (`--effort`), and Pi (`--thinking`). Cursor, OpenCode, and MiMo
  Code do not support it; never translate reasoning to `variant` or another
  provider flag.

Pass requested values unchanged in the structured action arguments and let the
provider CLI make the final upstream validity decision after Toastty delivers
the command. Toastty performs only bounded syntax validation and safe
replacement of equivalent configured argv flags. An ambiguous wrapper or flag
shape is a clean launch failure, not a reason to retry with raw terminal input.

On success, treat `result.command` as composed-invocation evidence. It includes
Toastty instrumentation and environment assignments, so inspect it locally to
verify the expected provider flag/value and report only that check plus the
returned session/workspace/panel IDs. Never echo or log the complete command or
unrelated environment values.

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
5. Set the returned child's explicit scope to the target workspace. When the delegated task requires a reply to the parent, also include the parent's workspace: `session scope set --session <child-session-id> --workspace <workspace-id> --workspace <parent-workspace-id>`. This grants automation access to both entire workspaces. Resolve the parent's workspace and panel before launch and include its exact managed session ID in the handoff. The authorized delegation includes the return message; the child does not need a separate direct user request to deliver it.
6. Show and verify the child scope. Require `isScoped == true` and both `workspaceIDs` and `effectiveWorkspaceIDs` to contain exactly the assigned workspace IDs, regardless of order. Stop and report if any step fails.
7. For the return message, use `terminal.send-text` with the recorded parent panel and `expectedSessionID`. No parent snapshot is required. If the parent is gone, replaced, or out of scope, report failed delivery rather than targeting another session or broadening scope.

If the parent began unrestricted and step 2 succeeds, it remains scoped after a successful handoff. On failure, report whether the parent was changed and whether a workspace or child session may already exist. A transactional helper may restore a previously unrestricted parent with `session scope clear` as a recorded failure rollback; never clear a parent that was already scoped, and do not silently broaden scope.

## Worked Examples

### Launch A Workspace-Bounded Child Agent

This example has no terminal reply requirement and uses child-only scope. For a task that must reply to its parent, include the parent workspace in the scope and expected scope verification as described above.

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
