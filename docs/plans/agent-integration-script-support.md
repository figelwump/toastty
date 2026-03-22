# Toastty Agent Integration Script Support Plan

## Goal

Add first-class support for user-provided third-party agent integration scripts
in `~/.toastty/agents.toml`.

Today, custom agents can already report status through `TOASTTY_CLI_PATH`, but
they have no dedicated config surface for provider-specific launch setup. Users
can work around that by putting wrapper scripts directly in `argv`, but that
does not give Toastty a clear contract for:

- managed per-launch scratch space
- validation of the integration entry point
- documentation for how custom integrations should behave
- a stable path for agents to suggest when generating `agents.toml`

This plan adds one explicit config field for that purpose without turning
Toastty into a generic provider hook engine.

---

## Current State

Current behavior:

- `AgentProfile` supports `id`, `displayName`, `argv`, and `shortcutKey`
- `AgentProfilesFile` rejects unknown keys
- built-in instrumentation exists only for `codex` and `claude`
- custom agents launch with the base `TOASTTY_*` environment only
- `session ingest-agent-event` is intentionally private to the built-in
  Codex and Claude integrations
- managed launch artifacts already exist for built-in integrations and are
  cleaned up with the session lifecycle

The current custom-agent story is therefore:

- Toastty starts the session
- Toastty launches the configured command
- the command or wrapper script may call `TOASTTY_CLI_PATH`
- Toastty does not configure provider-specific hooks on the user's behalf

---

## Recommended Shape

Add one optional field to `agents.toml`:

```toml
[gemini]
displayName = "Gemini"
argv = ["gemini"]
integrationScript = "~/.toastty/integrations/gemini.sh"
shortcutKey = "g"
```

Design rules:

- `integrationScript` is allowed only on non-built-in profiles
- `integrationScript` is rejected on `codex` and `claude`
- `argv` remains the underlying provider command
- `integrationScript` is a launch adapter that runs before the provider
- if users need multiple helper scripts, they compose them behind the one
  `integrationScript`

This intentionally avoids:

- multiple per-event script fields in `agents.toml`
- a public generic replacement for `session ingest-agent-event`
- provider-specific schema in the app for arbitrary third-party agents

Why this shape:

- it is strictly more usable than asking users to overload `argv`
- it keeps provider-specific logic in user-owned scripts, not in Toastty
- it reuses the existing managed-artifacts model
- it stays small enough to document clearly and validate deterministically

---

## Launch Contract

When `integrationScript` is present on a custom profile, Toastty should:

1. Create a managed per-launch artifacts directory.
2. Inject a new environment variable:
   - `TOASTTY_AGENT_ARTIFACTS_DIR`
3. Launch the integration script first, with the original `argv` appended:

```sh
TOASTTY_* TOASTTY_AGENT_ARTIFACTS_DIR=... /resolved/integration-script <original argv...>
```

The script contract:

- the script may create helper files in `TOASTTY_AGENT_ARTIFACTS_DIR`
- the script may call `TOASTTY_CLI_PATH` with the existing session commands
- the script should `exec` the final provider command
- the script should treat `TOASTTY_AGENT_ARTIFACTS_DIR` as ephemeral
- detached background helpers that depend on that directory are unsupported

Example:

```sh
#!/bin/sh
set -eu

helper="$TOASTTY_AGENT_ARTIFACTS_DIR/provider-hook.sh"
cat > "$helper" <<'EOF'
#!/bin/sh
"$TOASTTY_CLI_PATH" session status \
  --session "$TOASTTY_SESSION_ID" \
  --kind working \
  --summary "Running" >/dev/null 2>&1 || true
EOF
chmod +x "$helper"

exec "$@"
```

This contract is intentionally simple. Toastty does not need to understand the
provider's hook mechanism. The integration script owns that translation layer.

---

## Path Resolution And Validation

`integrationScript` should be validated when `agents.toml` loads or reloads,
not only when a user clicks the profile.

Validation rules:

- reject empty strings
- reject duplicate `integrationScript`
- reject `integrationScript` on `codex`
- reject `integrationScript` on `claude`
- expand `~`
- resolve relative paths against the directory containing `agents.toml`
- require the resolved target to exist
- require the resolved target to be executable

This matches the current strict config model where malformed profile data causes
reload failure rather than deferring surprising errors to launch time.

---

## Non-Goals

Do not add these in the first pass:

- `preLaunchScript`, `approvalScript`, `stopScript`, or similar per-event fields
- a public generic `session ingest-agent-event` API
- process-tree or child-PID tracking for custom integration scripts
- automatic translation of third-party provider payloads into Toastty status
- support for layering `integrationScript` on top of built-in `codex` or
  `claude` instrumentation

If future work needs richer event streaming, it should be designed as a
separate public contract, likely using a dedicated side channel. It should not
be smuggled into this first `agents.toml` extension.

---

## Implementation Order

### 1. Extend the profile model

Update the profile model in `Sources/Core/Agents/AgentCatalog.swift`:

- add `integrationScript: String?` to `AgentProfile`
- update `Codable` support
- update equality and round-trip tests

This keeps the new field available everywhere the catalog is already consumed.

### 2. Extend parser and loader validation

Update `Sources/Core/Agents/AgentProfilesFile.swift`:

- parse `integrationScript`
- reject unknown duplicates
- preserve line-aware parse errors
- validate built-in rejection
- resolve and validate the configured script path
- update the generated template comments

The parser currently rejects unknown keys, so this schema change must land as
part of the same implementation. It cannot be a follow-up.

### 3. Add the new launch environment contract

Update `Sources/Core/Sessions/ToasttyLaunchContextEnvironment.swift`:

- add `TOASTTY_AGENT_ARTIFACTS_DIR`

Update related docs so the injected environment is fully enumerated and the
`TOASTTY_` prefix remains a clearly reserved namespace.

### 4. Add custom integration launch preparation

Extend `Sources/App/Agents/AgentLaunchInstrumentation.swift`:

- keep the existing `claude` path unchanged
- keep the existing `codex` path unchanged
- add a custom integration path for profiles with `integrationScript`
- create and return managed artifacts for that launch
- rewrite `argv` to `[integrationScript] + originalArgv`
- inject `TOASTTY_AGENT_ARTIFACTS_DIR`

This should reuse the existing `PreparedAgentLaunchArtifacts` structure rather
than inventing a second cleanup lifecycle.

### 5. Thread the profile through launch prep

Update `Sources/App/Agents/AgentLaunchService.swift`:

- pass the full `AgentProfile` into launch preparation, not only `agent` plus
  `argv`
- keep built-in instrumentation precedence unchanged
- keep session start timing unchanged so `TOASTTY_SESSION_ID` is valid before
  the script runs

No new public agent-launch mode is needed. This remains an internal extension
of the current launch pipeline.

### 6. Update docs

Update:

- `README.md`
- `docs/running-agents.md`
- `docs/socket-protocol.md`
- `Sources/Core/Agents/AgentProfilesFile.swift` template comments

Document:

- the new `integrationScript` field
- rejection on built-ins
- path resolution rules
- the `TOASTTY_AGENT_ARTIFACTS_DIR` contract
- the requirement to `exec "$@"`
- the fact that `session ingest-agent-event` remains private to built-ins

### 7. Add tests

Update or add tests in:

- `Tests/Core/AgentProfilesFileTests.swift`
- `Tests/Core/AgentProfileCodableTests.swift`
- `Tests/App/AgentLaunchInstrumentationTests.swift`
- `Tests/App/AgentLaunchServiceTests.swift`

Coverage to add:

- custom profile with valid `integrationScript`
- relative path resolution against the config directory
- missing script rejection
- non-executable script rejection
- rejection on `codex`
- rejection on `claude`
- shell quoting for script paths and `argv` containing spaces or quotes
- `TOASTTY_AGENT_ARTIFACTS_DIR` injection
- launch artifact cleanup behavior for custom integrations

---

## Example User Configuration

```toml
[amp]
displayName = "Amp"
argv = ["amp"]
integrationScript = "~/.toastty/integrations/amp.sh"
shortcutKey = "a"

[pi]
displayName = "Pi"
argv = ["pi"]
integrationScript = "~/.toastty/integrations/pi.sh"
shortcutKey = "p"
```

This keeps the provider command visible in `argv` while making the integration
entry point explicit.

---

## Why Not Just Keep Using argv Wrappers

Users can already put a wrapper script directly in `argv`, but that leaves too
much implicit:

- no dedicated validation for the integration entry point
- no documented scratch directory contract
- no clear guidance for agents generating `agents.toml`
- no way to distinguish "provider command" from "provider adapter"

Adding one explicit field solves those problems without requiring Toastty to
learn every provider's hook system.

---

## Simplification Check

This plan deliberately stops at one extension point:

- one new profile field
- one new env var
- one new documented script contract

That is the smallest design that gives users a real place to reference their
integration scripts while keeping Toastty's built-in Codex and Claude paths
separate and stable.
