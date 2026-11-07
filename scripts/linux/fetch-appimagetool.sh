#!/usr/bin/env bash
# Download the pinned appimagetool that scripts/linux/package.sh uses into
# linux/.deps/tools/, checking its SHA-256. Rerun after bumping the pin.
#
# Usage: scripts/linux/fetch-appimagetool.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version=1.9.1
sha256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
url="https://github.com/AppImage/appimagetool/releases/download/$version/appimagetool-x86_64.AppImage"
target="$repo_root/linux/.deps/tools/appimagetool-x86_64.AppImage"

if [[ -x "$target" ]] && echo "$sha256  $target" | sha256sum -c --status; then
  echo "appimagetool $version is already at ${target#"$repo_root/"}"
  exit 0
fi
download="$(mktemp -d)"
trap 'rm -rf "$download"' EXIT
curl -fsSL -o "$download/appimagetool" "$url"
echo "$sha256  $download/appimagetool" | sha256sum -c --status \
  || { echo "fetch-appimagetool.sh: checksum mismatch for $url" >&2; exit 1; }
mkdir -p "$(dirname "$target")"
install -m 0755 "$download/appimagetool" "$target"
echo "Installed appimagetool $version at ${target#"$repo_root/"}"
