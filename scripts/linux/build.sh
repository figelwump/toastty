#!/usr/bin/env bash
# Build the Linux SwiftPM graph (linux/Package.swift).
#
# Usage: scripts/linux/build.sh [--release|--debug] [--product NAME]... [--target NAME]... [-- extra swift build args]
#
#   --release / --debug   build configuration (default: debug)
#   --product NAME        build only this product (repeatable), e.g. toastty, toastty-agent-shim
#   --target NAME         build only this target (repeatable), e.g. CoreState
#   --shared-only         build only the shared-core subset of linux/Package.swift
#                         (see scripts/linux/shared-only-package.py)
#   --app-logic           shared-core plus the app-logic block (no GTK targets)
#
# Mirrors shared Sources/ and Tests/ files into linux/.generated first
# (scripts/linux/sync-shared-sources.py), then runs `swift build` from linux/.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$repo_root/linux/env.sh"

configuration=debug
shared_only=0
app_logic=0
selections=()
extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) configuration=release ;;
    --debug) configuration=debug ;;
    --shared-only) shared_only=1 ;;
    --app-logic) app_logic=1 ;;
    --product|--target)
      [[ $# -ge 2 ]] || { echo "build.sh: $1 needs a value" >&2; exit 64; }
      selections+=("$1" "$2"); shift ;;
    --) shift; extra=("$@"); break ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "build.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

python3 "$repo_root/scripts/linux/sync-shared-sources.py"

package_dir="$repo_root/linux"
if [[ "$shared_only" == "1" ]]; then
  package_dir="$(python3 "$repo_root/scripts/linux/shared-only-package.py")"
elif [[ "$app_logic" == "1" ]]; then
  package_dir="$(python3 "$repo_root/scripts/linux/shared-only-package.py" --with-app-logic)"
fi
cd "$package_dir"
if [[ ${#selections[@]} -eq 0 ]]; then
  exec swift build -c "$configuration" "${extra[@]}"
fi
# swift build accepts a single --product/--target per invocation.
for ((i = 0; i < ${#selections[@]}; i += 2)); do
  swift build -c "$configuration" "${selections[i]}" "${selections[i + 1]}" "${extra[@]}"
done
