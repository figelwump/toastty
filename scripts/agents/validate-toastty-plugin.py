#!/usr/bin/env python3
"""Validate the repo-owned Toastty agent plugin and its bundled copy."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


EXPECTED_SKILLS = [
    "toastty-capabilities",
    "toastty-open-markdown",
    "toastty-read-terminal",
    "toastty-scratchpad",
    "toastty-send-diagnostics",
    "worktree-create",
]

EXPECTED_CURSOR_HOOKS = [
    "sessionStart",
    "beforeSubmitPrompt",
    "preToolUse",
    "postToolUseFailure",
    "stop",
    "sessionEnd",
]
EXPECTED_CURSOR_HOOK_COMMANDS = {
    hook_name: f'"${{CURSOR_PLUGIN_ROOT}}/cursor-hooks/forwarder.sh" {hook_name}'
    for hook_name in EXPECTED_CURSOR_HOOKS
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
    )
    parser.add_argument(
        "--bundle-resources",
        type=Path,
        help="Optional path to Toastty.app/Contents/Resources for byte-for-byte validation.",
    )
    parser.add_argument(
        "--marketplace-root",
        type=Path,
        help="Validate a copied marketplace root instead of the repository sources.",
    )
    return parser.parse_args()


def load_json(path: Path, errors: list[str]) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"unable to read JSON at {path}: {error}")
        return {}
    if not isinstance(value, dict):
        errors.append(f"expected a JSON object at {path}")
        return {}
    return value


def frontmatter_name(path: Path, errors: list[str]) -> str | None:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        errors.append(f"unable to read {path}: {error}")
        return None
    match = re.match(r"\A---\s*\n(.*?)\n---(?:\s*\n|\Z)", text, re.DOTALL)
    if match is None:
        errors.append(f"missing YAML frontmatter in {path}")
        return None
    name = re.search(r"^name:\s*([^\s]+)\s*$", match.group(1), re.MULTILINE)
    if name is None:
        errors.append(f"missing frontmatter name in {path}")
        return None
    return name.group(1)


def relative_files(root: Path) -> list[Path]:
    return sorted(
        path.relative_to(root)
        for path in root.rglob("*")
        if path.is_file()
    )


def validate_plugin(marketplace_path: Path, plugin_root: Path, errors: list[str]) -> None:
    codex_manifest_path = plugin_root / ".codex-plugin" / "plugin.json"
    claude_manifest_path = plugin_root / ".claude-plugin" / "plugin.json"
    cursor_manifest_path = plugin_root / ".cursor-plugin" / "plugin.json"
    cursor_hooks_path = plugin_root / "cursor-hooks" / "hooks.json"
    cursor_forwarder_path = plugin_root / "cursor-hooks" / "forwarder.sh"
    # Codex and Claude discover this path even without a manifest hooks entry.
    if (plugin_root / "hooks" / "hooks.json").exists():
        errors.append("skills-only hosts must not discover a default hooks/hooks.json")
    skills_root = plugin_root / "skills"

    marketplace = load_json(marketplace_path, errors)
    expected_entry = {
        "name": "toastty",
        "source": {"source": "local", "path": "./plugins/toastty"},
        "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
        "category": "Developer Tools",
    }
    if marketplace.get("name") != "toastty":
        errors.append("marketplace name must be exactly `toastty`")
    if marketplace.get("plugins") != [expected_entry]:
        errors.append("marketplace must contain only the exact Toastty plugin entry")

    codex_manifest = load_json(codex_manifest_path, errors)
    claude_manifest = load_json(claude_manifest_path, errors)
    cursor_manifest = load_json(cursor_manifest_path, errors)
    if codex_manifest.get("name") != "toastty":
        errors.append("Codex plugin manifest name must be exactly `toastty`")
    if claude_manifest.get("name") != "toastty":
        errors.append("Claude plugin manifest name must be exactly `toastty`")
    if cursor_manifest.get("name") != "toastty":
        errors.append("Cursor plugin manifest name must be exactly `toastty`")
    manifest_versions = {
        codex_manifest.get("version"),
        claude_manifest.get("version"),
        cursor_manifest.get("version"),
    }
    if None in manifest_versions or len(manifest_versions) != 1:
        errors.append("Codex, Claude, and Cursor plugin manifest versions must match")
    if codex_manifest.get("skills") != "./skills/":
        errors.append("Codex plugin manifest skills path must be `./skills/`")
    if cursor_manifest.get("skills") != "./skills/":
        errors.append("Cursor plugin manifest skills path must be `./skills/`")
    if cursor_manifest.get("hooks") != "./cursor-hooks/hooks.json":
        errors.append("Cursor plugin manifest hooks path must be `./cursor-hooks/hooks.json`")
    for host, manifest in (("Codex", codex_manifest), ("Claude", claude_manifest)):
        forbidden_components = sorted(
            {"agents", "apps", "hooks", "mcpServers", "commands"}.intersection(manifest)
        )
        if forbidden_components:
            errors.append(
                f"{host} skills-only manifest declares forbidden components: {forbidden_components}"
            )

    cursor_hooks = load_json(cursor_hooks_path, errors)
    if cursor_hooks.get("version") != 1:
        errors.append("Cursor hooks config version must be exactly `1`")
    hook_definitions = cursor_hooks.get("hooks")
    if not isinstance(hook_definitions, dict):
        errors.append("Cursor hooks config must contain a `hooks` object")
        hook_definitions = {}
    if sorted(hook_definitions) != sorted(EXPECTED_CURSOR_HOOKS):
        errors.append(
            f"Cursor hook allowlist mismatch: found {sorted(hook_definitions)}"
        )
    for hook_name in EXPECTED_CURSOR_HOOKS:
        entries = hook_definitions.get(hook_name)
        if not isinstance(entries, list) or len(entries) != 1 or not isinstance(entries[0], dict):
            errors.append(f"Cursor hook {hook_name} must contain exactly one command definition")
            continue
        definition = entries[0]
        if definition.get("command") != EXPECTED_CURSOR_HOOK_COMMANDS[hook_name]:
            errors.append(
                f"Cursor hook {hook_name} must invoke the plugin-root forwarder "
                "with its event name"
            )
        timeout = definition.get("timeout")
        if (
            isinstance(timeout, bool)
            or not isinstance(timeout, (int, float))
            or timeout <= 0
            or timeout > 2
        ):
            errors.append(f"Cursor hook {hook_name} timeout must be at most 2 seconds")
        if definition.get("failClosed") is not False:
            errors.append(f"Cursor hook {hook_name} must explicitly fail open")

    try:
        if cursor_forwarder_path.stat().st_mode & 0o111 == 0:
            errors.append(f"Cursor hook forwarder is not executable: {cursor_forwarder_path}")
    except OSError as error:
        errors.append(f"unable to inspect Cursor hook forwarder at {cursor_forwarder_path}: {error}")

    try:
        top_level_entries = sorted(path.name for path in plugin_root.iterdir())
    except OSError as error:
        errors.append(f"unable to enumerate {plugin_root}: {error}")
        return
    if top_level_entries != [
        ".claude-plugin",
        ".codex-plugin",
        ".cursor-plugin",
        "cursor-hooks",
        "skills",
    ]:
        errors.append(f"plugin top-level allowlist mismatch: found {top_level_entries}")
    unexpected_metadata = sorted(
        path.relative_to(plugin_root).as_posix()
        for path in plugin_root.rglob(".DS_Store")
    )
    if unexpected_metadata:
        errors.append(f"plugin contains Finder metadata: {unexpected_metadata}")

    # The app's plugin reader rejects any symlink inside the bundle, so catch
    # one here before it ships (a stray link inside a skill folder breaks skill
    # delivery for every managed agent at runtime).
    symlinks = sorted(
        path.relative_to(plugin_root).as_posix()
        for path in plugin_root.rglob("*")
        if path.is_symlink()
    )
    if symlinks:
        errors.append(f"plugin contains symbolic links: {symlinks}")

    try:
        skill_names = sorted(path.name for path in skills_root.iterdir() if path.is_dir())
    except OSError as error:
        errors.append(f"unable to enumerate {skills_root}: {error}")
        return
    if skill_names != EXPECTED_SKILLS:
        errors.append(f"plugin skill allowlist mismatch: found {skill_names}")

    helper_references = {
        "toastty-open-markdown": [
            '$TOASTTY_SKILLS_ROOT/toastty-open-markdown/scripts/open-markdown-file.sh'
        ],
        "toastty-scratchpad": [
            '$TOASTTY_SKILLS_ROOT/toastty-scratchpad/scripts/publish-scratchpad-outline.sh',
            '$TOASTTY_SKILLS_ROOT/toastty-scratchpad/scripts/publish-scratchpad-html.sh',
        ],
        "worktree-create": [
            '$TOASTTY_SKILLS_ROOT/worktree-create/scripts/create-worktree.sh',
            '$TOASTTY_SKILLS_ROOT/worktree-create/scripts/open-toastty-worktree-session.sh',
        ],
    }
    skills_requiring_managed_root = {
        "toastty-open-markdown",
        "toastty-scratchpad",
        "worktree-create",
    }
    for skill_name in EXPECTED_SKILLS:
        skill_path = skills_root / skill_name / "SKILL.md"
        if frontmatter_name(skill_path, errors) != skill_name:
            errors.append(f"skill directory and frontmatter name differ for {skill_name}")
        try:
            skill_text = skill_path.read_text(encoding="utf-8")
        except OSError:
            continue
        if skill_name == "toastty-capabilities":
            description = re.search(r"^description:\s*(.+)$", skill_text, re.MULTILINE)
            if (
                description is None
                or "toastty workspace annotations" not in description.group(1).lower()
            ):
                errors.append(
                    "toastty-capabilities description must route Toastty workspace annotations"
                )
        if skill_name in skills_requiring_managed_root:
            if "TOASTTY_SKILLS_ROOT" not in skill_text:
                errors.append(f"{skill_name} does not require TOASTTY_SKILLS_ROOT")
            if '${TOASTTY_SKILLS_ROOT:-}' not in skill_text:
                errors.append(f"{skill_name} lacks an explicit unset-root guard")
            if f'$TOASTTY_SKILLS_ROOT/{skill_name}' not in skill_text:
                errors.append(f"{skill_name} does not verify its directory under the managed root")
        if "must run inside a Toastty-managed agent session" not in skill_text:
            errors.append(f"{skill_name} lacks the run-inside-Toastty error")
        if re.search(r"(?:~?/)?\.agents/skills/[^\s`]+/scripts/", skill_text):
            errors.append(f"{skill_name} still invokes a repo/global .agents helper path")
        for reference in helper_references.get(skill_name, []):
            if reference not in skill_text:
                errors.append(f"{skill_name} is missing helper reference {reference}")

    for script_path in sorted(skills_root.glob("*/scripts/*.sh")):
        try:
            executable = script_path.stat().st_mode & 0o111
        except OSError as error:
            errors.append(f"unable to inspect helper mode at {script_path}: {error}")
            continue
        if executable == 0:
            errors.append(f"plugin helper is not executable: {script_path}")


def validate_repo_layout(repo_root: Path, errors: list[str]) -> None:
    canonical_root = repo_root / "plugins" / "toastty" / "skills"
    compatibility_root = repo_root / ".agents" / "skills"
    for skill_name in EXPECTED_SKILLS:
        compatibility_path = compatibility_root / skill_name
        canonical_path = canonical_root / skill_name
        if not compatibility_path.is_symlink():
            errors.append(f"compatibility path is not a symlink: {compatibility_path}")
            continue
        expected_target = Path("../../plugins/toastty/skills") / skill_name
        if compatibility_path.readlink() != expected_target:
            errors.append(
                f"compatibility link must use literal target {expected_target}: {compatibility_path}"
            )
        if compatibility_path.resolve() != canonical_path.resolve():
            errors.append(f"compatibility link does not resolve to canonical skill: {compatibility_path}")

    worktree_done_path = compatibility_root / "worktree-done"
    if worktree_done_path.is_symlink() or not (worktree_done_path / "SKILL.md").is_file():
        errors.append("worktree-done must be a real repo-local skill directory")
    if (canonical_root / "worktree-done").exists():
        errors.append("worktree-done must not be present in the shared plugin")

    link_script = (repo_root / "scripts" / "agents" / "link-global-skills.sh").read_text(
        encoding="utf-8"
    )
    if "codex" in re.findall(r"agents\|claude\|([a-z]+)", link_script):
        errors.append("global skill linker still exposes a Codex target")
    if ".codex/skills" in link_script:
        errors.append("global skill linker still writes to ~/.codex/skills")
    for skill_name in EXPECTED_SKILLS:
        if f'"{skill_name}"' not in link_script:
            errors.append(f"global skill linker omits {skill_name}")
    if 'fail "--target is required for development links"' not in link_script:
        errors.append("global skill linker must require an explicit development target")
    if '"worktree-done"' in link_script:
        errors.append("global skill linker must not expose repo-local worktree-done")

    project_text = (repo_root / "Project.swift").read_text(encoding="utf-8")
    resource_markers = [
        'subpath: "ToasttyAgentPluginBundle/.agents/plugins"',
        'files: [".agents/plugins/marketplace.json"]',
        'subpath: "ToasttyAgentPluginBundle/plugins"',
        'files: [.folderReference(path: "plugins/toastty")]',
    ]
    for marker in resource_markers:
        if project_text.count(marker) != 1:
            errors.append(f"Project.swift must contain exactly one resource marker: {marker}")


def validate_bundled_copy(repo_root: Path, resources_root: Path, errors: list[str]) -> None:
    source_marketplace = repo_root / ".agents" / "plugins" / "marketplace.json"
    source_plugin = repo_root / "plugins" / "toastty"
    bundled_root = resources_root / "ToasttyAgentPluginBundle"
    bundled_marketplace = bundled_root / ".agents" / "plugins" / "marketplace.json"
    bundled_plugin = bundled_root / "plugins" / "toastty"

    validate_plugin(bundled_marketplace, bundled_plugin, errors)
    if bundled_marketplace.is_file() and source_marketplace.read_bytes() != bundled_marketplace.read_bytes():
        errors.append("bundled marketplace.json differs from the repository source")

    source_files = relative_files(source_plugin)
    bundled_files = relative_files(bundled_plugin) if bundled_plugin.is_dir() else []
    if bundled_files != source_files:
        errors.append("bundled plugin file allowlist differs from the repository source")
        return
    for relative_path in source_files:
        if (source_plugin / relative_path).read_bytes() != (bundled_plugin / relative_path).read_bytes():
            errors.append(f"bundled plugin file differs: {relative_path}")


def main() -> int:
    arguments = parse_args()
    repo_root = arguments.repo_root.resolve()
    errors: list[str] = []

    if arguments.marketplace_root is not None:
        copied_root = arguments.marketplace_root.resolve()
        validate_plugin(
            copied_root / ".agents" / "plugins" / "marketplace.json",
            copied_root / "plugins" / "toastty",
            errors,
        )
    else:
        validate_plugin(
            repo_root / ".agents" / "plugins" / "marketplace.json",
            repo_root / "plugins" / "toastty",
            errors,
        )
        validate_repo_layout(repo_root, errors)

    if arguments.bundle_resources is not None:
        validate_bundled_copy(repo_root, arguments.bundle_resources.resolve(), errors)

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print("Toastty three-host plugin validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
