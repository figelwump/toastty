#!/usr/bin/env bash
# Build the documented Ghostty revision for the hosted arm64 Mac.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pin="$(sed -nE 's|^git -C \.\./ghostty checkout ([0-9a-f]{40})$|\1|p' "$root/docs/ghostty-integration.md")"
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] || { echo "Cannot find the macOS Ghostty pin" >&2; exit 1; }

temp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/toastty-ghostty.XXXXXX")"
trap 'rm -rf -- "$temp"' EXIT
src="$temp/ghostty"
git init -q "$src"
git -C "$src" fetch --depth 1 https://github.com/figelwump/ghostty.git "$pin"
git -C "$src" checkout --detach FETCH_HEAD
test "$(git -C "$src" rev-parse HEAD)" = "$pin"

zig_version="$(sed -nE 's/^[[:space:]]*\.minimum_zig_version = "([0-9]+\.[0-9]+\.[0-9]+)",$/\1/p' "$src/build.zig.zon")"
[[ "$zig_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Cannot find the pinned Ghostty's Zig version" >&2; exit 1; }
zig_dist="zig-aarch64-macos-$zig_version"
curl -fsSL --retry 3 "https://ziglang.org/download/$zig_version/$zig_dist.tar.xz" -o "$temp/zig.tar.xz"
tar -xf "$temp/zig.tar.xz" -C "$temp"
zig="$temp/$zig_dist/zig"
test "$("$zig" version)" = "$zig_version"

flags=(-Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=native -Dsentry=false)
(cd "$src" && "$zig" build "${flags[@]}")
GHOSTTY_BUILD_FLAGS="${flags[*]}" \
  GHOSTTY_XCFRAMEWORK_SOURCE="$src/macos/GhosttyKit.xcframework" \
  "$root/scripts/ghostty/install-local-xcframework.sh"
test -f "$root/Dependencies/GhosttyKit.Debug.xcframework/Info.plist"
"$root/scripts/release/check-ghostty-pin.sh" "$pin"
