#!/usr/bin/env python3
"""Write linux/.shared-only/Package.swift: the shared-core subset of linux/Package.swift.

With `--with-app-logic`, writes linux/.app-logic-only/ instead, holding the
shared-core and app-logic blocks (`// MARK: app-logic` ... `// MARK: end app-logic`).

Keeps shared modules and their tests buildable while frontend targets in the
full package are mid-change. The subset is the text between
"// MARK: shared-core" and "// MARK: end shared-core" in linux/Package.swift;
sources are reached through symlinks, so nothing is copied. Prints the
package directory.
"""

from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LINUX = ROOT / "linux"


def block(manifest: str, name: str) -> str:
    start = manifest.index(f"        // MARK: {name}")
    end = manifest.index(f"        // MARK: end {name}")
    return manifest[start:end]


def main() -> None:
    import sys

    with_app_logic = "--with-app-logic" in sys.argv[1:]
    OUT = LINUX / (".app-logic-only" if with_app_logic else ".shared-only")
    manifest = (LINUX / "Package.swift").read_text(encoding="utf-8")
    header = manifest[: manifest.index("    products:")]
    dependencies = manifest[manifest.index("    dependencies: [") : manifest.index("    targets: [")]
    targets = block(manifest, "shared-core")
    if with_app_logic:
        targets += block(manifest, "app-logic")
    text = header + dependencies + "    targets: [\n" + targets + "    ]\n)\n"
    OUT.mkdir(exist_ok=True)
    (OUT / "Sources").mkdir(exist_ok=True)
    links = {
        OUT / ".generated": LINUX / ".generated",
        OUT / "Sources" / "Shims": LINUX / "Sources" / "Shims",
    }
    for link, target in links.items():
        if link.is_symlink() and Path(os.readlink(link)) == target:
            continue
        if link.is_symlink():
            link.unlink()
        link.symlink_to(target)
    package = OUT / "Package.swift"
    if not package.exists() or package.read_text(encoding="utf-8") != text:
        package.write_text(text, encoding="utf-8")
    resolved = LINUX / "Package.resolved"
    if resolved.exists():
        (OUT / "Package.resolved").write_bytes(resolved.read_bytes())
    print(OUT)


if __name__ == "__main__":
    main()
