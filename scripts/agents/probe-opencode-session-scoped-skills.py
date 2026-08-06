#!/usr/bin/env python3
"""Probe how opencode loads session-scoped skills via config injection.

Answers one architecture question for managed Toastty launches: can a single
`opencode` process load Toastty-staged skills through `OPENCODE_CONFIG_CONTENT`
alone, with no persistent writes to `~/.config/opencode` or the project's
`opencode.json`? Every scenario runs against temporary `HOME`, isolated
`XDG_CONFIG_HOME`/`XDG_DATA_HOME` directories, and a throwaway git-initialized
project directory, and reads model-visible skill discovery from
`opencode debug skill` (plus `opencode debug config` for merge/precedence
checks), so no authentication or model request is needed for the gated
checks.

Proven mechanism (see the matching evidence document): opencode's config
schema documents a top-level `skills: {paths, urls}` object. Toastty's
existing `OPENCODE_CONFIG_CONTENT` injection point (already used for the
status plugin, see `AgentLaunchInstrumentation.swift`) can carry a
`skills.paths` entry pointing at a Toastty-staged directory in the same JSON
blob as the `plugin` array, and opencode applies both from a single config
layer with no plugin/skill conflict.

The checks assert the currently proven capability landscape, including two
load-bearing negative/soft results this design depends on:

- `OPENCODE_CONFIG_CONTENT` deep-merges array fields like `instructions`
  (concatenates across global -> project -> env) but *replaces* object
  fields like `skills` wholesale at each layer (the last layer that sets
  `skills.paths` wins outright; it does not concatenate with an earlier
  layer's `skills.paths`).
- Skill-name collisions between Toastty's injected `skills.paths` entry and
  a naturally-discovered location (project `.opencode/skills`, project or
  home `.claude/skills`, project or home `.agents/skills`) are resolved by
  a **non-deterministic** async race: the same fixture can produce a
  different winner across repeated runs of this script. The script asserts
  only the deterministic invariant (exactly one entry survives, never both
  or neither) and separately records the observed winner distribution across
  repeated trials as evidence, not as a pass/fail gate.

A failing gated check means opencode's behavior changed and the
session-scoped skill delivery design should be re-evaluated, not that the
script is broken.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from collections import Counter
from pathlib import Path

COLLISION_TRIALS = 8


class ProbeError(RuntimeError):
    pass


def write_skill(root: Path, name: str, description: str, *, nested: bool = False) -> None:
    """Write a `<root>/<name>/SKILL.md` (or `<root>/SKILL.md` when name == root)."""
    if nested:
        skill_dir = root / "group" / name
    else:
        skill_dir = root / name
    skill_dir.mkdir(parents=True, exist_ok=True)
    (skill_dir / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: {description}\n---\n\nMarker: {description}\n",
        encoding="utf-8",
    )


def write_bare_skill(root: Path, description: str) -> None:
    """Write `<root>/SKILL.md` directly -- the single-skill-folder shape."""
    root.mkdir(parents=True, exist_ok=True)
    name = root.name
    (root / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: {description}\n---\n\nMarker: {description}\n",
        encoding="utf-8",
    )


class Harness:
    def __init__(self, opencode: str, root: Path) -> None:
        self.opencode = opencode
        self.root = root
        self._data_home_counter = 0

    def fresh_data_home(self) -> Path:
        """opencode caches project/session state in a SQLite db under the data
        home. Every scenario that could be sensitive to that cache (which is
        every scenario touching skill discovery) gets its own throwaway data
        home so runs cannot contaminate each other."""
        self._data_home_counter += 1
        path = self.root / f"data-{self._data_home_counter}"
        path.mkdir(parents=True)
        return path

    def make_home(self, name: str) -> Path:
        home = self.root / f"home-{name}"
        home.mkdir(parents=True, exist_ok=True)
        return home

    def make_workspace(self, name: str) -> Path:
        workspace = self.root / f"workspace-{name}"
        workspace.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["git", "init", "-q", str(workspace)],
            check=True,
            timeout=30,
        )
        return workspace

    def run_opencode(
        self,
        *,
        arguments: list[str],
        home: Path,
        workspace: Path,
        xdg_config_home: Path | None = None,
        config_content: dict | str | None = None,
        opencode_config_path: Path | None = None,
        extra_env: dict[str, str] | None = None,
        data_home: Path | None = None,
        accepted_codes: set[int] | None = None,
        timeout: int = 60,
    ) -> subprocess.CompletedProcess[str]:
        environment: dict[str, str] = {
            "HOME": str(home),
            "PATH": os.environ.get("PATH", ""),
        }
        environment["XDG_CONFIG_HOME"] = str(
            xdg_config_home if xdg_config_home is not None else self.root / "xdg-config-empty"
        )
        environment["XDG_CONFIG_HOME"] and Path(environment["XDG_CONFIG_HOME"]).mkdir(
            parents=True, exist_ok=True
        )
        environment["XDG_DATA_HOME"] = str(data_home if data_home is not None else self.fresh_data_home())
        if config_content is not None:
            payload = (
                config_content if isinstance(config_content, str) else json.dumps(config_content)
            )
            environment["OPENCODE_CONFIG_CONTENT"] = payload
        if opencode_config_path is not None:
            environment["OPENCODE_CONFIG"] = str(opencode_config_path)
        if extra_env:
            environment.update(extra_env)

        result = subprocess.run(
            [self.opencode, *arguments],
            cwd=workspace,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        allowed = accepted_codes or {0}
        if result.returncode not in allowed:
            raise ProbeError(
                f"opencode {' '.join(arguments[:4])} exited {result.returncode}: "
                f"{result.stderr.strip() or result.stdout.strip()}"
            )
        return result

    def debug_config(self, **kwargs) -> dict:
        result = self.run_opencode(arguments=["debug", "config"], **kwargs)
        return json.loads(result.stdout)

    def debug_skill(self, **kwargs) -> list[dict]:
        result = self.run_opencode(arguments=["debug", "skill"], **kwargs)
        return json.loads(result.stdout)

    def skill_entries(self, name: str, **kwargs) -> list[dict]:
        return [entry for entry in self.debug_skill(**kwargs) if entry.get("name") == name]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--opencode",
        default=os.environ.get("OPENCODE_BIN"),
        help=(
            "Path to the real opencode binary (avoid Toastty-managed shims -- "
            "`which opencode` on a dev machine with Toastty running commonly "
            "resolves to a runtime-isolated dev-run shim, not the real CLI)."
        ),
    )
    options = parser.parse_args()

    resolved = options.opencode or shutil.which("opencode")
    if not resolved:
        raise ProbeError("opencode must be installed or passed via --opencode/OPENCODE_BIN")
    if any(marker in resolved for marker in ("dev-run", "runtime-home", "toastty")):
        raise ProbeError(
            f"refusing to use likely Toastty-managed shim at {resolved}; "
            "pass --opencode/OPENCODE_BIN pointing at the real opencode binary"
        )

    with tempfile.TemporaryDirectory(prefix="toastty-opencode-session-skills-probe.") as raw_root:
        harness = Harness(resolved, Path(raw_root))
        checks: dict[str, bool] = {}
        notes: list[str] = []

        version = subprocess.run(
            [resolved, "--version"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=30, check=True,
        ).stdout.strip()

        # ------------------------------------------------------------------
        # Q1: OPENCODE_CONFIG_CONTENT merge / precedence semantics.
        # ------------------------------------------------------------------
        home1 = harness.make_home("merge")
        ws1 = harness.make_workspace("merge")
        xdg1 = harness.root / "xdg-config-merge"
        (xdg1 / "opencode").mkdir(parents=True)
        (xdg1 / "opencode" / "opencode.json").write_text(
            json.dumps(
                {
                    "instructions": ["global-instructions-marker.md"],
                    "skills": {"paths": ["global-skills-path-marker"]},
                }
            ),
            encoding="utf-8",
        )
        (ws1 / "opencode.json").write_text(
            json.dumps(
                {
                    "instructions": ["project-instructions-marker.md"],
                    "skills": {"paths": ["project-skills-path-marker"]},
                }
            ),
            encoding="utf-8",
        )

        global_and_project = harness.debug_config(home=home1, workspace=ws1, xdg_config_home=xdg1)
        checks["instructions_array_concatenates_global_then_project"] = (
            global_and_project.get("instructions")
            == ["global-instructions-marker.md", "project-instructions-marker.md"]
        )
        checks["skills_object_field_replaced_not_merged_by_project"] = global_and_project.get(
            "skills"
        ) == {"paths": ["project-skills-path-marker"]}

        with_env = harness.debug_config(
            home=home1,
            workspace=ws1,
            xdg_config_home=xdg1,
            config_content={
                "instructions": ["env-instructions-marker.md"],
                "skills": {"paths": ["env-skills-path-marker"]},
            },
        )
        checks["env_config_content_instructions_appended_last"] = with_env.get("instructions") == [
            "global-instructions-marker.md",
            "project-instructions-marker.md",
            "env-instructions-marker.md",
        ]
        checks["env_config_content_skills_object_wins_outright"] = with_env.get("skills") == {
            "paths": ["env-skills-path-marker"]
        }

        explicit_config_path = harness.root / "explicit-config.json"
        explicit_config_path.write_text(
            json.dumps({"instructions": ["explicit-config-marker.md"]}), encoding="utf-8"
        )
        with_opencode_config = harness.debug_config(
            home=home1, workspace=ws1, xdg_config_home=xdg1, opencode_config_path=explicit_config_path
        )
        # OPENCODE_CONFIG merges additively, but NOT after the project config:
        # the observed layer order is global -> OPENCODE_CONFIG -> project ->
        # OPENCODE_CONFIG_CONTENT (the last, "final local-scope merge" layer).
        checks["opencode_config_env_var_adds_file_between_global_and_project"] = (
            with_opencode_config.get("instructions")
            == [
                "global-instructions-marker.md",
                "explicit-config-marker.md",
                "project-instructions-marker.md",
            ]
        )

        disable_project = harness.debug_config(
            home=home1,
            workspace=ws1,
            xdg_config_home=xdg1,
            extra_env={"OPENCODE_DISABLE_PROJECT_CONFIG": "1"},
            config_content={"instructions": ["env-instructions-marker.md"]},
        )
        checks["disable_project_config_skips_project_keeps_global_and_env"] = (
            disable_project.get("instructions")
            == ["global-instructions-marker.md", "env-instructions-marker.md"]
        )

        # ------------------------------------------------------------------
        # Q2: skills.paths entry shapes.
        # ------------------------------------------------------------------
        home2 = harness.make_home("shapes")
        ws2 = harness.make_workspace("shapes")
        skills_root_a = harness.root / "skills-root-a"  # dir of skill folders
        write_skill(skills_root_a, "probe-skill-shape-a", "shape (a): dir of skill folders")
        skills_root_b = harness.root / "skills-root-b"  # single skill folder
        write_bare_skill(skills_root_b, "shape (b): single skill folder")
        skills_root_nested = harness.root / "skills-root-nested"
        write_skill(skills_root_nested, "probe-skill-nested", "two-level nesting", nested=True)

        checks["skills_paths_dir_of_skill_folders_discovered"] = bool(
            harness.skill_entries(
                "probe-skill-shape-a",
                home=home2,
                workspace=ws2,
                config_content={"skills": {"paths": [str(skills_root_a)]}},
            )
        )
        checks["skills_paths_single_skill_folder_discovered"] = bool(
            harness.skill_entries(
                skills_root_b.name,
                home=home2,
                workspace=ws2,
                config_content={"skills": {"paths": [str(skills_root_b)]}},
            )
        )
        checks["skills_paths_scanned_recursively_for_nested_skill_md"] = bool(
            harness.skill_entries(
                "probe-skill-nested",
                home=home2,
                workspace=ws2,
                config_content={"skills": {"paths": [str(skills_root_nested)]}},
            )
        )
        checks["skills_paths_relative_path_resolved_from_cwd"] = bool(
            harness.skill_entries(
                "probe-skill-shape-a",
                home=home2,
                workspace=ws2,
                config_content={
                    "skills": {"paths": [os.path.relpath(skills_root_a, ws2)]}
                },
            )
        )
        checks["skills_paths_file_uri_not_supported"] = not harness.skill_entries(
            "probe-skill-shape-a",
            home=home2,
            workspace=ws2,
            config_content={"skills": {"paths": [f"file://{skills_root_a}"]}},
        )

        # ------------------------------------------------------------------
        # Q3: skills from skills.paths reach model-visible discovery.
        # ------------------------------------------------------------------
        checks["skill_from_skills_paths_reaches_debug_skill_listing"] = checks[
            "skills_paths_dir_of_skill_folders_discovered"
        ]
        notes.append(
            "Q3 additionally confirmed live: `opencode run --model "
            "opencode/deepseek-v4-flash-free \"List the exact names of every "
            "skill available to you...\"` against real HOME auth (isolated "
            "XDG_CONFIG_HOME, injected OPENCODE_CONFIG_CONTENT skills.paths) "
            "returned the injected marker skill's exact name in the model's "
            "own answer. Not re-run by this script (requires configured "
            "provider auth); see the evidence doc for the transcript."
        )

        # ------------------------------------------------------------------
        # Q4: collision between skills.paths and a discovered location.
        # ------------------------------------------------------------------
        collision_winners: Counter[str] = Counter()
        for trial in range(COLLISION_TRIALS):
            home_c = harness.make_home(f"collision-{trial}")
            ws_c = harness.make_workspace(f"collision-{trial}")
            write_skill(
                ws_c / ".opencode" / "skills", "probe-collision", "SOURCE-PROJECT-OPENCODE"
            )
            ext_root = harness.root / f"collision-ext-{trial}"
            write_skill(ext_root, "probe-collision", "SOURCE-SKILLS-PATHS")
            entries = harness.skill_entries(
                "probe-collision",
                home=home_c,
                workspace=ws_c,
                config_content={"skills": {"paths": [str(ext_root)]}},
            )
            if len(entries) == 1:
                collision_winners[entries[0]["description"]] += 1
            else:
                collision_winners[f"__count_{len(entries)}__"] += 1

        checks["colliding_skill_name_always_dedupes_to_exactly_one_entry"] = all(
            not key.startswith("__count_") or key == "__count_1__" for key in collision_winners
        ) and sum(collision_winners.values()) == COLLISION_TRIALS

        # ------------------------------------------------------------------
        # Q5: discovery baseline (collision surface for the management sheet).
        # ------------------------------------------------------------------
        home5 = harness.make_home("baseline")
        ws5 = harness.make_workspace("baseline")
        write_skill(ws5 / ".opencode" / "skills", "probe-project-opencode", "project .opencode/skills")
        write_skill(ws5 / ".claude" / "skills", "probe-project-claude", "project .claude/skills")
        write_skill(ws5 / ".agents" / "skills", "probe-project-agents", "project .agents/skills")
        write_skill(home5 / ".claude" / "skills", "probe-home-claude", "home .claude/skills")
        write_skill(home5 / ".agents" / "skills", "probe-home-agents", "home .agents/skills")

        baseline = {entry["name"] for entry in harness.debug_skill(home=home5, workspace=ws5)}
        checks["project_opencode_skills_auto_discovered"] = "probe-project-opencode" in baseline
        checks["project_claude_skills_auto_discovered"] = "probe-project-claude" in baseline
        checks["project_agents_skills_auto_discovered"] = "probe-project-agents" in baseline
        checks["home_claude_skills_auto_discovered"] = "probe-home-claude" in baseline
        checks["home_agents_skills_auto_discovered"] = "probe-home-agents" in baseline

        disable_claude_code = {
            entry["name"]
            for entry in harness.debug_skill(
                home=home5, workspace=ws5, extra_env={"OPENCODE_DISABLE_CLAUDE_CODE_SKILLS": "1"}
            )
        }
        checks["disable_claude_code_skills_removes_dot_claude_only"] = (
            "probe-project-claude" not in disable_claude_code
            and "probe-home-claude" not in disable_claude_code
            and "probe-project-agents" in disable_claude_code
            and "probe-home-agents" in disable_claude_code
        )

        disable_external = {
            entry["name"]
            for entry in harness.debug_skill(
                home=home5, workspace=ws5, extra_env={"OPENCODE_DISABLE_EXTERNAL_SKILLS": "1"}
            )
        }
        checks["disable_external_skills_removes_claude_and_agents_both"] = (
            "probe-project-claude" not in disable_external
            and "probe-home-claude" not in disable_external
            and "probe-project-agents" not in disable_external
            and "probe-home-agents" not in disable_external
            and "probe-project-opencode" in disable_external
        )

        # ------------------------------------------------------------------
        # Q6: plugin + skills.paths coexistence in one config blob.
        # ------------------------------------------------------------------
        home6 = harness.make_home("coexist")
        ws6 = harness.make_workspace("coexist")
        marker_path = harness.root / "plugin-executed.marker"
        plugin_path = harness.root / "noop-plugin.js"
        plugin_path.write_text(
            "import { writeFileSync } from \"node:fs\";\n"
            "export async function ToasttyProbeNoopPlugin() {\n"
            f"  writeFileSync({json.dumps(str(marker_path))}, \"executed\\n\");\n"
            "  return {};\n"
            "}\n",
            encoding="utf-8",
        )
        coexist_skills_root = harness.root / "coexist-skills"
        write_skill(coexist_skills_root, "probe-coexist", "plugin + skills.paths coexistence")
        harness.debug_skill(
            home=home6,
            workspace=ws6,
            config_content={
                "plugin": [f"file://{plugin_path}"],
                "skills": {"paths": [str(coexist_skills_root)]},
            },
        )
        checks["plugin_executes_when_skills_paths_also_set"] = marker_path.is_file()
        checks["skill_present_when_plugin_also_set"] = bool(
            harness.skill_entries(
                "probe-coexist",
                home=harness.make_home("coexist-verify"),
                workspace=harness.make_workspace("coexist-verify"),
                config_content={
                    "plugin": [f"file://{plugin_path}"],
                    "skills": {"paths": [str(coexist_skills_root)]},
                },
            )
        )

        # ------------------------------------------------------------------
        # Q7: failure modes.
        # ------------------------------------------------------------------
        home7 = harness.make_home("failure")
        ws7 = harness.make_workspace("failure")
        nonexistent_result = harness.run_opencode(
            arguments=["debug", "skill"],
            home=home7,
            workspace=ws7,
            config_content={"skills": {"paths": [str(harness.root / "does-not-exist-probe")]}},
            accepted_codes={0, 1},
        )
        checks["nonexistent_skills_path_entry_does_not_error"] = nonexistent_result.returncode == 0

        malformed_root = harness.root / "skills-malformed"
        malformed_dir = malformed_root / "probe-malformed"
        malformed_dir.mkdir(parents=True)
        (malformed_dir / "SKILL.md").write_text(
            "---\nname: probe-malformed\n---\n\nBody with no description frontmatter.\n",
            encoding="utf-8",
        )
        malformed_entries = harness.skill_entries(
            "probe-malformed",
            home=home7,
            workspace=ws7,
            config_content={"skills": {"paths": [str(malformed_root)]}},
        )
        checks["malformed_skill_missing_description_does_not_crash_startup"] = True  # implied by no ProbeError above
        checks["malformed_skill_still_listed_by_debug_skill_without_description_field"] = bool(
            malformed_entries
        ) and "description" not in malformed_entries[0]
        notes.append(
            "opencode's own built-in `customize-opencode` skill claims skills "
            "without a description 'are filtered out and never surfaced to the "
            "model.' `opencode debug skill` still lists the malformed fixture "
            "(minus the description field), which is a debug/registry view, not "
            "necessarily the final model-facing set. Whether the malformed skill "
            "actually reaches the model's system prompt could not be confirmed "
            "without a model call; treat this as unresolved, not as a "
            "contradiction of the documented behavior."
        )

        # ------------------------------------------------------------------
        # Q8: default `skill` permission.
        # ------------------------------------------------------------------
        home8 = harness.make_home("permission")
        ws8 = harness.make_workspace("permission")
        agent_result = harness.run_opencode(
            arguments=["debug", "agent", "build"], home=home8, workspace=ws8
        )
        agent_config = json.loads(agent_result.stdout)
        permission_rules = agent_config.get("permission", [])
        skill_specific_rules = [rule for rule in permission_rules if rule.get("permission") == "skill"]
        wildcard_rules = [
            rule
            for rule in permission_rules
            if rule.get("permission") == "*" and rule.get("pattern") == "*"
        ]
        checks["default_build_agent_has_no_skill_specific_permission_override"] = (
            skill_specific_rules == []
        )
        checks["default_build_agent_wildcard_permission_is_allow"] = bool(
            wildcard_rules
        ) and wildcard_rules[0].get("action") == "allow"
        notes.append(
            "No `skill`-specific permission rule exists for the default `build` "
            "agent; skill usage falls through to the top-level `*` -> `allow` "
            "wildcard rule, so the `skill` permission does not block skill "
            "usage by default."
        )

        # ------------------------------------------------------------------
        # Q9: version, env vars honored, log location.
        # ------------------------------------------------------------------
        home9 = harness.make_home("paths")
        ws9 = harness.make_workspace("paths")
        xdg_config9 = harness.root / "xdg-config-9"
        xdg_data9 = harness.root / "xdg-data-9"
        paths_result = harness.run_opencode(
            arguments=["debug", "paths"],
            home=home9,
            workspace=ws9,
            xdg_config_home=xdg_config9,
            data_home=xdg_data9,
        )
        checks["xdg_config_home_honored"] = str(xdg_config9) in paths_result.stdout
        checks["xdg_data_home_honored"] = str(xdg_data9) in paths_result.stdout

        failures = [name for name, passed in checks.items() if not passed]
        result = {
            "opencodeVersion": version,
            "opencodeBinary": resolved,
            "sessionScopedDeliveryAvailable": True,
            "sessionScopedMechanism": (
                "OPENCODE_CONFIG_CONTENT carrying {\"plugin\": [...], \"skills\": "
                "{\"paths\": [...]}} in one JSON blob -- both apply, and the env "
                "layer is documented by opencode itself as 'a final local-scope "
                "merge' (no CODEX_HOME-style profile/session-scoping flag needed, "
                "since Toastty already sets OPENCODE_CONFIG_CONTENT fresh per "
                "managed launch)."
            ),
            "checks": checks,
            "collisionWinnerDistribution": dict(collision_winners),
            "envVarsHonoredForIsolation": ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"],
            "envVarsNotUsedForIsolation": [
                "OPENCODE_CONFIG (additive explicit file, not an isolation override)",
            ],
            "logDirectoryUnderXdgDataHome": "<XDG_DATA_HOME>/opencode/log",
            "notes": notes
            + [
                "All gated checks ran against temporary HOME, XDG_CONFIG_HOME, "
                "and XDG_DATA_HOME directories, and a throwaway git-initialized "
                "project directory. No authentication or model request was made "
                "for any gated check.",
                "collisionWinnerDistribution records the observed winning "
                "description across repeated identical trials of the same "
                "skills.paths-vs-project-.opencode/skills collision fixture. A "
                "distribution with more than one key confirms the collision "
                "resolution race documented in the evidence doc; it is recorded "
                "as evidence, not gated as a pass/fail check, because either "
                "winner is 'correct' per observed opencode behavior.",
                "Failing gated checks mean opencode's capability landscape "
                "changed and the session-scoped skill delivery design should be "
                "re-evaluated, not that the script is broken.",
            ],
        }
        print(json.dumps(result, indent=2, sort_keys=True))
        if failures:
            raise ProbeError(f"failed checks: {', '.join(failures)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ProbeError, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=os.sys.stderr)
        raise SystemExit(1)
