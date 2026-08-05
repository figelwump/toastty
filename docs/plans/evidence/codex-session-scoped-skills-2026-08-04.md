# Codex session-scoped skills probe — 2026-08-04

The repeatable probe at `scripts/agents/probe-codex-session-scoped-skills.py`
ran successfully against Codex CLI `0.146.0` (24/24 checks). Every scenario
used a temporary `HOME` and `CODEX_HOME`, and skill discovery was read from
`codex debug prompt-input`, so no authentication, model request, or developer
state was involved.

Question probed: can a single managed Codex process load Toastty-staged
skills without persistent writes to the user's `config.toml` — the
`--plugin-dir` equivalent the original capability probe never asked for.

## Negative results (mechanisms that do not exist)

- No additive skill-path config keys: `skills.paths`, `skills.roots`,
  `skills.dirs`, and six other candidates are unrecognized (probed via the
  known-key type-error oracle; unknown keys are silently ignored).
- `skills.config` entries with `path=` do not load skills from outside the
  discovery roots, whether pointed at a `SKILL.md` or a skill directory. The
  key only toggles already-discovered skills.
- Plugin activation is config-file-driven only. `-c` overrides for
  `marketplaces` and `plugins` tables (map and dotted forms) are inert in
  both directions: they can neither activate a cached plugin nor disable an
  enabled one.
- `skills.config` cannot enable a skill belonging to a plugin whose
  `[plugins."…"]` entry is `enabled = false`; a disabled plugin's skills are
  entirely absent from discovery (not listed as disabled).
- In-`config.toml` `[profiles.*]` tables are legacy-removed; `-c profile=`
  errors with a pointer to `--profile <name>` and `<name>.config.toml`.

## Positive results (the session-scoped mechanism)

- A Toastty-owned `CODEX_HOME/toastty.config.toml` containing only
  `[plugins."toastty@toastty"] enabled = true`, combined with
  `--profile toastty`, loads the cached plugin's skills for exactly the
  flagged process. The same home without the flag exposes nothing.
- The profile overlays the main config rather than replacing it: the user's
  own CLI-installed plugin still loads, `$HOME/.agents/skills` discovery
  still works, and a root-level `skills.config` disable in the main config
  remains honored under the profile.
- The plugin cache (`CODEX_HOME/plugins/cache/<marketplace>/<plugin>/<version>/`)
  is inert by itself, and no `[marketplaces]` entry is required for loading —
  cache plus one `[plugins]` entry is the complete load condition.
- `codex plugin add` over a bumped local plugin replaces the cached version
  in place (single-version cache) and the refreshed content loads.
- `--profile` applies to runtime commands only (`codex`, `exec`, `review`,
  `resume`, `fork`, `mcp`, `sandbox`, `debug prompt-input`) and is rejected
  by plugin-management commands; repeating the flag is a hard CLI error.

## Architectural implication

Session-scoped Codex delivery is viable without touching the user's
`config.toml`: populate the plugin cache from a throwaway `CODEX_HOME`
install (the same binary writes and later reads the cache), write the
Toastty-owned profile config file, and inject `--profile toastty` into
managed runtime argv. Ordinary sessions see no Toastty skills, no disabled
names, and no tombstones. A caller-supplied `--profile` is a detectable
conflict (skills must be skipped with a diagnostic because the flag cannot
repeat). `resume` and `fork` accept the flag, so restore keeps
current-on-restore semantics through cache refresh.

Run the probe again with:

```bash
scripts/agents/probe-codex-session-scoped-skills.py
```

Pass `--codex <path>` (or `CODEX_BIN`) when the `codex` on `PATH` is a
Toastty-managed shim.
