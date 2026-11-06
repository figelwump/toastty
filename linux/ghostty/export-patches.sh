#!/usr/bin/env bash
# Regenerate linux/ghostty/patches/*.patch from the commits on top of the
# pinned Ghostty commit in linux/.deps/ghostty-src. Workflow: make commits
# in that checkout (any branch), run this, then build-libghostty.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/../.deps/ghostty-src"
base="$(sed -n 's/^GHOSTTY_COMMIT="\(.*\)"$/\1/p' "$here/build-libghostty.sh")"
rm -f "$here"/patches/*.patch
git -C "$src" format-patch --quiet --no-signature --zero-commit --no-stat \
  -o "$here/patches" "$base..HEAD"
ls "$here/patches"
