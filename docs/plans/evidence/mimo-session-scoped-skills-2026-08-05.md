# mimo session-scoped skills probe — 2026-08-05

The repeatable probe at `scripts/agents/probe-mimo-session-scoped-skills.py`
ran successfully against `mimo` CLI `0.1.9` (30/30 checks, including one
live-model call). Every scenario used a temporary `HOME` (plus one temporary
`XDG_CONFIG_HOME`), and model-visible skill discovery was read from
`mimo debug skill` / `mimo debug config` — the same no-model-call posture as
the Codex probe. One optional check ran a real model turn through
`sv exec --key ANTHROPIC_API_KEY -- ... --live-model` to confirm the injected
skill reaches the model itself, not just the debug tooling.

Question probed: does this opencode-family fork's base version (0.1.9) accept
upstream opencode's top-level `skills` config object
(`{"paths": [string], "urls": [string]}`), and with what semantics — the gap
between what Toastty already injects via `MIMOCODE_CONFIG_CONTENT` (only
`{"plugin": [...]}`, see `Sources/App/Agents/AgentLaunchInstrumentation.swift`
~lines 311-478) and what upstream opencode documents.

## Headline result

**Yes. mimo 0.1.9 fully supports `skills.paths` (and schema-accepts
`skills.urls`) via `MIMOCODE_CONFIG_CONTENT`, and the injected skills reach
the model.** This is a positive result, unlike the Codex probe's negative
finding for additive skill-path config keys.

## Tooling note: pipe-capture truncation bug (not a mimo skills bug)

`mimo debug skill` output is a JSON dump of the full effective skill catalog,
frequently 300-350 KB (~40 skills, several with large markdown bodies). When
the probe captured this via Python's `subprocess.PIPE`, the payload was
silently truncated at a non-deterministic point (observed truncation lengths:
64703, 61670, 46837, 314723 bytes across repeated runs) even though the
process exited 0. Redirecting stdout/stderr to regular files instead of pipes
produced complete, valid JSON on every repeat (39/39 entries, byte-identical
catalog size across 3 consecutive runs). This matches the well-known
Node/Bun gotcha where a large `process.stdout.write` to a pipe is
asynchronous and `process.exit()` can fire before the write flushes; writes
to a file or TTY don't race exit the same way. The probe script redirects to
files for this reason — any other tooling that shells out to `mimo` and
captures stdout via a pipe (rather than a file) should assume large JSON
output can be silently truncated.

## Q1 — Does mimo accept a `skills` config object at all?

Yes, decisively. mimo's config schema is strict (zod-like): an **unrecognized
top-level key is a hard error** (exit 1, `Unrecognized key: "..."`), and a
**recognized key with the wrong type is a hard error** with a field-scoped
message (`Invalid input: expected array, received string skills.paths`).
`{"skills": {...}}` never triggers either error — it round-trips through
`mimo debug config` unmodified. This is a stronger (and more decisive) oracle
than Codex's silent-ignore-unknown-keys behavior: on mimo, "no error" *is*
"recognized," full stop.

Verified via both `MIMOCODE_CONFIG_CONTENT` and a config file
(`$HOME/.config/mimocode/mimocode.json`, see Q8 for the full file-candidate
list).

## Q2 — Which env vars does the fork honor?

- `MIMOCODE_CONFIG_CONTENT` — honored. `skills.paths` set through it appears
  verbatim in `mimo debug config` and loads into `mimo debug skill`.
- `OPENCODE_CONFIG_CONTENT` — **not honored at all**. The same JSON payload
  produces a `debug config` dump with no `skills` key and no error; it is
  invisible to mimo, not merged, not rejected. The fork renamed the env var
  and does not fall back to the upstream prefix.
- `MIMOCODE_CONFIG` (a file-path env var, undocumented in `--help` but
  present in the fork) — honored. Pointing it at an external JSON file with
  `skills.paths` loads the skill.
- `XDG_CONFIG_HOME` — honored for the config search root only
  (`mimo debug paths` reports `config` under `$XDG_CONFIG_HOME/mimocode`).
  `data`, `cache`, and `state` are derived from `$HOME` directly
  (`$HOME/.local/share/mimocode`, `$HOME/.cache/mimocode`,
  `$HOME/.local/state/mimocode`) regardless of `XDG_DATA_HOME` /
  `XDG_CACHE_HOME` / `XDG_STATE_HOME` env values — those were set in every
  probe scenario for isolation but the tool did not require them.

## Q3 — Entry shape and does it reach the model?

Both shapes work identically:

- **Parent-dir shape**: `skills.paths: ["<dir>"]` where `<dir>` contains
  `<name>/SKILL.md` subfolders (upstream opencode's documented shape).
- **Single-skill-folder shape**: `skills.paths: ["<dir>/<name>"]` pointing
  directly at one skill's folder also loads that one skill.

Reach confirmed at two layers:
1. `mimo debug skill` lists the injected skill by name/description/location,
   indistinguishable from a builtin skill entry.
2. **Live model call**: `mimo run "List the names of every skill available to
   you, one per line, nothing else." --model anthropic/claude-haiku-4-5` with
   `MIMOCODE_CONFIG_CONTENT` carrying `skills.paths` returned `probe-skill-alpha`
   in the model's own output, interleaved alphabetically with the builtin/compose
   catalog. The skill is genuinely tool-visible to the model, not just listed
   by debug tooling.

## Q4 — Merge semantics

`MIMOCODE_CONFIG_CONTENT`'s `skills.paths` **replaces** the global config
file's `skills.paths` rather than unioning with it: with the global config
file pointing at fixture A and `MIMOCODE_CONFIG_CONTENT` pointing at fixture
B, only B's skill was discovered — A's was completely absent, not merged in
alongside B's. Toastty must treat `skills.paths` as last-writer-wins for the
whole array, not additive, when composing config content on top of any
existing user config.

## Q5 — Coexistence of `plugin` and `skills` in one CONFIG_CONTENT

Clean coexistence, no interaction observed. A single
`MIMOCODE_CONFIG_CONTENT` blob with both `{"plugin": ["file://..."]}` (the
existing Toastty status-plugin mechanism) and `{"skills": {"paths": [...]}}`
loaded the plugin (`INFO service=plugin ... loading plugin` in the debug log,
no errors) and the skill simultaneously. Toastty can extend the existing
`configContent` dictionary in `AgentLaunchInstrumentation.swift` with a
`skills` key without touching the `plugin` key's behavior.

## Q6 — Failure modes

- **Nonexistent `skills.paths` entry**: warn-and-continue. Exit 0, a
  `WARN ... service=skill path=<path> skill path not found` line at
  `--log-level DEBUG`, no crash, other skills (builtin/compose/other valid
  paths) still load normally. No warning is visible without `--print-logs
  --log-level DEBUG`; ordinary stderr is silent about it.
- **Malformed skill (no YAML frontmatter, or frontmatter missing
  `description`)**: silently dropped, not even a warning at DEBUG level. The
  rest of the catalog (including other valid skills in the same
  `skills.paths` directory) loads unaffected.
- **Unreachable `skills.urls` entry**: does not block `skills.paths` loading
  in the same config — a bad-host URL alongside a valid path still surfaced
  the path-based skill, exit 0.

Two distinct silent-failure classes exist: a bad *path* logs a WARN (visible
only with verbose logging); a bad *skill file* logs nothing at all. Neither
is fatal to the rest of the catalog.

## Q7 — Auto-discovery dirs (collision-warning story)

At **project level** (cwd-relative), mimo auto-discovers skills under:
`.opencode/skills`, `.claude/skills`, `.agents/skills`, `.mimocode/skills`.
**Not** `.mimo/skills` (the CLI's own binary/config basename) — confirmed
absent as a negative control.

At **`$HOME` level**, mimo auto-discovers the same family plus one more:
`.claude/skills`, `.agents/skills`, `.codex/skills`, `.opencode/skills`,
`.mimocode/skills`. XDG-style paths (e.g.
`$XDG_CONFIG_HOME/opencode/skills`) were not probed for auto-discovery and
should not be assumed.

This is a real collision surface: a workspace or `$HOME` with
`.agents/skills` or `.claude/skills` populated by another runtime (per
`docs/running-agents.md`, Toastty explicitly does not touch
`~/.codex/skills`, `~/.claude/skills`, or `~/.agents/skills`) will have those
skills silently surfaced to mimo too, unnamespaced, alongside anything
Toastty injects via `skills.paths`. Toastty's own user-skill store
(`~/.toastty/skills`) is not on this auto-discovery list, so it does not
leak in by accident — but skills placed by *other* agent runtimes in their
own conventional dirs will.

## Q8 — Version and config/log locations

- `mimo --version` → `0.1.9`.
- `mimo debug paths` reports, relative to `$HOME` (or `$XDG_CONFIG_HOME` for
  `config` specifically):
  - `data` — `.local/share/mimocode`
  - `bin` — `.cache/mimocode/bin`
  - `log` — `.local/share/mimocode/log`
  - `cache` — `.cache/mimocode`
  - `config` — `.config/mimocode` (or `$XDG_CONFIG_HOME/mimocode`)
  - `state` — `.local/state/mimocode`
- Config file candidates loaded from the config dir, in order (all logged at
  `INFO service=config ... loading` under `--print-logs`):
  `config.json`, `mimocode.json`, `mimocode.jsonc`.
- `mimo debug config` prints the fully resolved effective config as JSON
  (agent, mode, plugin, command, skills, provider, ...) — the ground-truth
  oracle this probe used for schema-acceptance checks.
- `mimo debug skill` prints the fully resolved effective skill catalog as
  JSON (name, description, location, full content) — the ground-truth oracle
  this probe used for discovery/reachability checks.

## Design consequences for Toastty

1. **Toastty can ship session-scoped skill delivery to mimo today**, using
   the exact mechanism already wired for the `plugin` key: extend the
   `configContent` dictionary built in
   `prepareOpenCodeFamilyLaunch` (`Sources/App/Agents/AgentLaunchInstrumentation.swift`)
   with a `skills.paths` entry pointing at the staged Toastty skill bundle,
   emitted only for the `mimocode` runtime (not `opencode` — `OPENCODE_CONFIG_CONTENT`
   is a different, real upstream project this probe did not touch; do not
   assume parity without a separate probe against the real opencode binary).
2. **Do not union with the user's own config.** Because `skills.paths`
   replaces rather than merges, Toastty's injected config content must
   include the user's own `skills.paths` entries (read from their resolved
   config, if any) alongside Toastty's staged path, or a user who has
   configured their own mimo skills would see them disappear for the
   duration of the managed session. (Codex sidesteps this entirely via a
   profile-file overlay that never touches the user's main config; mimo has
   no equivalent overlay file — `MIMOCODE_CONFIG_CONTENT` is the whole
   config surface for a managed launch, so composition is Toastty's
   responsibility.)
3. **Prefer the parent-dir shape** (`skills.paths: [<toastty-skills-root>]`)
   over enumerating individual skill folders — both work, but the parent-dir
   form matches upstream opencode's documented shape and lets Toastty add or
   remove staged skills without touching the injected config shape.
4. **A nonexistent staged-skills path degrades silently** (WARN-level log
   only, visible with `--print-logs --log-level DEBUG`), so Toastty's own
   staging step must independently verify the directory exists and is
   non-empty before injecting `skills.paths` — mimo will not surface a
   user-visible error if staging silently failed.
5. **The collision surface is real but bounded.** mimo auto-discovers
   `.claude/skills` and `.agents/skills` at both project and `$HOME` level.
   If Toastty ever documents a "why do I see skills I didn't add" support
   note for mimo (mirroring the existing Codex/Claude non-inspection
   language in `docs/running-agents.md`), it should name mimo's own
   auto-discovery list, not assume it matches Codex's or Claude's.
6. **Toastty's status-plugin mechanism is unaffected.** `plugin` and
   `skills` coexist cleanly in one `MIMOCODE_CONFIG_CONTENT` blob, so the
   existing `toastty-mimocode-status-plugin.js` injection needs no changes
   to add skills delivery alongside it.
7. **Tooling gotcha for any future mimo probing/automation**: never capture
   `mimo debug skill` (or any large-output mimo subcommand) via a plain pipe
   without accounting for the async-write/exit race — redirect to a file, as
   this probe's harness now does, or the JSON may parse-fail non-deterministically.

Run the probe again with:

```bash
scripts/agents/probe-mimo-session-scoped-skills.py --mimo /Users/vishal/.mimocode/bin/mimo
```

Add `--live-model` (with credentials, e.g.
`sv exec --key ANTHROPIC_API_KEY -- scripts/agents/probe-mimo-session-scoped-skills.py --live-model`)
to re-confirm the injected skill reaches a real model turn, not just debug
tooling.
