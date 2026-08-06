# opencode session-scoped skills probe — 2026-08-05

The repeatable probe at `scripts/agents/probe-opencode-session-scoped-skills.py`
ran successfully against `opencode` CLI `1.18.11` (29/29 gated checks). Every
scenario used a temporary `HOME`, isolated `XDG_CONFIG_HOME`/`XDG_DATA_HOME`
directories, and a throwaway git-initialized project directory, and skill
discovery was read from `opencode debug config` / `opencode debug skill` /
`opencode debug agent` / `opencode debug paths` — no authentication or model
request was needed for any gated check.

Question probed: how does `opencode` load session-scoped skills through
config injection, so Toastty can deliver its shipped skills (and, later,
user-created skills) to managed `opencode`/`mimocode` launches the same way
it already injects the status plugin — via `OPENCODE_CONFIG_CONTENT`, with no
persistent writes to `~/.config/opencode` or the project's `opencode.json`.

`opencode debug config`, `opencode debug skill`, `opencode debug agent`, and
`opencode debug paths` are all offline, no-auth, no-model-call surfaces —
opencode's equivalent of Codex's `codex debug prompt-input`. They were the
primary evidence source throughout. `opencode` also ships a built-in
`customize-opencode` skill whose body is essentially opencode's own internal
config/skill documentation (fetched via `opencode debug skill` with no
`skills.paths` override); several findings below were cross-checked against
that built-in text, and one place where the probe's *observed* behavior
diverges from that text is flagged explicitly.

Run the probe again with:

```bash
scripts/agents/probe-opencode-session-scoped-skills.py --opencode /path/to/real/opencode
```

`--opencode`/`OPENCODE_BIN` is required in practice: on a dev machine with
Toastty running, plain `opencode` on `PATH` commonly resolves to a
runtime-isolated dev-run shim (e.g.
`.../artifacts/dev-runs/worktree-.../runtime-home/bin/opencode`), not the
real CLI. The script refuses to run against a binary path containing
`dev-run`, `runtime-home`, or `toastty` and asks for an explicit path instead
of silently probing the wrong binary.

## Q1 — `OPENCODE_CONFIG_CONTENT` merge / precedence

Confirmed via distinct `instructions` and `skills.paths` markers at each
layer (`opencode debug config`), with a **four-layer merge order**:

```
~/.config/opencode/opencode.json   (global)
        |
OPENCODE_CONFIG=<path>             (explicit extra file, additive)
        |
./opencode.json                    (project; walks up from cwd to worktree root)
        |
OPENCODE_CONFIG_CONTENT=<json>     (env; applied last — opencode's own docs
                                     call this "a final local-scope merge")
```

- **Array fields concatenate.** `instructions` at global+project+env produced
  `["global-marker", "project-marker", "env-marker"]` — every layer's entries
  survive, in layer order.
- **Object fields replace wholesale, not merge.** `skills` (an object with a
  `paths` array) does **not** concatenate across layers. Setting
  `skills.paths` at the project layer completely replaced the global layer's
  `skills.paths` (only the project marker remained); setting it again via
  `OPENCODE_CONFIG_CONTENT` replaced the project layer's value in turn (only
  the env marker remained). This is the single most consequential distinction
  for injection design — see "Design consequences" below.
- `OPENCODE_CONFIG=<path>` is additive (not an isolation override): it loads
  an extra explicit config file and inserts it **between the global and
  project layers**, not after project as its escape-hatch description ("load
  an additional explicit config") might suggest in isolation. Toastty does
  not need this variable; `OPENCODE_CONFIG_CONTENT` alone is sufficient and
  is already documented as the last-applied layer.
- `OPENCODE_DISABLE_PROJECT_CONFIG=1` skips only the project's local
  `opencode.json`; global config and `OPENCODE_CONFIG_CONTENT` still apply.

## Q2 — `skills.paths` entry shapes

Both documented shapes work, verified by pointing `skills.paths` at each and
reading the resulting `location` in `opencode debug skill`:

- **(a) Directory of skill folders**: `<path>/<name>/SKILL.md` — resolved.
- **(b) Single skill folder**: `<path>/SKILL.md` directly (the last path
  segment becomes the implicit context; the skill's own frontmatter `name`
  is what is registered) — resolved.
- **Scanned recursively**: a `SKILL.md` two directories deep
  (`<path>/group/<name>/SKILL.md`) was also discovered. opencode's own
  built-in doc confirms this explicitly: "`skills.paths` (scanned recursively
  for `**/SKILL.md`)".
- **Relative paths resolve against the launch cwd**, not the declaring
  config's directory: a `skills.paths` entry of `../skills-root-a` relative
  to the project workspace resolved correctly.
- **`file://` URIs are NOT supported for `skills.paths`** (unlike `plugin`
  entries, which do support `file://`). A `skills.paths` entry written as
  `file:///abs/path` silently discovered nothing — no error, the skill was
  simply absent. This is a real footgun: a `plugin`-style `file://` path
  reused for `skills.paths` fails silently rather than erroring.

## Q3 — Do skills.paths skills reach the model?

Yes, confirmed two ways:

1. **No-model-call evidence (primary, used by the automated probe)**: the
   injected skill's `name`/`description`/`location`/`content` appear
   verbatim in `opencode debug skill`, which is the same registry opencode
   assembles before handing skill availability to the model.
2. **Live model-call confirmation (manual, not re-run by the script)**: with
   real `HOME` (for existing provider auth) and isolated `XDG_CONFIG_HOME`,
   running

   ```
   OPENCODE_CONFIG_CONTENT='{"skills":{"paths":["<marker-skill-dir>"]}}' \
     opencode run --model opencode/deepseek-v4-flash-free \
     "List the exact names of every skill available to you, one per line, nothing else."
   ```

   returned `toastty-probe-marker-skill` verbatim in the model's own answer,
   alongside the user's other real skills (`customize-opencode`, several
   `printing-press-*` skills, etc. — all pre-existing, none created or
   modified by this probe). No `ANTHROPIC_API_KEY`/`sv exec` was needed: the
   user's `~/.local/share/opencode/auth.json` already had a free `opencode/`
   provider model configured.

## Q4 — Collision resolution is a non-deterministic race

This is the headline finding and changes the design story materially from
Codex's session-scoping probe (where precedence was a clean, deterministic
overlay). **When the same skill `name` exists in more than one discovery
location, opencode resolves the collision via a non-deterministic async
race — not a fixed precedence order.**

The automated probe's gated check only asserts the deterministic invariant
(`colliding_skill_name_always_dedupes_to_exactly_one_entry`: exactly one
survives, never both, never zero — confirmed across 8 identical trials). It
does **not** assert which one wins, because which one wins was observed to
vary run to run of an otherwise byte-identical fixture. Supplementary manual
measurements (15 trials each, outside the gated script, same isolation
technique) quantify this:

| Collision fixture (same `name` in each) | Trials | Distribution |
| --- | --- | --- |
| project `.opencode/skills` vs `skills.paths` | 15 | `skills.paths` 12 / project `.opencode/skills` 3 |
| project `.opencode/skills` vs home `~/.claude/skills` (neither via `skills.paths`) | 15 | project `.opencode/skills` 11 / home `.claude` 4 |
| All 5 natural locations + `skills.paths` simultaneously | 15 | `skills.paths` 8 / project `.opencode/skills` 4 / project `.claude/skills` 2 / project `.agents/skills` 1 |

`skills.paths` wins more often than it loses in these samples, but it is
**not reliable** — it lost outright in roughly a fifth to a third of trials
in every fixture tested, including the simplest 2-way case. This is
consistent with concurrent, async filesystem scans across the several
discovery roots (project `.opencode/skills`, project `.claude/skills`,
project `.agents/skills`, home `.claude/skills`, home `.agents/skills`,
`skills.paths`) that are merged by last-writer-wins as each scan resolves,
rather than a synchronous, ordered overlay.

Repeated single-shot runs of the automated probe script itself can and did
produce different `collisionWinnerDistribution` results between invocations
(one run: 8/8 `skills.paths`; a separate 15-trial sample: 12/15). Treat any
single run's distribution as a sample, not a guarantee.

## Q5 — Discovery baseline (collision surface)

With isolated config and no `skills.paths` override, **all five** of the
following locations auto-load, confirmed by planting a distinctly-named
skill in each and reading `opencode debug skill`:

- Project `.opencode/skills/<name>/SKILL.md` (opencode's own primary root)
- Project `.claude/skills/<name>/SKILL.md`
- Project `.agents/skills/<name>/SKILL.md`
- Home `~/.claude/skills/<name>/SKILL.md`
- Home `~/.agents/skills/<name>/SKILL.md`

Two escape-hatch env vars gate the last four (not the first):

- `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` removes both `.claude/skills`
  locations (project and home) only; `.agents/skills` and project
  `.opencode/skills` remain.
- `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` removes all four "external" locations
  (`.claude` and `.agents`, project and home); only project
  `.opencode/skills` remains.

**Collision surface for the management sheet**: any user, on any project,
who happens to create `.opencode/skills/`, `.claude/skills/`, or
`.agents/skills/` (project-local or in their home directory) with a skill
`name` matching a Toastty-shipped skill will collide with Toastty's injected
copy, and — per Q4 — **which copy the model actually sees is not
predictable and can differ between launches of the same session type.**
Toastty-shipped skill names should be treated as reserved/namespaced to make
this collision surface unreachable in practice, rather than relying on any
override guarantee.

## Q6 — Plugin + skills.paths coexistence

Both apply from a single `OPENCODE_CONFIG_CONTENT` JSON blob with no
conflict: `{"plugin": ["file://.../plugin.js"], "skills": {"paths": [...]}}`.
Verified two ways in the same run: the injected skill appeared in
`opencode debug skill`, and the plugin's exported function actually executed
(confirmed via a side-effecting marker file the plugin writes on load, not
just "no error on import"). This directly matches Toastty's actual
`OPENCODE_CONFIG_CONTENT` shape today (`{"plugin": [...]}` only, from
`AgentLaunchInstrumentation.swift` lines ~349–356) — adding a `skills` key
to that same object is additive and requires no new injection point.

## Q7 — Failure modes

- **Nonexistent `skills.paths` entry**: exits `0`, skill list unaffected by
  the missing entry — warn-and-continue (actually: continue with no
  observable warning in stdout/stderr from `debug skill`), not a hard
  startup error.
- **Malformed skill (missing `description` frontmatter)**: does not crash
  startup. `opencode debug skill` still lists the skill by `name` and
  `location`, with the `description` field simply absent from the JSON
  entry. This is a soft **discrepancy** worth flagging: opencode's own
  built-in `customize-opencode` skill text states "skills without one
  [a description] are filtered out and never surfaced to the model." The
  probe confirms the malformed skill is not filtered out of the
  `debug skill` *registry* view; whether it is filtered before reaching the
  model's actual system prompt / skill tool could not be confirmed without a
  model call and is left **unresolved** — do not treat `debug skill`
  presence as proof the model would see it, nor treat this as disproving
  opencode's documented filtering claim.

## Q8 — Default `skill` permission

No `skill`-specific permission rule exists in the default `build` agent's
resolved permission set (`opencode debug agent build`). Skill usage falls
through to the top-level `*` → `allow` wildcard rule that is also the
default for every other undeclared permission kind. The `skill` permission
key does not block skill usage in `opencode run` by default.

## Q9 — Version, isolation env vars, logs

- `opencode --version`: `1.18.11`
- Env vars honored for isolation, confirmed via `opencode debug paths`:
  `HOME` (fallback default paths), `XDG_CONFIG_HOME` (overrides the `config`
  path), `XDG_DATA_HOME` (overrides `data`, `log`, and `repos` paths — note
  `cache`/`bin` stayed under `$HOME/.cache`, not `XDG_CACHE_HOME`, in this
  version).
- `OPENCODE_CONFIG` and `OPENCODE_CONFIG_CONTENT` are **not** isolation
  variables — they are additive config-merge inputs (see Q1); isolation
  comes entirely from `HOME`/`XDG_CONFIG_HOME`/`XDG_DATA_HOME`.
- Logs live under `<XDG_DATA_HOME>/opencode/log/opencode.log`
  (`$HOME/.local/share/opencode/log/opencode.log` when `XDG_DATA_HOME` is
  unset). `--print-logs` streams logs to stderr for the current invocation
  instead of/in addition to the file.
- **Shared per-data-home SQLite cache**: `<XDG_DATA_HOME>/opencode/opencode.db`
  (with `-shm`/`-wal` sidecars) persists project/session state across
  invocations that share the same `XDG_DATA_HOME`. Reusing one `XDG_DATA_HOME`
  across probe scenarios produced stale/contaminated results (a scenario
  correctly isolated by `HOME`/`XDG_CONFIG_HOME` still bled state through a
  shared data home). The probe script gives every scenario its own fresh
  `XDG_DATA_HOME`; any future opencode probing or real dev-run isolation
  should do the same.

## Architectural implication

Session-scoped opencode skill delivery is viable through the exact
injection point Toastty already uses: extend the existing
`OPENCODE_CONFIG_CONTENT` JSON (currently `{"plugin": [...]}`, built in
`AgentLaunchInstrumentation.swift`'s `prepareOpenCodeFamilyLaunch`) with a
`skills: {"paths": [<toastty-staged-skills-dir>]}` key. No `CODEX_HOME`-style
profile file or `--profile` flag equivalent is needed — opencode already
treats `OPENCODE_CONFIG_CONTENT` as a final, env-scoped merge layer applied
fresh to each process, and Toastty already sets this variable per managed
launch (with the existing guard that refuses to overwrite a
caller-already-set value). The `skills.paths` shape is flexible enough to
point directly at the same staged directory pattern Toastty already uses for
Claude's `--plugin-dir` (a directory containing `<name>/SKILL.md`
subfolders).

The one design constraint this probe surfaces that the Codex probe did not:
**there is no reliable override or shadow guarantee.** Codex's profile
overlay is a clean, deterministic layer. opencode's skill merge is a race.
Toastty must not depend on its injected `skills.paths` skills reliably
beating (or reliably losing to) a same-named skill discovered elsewhere; the
only safe mitigation is namespacing/uniqueness of Toastty's shipped skill
names so the collision case never actually arises in practice, plus a
management-sheet warning (per Q5) that user-created `.opencode/skills`,
`.claude/skills`, or `.agents/skills` directories with a name matching a
Toastty skill produce unpredictable, run-to-run-varying behavior rather than
a defined override.

## Design consequences for Toastty

1. **Injection point**: add a `skills` key alongside the existing `plugin`
   key in the same `OPENCODE_CONFIG_CONTENT` JSON blob built in
   `prepareOpenCodeFamilyLaunch` (`Sources/App/Agents/AgentLaunchInstrumentation.swift`
   ~line 349). No new environment variable, no `--profile`-style argv
   injection, no persistent writes — confirmed both apply together from one
   blob (Q6).
2. **Staged skill directory shape**: point `skills.paths` at a directory
   containing `<name>/SKILL.md` subfolders (shape (a), Q2) — the same shape
   already used for Claude's `--plugin-dir` staging, so the staging code can
   likely be shared or trivially adapted rather than rebuilt per-agent.
3. **Use an absolute filesystem path, never a `file://` URI**, for
   `skills.paths` entries — `file://` silently discovers nothing (Q2), a
   distinct and non-obvious pitfall from the `plugin` array's `file://`
   requirement in the same config blob.
4. **Do not build any "our skill overrides/loses to a project skill"
   guarantee into the design or its documentation.** Q4 shows this is
   fundamentally a race, not a policy. The only durable mitigation is
   choosing Toastty skill names that are reserved/namespaced enough that a
   user or project skill of the same name is very unlikely to exist —
   analogous to how the existing Claude Code delivery already namespaces
   under `toastty:` per `docs/running-agents.md`. The opencode-facing
   management/help copy should warn users that `.opencode/skills/`,
   `.claude/skills/`, or `.agents/skills/` directories (project or home)
   containing a name that collides with a Toastty skill name produce
   unpredictable per-launch behavior, not a silent-and-safe override in
   either direction.
5. **`skills.paths` replaces, not merges, across config layers** (Q1). If a
   user's own project or global `opencode.json` sets `skills.paths`,
   Toastty's `OPENCODE_CONFIG_CONTENT`-supplied `skills.paths` value will
   silently replace it (the user's custom skill roots stop loading) rather
   than being appended to it, because opencode deep-merges `instructions`
   but replaces `skills` wholesale. If Toastty ever needs the user's own
   `skills.paths` entries to keep working, it must be read (config
   resolution equivalent of `opencode debug config`) and re-emitted
   alongside Toastty's own entries in the injected `skills.paths` array,
   the same way Claude's `--plugin-dir` injection is careful to be additive
   to any existing `--plugin-dir` arguments rather than replacing them.
6. **Isolate `XDG_DATA_HOME` per throwaway probe/test scenario.** Any future
   opencode-focused automation (probes, isolated dev/test launches) must not
   share one `XDG_DATA_HOME` across scenarios expected to be independent —
   opencode's shared per-data-home SQLite cache (`opencode.db`) leaked state
   across scenarios during this probe's development and produced
   misleading, non-reproducible results until each scenario got its own
   fresh data home (Q9).
7. **User-created skills** (the `~/.toastty/skills/<name>/SKILL.md` flow
   documented for Codex/Claude in `docs/running-agents.md`) can extend to
   opencode/mimocode the same way: a second `skills.paths` entry pointing at
   the user-skills staging snapshot, appended into the same array as
   Toastty's shipped-skills entry — not a second config layer, since Q1
   shows a second layer would simply replace the first rather than add to
   it.
