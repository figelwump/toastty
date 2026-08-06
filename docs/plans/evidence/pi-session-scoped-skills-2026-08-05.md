# pi session-scoped skills probe — 2026-08-05

The repeatable probe at `scripts/agents/probe-pi-session-scoped-skills.sh`
ran against `pi` CLI `0.70.2` (`@mariozechner/pi-coding-agent`, binary at
`/Users/vishal/.nvm/versions/node/v22.13.1/bin/pi`): 8/8 no-model checks
pass standalone, and 24/24 checks pass with `--with-model` (real
`claude-haiku-4-5` calls via `sv exec --`, which injects `ANTHROPIC_API_KEY`).
Every scenario used a temporary `HOME`, a temporary `PI_CODING_AGENT_DIR`
(pi's per-user `~/.pi/agent` equivalent), and a temporary project `cwd`. No
probe touched `~/.pi`, `~/.claude`, `~/.codex`, `~/.agents`, or
`~/.config/opencode`, and no probe ran `pi install`/`pi remove`/`pi config`.

Question probed: exactly how `pi --skill <path>` and pi's default skill
discovery work, so Toastty can inject managed skills into a `pi` process at
launch without touching the user's real `~/.pi`.

## Environment

- `pi --version`: `0.70.2`
- Binary: `/Users/vishal/.nvm/versions/node/v22.13.1/bin/pi` →
  `@mariozechner/pi-coding-agent` npm package, `dist/cli.js` → `main.js`.
- Relevant env vars (from `pi --help` and package source):
  - `PI_CODING_AGENT_DIR` — overrides the agent config dir (default
    `~/.pi/agent`); this is where `skills/`, `settings.json`, `sessions/`,
    etc. live. This is pi's isolation knob, analogous to Codex's
    `CODEX_HOME`.
  - `HOME` — honored directly (`process.env.HOME || os.homedir()`) and used
    both for the default `PI_CODING_AGENT_DIR` and for `$HOME/.agents/skills`
    discovery.
  - `PI_PACKAGE_DIR` — overrides where pi resolves its own shipped assets
    (themes, docs); irrelevant to skill discovery.
  - `PI_OFFLINE` — disables startup network operations; not needed for these
    probes (no model calls except under `--with-model`, and no `--list-models`
    network dependency was observed for a local model catalog).
  - No `PI_HOME` exists. `HOME` + `PI_CODING_AGENT_DIR` together fully
    isolate a run.
- Ground truth source: the installed package ships readable, unminified ESM
  under `dist/`. Every claim below is cross-checked against
  `dist/core/skills.js`, `dist/core/resource-loader.js`,
  `dist/core/package-manager.js`, `dist/cli/args.js`, `dist/config.js`, and
  `dist/core/system-prompt.js`, then confirmed dynamically by running the
  real `pi` binary. Line/function references below point at that installed
  copy of `0.70.2`; a different pi version could change them.

**No dry-run debug command exists.** Unlike `codex debug prompt-input`, pi
has no non-interactive way to dump what skills would load. Skill-loading
diagnostics (bad `--skill` path, missing `description`, name collisions) are
only ever printed by the *interactive* TUI startup banner
(`modes/interactive/interactive-mode.js:1088-1090`); print/json/rpc mode
never surfaces them. This shaped the probe design below: no-model checks use
a black-box "does the failure output change" oracle, and everything that
requires seeing what the model was actually given uses a real (optional)
model call.

## Per-probe command / observation / verdict

### 1. `--skill <path>` argument shape

Command (representative; script builds all three fixtures and one repeatable-flag fixture):
```bash
sv exec -- pi --no-session --print --provider anthropic --model claude-haiku-4-5 \
  --skill <dir-with-SKILL.md-directly> \
  -p "List the names of every skill available to you, one per line, and nothing else."
```
Observation: all three shapes load, and the flag is repeatable.
- (a) directory containing `SKILL.md` directly → single skill loaded
  (`shape-a-dir` appeared).
- (b) parent directory containing multiple `<name>/SKILL.md` subfolders →
  every subfolder loaded as its own skill (`child-one` and `child-two` both
  appeared from one `--skill <parent>`).
- (c) a `SKILL.md` file path itself → loads (`shape-c-dir` appeared,
  passing `.../shape-c-dir/SKILL.md` directly).
- Two `--skill` flags (`repeat-a`, `repeat-b`) both loaded.
Source: `loadSkills()` in `dist/core/skills.js` — for each path in
`skillPaths`, if it `stats.isDirectory()` it calls
`loadSkillsFromDirInternal()`, whose discovery rule is "if the directory
contains `SKILL.md`, treat it as a skill root and stop; otherwise recurse
into subdirectories, loading each one that contains `SKILL.md`, plus any
loose root-level `.md` files." If the path `stats.isFile() && endsWith(".md")`
it's loaded directly via `loadSkillFromFile()`. `--skill` accumulates into an
array in `dist/cli/args.js:105-108` (`result.skills.push(...)`), so it is
repeatable by construction.
**Verdict: all three shapes load; the flag is repeatable.** Confirmed by
source and by `model_visible_shape_a_single_skill_dir`,
`model_visible_shape_b_parent_dir_multi_skill{,_2}`,
`model_visible_shape_c_skill_md_file_path`,
`model_visible_repeatable_skill_flags{,_2}` in the probe script.

### 2. Model-visible skill name + description

Same command as above. The model, given
`--skill .../shape-a-dir` and prompted to list every available skill by
name, listed `shape-a-dir` alongside every auto-discovered fixture skill.
Source: skills are formatted into an `<available_skills>` XML block
(`formatSkillsForPrompt()` in `dist/core/skills.js`) with `<name>`,
`<description>`, and `<location>`, appended to the system prompt in
`dist/core/system-prompt.js`.
**Verdict: confirmed.** Cheapest reliable signal is the real model call
(pi has no cheaper one — see "No dry-run debug command exists" above).

**Surprise finding, not asked but load-bearing:** the `<available_skills>`
block is only appended **if the `read` tool is selected**
(`dist/core/system-prompt.js:34,111-113`: `if (customPromptHasRead && ...)` /
`if (hasRead && skills.length > 0)`). A first attempt using `--no-tools`
loaded skills successfully (per the resource loader) but the model reported
zero skills, because the system prompt never mentioned them. Toastty must
keep the `read` tool enabled (the default) on any process where injected
skills need to be visible; `--tools <allowlist>` must include `read`.

### 3. `--no-skills` / `--skill` interplay

Command:
```bash
sv exec -- pi --no-session --print --provider anthropic --model claude-haiku-4-5 \
  --no-skills \
  --skill "$EXTERNAL/shape-b-parent" --skill "$EXTERNAL/shape-c-dir/SKILL.md" \
  --skill "$EXTERNAL/repeat-a" --skill "$EXTERNAL/repeat-b" \
  -p "List the names of every skill available to you, one per line, and nothing else."
```
Observation: `child-one`, `child-two`, `shape-c-dir`, `repeat-a`, `repeat-b`
all appeared; none of the auto-discovered fixtures (`project-pi-skill`,
`project-agents-skill`, `user-pi-skill`, `user-agents-skill`,
`collide-name`) appeared.
Source: `dist/core/resource-loader.js:292-294`:
```js
const skillPaths = this.noSkills
    ? this.mergePaths(cliEnabledSkills, this.additionalSkillPaths)
    : this.mergePaths([...cliEnabledSkills, ...enabledSkills], this.additionalSkillPaths);
```
`this.additionalSkillPaths` is exactly the `--skill` list; `enabledSkills`
(the auto-discovered set) is only merged in when `noSkills` is false.
**Verdict: same shape as Codex's `-ne`/`-e` and matches the task's
hypothesis exactly** — `--no-skills` disables auto-discovery only; explicit
`--skill` paths always load, with or without it. Confirmed by
`no_skills_suppresses_discovery_keeps_explicit` in the script (and by the
5 `model_visible_*` checks in the same run).

### 4. Skill discovery roots

Command: seed one skill fixture in each candidate directory, then run with
ambient discovery on (no `--no-skills`, no `--skill`), isolated `HOME` and
`PI_CODING_AGENT_DIR`, `cwd` = temp workspace:
```bash
sv exec -- pi --no-session --print --provider anthropic --model claude-haiku-4-5 \
  -p "List the names of every skill available to you, one per line, and nothing else."
```
Observation — the actual discovered set, empirically confirmed via model
output *and* matching source (`dist/core/package-manager.js:1743-1774`,
`collectAncestorAgentsSkillDirs()`, `collectAutoSkillEntries()`):

| Root | Path | Scope | Confirmed |
|---|---|---|---|
| project, "pi" mode | `<cwd>/.pi/skills/` | project | yes (`project-pi-skill`) |
| project, "agents" mode | `<cwd>/.agents/skills/`, and every `.agents/skills/` at each ancestor directory up to the enclosing git repo root (or filesystem root if no `.git` is found) | project | yes (`project-agents-skill`) |
| user, "pi" mode | `$PI_CODING_AGENT_DIR/skills/` (default `~/.pi/agent/skills/`) | user | yes (`user-pi-skill`) |
| user, "agents" mode | `$HOME/.agents/skills/` | user | yes (`user-agents-skill`) |

Explicitly **not** a discovery root — decoy seeded, absent from output:
- `$HOME/.claude/skills/` (`claude-decoy-skill` never appeared).

No other roots exist. `AGENTS.md`/`CLAUDE.md` files are a *separate*
mechanism (`--no-context-files`, `loadProjectContextFiles`) for prepending
file contents to the system prompt — unrelated to skill discovery.

**Precedence** (`resourcePrecedenceRank()` in `dist/core/package-manager.js`,
used to order the discovered list before name-collision resolution):
project settings-entry (0) > project auto-discovered (1) > user
settings-entry (2) > user auto-discovered (3) > package resource (4).

**Verdict: confirmed** by `discovery_roots_project_pi_skills`,
`discovery_roots_project_agents_skills`, `discovery_roots_user_pi_agent_skills`,
`discovery_roots_user_home_agents_skills`, `discovery_excludes_claude_skills_dir`.

**Note on ancestor scanning:** without a git repository boundary,
`collectAncestorAgentsSkillDirs()` walks every ancestor directory up to
filesystem root looking for `.agents/skills`. This is a cheap `existsSync`
check per level and harmless when nothing is there, but it means pi always
probes far outside the project tree when a worktree has no `.git` (e.g. a
plain temp dir, as used by this probe).

### 5. Name collision: discovered skill vs. explicit `--skill`, same name

Command:
```bash
sv exec -- pi --no-session --print --provider anthropic --model claude-haiku-4-5 \
  --skill "$EXTERNAL/collide-name-explicit" \
  -p "Find the skill named exactly collide-name in your available_skills list. Quote its <description> value verbatim, and nothing else."
```
with `$WORKSPACE/.pi/skills/collide-name/SKILL.md` (description: "DISCOVERED
version...") auto-discovered from `cwd`, and `$EXTERNAL/collide-name-explicit/SKILL.md`
(description: "EXPLICIT --skill version...") passed via `--skill`.
Observation: the model quoted the **DISCOVERED** description. Only one
`collide-name` entry appeared at all (`name_collision_produces_single_entry_not_duplicate`);
no error, warning, or duplicate was visible in print mode.
Source: `dist/core/skills.js` `loadSkills()`'s `addSkills()` helper only
registers a name into `skillMap` if it isn't already present — first
insertion wins, later ones become silent (in print mode) collision
diagnostics. `dist/core/resource-loader.js:292-294` puts discovered
(`enabledSkills`) paths *before* `additionalSkillPaths` (the `--skill` list)
in the merged array pi ultimately loads from, so **the auto-discovered skill
always wins a name collision against an explicit `--skill` of the same
name; the explicit one is silently dropped.**
**Verdict: confirmed — discovered wins, explicit loses, no error surfaced in
print mode.** This is the opposite of what a naive "explicit overrides
discovered" assumption would predict, and is a hard constraint for Toastty:
an injected skill can be silently shadowed by anything the user's own
project or `~/.agents/skills`/`~/.pi/agent/skills` happens to define under
the same `name:`.

### 6. Frontmatter validation

Command:
```bash
sv exec -- pi --no-session --print --provider anthropic --model claude-haiku-4-5 \
  --skill "$EXTERNAL/bad-frontmatter-missing-desc" \
  -p "List the names of every skill available to you, one per line, and nothing else."
```
where the fixture's `SKILL.md` has `name:` but no `description:` at all
(otherwise identical shape to `plugins/toastty/skills/*/SKILL.md`).
Observation: `bad-frontmatter-missing-desc` never appeared in the model's
list; the process did not error or crash (same exit-code-0 model
completion as any other run).
Source: `dist/core/skills.js` `validateDescription()` + `loadSkillFromFile()`:
```js
if (!frontmatter.description || frontmatter.description.trim() === "") {
    return { skill: null, diagnostics };
}
```
A missing (or empty/whitespace-only) `description` makes the skill silently
unloadable — not a partial load, not a fallback description, just excluded.
Name-mismatch and other spec violations (wrong case, consecutive hyphens,
name ≠ parent directory name) are only *warnings* and do not exclude the
skill — but those warnings are only ever printed in the interactive banner,
never in print/json/rpc mode. The exact frontmatter shape used by
`plugins/toastty/skills/*/SKILL.md` (`name:` + `description:`, nothing else
required) loads cleanly — every shape/discovery-root fixture in this probe
uses that identical two-key frontmatter and all of them loaded.
**Verdict: confirmed** by `missing_description_skill_excluded_without_crash`.

### 7. Failure modes: nonexistent path / dir without `SKILL.md`

Command (no-model, black-box oracle — compares stderr+exit code against an
identical invocation with no bad `--skill` flag, both failing on the same
missing-API-key condition):
```bash
env -i HOME=<isolated> PI_CODING_AGENT_DIR=<isolated> pi --no-session --print \
  --skill /nonexistent/path -p "hi"
# vs. baseline: pi --no-session --print -p "hi"
```
Observation: byte-identical stderr (`No API key found for the selected
model.` + login help text) and identical exit code (`1`) for: baseline, a
nonexistent `--skill` path, and a `--skill` directory with no `SKILL.md`
inside it (and no loose `.md` files either).
Source: `dist/core/resource-loader.js:297-301` pushes a `type: "error"`
diagnostic into `this.skillDiagnostics` for a nonexistent path, but that
array is never included in `runtime.diagnostics` (`main.js:520-522`, which
only aggregates `services.diagnostics` + settings diagnostics + *extension*
errors) — so it never causes `process.exit(1)` and is never printed outside
the interactive banner. A directory without `SKILL.md` just yields an empty
skill list with no diagnostic at all (`loadSkillsFromDirInternal` returns
`{skills: [], diagnostics: []}` when nothing matches).
**Verdict: warn-and-continue (fail open), confirmed by
`nonexistent_skill_path_fails_open_silently` and
`skill_dir_without_SKILL_md_fails_open_silently`.** In print/json/rpc mode
it is stronger than "warn" — there is no visible signal at all; the process
proceeds identically to a run with no bad flag, and exit code is driven
entirely by unrelated concerns (auth, model errors). This determines
Toastty's fail-open design point: a stale or mistyped injected skill path
will never crash a managed session, but Toastty also cannot detect the
problem from the child process's own output in non-interactive mode — any
staging-time validation must happen before injection, not by watching pi's
exit code.

### 8. Argv placement

Commands:
```bash
pi --no-session --print -p "hi" --skill <path>        # flag after positional message
pi --no-session --print -p "hi" --                    # literal "--" alone
```
Observation:
- `--skill` placed **after** the message token still parses identically to
  placing it first (same generic no-API-key failure both times) — confirmed
  by `skill_flag_after_positional_message_parses` /
  `_reaches_same_stage`.
- A literal `--` token is **not** a supported end-of-flags separator and
  produces a distinct, immediate, pre-model failure: `Error: Unknown option:
  --`, exit code 1 — confirmed by
  `literal_double_dash_is_hard_error_distinct_from_baseline`.
Source: `dist/cli/args.js` parses argv as one flat left-to-right scan
(`parseArgs`) with no positional/flag boundary and no special-cased `"--"`
token; every arg is tested against every known-flag branch regardless of
where it sits in argv, so `--skill` is recognized no matter its position.
But `"--".startsWith("--")` is `true` in JS, so a bare `--` falls into the
generic long-flag branch (`dist/cli/args.js:147-162`), is recorded as an
unrecognized extension flag with an **empty name** (`arg.slice(2)` of `"--"`
is `""`), and is reported and hard-failed later in
`dist/core/agent-session-services.js:43` as `Unknown option: --` — this
check happens in `createRuntime()`, *before* any model contact, and does
kill the whole invocation (`main.js:520-523`).
**Verdict: `--skill` is a true flag, not a positional-terminated one — it
parses correctly wherever Toastty inserts it in argv, including after
message tokens. But Toastty must never insert a bare `--` separator into
pi's argv; unlike many CLIs, pi treats it as an invalid flag and hard-fails
the whole process before doing any work, including before skill loading
has a chance to matter.**

### 9. Version and env vars

- `pi --version` → `0.70.2`.
- `PI_CODING_AGENT_DIR` isolates pi's whole per-user state (skills,
  extensions, prompts, themes, sessions, settings.json, auth.json,
  models.json) — the direct analog of Codex's `CODEX_HOME`.
- `HOME` isolates `$HOME/.agents/skills` (and, since `PI_CODING_AGENT_DIR`
  defaults from `homedir()`, also isolates the default agent dir when
  `PI_CODING_AGENT_DIR` itself is unset).
- No further isolation is needed beyond these two variables plus running
  from a controlled `cwd` (which gates `<cwd>/.pi/skills` and the
  `<cwd>/.agents/skills` ancestor walk).

## Design consequences for Toastty

1. **Use `--skill <path>` directly, repeated once per managed skill
   directory**, pointed at each skill's own directory (shape (a)); no need
   to stage a synthetic parent directory (shape (b) also works, but adds an
   indirection with no benefit over one `--skill` per skill).
2. **Never disable the `read` tool** on a process where injected skills must
   be visible to the model — `formatSkillsForPrompt()` output is dropped
   entirely from the system prompt whenever the `read` tool isn't selected.
   If Toastty ever restricts tools via `--tools`/`--no-tools`, `read` must
   stay in the allowlist.
3. **Name collisions are a real risk, and discovered skills always win.**
   If a user's own project (`.pi/skills`, `.agents/skills`) or home
   directory (`~/.pi/agent/skills`, `~/.agents/skills`) happens to define a
   skill with the same `name:` as a Toastty-managed skill, the user's
   version silently wins and Toastty's version is dropped with no visible
   diagnostic in non-interactive mode. Toastty-managed skill names should be
   namespaced/prefixed distinctively (the shipped `toastty-*` naming already
   does this) to make accidental collisions unlikely, and any provisioning
   tooling should treat "our skill silently didn't load" as a possible
   outcome rather than an error condition it can detect from pi's output.
4. **`--no-skills` is safe to combine with Toastty's own `--skill` flags** —
   it suppresses only the four auto-discovery roots, never the explicit
   list. This mirrors Codex's `-ne`/`-e` pattern and gives Toastty a clean
   way to hand a user a "only what we injected" session if that's ever
   wanted, without breaking injection.
5. **There is no supported way to detect a bad injected skill path from the
   child process.** A stale/missing path is completely invisible outside the
   interactive TUI banner — no diagnostic, no nonzero exit, no stderr
   difference. Toastty must validate skill paths before constructing argv
   (e.g. `stat` each staged path itself) rather than relying on pi to report
   problems.
6. **Never insert a bare `--` into pi's argv.** It is parsed as an invalid,
   empty-named extension flag and hard-fails the whole process before any
   model contact — this is a landmine specifically for tooling (like
   Toastty) that assembles argv programmatically and might otherwise use
   `--` defensively as an end-of-flags marker the way many other CLIs
   (including `codex`) support.
7. **Argv position is otherwise unconstrained.** `--skill` (and other
   long flags) parse correctly no matter where they land relative to
   positional message tokens, since pi's parser is a single flat left-to-right
   scan with no positional-boundary concept. Toastty does not need to worry
   about inserting flags "early enough" in argv, only about avoiding a bare
   `--`.
8. **Isolation is two env vars plus cwd control**: `HOME` and
   `PI_CODING_AGENT_DIR`, matching how this probe (and Toastty's own launch
   wrapper, if it isolates a managed pi process) can fully sandbox pi's
   state without ever touching the developer's real `~/.pi`.

Run the probe again with:

```bash
scripts/agents/probe-pi-session-scoped-skills.sh --pi "$(command -v pi)"
```

Add `--with-model` (via `sv exec --`) to additionally exercise the real
model-visibility, discovery-root, no-skills-interplay, name-collision, and
frontmatter-validation checks:

```bash
sv exec -- scripts/agents/probe-pi-session-scoped-skills.sh --pi "$(command -v pi)" --with-model
```
