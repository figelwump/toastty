#!/usr/bin/env python3
"""Probe whether Codex offers session-scoped plugin/skill delivery.

Answers one architecture question for managed Toastty launches: can a single
Codex process load Toastty-staged skills without persistent, user-visible
writes to Codex-owned global configuration? Every scenario runs against
temporary `HOME` and `CODEX_HOME` directories and reads model-visible skill
discovery from `codex debug prompt-input`, so no authentication or model
request is needed.

Proven mechanism (see the matching evidence document): a Toastty-owned
`<profile>.config.toml` in `CODEX_HOME` that enables a cached plugin, plus
`--profile <name>` on runtime commands, activates the plugin for exactly the
flagged process while overlaying (never replacing) the user's main config.
The plugin cache alone is inert, so ordinary sessions see nothing.

The checks assert the currently proven capability landscape, including the
negative results this design depends on. A failing check means Codex behavior
changed and the session-scoping design should be re-evaluated, not that the
script is broken.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

PROFILE_NAME = "toastty"
MARKETPLACE_NAME = "toastty-probe"
PLUGIN_NAME = "toastty-probe"
PLUGIN_KEY = f"{PLUGIN_NAME}@{MARKETPLACE_NAME}"
PLUGIN_SKILL = "probe-plugin-skill"
PLUGIN_SKILL_V1 = "toastty-plugin-probe-v1"
PLUGIN_SKILL_V2 = "toastty-plugin-probe-v2"
USER_MARKETPLACE_NAME = "user-probe"
USER_PLUGIN_NAME = "user-probe"
USER_PLUGIN_SKILL = "user-plugin-skill"
USER_SKILL = "probe-user-skill"
EXTERNAL_SKILL = "probe-ext-skill"

# Candidate config keys for additive skill discovery roots. Codex silently
# ignores unknown keys but reports a type error for known keys, so probing
# each with a float is a one-way existence test.
CANDIDATE_PATH_KEYS = [
    "skills.paths",
    "skills.roots",
    "skills.dirs",
    "skills.directories",
    "skills.extra_paths",
    "skills.additional_paths",
    "skills.sources",
    "skills.load_paths",
    "plugin_paths",
]

PLUGIN_ENABLED_CONFIG = f'[plugins."{PLUGIN_KEY}"]\nenabled = true\n'
PLUGIN_DISABLED_CONFIG = f'[plugins."{PLUGIN_KEY}"]\nenabled = false\n'
USER_SKILL_DISABLED_LINE = (
    f'skills.config = [{{name = "{USER_SKILL}", enabled = false}}]\n'
)


class ProbeError(RuntimeError):
    pass


def write_skill(root: Path, name: str, description: str) -> None:
    (root / name).mkdir(parents=True)
    (root / name / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: {description}\n---\n\nMarker: {description}\n",
        encoding="utf-8",
    )


def write_plugin_fixture(
    marketplace_root: Path,
    *,
    marketplace_name: str,
    plugin_name: str,
    skill_name: str,
    skill_description: str,
    version: str = "0.1.0",
) -> None:
    plugin_root = marketplace_root / "plugins" / plugin_name
    (plugin_root / ".codex-plugin").mkdir(parents=True)
    manifest = {
        "name": plugin_name,
        "version": version,
        "description": "Isolated session-scoping probe.",
        "author": {"name": "Giant Things"},
        "skills": "./skills/",
        "interface": {
            "displayName": "Toastty Probe",
            "shortDescription": "Probe session-scoped plugin behavior.",
            "longDescription": "Probe session-scoped plugin behavior.",
            "developerName": "Giant Things",
            "category": "Developer Tools",
            "capabilities": ["Interactive"],
            "defaultPrompt": ["Use the probe skill."],
        },
    }
    (plugin_root / ".codex-plugin" / "plugin.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    write_skill(plugin_root / "skills", skill_name, skill_description)
    marketplace = {
        "name": marketplace_name,
        "interface": {"displayName": "Toastty Probe"},
        "plugins": [
            {
                "name": plugin_name,
                "source": {"source": "local", "path": f"./plugins/{plugin_name}"},
                "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
                "category": "Developer Tools",
            }
        ],
    }
    manifest_path = marketplace_root / ".agents" / "plugins" / "marketplace.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(marketplace, indent=2) + "\n", encoding="utf-8")


class Harness:
    def __init__(self, codex: str, root: Path) -> None:
        self.codex = codex
        self.root = root
        self.home = root / "home"
        self.workspace = root / "workspace"
        self.marketplace_root = root / "marketplace"
        self.user_marketplace_root = root / "user-marketplace"
        self.cache_template: Path | None = None
        self.home.mkdir()
        self.workspace.mkdir()
        write_plugin_fixture(
            self.marketplace_root,
            marketplace_name=MARKETPLACE_NAME,
            plugin_name=PLUGIN_NAME,
            skill_name=PLUGIN_SKILL,
            skill_description=PLUGIN_SKILL_V1,
        )
        write_plugin_fixture(
            self.user_marketplace_root,
            marketplace_name=USER_MARKETPLACE_NAME,
            plugin_name=USER_PLUGIN_NAME,
            skill_name=USER_PLUGIN_SKILL,
            skill_description="user-plugin-probe",
        )
        write_skill(self.home / ".agents" / "skills", USER_SKILL, "toastty-user-probe")
        write_skill(root / "external" / "skills", EXTERNAL_SKILL, "toastty-ext-probe")
        self.external_skill_dir = root / "external" / "skills" / EXTERNAL_SKILL

    def environment(self, codex_home: Path) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update({"HOME": str(self.home), "CODEX_HOME": str(codex_home)})
        return environment

    def run_codex(
        self,
        codex_home: Path,
        arguments: list[str],
        *,
        accepted_codes: set[int] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [self.codex, *arguments],
            cwd=self.workspace,
            env=self.environment(codex_home),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
            check=False,
        )
        allowed = accepted_codes or {0}
        if result.returncode not in allowed:
            raise ProbeError(
                f"codex {' '.join(arguments[:4])} exited {result.returncode}: "
                f"{result.stderr.strip() or result.stdout.strip()}"
            )
        return result

    def prompt_input_lists(
        self,
        codex_home: Path,
        needle: str,
        *,
        config_overrides: list[str] | None = None,
        profile: str | None = None,
    ) -> bool:
        arguments: list[str] = []
        if profile is not None:
            arguments.extend(["--profile", profile])
        for override in config_overrides or []:
            arguments.extend(["-c", override])
        arguments.extend(["debug", "prompt-input"])
        result = self.run_codex(codex_home, arguments)
        return needle in result.stdout

    def install_plugin_via_cli(
        self, codex_home: Path, marketplace_root: Path, plugin_key: str
    ) -> None:
        """Install through the supported CLI to obtain a genuine plugin cache."""
        self.run_codex(
            codex_home,
            ["plugin", "marketplace", "add", str(marketplace_root), "--json"],
        )
        self.run_codex(codex_home, ["plugin", "add", plugin_key, "--json"])

    def prepare_cache_template(self) -> Path:
        codex_home = self.root / "codex-home-installer"
        codex_home.mkdir()
        self.install_plugin_via_cli(codex_home, self.marketplace_root, PLUGIN_KEY)
        cache = codex_home / "plugins" / "cache"
        if not (cache / MARKETPLACE_NAME / PLUGIN_NAME).is_dir():
            raise ProbeError(f"plugin cache missing under {cache}")
        self.cache_template = cache
        return codex_home

    def scenario_home(
        self,
        name: str,
        *,
        with_cache: bool,
        config: str | None,
        profile_config: str | None = None,
    ) -> Path:
        codex_home = self.root / f"codex-home-{name}"
        codex_home.mkdir()
        if with_cache:
            if self.cache_template is None:
                raise ProbeError("plugin cache template not prepared")
            shutil.copytree(self.cache_template, codex_home / "plugins" / "cache")
        if config is not None:
            (codex_home / "config.toml").write_text(config, encoding="utf-8")
        if profile_config is not None:
            (codex_home / f"{PROFILE_NAME}.config.toml").write_text(
                profile_config, encoding="utf-8"
            )
        return codex_home


def probe_path_key_existence(harness: Harness, empty_home: Path) -> dict[str, bool]:
    recognized: dict[str, bool] = {}
    for key in CANDIDATE_PATH_KEYS:
        result = harness.run_codex(
            empty_home,
            ["-c", f"{key}=3.14159", "debug", "prompt-input"],
            accepted_codes={0, 1},
        )
        recognized[key] = "invalid type" in result.stderr
    return recognized


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--codex",
        default=os.environ.get("CODEX_BIN") or shutil.which("codex"),
        help="Path to the real codex binary (avoid Toastty-managed shims).",
    )
    options = parser.parse_args()
    if not options.codex:
        raise ProbeError("codex must be installed or passed via --codex/CODEX_BIN")

    with tempfile.TemporaryDirectory(prefix="toastty-session-skills-probe.") as raw_root:
        harness = Harness(options.codex, Path(raw_root))
        source = str(harness.marketplace_root)
        installer_home = harness.prepare_cache_template()

        empty = harness.scenario_home("empty", with_cache=False, config=None)
        recognized_keys = probe_path_key_existence(harness, empty)

        map_override = [
            f'marketplaces={{{MARKETPLACE_NAME}={{source_type="local",source="{source}"}}}}',
            f'plugins={{"{PLUGIN_KEY}"={{enabled=true}}}}',
        ]
        dotted_override = [
            f'marketplaces.{MARKETPLACE_NAME}.source_type="local"',
            f'marketplaces.{MARKETPLACE_NAME}.source="{source}"',
            f'plugins."{PLUGIN_KEY}".enabled=true',
        ]
        marketplace_and_plugin_config = (
            f"[marketplaces.{MARKETPLACE_NAME}]\n"
            'source_type = "local"\n'
            f'source = "{source}"\n\n' + PLUGIN_ENABLED_CONFIG
        )
        skill_md_path = harness.external_skill_dir / "SKILL.md"

        cache_profile = harness.scenario_home(
            "cache-profile",
            with_cache=True,
            config=None,
            profile_config=PLUGIN_ENABLED_CONFIG,
        )
        file_full = harness.scenario_home(
            "file-full", with_cache=True, config=marketplace_and_plugin_config
        )
        file_minimal = harness.scenario_home(
            "file-minimal", with_cache=True, config=PLUGIN_ENABLED_CONFIG
        )
        file_disabled = harness.scenario_home(
            "file-disabled", with_cache=True, config=PLUGIN_DISABLED_CONFIG
        )

        # Overlay scenario: the user's own CLI-installed plugin and root-level
        # skill disables live in the main config; Toastty's plugin arrives only
        # through the profile file and cache.
        overlay = harness.scenario_home(
            "overlay",
            with_cache=True,
            config=USER_SKILL_DISABLED_LINE,
            profile_config=PLUGIN_ENABLED_CONFIG,
        )
        harness.install_plugin_via_cli(
            overlay,
            harness.user_marketplace_root,
            f"{USER_PLUGIN_NAME}@{USER_MARKETPLACE_NAME}",
        )

        profile_on_management_command = harness.run_codex(
            cache_profile,
            [
                "--profile",
                PROFILE_NAME,
                "plugin",
                "marketplace",
                "add",
                source,
                "--json",
            ],
            accepted_codes={0, 1, 2},
        )
        duplicate_profile = harness.run_codex(
            cache_profile,
            ["--profile", "aaa", "--profile", PROFILE_NAME, "debug", "prompt-input"],
            accepted_codes={0, 1, 2},
        )

        checks = {
            # Controls proving the harness observes skill discovery at all.
            "prompt_input_lists_user_scope_agents_skill": harness.prompt_input_lists(
                empty, USER_SKILL
            ),
            "cli_installed_home_lists_plugin_skill": harness.prompt_input_lists(
                installer_home, PLUGIN_SKILL
            ),
            # No additive skill-path mechanism exists outside plugins.
            "no_recognized_skills_path_config_keys": not any(recognized_keys.values()),
            "skills_config_path_entry_does_not_load_external_skill_md": not harness.prompt_input_lists(
                empty,
                EXTERNAL_SKILL,
                config_overrides=[
                    f'skills.config=[{{path="{skill_md_path}",enabled=true}}]'
                ],
            ),
            "skills_config_path_entry_does_not_load_external_skill_dir": not harness.prompt_input_lists(
                empty,
                EXTERNAL_SKILL,
                config_overrides=[
                    f'skills.config=[{{path="{harness.external_skill_dir}",enabled=true}}]'
                ],
            ),
            # Plugin activation is file-driven; inline overrides are inert.
            "plugin_cache_alone_stays_inert": not harness.prompt_input_lists(
                cache_profile, PLUGIN_SKILL
            ),
            "config_file_with_cache_loads_plugin_skill": harness.prompt_input_lists(
                file_full, PLUGIN_SKILL
            ),
            "marketplace_entry_not_required_for_loading": harness.prompt_input_lists(
                file_minimal, PLUGIN_SKILL
            ),
            "inline_map_override_does_not_activate_plugin": not harness.prompt_input_lists(
                cache_profile, PLUGIN_SKILL, config_overrides=map_override
            ),
            "inline_dotted_override_does_not_activate_plugin": not harness.prompt_input_lists(
                cache_profile, PLUGIN_SKILL, config_overrides=dotted_override
            ),
            "plugin_disabled_in_config_hides_skills_entirely": not harness.prompt_input_lists(
                file_disabled, PLUGIN_SKILL
            ),
            "inline_override_cannot_enable_disabled_plugin": not harness.prompt_input_lists(
                file_disabled,
                PLUGIN_SKILL,
                config_overrides=[f'plugins."{PLUGIN_KEY}".enabled=true'],
            ),
            "inline_override_cannot_disable_enabled_plugin": harness.prompt_input_lists(
                file_minimal,
                PLUGIN_SKILL,
                config_overrides=[f'plugins."{PLUGIN_KEY}".enabled=false'],
            ),
            "skills_config_cannot_enable_skill_of_disabled_plugin": not harness.prompt_input_lists(
                file_disabled,
                PLUGIN_SKILL,
                config_overrides=[
                    f'skills.config=[{{name="{PLUGIN_NAME}:{PLUGIN_SKILL}",enabled=true}}]'
                ],
            ),
            # The session-scoped mechanism: profile config file plus --profile.
            "profile_file_activates_plugin_for_flagged_process": harness.prompt_input_lists(
                cache_profile, PLUGIN_SKILL, profile=PROFILE_NAME
            ),
            "profile_file_inert_without_flag": not harness.prompt_input_lists(
                cache_profile, PLUGIN_SKILL
            ),
            "user_scope_skill_still_discovered_under_profile": harness.prompt_input_lists(
                cache_profile, USER_SKILL, profile=PROFILE_NAME
            ),
            "profile_overlays_user_plugin_from_main_config": harness.prompt_input_lists(
                overlay, USER_PLUGIN_SKILL, profile=PROFILE_NAME
            ),
            "profile_activates_toastty_plugin_in_overlay_home": harness.prompt_input_lists(
                overlay, PLUGIN_SKILL, profile=PROFILE_NAME
            ),
            "profile_preserves_main_config_skill_disable": not harness.prompt_input_lists(
                overlay, USER_SKILL, profile=PROFILE_NAME
            ),
            "overlay_home_hides_toastty_plugin_without_flag": not harness.prompt_input_lists(
                overlay, PLUGIN_SKILL
            ),
            # Launch-shape and lifecycle constraints the integration must handle.
            "duplicate_profile_flags_rejected": duplicate_profile.returncode != 0
            and "cannot be used multiple times" in duplicate_profile.stderr,
            "profile_rejected_on_plugin_management_commands": (
                "only applies to runtime commands"
                in (
                    profile_on_management_command.stderr
                    + profile_on_management_command.stdout
                )
            ),
        }

        # Refreshing the plugin through the supported CLI replaces the cached
        # version instead of accumulating versions. Runs last because earlier
        # scenarios copied the v1 cache template.
        shutil.rmtree(harness.marketplace_root / "plugins" / PLUGIN_NAME)
        write_plugin_fixture(
            harness.marketplace_root,
            marketplace_name=MARKETPLACE_NAME,
            plugin_name=PLUGIN_NAME,
            skill_name=PLUGIN_SKILL,
            skill_description=PLUGIN_SKILL_V2,
            version="0.2.0",
        )
        harness.run_codex(installer_home, ["plugin", "add", PLUGIN_KEY, "--json"])
        cached_versions = sorted(
            entry.name
            for entry in (
                installer_home / "plugins" / "cache" / MARKETPLACE_NAME / PLUGIN_NAME
            ).iterdir()
            if entry.is_dir()
        )
        checks["plugin_refresh_replaces_cached_version"] = cached_versions == [
            "0.2.0"
        ] and harness.prompt_input_lists(installer_home, PLUGIN_SKILL_V2)

        failures = [name for name, passed in checks.items() if not passed]
        result = {
            "codexVersion": harness.run_codex(empty, ["--version"]).stdout.strip(),
            "sessionScopedDeliveryAvailable": True,
            "sessionScopedMechanism": (
                f"CODEX_HOME/{PROFILE_NAME}.config.toml plugin enablement plus "
                f"--profile {PROFILE_NAME} on runtime commands"
            ),
            "checks": checks,
            "recognizedPathKeys": recognized_keys,
            "notes": [
                "All state lived under a temporary HOME and CODEX_HOME.",
                "Model-visible skill discovery was read from `codex debug prompt-input`; no authentication or model request was made.",
                "Failing checks mean the Codex capability landscape changed and the session-scoping design should be re-evaluated.",
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
