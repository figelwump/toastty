#!/usr/bin/env python3
"""Probe whether mimo (opencode-family fork, v0.1.9) supports session-scoped
skills via config injection, the same question the Codex probe answers for
Codex (see `probe-codex-session-scoped-skills.py`).

Upstream opencode documents a top-level `skills` config object shaped like
`{"paths": [string], "urls": [string]}`. Toastty already injects config into
mimo through the `MIMOCODE_CONFIG_CONTENT` env var (see the OpenCodeFamily
section of `Sources/App/Agents/AgentLaunchInstrumentation.swift`), currently
carrying only `{"plugin": ["file://..."]}`. This probe establishes whether
this fork's base version accepts `skills` too, and with what semantics.

Every scenario runs against a temporary `HOME` (and, for one scenario, a
temporary `XDG_CONFIG_HOME`), so no Toastty-managed or real user agent state
is touched. Model-visible skill discovery is read from `mimo debug skill`
(mirrors `codex debug prompt-input`) and resolved config from
`mimo debug config`; neither needs authentication or a model request. One
additional check makes a real model call and is skipped unless
`--live-model` is passed (the caller is expected to provide provider
credentials, e.g. via `sv exec -- ... --live-model`).

mimo's config schema is strict (zod-like): an unrecognized top-level key is
a hard error, and a recognized key with the wrong type is a hard error with
a field-scoped message. That makes existence probing more decisive here than
for Codex, which silently ignores unknown config keys.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

DEFAULT_TIMEOUT = 120  # bun cold-start + one-time sqlite migration per fresh HOME


class ProbeError(RuntimeError):
    pass


def write_skill(root: Path, name: str, description: str, *, body: str | None = None, frontmatter: bool = True) -> None:
    (root / name).mkdir(parents=True, exist_ok=True)
    if not frontmatter:
        (root / name / "SKILL.md").write_text(
            body or "No frontmatter at all, just prose.\n", encoding="utf-8"
        )
        return
    text = f"---\nname: {name}\n"
    if description is not None:
        text += f"description: {description}\n"
    text += f"---\nMarker: {body or description}\n"
    (root / name / "SKILL.md").write_text(text, encoding="utf-8")


class Harness:
    def __init__(self, mimo: str, root: Path, timeout: int) -> None:
        self.mimo = mimo
        self.root = root
        self.timeout = timeout
        self.workspace = root / "workspace"
        self.workspace.mkdir()
        subprocess.run(
            ["git", "init", "-q", str(self.workspace)],
            check=False,
            timeout=timeout,
        )

        self.skills_a = root / "fixtures" / "skills-a"
        write_skill(self.skills_a, "probe-skill-alpha", "Probe fixture skill alpha for mimo skills.paths testing.")

        self.skills_b = root / "fixtures" / "skills-b"
        write_skill(self.skills_b, "probe-skill-beta", "Probe fixture skill beta, distinct from alpha, for merge-semantics testing.")

        self.skills_bad = root / "fixtures" / "skills-bad"
        write_skill(self.skills_bad, "probe-skill-malformed", None, frontmatter=False)
        write_skill(self.skills_bad, "probe-skill-nodesc", None, body="No description in frontmatter.")

        self.plugin_dir = root / "fixtures" / "plugin"
        self.plugin_dir.mkdir(parents=True)
        (self.plugin_dir / "noop-plugin.js").write_text(
            "export const NoopPlugin = async () => { return {}; };\n", encoding="utf-8"
        )

        self.single_skill_dir = self.skills_a / "probe-skill-alpha"

    def make_home(self, name: str) -> Path:
        home = self.root / "homes" / name
        home.mkdir(parents=True)
        return home

    def run(
        self,
        home: Path,
        args: list[str],
        *,
        extra_env: dict[str, str] | None = None,
        accepted_codes: set[int] | None = None,
        cwd: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["HOME"] = str(home)
        # Isolate every XDG root so nothing falls back to a real user path,
        # even though mimo derives data/cache/state from HOME by default.
        env.setdefault("XDG_CONFIG_HOME", str(home / ".config"))
        env.setdefault("XDG_DATA_HOME", str(home / ".local" / "share"))
        env.setdefault("XDG_CACHE_HOME", str(home / ".cache"))
        env.setdefault("XDG_STATE_HOME", str(home / ".local" / "state"))
        if extra_env:
            env.update(extra_env)
        # mimo (Bun-compiled) writes stdout asynchronously and can call
        # process.exit() before a large write to a *pipe* finishes flushing,
        # silently truncating the JSON payload (`debug skill` dumps often
        # exceed 300 KB). Writes to a regular file do not race process exit,
        # so redirect to files instead of subprocess.PIPE. Confirmed via
        # repeated runs: PIPE capture truncated at ~64 KB non-deterministically
        # every time; file redirection was complete and stable across repeats.
        self._io_counter = getattr(self, "_io_counter", 0) + 1
        stdout_path = self.root / "io" / f"{self._io_counter:04d}.stdout"
        stderr_path = self.root / "io" / f"{self._io_counter:04d}.stderr"
        stdout_path.parent.mkdir(exist_ok=True)
        with stdout_path.open("w", encoding="utf-8") as stdout_file, stderr_path.open(
            "w", encoding="utf-8"
        ) as stderr_file:
            completed = subprocess.run(
                [self.mimo, *args],
                cwd=str(cwd or self.workspace),
                env=env,
                stdout=stdout_file,
                stderr=stderr_file,
                timeout=self.timeout,
                check=False,
            )
        stdout_text = stdout_path.read_text(encoding="utf-8")
        stderr_text = stderr_path.read_text(encoding="utf-8")
        result = subprocess.CompletedProcess(
            completed.args, completed.returncode, stdout_text, stderr_text
        )
        allowed = accepted_codes if accepted_codes is not None else {0}
        if result.returncode not in allowed:
            raise ProbeError(
                f"mimo {' '.join(args[:3])} in {home.name} exited {result.returncode}: "
                f"{result.stderr.strip()[-800:] or result.stdout.strip()[-800:]}"
            )
        return result

    def debug_config(
        self, home: Path, *, extra_env: dict[str, str] | None = None, accepted_codes: set[int] | None = None
    ) -> tuple[subprocess.CompletedProcess[str], dict | None]:
        result = self.run(home, ["debug", "config"], extra_env=extra_env, accepted_codes=accepted_codes)
        parsed = json.loads(result.stdout) if result.returncode == 0 and result.stdout.strip() else None
        return result, parsed

    def debug_skill_names(
        self, home: Path, *, extra_env: dict[str, str] | None = None, cwd: Path | None = None
    ) -> set[str]:
        result = self.run(home, ["debug", "skill"], extra_env=extra_env, cwd=cwd)
        entries = json.loads(result.stdout)
        return {entry["name"] for entry in entries}

    def config_content(self, obj: dict) -> str:
        return json.dumps(obj)


def make_scaffold_tree(root: Path, relative_dirs: list[str], name_prefix: str) -> dict[str, str]:
    """Write a marker skill under each of `relative_dirs` beneath `root`; return {dir: skill_name}."""
    created = {}
    for rel in relative_dirs:
        name = f"{name_prefix}-{rel.strip('.').replace('/', '-')}-probe"
        write_skill(root / rel, name, f"Auto-discovery probe for {rel}")
        created[rel] = name
    return created


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mimo",
        default=os.environ.get("MIMO_BIN") or shutil.which("mimo") or os.path.expanduser("~/.mimocode/bin/mimo"),
        help="Path to the real mimo binary (avoid Toastty-managed shims).",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help="Per-invocation subprocess timeout in seconds.",
    )
    parser.add_argument(
        "--live-model",
        action="store_true",
        help=(
            "Also run one real model call to confirm the injected skill reaches the "
            "model's own listing, not just `mimo debug skill`. Requires a working "
            "provider credential in the environment (e.g. `sv exec -- ... --live-model`). "
            "Skipped by default."
        ),
    )
    parser.add_argument(
        "--live-model-id",
        default="anthropic/claude-haiku-4-5",
        help=(
            "provider/model id passed to `mimo run --model` for --live-model. mimo's "
            "bundled free-tier provider has no default model wired up, so this must "
            "name a model the caller's credentials can actually reach."
        ),
    )
    options = parser.parse_args()
    if not options.mimo or not os.path.exists(options.mimo):
        raise ProbeError("mimo must be installed or passed via --mimo/MIMO_BIN")

    with tempfile.TemporaryDirectory(prefix="toastty-mimo-session-skills-probe.") as raw_root:
        harness = Harness(options.mimo, Path(raw_root), options.timeout)
        checks: dict[str, bool] = {}
        notes: list[str] = []

        version = harness.run(harness.make_home("version"), ["--version"]).stdout.strip()

        # --- Q1/Q2: does `skills` exist at all, and via which env var? --------
        empty_content = harness.config_content({"skills": {"paths": [str(harness.skills_a)]}})

        mimocode_home = harness.make_home("mimocode-content")
        _, mimocode_cfg = harness.debug_config(mimocode_home, extra_env={"MIMOCODE_CONFIG_CONTENT": empty_content})
        checks["mimocode_config_content_accepts_skills_paths"] = bool(
            mimocode_cfg and mimocode_cfg.get("skills", {}).get("paths") == [str(harness.skills_a)]
        )

        opencode_home = harness.make_home("opencode-content")
        _, opencode_cfg = harness.debug_config(opencode_home, extra_env={"OPENCODE_CONFIG_CONTENT": empty_content})
        checks["opencode_config_content_env_var_not_honored"] = bool(
            opencode_cfg is not None and "skills" not in opencode_cfg
        )

        # Schema strictness oracle: unknown top-level key is a hard error;
        # `skills` is not treated as unknown.
        unknown_key_home = harness.make_home("unknown-key")
        unknown_result, _ = harness.debug_config(
            unknown_key_home,
            extra_env={"MIMOCODE_CONFIG_CONTENT": '{"totallyBogusTopLevelKey": {"foo": "bar"}}'},
            accepted_codes={0, 1},
        )
        checks["unrecognized_top_level_key_hard_errors"] = (
            unknown_result.returncode == 1 and "Unrecognized key" in unknown_result.stderr
        )

        invalid_type_home = harness.make_home("invalid-type")
        invalid_result, _ = harness.debug_config(
            invalid_type_home,
            extra_env={"MIMOCODE_CONFIG_CONTENT": '{"skills": {"paths": "not-an-array"}}'},
            accepted_codes={0, 1},
        )
        checks["skills_paths_wrong_type_hard_errors"] = (
            invalid_result.returncode == 1
            and "expected array" in invalid_result.stderr
            and "skills.paths" in invalid_result.stderr
        )

        urls_home = harness.make_home("urls-empty")
        _, urls_cfg = harness.debug_config(urls_home, extra_env={"MIMOCODE_CONFIG_CONTENT": '{"skills": {"urls": []}}'})
        checks["skills_urls_key_schema_accepted"] = bool(urls_cfg and urls_cfg.get("skills", {}).get("urls") == [])

        # --- Q3: entry shape and does it reach `debug skill`? ------------------
        parent_dir_home = harness.make_home("shape-parent-dir")
        parent_names = harness.debug_skill_names(
            parent_dir_home,
            extra_env={"MIMOCODE_CONFIG_CONTENT": harness.config_content({"skills": {"paths": [str(harness.skills_a)]}})},
        )
        checks["skills_paths_parent_dir_shape_loads_skill"] = "probe-skill-alpha" in parent_names

        single_dir_home = harness.make_home("shape-single-dir")
        single_names = harness.debug_skill_names(
            single_dir_home,
            extra_env={
                "MIMOCODE_CONFIG_CONTENT": harness.config_content({"skills": {"paths": [str(harness.single_skill_dir)]}})
            },
        )
        checks["skills_paths_single_skill_dir_shape_also_loads"] = "probe-skill-alpha" in single_names

        # --- Q1 (continued): via a config file, not just env content ----------
        global_config_home = harness.make_home("global-config-file")
        (global_config_home / ".config" / "mimocode").mkdir(parents=True)
        (global_config_home / ".config" / "mimocode" / "mimocode.json").write_text(
            json.dumps({"skills": {"paths": [str(harness.skills_a)]}}), encoding="utf-8"
        )
        global_config_names = harness.debug_skill_names(global_config_home)
        checks["global_config_file_skills_paths_loads_skill"] = "probe-skill-alpha" in global_config_names

        mimocode_config_var_home = harness.make_home("mimocode-config-var")
        conf_file = harness.root / "fixtures" / "mimocode-config-var.json"
        conf_file.write_text(json.dumps({"skills": {"paths": [str(harness.skills_a)]}}), encoding="utf-8")
        conf_var_names = harness.debug_skill_names(
            mimocode_config_var_home, extra_env={"MIMOCODE_CONFIG": str(conf_file)}
        )
        checks["mimocode_config_file_path_env_var_loads_skill"] = "probe-skill-alpha" in conf_var_names

        # --- Q4: merge semantics of *_CONFIG_CONTENT vs a config file ---------
        merge_home = harness.make_home("merge-semantics")
        (merge_home / ".config" / "mimocode").mkdir(parents=True)
        (merge_home / ".config" / "mimocode" / "mimocode.json").write_text(
            json.dumps({"skills": {"paths": [str(harness.skills_a)]}}), encoding="utf-8"
        )
        merge_names = harness.debug_skill_names(
            merge_home,
            extra_env={
                "MIMOCODE_CONFIG_CONTENT": harness.config_content({"skills": {"paths": [str(harness.skills_b)]}})
            },
        )
        checks["config_content_skills_paths_replaces_not_merges_with_file"] = (
            "probe-skill-beta" in merge_names and "probe-skill-alpha" not in merge_names
        )

        # --- Q5: coexistence of "plugin" and "skills" in one CONFIG_CONTENT ---
        coexist_home = harness.make_home("coexist")
        coexist_content = harness.config_content(
            {
                "plugin": [harness.plugin_dir.joinpath("noop-plugin.js").absolute().as_uri()],
                "skills": {"paths": [str(harness.skills_b)]},
            }
        )
        coexist_result = harness.run(
            coexist_home, ["debug", "skill", "--print-logs", "--log-level", "DEBUG"], extra_env={"MIMOCODE_CONFIG_CONTENT": coexist_content}
        )
        coexist_names = {entry["name"] for entry in json.loads(coexist_result.stdout)}
        checks["plugin_and_skills_coexist_in_one_config_content"] = (
            "probe-skill-beta" in coexist_names
            and "loading plugin" in coexist_result.stderr
            and "ERROR" not in coexist_result.stderr
        )

        # --- Q6: failure modes ---------------------------------------------
        missing_path_home = harness.make_home("missing-path")
        missing_result = harness.run(
            missing_path_home,
            ["debug", "skill", "--print-logs", "--log-level", "DEBUG"],
            extra_env={
                "MIMOCODE_CONFIG_CONTENT": harness.config_content(
                    {"skills": {"paths": [str(harness.root / "fixtures" / "does-not-exist")]}}
                )
            },
        )
        checks["nonexistent_skills_path_warns_and_continues"] = (
            missing_result.returncode == 0 and "skill path not found" in missing_result.stderr
        )

        malformed_home = harness.make_home("malformed-skill")
        malformed_names = harness.debug_skill_names(
            malformed_home,
            extra_env={"MIMOCODE_CONFIG_CONTENT": harness.config_content({"skills": {"paths": [str(harness.skills_bad)]}})},
        )
        checks["malformed_skill_no_frontmatter_silently_dropped"] = "probe-skill-malformed" not in malformed_names
        checks["malformed_skill_missing_description_silently_dropped"] = "probe-skill-nodesc" not in malformed_names
        checks["malformed_skills_do_not_error_whole_load"] = len(malformed_names) > 0  # builtins still present

        bad_url_home = harness.make_home("bad-url")
        bad_url_names = harness.debug_skill_names(
            bad_url_home,
            extra_env={
                "MIMOCODE_CONFIG_CONTENT": harness.config_content(
                    {
                        "skills": {
                            "paths": [str(harness.skills_a)],
                            "urls": ["https://example.invalid/skills.zip"],
                        }
                    }
                )
            },
        )
        checks["unreachable_skills_url_does_not_block_paths_loading"] = "probe-skill-alpha" in bad_url_names

        # --- Q7: auto-discovery dirs, for the collision-warning story --------
        project_ws = harness.root / "workspace-autodiscovery"
        project_ws.mkdir()
        subprocess.run(["git", "init", "-q", str(project_ws)], check=False, timeout=options.timeout)
        # `.mimo/skills` (the CLI's own basename) is deliberately included as a
        # negative control: confirmed NOT discovered, only `.mimocode/skills` is.
        project_discovered_dirs = {".opencode/skills", ".claude/skills", ".agents/skills", ".mimocode/skills"}
        project_not_discovered_dirs = {".mimo/skills"}
        project_created = make_scaffold_tree(
            project_ws, sorted(project_discovered_dirs | project_not_discovered_dirs), "project-auto"
        )
        project_home = harness.make_home("project-autodiscovery")
        project_names = harness.debug_skill_names(project_home, cwd=project_ws)
        for rel, name in project_created.items():
            expected_present = rel in project_discovered_dirs
            checks[f"project_autodiscovery[{rel}]={'discovered' if expected_present else 'not_discovered'}"] = (
                (name in project_names) if expected_present else (name not in project_names)
            )

        home_candidates = [".claude/skills", ".agents/skills", ".codex/skills", ".opencode/skills", ".mimocode/skills"]
        home_auto_home = harness.make_home("home-autodiscovery")
        home_created = make_scaffold_tree(home_auto_home, home_candidates, "home-auto")
        home_names = harness.debug_skill_names(home_auto_home)
        for rel, name in home_created.items():
            checks[f"home_autodiscovery[{rel}]"] = name in home_names

        # --- Q8: version, config/log locations ------------------------------
        paths_home = harness.make_home("paths")
        paths_result = harness.run(paths_home, ["debug", "paths"])
        paths_lines = dict(
            line.split(None, 1) for line in paths_result.stdout.strip().splitlines() if len(line.split(None, 1)) == 2
        )
        checks["debug_paths_reports_home_scoped_locations"] = all(
            str(paths_home) in paths_lines.get(key, "") for key in ("data", "config", "cache", "state")
        )

        xdg_home = harness.make_home("xdg-config-home")
        xdg_config_dir = harness.root / "xdg-config-override"
        xdg_config_dir.mkdir()
        xdg_paths_result = harness.run(
            xdg_home, ["debug", "paths"], extra_env={"XDG_CONFIG_HOME": str(xdg_config_dir)}
        )
        xdg_lines = dict(
            line.split(None, 1) for line in xdg_paths_result.stdout.strip().splitlines() if len(line.split(None, 1)) == 2
        )
        checks["xdg_config_home_overrides_config_location"] = str(xdg_config_dir) in xdg_lines.get("config", "")
        checks["data_cache_state_still_derive_from_home_not_xdg"] = all(
            str(xdg_home) in xdg_lines.get(key, "") for key in ("data", "cache", "state")
        )

        # --- Optional: live model call ---------------------------------------
        live_model_status = "skipped (pass --live-model with provider credentials in env)"
        if options.live_model:
            live_home = harness.make_home("live-model")
            live_content = harness.config_content({"skills": {"paths": [str(harness.skills_a)]}})
            live_result = harness.run(
                live_home,
                [
                    "run",
                    "List the names of every skill available to you, one per line, nothing else.",
                    "--model",
                    options.live_model_id,
                    "--format",
                    "json",
                ],
                extra_env={"MIMOCODE_CONFIG_CONTENT": live_content},
                accepted_codes={0, 1},
            )
            found = "probe-skill-alpha" in live_result.stdout
            checks["live_model_lists_injected_skill"] = found
            live_model_status = "ran" if live_result.returncode == 0 else f"mimo exited {live_result.returncode}"
            if not found:
                notes.append(f"live-model stdout tail: {live_result.stdout[-500:]}")

        failures = [name for name, passed in checks.items() if not passed]
        result = {
            "mimoVersion": version,
            "skillsConfigSupported": checks["mimocode_config_content_accepts_skills_paths"],
            "envVarHonored": "MIMOCODE_CONFIG_CONTENT (OPENCODE_CONFIG_CONTENT is not honored by this fork)",
            "checks": checks,
            "liveModelCheck": live_model_status,
            "notes": notes
            + [
                "All state lived under a temporary HOME (and one temporary XDG_CONFIG_HOME).",
                "Model-visible skill discovery was read from `mimo debug skill`; resolved config from `mimo debug config`.",
                "mimo's config schema is strict: unrecognized top-level keys and wrong field types are hard errors "
                "(exit 1) with field-scoped messages, unlike Codex's silent-ignore-unknown-keys behavior.",
                "Failing checks mean mimo's capability landscape changed since v0.1.9 and this design note should be re-evaluated.",
            ],
        }
        print(json.dumps(result, indent=2, sort_keys=True))
        if failures:
            raise ProbeError(f"failed checks: {', '.join(failures)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ProbeError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        print(f"error: {error}", file=os.sys.stderr)
        raise SystemExit(1)
