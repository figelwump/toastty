#!/usr/bin/env bash
# Attach the Linux packages to the version's GitHub Release.
#
# Usage: scripts/release/publish-linux-release.sh --version X.Y.Z [--build-number N]
#          [--repo OWNER/REPO] [--tag TAG] [--clobber] [--dry-run]
#
# Reads artifacts/release/linux/<version>-<build>/package-metadata.env from
# scripts/linux/package.sh and uploads the .deb, the AppImage, its .zsync and
# SHA256SUMS-linux.txt to the release for TAG (default v<version>).
#
# The macOS publish (scripts/release/publish-github-release.sh --create-tag)
# creates the tag and the release, draft or published; this script only adds
# assets to it. It refuses when:
#   - the packages were built from a dirty tree,
#   - the tag on origin does not point at the commit the packages were built
#     from (TOASTTY_LINUX_SOURCE_COMMIT),
#   - the release does not exist yet,
#   - an asset with the same name exists (pass --clobber to replace it).
#
# AppImage updaters follow the AppImage's update information
# (gh-releases-zsync, latest release), so a published release with these
# assets is what updates AppImage users.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version=""
build_number="1"
repo=""
tag=""
clobber=0
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="$2"; shift ;;
    --build-number) build_number="$2"; shift ;;
    --repo) repo="$2"; shift ;;
    --tag) tag="$2"; shift ;;
    --clobber) clobber=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "publish-linux-release.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done
log() { printf '[publish-linux] %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ -n "$version" ]] || fail "--version is required"
command -v gh >/dev/null || fail "gh is required"

release_dir="$repo_root/artifacts/release/linux/$version-$build_number"
metadata="$release_dir/package-metadata.env"
[[ -s "$metadata" ]] || fail "missing $metadata (run scripts/linux/package.sh --version $version --build-number $build_number)"
# shellcheck source=/dev/null
source "$metadata"
[[ "${TOASTTY_LINUX_VERSION:-}" == "$version" ]] || fail "metadata version ${TOASTTY_LINUX_VERSION:-?} is not $version"
[[ "${TOASTTY_LINUX_SOURCE_DIRTY:-1}" == "0" ]] || fail "the packages were built from a dirty tree; rebuild from a clean checkout of the release commit"
commit="${TOASTTY_LINUX_SOURCE_COMMIT:?}"

if [[ -z "$repo" ]]; then
  url="$(git -C "$repo_root" config --get remote.origin.url || true)"
  case "$url" in
    https://github.com/*) repo="${url#https://github.com/}" ;;
    git@github.com:*) repo="${url#git@github.com:}" ;;
  esac
  repo="${repo%.git}"
  [[ -n "$repo" ]] || fail "could not determine the GitHub repository from origin; pass --repo"
fi
tag="${tag:-v$version}"

assets=()
for key in TOASTTY_LINUX_DEB TOASTTY_LINUX_APPIMAGE TOASTTY_LINUX_APPIMAGE_ZSYNC; do
  rel="${!key:-}"
  [[ -n "$rel" ]] || fail "$key is missing from $metadata"
  [[ -s "$repo_root/$rel" ]] || fail "missing $rel"
  assets+=("$repo_root/$rel")
done
sums="$release_dir/SHA256SUMS-linux.txt"
(cd "$release_dir" && sha256sum "${assets[@]##*/}") > "$sums"
assets+=("$sums")

# The tag on origin must name the commit the packages were built from.
remote_commit="$(git -C "$repo_root" ls-remote origin "refs/tags/$tag^{}" | awk '{print $1}')"
[[ -n "$remote_commit" ]] || remote_commit="$(git -C "$repo_root" ls-remote origin "refs/tags/$tag" | awk '{print $1}')"
[[ -n "$remote_commit" ]] || fail "tag $tag does not exist on origin; publish the macOS release first (toastty-publish)"
[[ "$remote_commit" == "$commit" ]] || fail "tag $tag is $remote_commit but the packages were built from $commit"

release_json="$(gh release view "$tag" --repo "$repo" --json isDraft,url,assets 2>/dev/null)" \
  || fail "release $tag does not exist in $repo; publish the macOS release first (toastty-publish)"
existing="$(jq -r '.assets[].name' <<<"$release_json")"
for asset in "${assets[@]}"; do
  if grep -qxF "$(basename "$asset")" <<<"$existing" && [[ "$clobber" == "0" ]]; then
    fail "$(basename "$asset") is already attached to $tag; pass --clobber to replace it"
  fi
done

command=(gh release upload "$tag" --repo "$repo")
[[ "$clobber" == "1" ]] && command+=(--clobber)
command+=("${assets[@]}")
log "release: $(jq -r .url <<<"$release_json") ($(jq -r 'if .isDraft then "draft" else "published" end' <<<"$release_json"))"
for asset in "${assets[@]}"; do log "asset: ${asset#"$repo_root/"}"; done
if [[ "$dry_run" == "1" ]]; then
  printf '+ '; printf '%q ' "${command[@]}"; printf '\n'
  exit 0
fi
"${command[@]}"
log "uploaded ${#assets[@]} assets to $tag"
