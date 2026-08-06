# Agent plugin capability probe — 2026-08-03

The repeatable probe at
`scripts/agents/probe-agent-plugin-capabilities.py` ran successfully against:

- Codex CLI `0.146.0`
- Claude Code `2.1.220`

Every probe used a temporary `HOME`, `CODEX_HOME`, and `CLAUDE_CONFIG_DIR`.
No developer plugin, skill, hook, configuration, authentication, or marketplace
state was read or changed.

## Results

- `codex plugin add` refreshed an installed local plugin after its stable source
  symlink moved from an immutable `0.1.0` directory to `0.2.0`.
- `skills/config/write` preserved unrelated TOML comments and settings.
- A configured user hook kept the same definition hash and trust status across
  skill disable and plugin install operations.
- Missing-skill disable tombstones were accepted.
- The installed qualified skill was disabled in an ordinary `skills/list` and
  enabled when the managed process supplied the deterministic `skills.config`
  override.
- A separate disabled standalone skill remained disabled under that managed
  override, confirming that the named Toastty entry did not replace unrelated
  user skill settings.
- Both Claude manifests passed `claude plugin validate --strict`.
- Claude accepted two repeated session-only `--plugin-dir` arguments.

The selected Codex staging transaction is therefore immutable versioned source
directories behind one stable Toastty-owned marketplace symlink. Toastty swaps
that symlink atomically, asks the public Codex plugin CLI to reinstall, and can
restore the previous symlink if installation or verification fails.

The isolated homes intentionally contained no authentication. The probe used
Codex's authoritative `skills/list` enabled state to check ordinary-versus-
managed eligibility rather than spending a model request. A later runtime
validation should exercise explicit skill invocation only if it can do so
without copying credentials or mutating a developer's real Codex state.

Run the probe again with:

```bash
scripts/agents/probe-agent-plugin-capabilities.py
```
