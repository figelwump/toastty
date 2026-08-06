#!/usr/bin/env python3
"""Probe Codex and Claude plugin behavior without touching developer state."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Any


PLUGIN_NAME = "toastty-probe"
MARKETPLACE_NAME = "toastty-probe"
SKILL_NAME = "probe-skill"
QUALIFIED_SKILL_NAME = f"{PLUGIN_NAME}:{SKILL_NAME}"
RETIRED_SKILL_NAME = f"{PLUGIN_NAME}:retired-skill"
UNRELATED_SKILL_NAME = "unrelated-probe-skill"


class ProbeError(RuntimeError):
    pass


def run(
    arguments: list[str],
    *,
    environment: dict[str, str],
    timeout: float = 15,
    accepted_codes: set[int] | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        arguments,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    allowed = accepted_codes or {0}
    if result.returncode not in allowed:
        command = " ".join(arguments[:4])
        raise ProbeError(
            f"{command} exited {result.returncode}: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    return result


def json_output(result: subprocess.CompletedProcess[str]) -> Any:
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ProbeError(f"expected JSON output: {error}: {result.stdout!r}") from error


class AppServer:
    def __init__(
        self,
        codex: str,
        environment: dict[str, str],
        working_directory: Path,
        config_overrides: list[str] | None = None,
    ) -> None:
        arguments = [codex]
        for override in config_overrides or []:
            arguments.extend(["-c", override])
        arguments.extend(["app-server", "--listen", "stdio://"])
        self.process = subprocess.Popen(
            arguments,
            cwd=working_directory,
            env=environment,
            text=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=1,
        )
        self.responses: dict[int, dict[str, Any]] = {}
        self.condition = threading.Condition()
        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.reader.start()
        self.next_id = 1
        self.request(
            "initialize",
            {
                "clientInfo": {
                    "name": "toastty-agent-plugin-probe",
                    "title": "Toastty Agent Plugin Probe",
                    "version": "1",
                },
                "capabilities": {"experimentalApi": True},
            },
        )
        self.notify("initialized")

    def _read_stdout(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            identifier = message.get("id")
            if isinstance(identifier, int):
                with self.condition:
                    self.responses[identifier] = message
                    self.condition.notify_all()

    def _send(self, message: dict[str, Any]) -> None:
        if self.process.poll() is not None:
            raise ProbeError("Codex app-server exited unexpectedly")
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def request(self, method: str, params: dict[str, Any]) -> Any:
        identifier = self.next_id
        self.next_id += 1
        self._send({"id": identifier, "method": method, "params": params})
        with self.condition:
            if not self.condition.wait_for(
                lambda: identifier in self.responses or self.process.poll() is not None,
                timeout=10,
            ):
                raise ProbeError(f"Codex app-server timed out for {method}")
            message = self.responses.pop(identifier, None)
        if message is None:
            raise ProbeError(f"Codex app-server exited during {method}")
        if "error" in message:
            raise ProbeError(f"Codex app-server rejected {method}: {message['error']}")
        return message.get("result")

    def notify(self, method: str) -> None:
        self._send({"method": method})

    def close(self) -> None:
        if self.process.stdin is not None:
            self.process.stdin.close()
        try:
            self.process.terminate()
            self.process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=1)

    def __enter__(self) -> AppServer:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def write_plugin(plugin_root: Path, version: str, marker: str) -> None:
    codex_manifest = {
        "name": PLUGIN_NAME,
        "version": version,
        "description": "Isolated Toastty host-capability probe.",
        "author": {"name": "Giant Things"},
        "skills": "./skills/",
        "interface": {
            "displayName": "Toastty Probe",
            "shortDescription": "Probe isolated plugin behavior.",
            "longDescription": "Probe isolated plugin behavior without developer state.",
            "developerName": "Giant Things",
            "category": "Developer Tools",
            "capabilities": ["Interactive"],
            "defaultPrompt": ["Use the probe skill."],
        },
    }
    claude_manifest = {
        "name": PLUGIN_NAME,
        "version": version,
        "description": "Isolated Toastty host-capability probe.",
        "author": {"name": "Giant Things"},
    }
    skill_text = (
        "---\n"
        f"name: {SKILL_NAME}\n"
        "description: Report the isolated Toastty plugin probe marker.\n"
        "---\n\n"
        f"Report this marker exactly: {marker}\n"
    )
    (plugin_root / ".codex-plugin").mkdir(parents=True)
    (plugin_root / ".claude-plugin").mkdir(parents=True)
    (plugin_root / "skills" / SKILL_NAME).mkdir(parents=True)
    (plugin_root / ".codex-plugin" / "plugin.json").write_text(
        json.dumps(codex_manifest, indent=2) + "\n", encoding="utf-8"
    )
    (plugin_root / ".claude-plugin" / "plugin.json").write_text(
        json.dumps(claude_manifest, indent=2) + "\n", encoding="utf-8"
    )
    (plugin_root / "skills" / SKILL_NAME / "SKILL.md").write_text(
        skill_text, encoding="utf-8"
    )


def write_marketplace(marketplace_root: Path) -> None:
    value = {
        "name": MARKETPLACE_NAME,
        "interface": {"displayName": "Toastty Probe"},
        "plugins": [
            {
                "name": PLUGIN_NAME,
                "source": {"source": "local", "path": f"./plugins/{PLUGIN_NAME}"},
                "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
                "category": "Developer Tools",
            }
        ],
    }
    path = marketplace_root / ".agents" / "plugins" / "marketplace.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def recursive_values(value: Any, key: str) -> list[Any]:
    found: list[Any] = []
    if isinstance(value, dict):
        for candidate_key, candidate_value in value.items():
            if candidate_key == key:
                found.append(candidate_value)
            found.extend(recursive_values(candidate_value, key))
    elif isinstance(value, list):
        for item in value:
            found.extend(recursive_values(item, key))
    return found


def skill_state(result: Any, name: str) -> bool | None:
    if not isinstance(result, dict):
        return None
    for entry in result.get("data", []):
        for skill in entry.get("skills", []):
            if skill.get("name") == name:
                enabled = skill.get("enabled")
                return enabled if isinstance(enabled, bool) else None
    return None


def hook_identity(result: Any) -> tuple[str, str] | None:
    if not isinstance(result, dict):
        return None
    for entry in result.get("data", []):
        for hook in entry.get("hooks", []):
            if hook.get("command") == "/usr/bin/true":
                current_hash = hook.get("currentHash")
                trust = hook.get("trustStatus")
                if isinstance(current_hash, str) and isinstance(trust, str):
                    return current_hash, trust
    return None


def main() -> int:
    codex = shutil.which("codex")
    claude = shutil.which("claude")
    if codex is None or claude is None:
        raise ProbeError("both codex and claude must be installed")

    with tempfile.TemporaryDirectory(prefix="toastty-agent-plugin-probe.") as raw_root:
        root = Path(raw_root)
        home = root / "home"
        codex_home = root / "codex-home"
        claude_home = root / "claude-home"
        working_directory = root / "workspace"
        marketplace_root = root / "marketplace"
        versions_root = marketplace_root / "versions"
        source_link = marketplace_root / "plugins" / PLUGIN_NAME
        for directory in (home, codex_home, claude_home, working_directory, source_link.parent):
            directory.mkdir(parents=True, exist_ok=True)

        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(home),
                "CODEX_HOME": str(codex_home),
                "CLAUDE_CONFIG_DIR": str(claude_home),
            }
        )

        version_one = versions_root / "0.1.0" / PLUGIN_NAME
        version_two = versions_root / "0.2.0" / PLUGIN_NAME
        write_plugin(version_one, "0.1.0", "toastty-probe-v1")
        write_plugin(version_two, "0.2.0", "toastty-probe-v2")
        write_marketplace(marketplace_root)
        source_link.symlink_to(version_one)

        config_text = (
            "# toastty-probe-preserve-comment\n"
            "model_reasoning_effort = \"high\"\n"
        )
        (codex_home / "config.toml").write_text(config_text, encoding="utf-8")
        unrelated_skill_root = codex_home / "skills" / UNRELATED_SKILL_NAME
        unrelated_skill_root.mkdir(parents=True)
        (unrelated_skill_root / "SKILL.md").write_text(
            "---\n"
            f"name: {UNRELATED_SKILL_NAME}\n"
            "description: Verify that managed Toastty overrides preserve unrelated skill settings.\n"
            "---\n",
            encoding="utf-8",
        )
        hooks_value = {
            "hooks": {
                "SessionStart": [
                    {
                        "hooks": [
                            {
                                "type": "command",
                                "command": "/usr/bin/true",
                                "timeout": 5,
                                "statusMessage": "Toastty Probe Hook",
                            }
                        ]
                    }
                ]
            }
        }
        (codex_home / "hooks.json").write_text(
            json.dumps(hooks_value, indent=2) + "\n", encoding="utf-8"
        )

        with AppServer(codex, environment, working_directory) as server:
            hooks_before = hook_identity(
                server.request("hooks/list", {"cwds": [str(working_directory)]})
            )
            tombstone = server.request(
                "skills/config/write", {"name": RETIRED_SKILL_NAME, "enabled": False}
            )
            disabled = server.request(
                "skills/config/write", {"name": QUALIFIED_SKILL_NAME, "enabled": False}
            )
            unrelated_disabled = server.request(
                "skills/config/write", {"name": UNRELATED_SKILL_NAME, "enabled": False}
            )
            hooks_after_config = hook_identity(
                server.request("hooks/list", {"cwds": [str(working_directory)]})
            )

        config_after = (codex_home / "config.toml").read_text(encoding="utf-8")
        marketplace_add = json_output(
            run(
                [codex, "plugin", "marketplace", "add", str(marketplace_root), "--json"],
                environment=environment,
            )
        )
        install_one = json_output(
            run(
                [codex, "plugin", "add", f"{PLUGIN_NAME}@{MARKETPLACE_NAME}", "--json"],
                environment=environment,
            )
        )

        with AppServer(codex, environment, working_directory) as server:
            ordinary_state = skill_state(
                server.request(
                    "skills/list",
                    {"cwds": [str(working_directory)], "forceReload": True},
                ),
                QUALIFIED_SKILL_NAME,
            )
            hooks_after_install = hook_identity(
                server.request("hooks/list", {"cwds": [str(working_directory)]})
            )

        override = (
            f'skills.config=[{{name="{QUALIFIED_SKILL_NAME}",enabled=true}}]'
        )
        with AppServer(codex, environment, working_directory, [override]) as server:
            managed_skills = server.request(
                "skills/list",
                {"cwds": [str(working_directory)], "forceReload": True},
            )
            managed_state = skill_state(managed_skills, QUALIFIED_SKILL_NAME)
            managed_unrelated_state = skill_state(managed_skills, UNRELATED_SKILL_NAME)

        replacement = source_link.with_name(f"{PLUGIN_NAME}.next")
        replacement.symlink_to(version_two)
        replacement.replace(source_link)
        install_two = json_output(
            run(
                [codex, "plugin", "add", f"{PLUGIN_NAME}@{MARKETPLACE_NAME}", "--json"],
                environment=environment,
            )
        )
        plugin_list = json_output(
            run([codex, "plugin", "list", "--json"], environment=environment)
        )
        installed_paths = [
            Path(value)
            for value in recursive_values(plugin_list, "installedPath")
            if isinstance(value, str) and PLUGIN_NAME in value
        ]
        installed_paths.extend(
            Path(value)
            for value in recursive_values(install_two, "installedPath")
            if isinstance(value, str) and PLUGIN_NAME in value
        )
        installed_markers = {
            path: (path / "skills" / SKILL_NAME / "SKILL.md").read_text(encoding="utf-8")
            for path in installed_paths
            if (path / "skills" / SKILL_NAME / "SKILL.md").is_file()
        }

        claude_one = root / "claude-one"
        claude_two = root / "claude-two"
        write_plugin(claude_one, "0.1.0", "claude-one")
        write_plugin(claude_two, "0.1.0", "claude-two")
        # Distinct names prove both repeated flag values are parsed independently.
        for plugin_root, name in ((claude_one, "toastty-probe-one"), (claude_two, "toastty-probe-two")):
            manifest_path = plugin_root / ".claude-plugin" / "plugin.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["name"] = name
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            run([claude, "plugin", "validate", "--strict", str(plugin_root)], environment=environment)
        repeated_flags = run(
            [
                claude,
                "--plugin-dir",
                str(claude_one),
                "--plugin-dir",
                str(claude_two),
                "--version",
            ],
            environment=environment,
        )

        checks = {
            "marketplace_registered": MARKETPLACE_NAME
            in recursive_values(marketplace_add, "marketplaceName"),
            "missing_skill_tombstone_disabled": isinstance(tombstone, dict)
            and tombstone.get("effectiveEnabled") is False,
            "bundled_skill_disabled_before_install": isinstance(disabled, dict)
            and disabled.get("effectiveEnabled") is False,
            "unrelated_skill_disabled_before_install": isinstance(unrelated_disabled, dict)
            and unrelated_disabled.get("effectiveEnabled") is False,
            "config_comment_preserved": "# toastty-probe-preserve-comment" in config_after,
            "config_setting_preserved": 'model_reasoning_effort = "high"' in config_after,
            "ordinary_skill_disabled": ordinary_state is False,
            "managed_override_enables_skill": managed_state is True,
            "managed_override_preserves_unrelated_skill_setting": managed_unrelated_state is False,
            "hook_identity_preserved": hooks_before is not None
            and hooks_before == hooks_after_config == hooks_after_install,
            "symlink_source_reinstall_refreshed_bytes": bool(installed_markers)
            and all("toastty-probe-v2" in text for text in installed_markers.values()),
            "claude_manifests_validate": True,
            "claude_repeated_plugin_dirs_parse": repeated_flags.returncode == 0,
        }
        failures = [name for name, passed in checks.items() if not passed]
        result = {
            "codexVersion": run([codex, "--version"], environment=environment).stdout.strip(),
            "claudeVersion": run([claude, "--version"], environment=environment).stdout.strip(),
            "selectedCodexStagingStrategy": "versioned-directories-behind-stable-symlink",
            "checks": checks,
            "notes": [
                "All state lived under a temporary HOME, CODEX_HOME, and CLAUDE_CONFIG_DIR.",
                "Skill discovery and explicit-use eligibility were checked through skills/list; model invocation was intentionally skipped because isolated homes have no authentication.",
                "Claude plugin validation and repeated --plugin-dir parsing were checked locally; official Claude documentation defines both flags as session-only and repeatable.",
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
