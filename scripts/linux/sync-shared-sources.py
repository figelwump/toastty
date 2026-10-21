#!/usr/bin/env python3
"""Mirror shared macOS Swift sources into linux/.generated for the Linux build.

The macOS sources stay the single source of truth. Each mirrored file keeps
its line layout and starts with a #sourceLocation directive, so compiler
diagnostics point at the original file under Sources/ or Tests/. Only import
lines and Darwin-qualified names are rewritten; behavioral differences belong
in Linux shim modules or in guarded code in the original file.

Manifest (linux/shared-sources.json), per target:
  "source":          directory under the repo root (Sources/... or Tests/...)
  "include":         optional list of files relative to source (default: all *.swift)
  "exclude":         optional list of files or directory prefixes to skip
  "implicitImports": optional Linux-only modules every mirrored file imports
                     (e.g. ToasttyFoundationShim, FoundationNetworking)
  "importRewrites":  optional per-target module renames, merged over the global
                     table, e.g. {"ToasttyApp": ["ToasttyAppLogic"]} so tests'
                     `@testable import ToasttyApp` reaches the Linux module
  "extraSources":    optional extra directories or files (relative to the repo
                     root) mirrored the same way: a directory such as
                     linux/Sources/ToasttyAppLogic lands in
                     <Target>/_linux/<dir name>/ (Linux replacements that must
                     share the module), a single file such as a shared test
                     fixture from another tree lands in <Target>/_extra/

  "textRewrites":    optional [from, to] literal replacements applied to every
                     line (e.g. Darwin's `st_mtimespec` -> Glibc's `st_mtim`);
                     use only for same-meaning spellings
  "darwinQualifier": optional module that replaces `Darwin.` in qualified
                     names (default Glibc). A shim module that re-exports
                     Glibc can add Darwin-only functions (e.g. removexattr's
                     three-argument form) without touching shared code.

Dotted imports (`import Carbon.HIToolbox`, `import CoreImage.CIFilterBuiltins`)
are rewritten by their top-level module.

Mirrors are named Foo.mirror.swift (main.swift keeps its name) so their own
#fileID does not collide with the one #sourceLocation produces. Tests that
locate fixtures with #filePath keep resolving against the original tree.

Usage: scripts/linux/sync-shared-sources.py [--check]
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GENERATED = ROOT / "linux" / ".generated"
MANIFEST = ROOT / "linux" / "shared-sources.json"

# import <Apple module>  ->  replacement import line(s), joined with "; " so
# the mirrored file keeps the original line numbering.
IMPORT_REWRITES = {
    "Darwin": ["Glibc"],
    "CryptoKit": ["Crypto"],
    "Combine": ["OpenCombine", "OpenCombineFoundation", "OpenCombineDispatch"],
    "CoreGraphics": ["Foundation"],
    "AppKit": ["ToasttyAppKitShim"],
    "Carbon": ["ToasttyAppKitShim"],
    "CoreVideo": ["ToasttyAppKitShim"],
    "CoreImage": ["ToasttyAppKitShim"],
    "UniformTypeIdentifiers": ["ToasttyAppKitShim"],
    "UserNotifications": ["ToasttyAppKitShim"],
    "Network": ["ToasttyNetworkShim"],
    "WebKit": ["ToasttyWebKitShim"],
    "Sparkle": ["ToasttyAppKitShim"],
}

IMPORT_RE = re.compile(
    r"^(?P<indent>\s*)(?P<attrs>(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*)import\s+(?P<module>[A-Za-z_][A-Za-z0-9_]*)(?P<submodule>(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*$"
)
DARWIN_QUALIFIED_RE = re.compile(r"\bDarwin\.")


def rewrite_line(line: str, rewrites: dict[str, list[str]], darwin_qualifier: str = "Glibc") -> str:
    match = IMPORT_RE.match(line.rstrip("\n"))
    if match:
        module = match.group("module")
        replacements = rewrites.get(module)
        if replacements is not None:
            indent = match.group("indent")
            attrs = match.group("attrs")
            return indent + "; ".join(f"{attrs}import {name}" for name in replacements) + "\n"
        return line
    return DARWIN_QUALIFIED_RE.sub(darwin_qualifier + ".", line)


def mirrored_text(
    source: Path,
    implicit_imports: list[str],
    rewrites: dict[str, list[str]] = IMPORT_REWRITES,
    darwin_qualifier: str = "Glibc",
    text_rewrites: list[list[str]] | None = None,
) -> str:
    text = source.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines = [rewrite_line(line, rewrites, darwin_qualifier) for line in lines]
    for old, new in text_rewrites or []:
        lines = [line.replace(old, new) for line in lines]
    if implicit_imports:
        add_implicit_imports(lines, implicit_imports)
    header = f'#sourceLocation(file: "{source}", line: 1)\n'
    return header + "".join(lines)


def add_implicit_imports(lines: list[str], modules: list[str]) -> None:
    """Import Linux-only companion modules (e.g. ToasttyFoundationShim).

    They join the first top-level import line so line numbers stay intact and
    nothing precedes #sourceLocation (code outside the directive would give
    the mirror its own conflicting #fileID).
    """
    extra = "; ".join(f"import {name}" for name in modules)
    depth = 0  # skip imports inside #if blocks; they may be inactive on Linux
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("#if"):
            depth += 1
        elif stripped.startswith("#endif"):
            depth -= 1
        match = IMPORT_RE.match(line.rstrip("\n"))
        if depth == 0 and match and not match.group("indent"):
            lines[index] = line.rstrip("\n") + "; " + extra + "\n"
            return
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped and not stripped.startswith(("//", "/*", "*", "#")):
            lines[index] = extra + "; " + line
            return
    lines.insert(0, extra + "\n")


def mirrored_relative_path(relative: Path) -> Path:
    """Mirror name for a shared file.

    `Foo.swift` becomes `Foo.mirror.swift`: if the mirror kept the original
    basename, its own #fileID would equal the one #sourceLocation produces,
    and swiftc warns about the conflict for every file. `main.swift` keeps its
    name because SwiftPM only allows top-level code there.
    """
    if relative.name == "main.swift" or relative.suffix != ".swift":
        return relative
    return relative.with_name(relative.stem + ".mirror.swift")


def load_manifest() -> dict:
    with MANIFEST.open(encoding="utf-8") as handle:
        return json.load(handle)


def selected_files(entry: dict) -> list[Path]:
    base = ROOT / entry["source"]
    excludes = set(entry.get("exclude", []))
    includes = entry.get("include")
    if includes is not None:
        candidates = [base / rel for rel in includes]
    else:
        candidates = sorted(base.rglob("*.swift"))
    files = []
    for path in candidates:
        rel = path.relative_to(base).as_posix()
        if rel in excludes or any(rel.startswith(prefix.rstrip("/") + "/") for prefix in excludes):
            continue
        if not path.is_file():
            raise SystemExit(f"shared-sources.json: missing {path}")
        files.append(path)
    return files


def sync(check_only: bool) -> int:
    manifest = load_manifest()
    expected: set[Path] = set()
    changed = 0
    for target, entry in manifest["targets"].items():
        base = ROOT / entry["source"]
        rewrites = {**IMPORT_REWRITES, **entry.get("importRewrites", {})}
        mirrored = [
            (source, GENERATED / target / mirrored_relative_path(source.relative_to(base)))
            for source in selected_files(entry)
        ]
        for extra in entry.get("extraSources", []):
            extra_base = ROOT / extra
            if extra_base.is_file():
                relative = Path("_extra") / extra_base.parent.name / extra_base.name
                mirrored.append((extra_base, GENERATED / target / mirrored_relative_path(relative)))
                continue
            if not extra_base.is_dir():
                raise SystemExit(f"shared-sources.json: missing {extra_base}")
            for source in sorted(extra_base.rglob("*.swift")):
                relative = Path("_linux") / extra_base.name / source.relative_to(extra_base)
                mirrored.append((source, GENERATED / target / mirrored_relative_path(relative)))
        for source, destination in mirrored:
            expected.add(destination)
            text = mirrored_text(
                source,
                entry.get("implicitImports", []),
                rewrites,
                entry.get("darwinQualifier", "Glibc"),
                entry.get("textRewrites"),
            )
            if destination.exists() and destination.read_text(encoding="utf-8") == text:
                continue
            changed += 1
            if check_only:
                print(f"stale: {destination.relative_to(ROOT)}")
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(text, encoding="utf-8")
    for target in manifest["targets"]:
        target_dir = GENERATED / target
        if not target_dir.exists():
            continue
        for path in target_dir.rglob("*.swift"):
            if path not in expected:
                changed += 1
                if check_only:
                    print(f"orphan: {path.relative_to(ROOT)}")
                else:
                    path.unlink()
    if check_only:
        return 1 if changed else 0
    if changed:
        print(f"sync-shared-sources: updated {changed} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(sync("--check" in sys.argv[1:]))
