#!/usr/bin/env bash
# Build Linux release packages from one release build.
#
# Usage: scripts/linux/package.sh --version X.Y.Z [--build-number N]
#          [--format deb|appimage|snap|flatpak|all]... [--no-build]
#
# Output: artifacts/release/linux/<version>-<build>/
#   toastty_<version>_amd64.deb
#   Toastty-<version>-x86_64.AppImage
#   toastty_<version>_amd64.snap          (needs snapcraft)
#   com.GiantThings.toastty-<version>.flatpak  (needs flatpak-builder)
#   package-metadata.env
#
# Every format wraps the stage that `install.sh --prefix /usr --destdir`
# produces (see docs/plans/linux-release.md). The Flatpak builds from source
# inside the GNOME SDK instead. Formats whose tools are missing fail with the
# command to install them; the others still build.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version=""
build_number="1"
formats=()
build=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="$2"; shift ;;
    --build-number) build_number="$2"; shift ;;
    --format) formats+=("$2"); shift ;;
    --no-build) build=0 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "package.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done
[[ -n "$version" ]] || { echo "package.sh: --version is required" >&2; exit 64; }
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "package.sh: version must look like 1.2.3" >&2; exit 64; }
[[ ${#formats[@]} -gt 0 ]] || formats=(all)
if [[ " ${formats[*]} " == *" all "* ]]; then formats=(deb appimage snap flatpak); fi

app_id=com.GiantThings.toastty
arch_deb=amd64
arch_appimage=x86_64
[[ "$(uname -m)" == "x86_64" ]] || { echo "package.sh: only x86_64 is supported for now" >&2; exit 1; }

out="$repo_root/artifacts/release/linux/$version-$build_number"
work="$out/work"
rm -rf "$work"
mkdir -p "$out" "$work"
stage="$work/stage"

log() { printf '[package] %s\n' "$*"; }

# --- Build and stage ---------------------------------------------------------

if [[ "$build" == "1" ]]; then
  log "Release build"
  "$repo_root/scripts/linux/build.sh" --release --product toastty-linux --product toastty --product toastty-agent-shim
fi

log "Staging /usr into $stage"
"$repo_root/scripts/linux/install.sh" --release --no-build --prefix /usr --destdir "$stage" >/dev/null
libdir="$stage/usr/lib/toastty"
printf '%s\n%s\n' "$version" "$build_number" > "$libdir/share/toastty/version"

# AppStream release entry for this version.
metainfo="$stage/usr/share/metainfo/$app_id.metainfo.xml"
release_date="$(date -u +%Y-%m-%d)"
python3 - "$metainfo" "$version" "$release_date" <<'PY'
import re, sys
path, version, date = sys.argv[1:]
text = open(path).read()
entry = f'    <release version="{version}" date="{date}"/>\n'
if "<releases>" in text:
    text = text.replace("<releases>\n", "<releases>\n" + entry, 1)
else:
    text = text.replace("</component>", f"  <releases>\n{entry}  </releases>\n</component>", 1)
open(path, "w").write(text)
PY

declare -A produced=()
declare -A failed=()

# --- .deb ----------------------------------------------------------------------

# Debian package names (with a minimum version) for the system libraries the
# staged ELF files link directly (DT_NEEDED), skipping the ones the stage
# bundles. Their own dependencies come in through those packages.
deb_depends() {
  local -A packages=()
  local -A bundled=()
  local file name path package installed
  for file in "$libdir"/lib/*.so*; do bundled["$(basename "$file")"]=1; done
  while IFS= read -r file; do
    file "$file" | grep -q 'ELF' || continue
    local resolved
    resolved="$(LD_LIBRARY_PATH="$libdir/lib" ldd "$file" 2>/dev/null)"
    while IFS= read -r name; do
      [[ -n "${bundled[$name]:-}" ]] && continue
      path="$(awk -v n="$name" '$1 == n && $3 ~ /^\// {print $3; exit}' <<<"$resolved")"
      [[ -n "$path" ]] || continue
      package="$(dpkg -S "$(readlink -f "$path")" 2>/dev/null | head -n1 | cut -d: -f1)" \
        || package="$(dpkg -S "$path" 2>/dev/null | head -n1 | cut -d: -f1)" || true
      [[ -n "$package" ]] && packages["$package"]=1
    done < <(objdump -p "$file" 2>/dev/null | awk '$1 == "NEEDED" {print $2}')
  done < <(find "$libdir/bin" "$libdir/lib" "$libdir/libexec" -type f 2>/dev/null)
  local -a entries=()
  for package in "${!packages[@]}"; do
    installed="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null)"
    # The upstream part of the version, so a rebuild of the same library still satisfies it.
    installed="${installed#*:}"
    installed="${installed%%-*}"
    entries+=("$package (>= $installed)")
  done
  printf '%s\n' "${entries[@]}" | sort | paste -sd, | sed 's/,/, /g'
}

build_deb() {
  command -v dpkg-deb >/dev/null && command -v fakeroot >/dev/null \
    || { echo "install dpkg-deb and fakeroot (sudo apt install dpkg fakeroot)"; return 1; }
  local root="$work/deb"
  rm -rf "$root"
  cp -a "$stage" "$root"
  mkdir -p "$root/DEBIAN"
  local depends installed_size maintainer
  # Like dh_make: DEBFULLNAME/DEBEMAIL, else the git identity.
  maintainer="${DEBFULLNAME:-$(git -C "$repo_root" config user.name)} <${DEBEMAIL:-$(git -C "$repo_root" config user.email)}>"
  depends="$(deb_depends)"
  installed_size="$(du -sk --exclude=DEBIAN "$root" | cut -f1)"
  cat > "$root/DEBIAN/control" <<EOF
Package: toastty
Version: $version-$build_number
Architecture: $arch_deb
Maintainer: $maintainer
Installed-Size: $installed_size
Depends: $depends
Section: x11
Priority: optional
Homepage: https://github.com/figelwump/toastty
Description: Terminal workspaces for running and following coding agents
 Toastty is a GTK terminal workspace app built on Ghostty, with split panes,
 workspace tabs, browser and document panels, and managed coding agents.
EOF
  (cd "$root" && find usr -type f -print0 | sort -z | xargs -0 md5sum > DEBIAN/md5sums)
  local deb="$out/toastty_${version}-${build_number}_${arch_deb}.deb"
  fakeroot dpkg-deb --build --root-owner-group -Zxz "$root" "$deb" >/dev/null
  produced[deb]="$deb"
}

# --- AppImage ----------------------------------------------------------------

# appimagetool is not downloaded here: provide it with APPIMAGETOOL, on PATH, or
# at linux/.deps/tools/appimagetool-x86_64.AppImage
# (https://github.com/AppImage/appimagetool/releases).
appimagetool="${APPIMAGETOOL:-$(command -v appimagetool || echo "$repo_root/linux/.deps/tools/appimagetool-x86_64.AppImage")}"

build_appimage() {
  [[ -x "$appimagetool" ]] \
    || { echo "appimagetool not found: set APPIMAGETOOL or put it at linux/.deps/tools/appimagetool-x86_64.AppImage (https://github.com/AppImage/appimagetool/releases)"; return 1; }
  local appdir="$work/AppDir"
  rm -rf "$appdir"
  mkdir -p "$appdir"
  cp -a "$stage/usr" "$appdir/usr"
  cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
# Toastty AppImage entry point. GTK 4, libadwaita and WebKitGTK 6.0 come from
# the host; Toastty, Ghostty and the Swift runtime are bundled.
here="$(dirname "$(readlink -f "$0")")"
case "$(basename "${ARGV0:-$0}")" in
  toastty) exec "$here/usr/lib/toastty/bin/toastty" "$@" ;;
esac
exec "$here/usr/lib/toastty/bin/toastty-linux" "$@"
EOF
  chmod 0755 "$appdir/AppRun"
  sed -e "s|^Exec=.*|Exec=toastty-linux|" -e "s|^TryExec=.*|TryExec=toastty-linux|" \
    "$stage/usr/share/applications/$app_id.desktop" > "$appdir/$app_id.desktop"
  cp "$stage/usr/share/icons/hicolor/256x256/apps/$app_id.png" "$appdir/$app_id.png"
  local image="$out/Toastty-$version-$arch_appimage.AppImage"
  ARCH="$arch_appimage" APPIMAGE_EXTRACT_AND_RUN=1 VERSION="$version" \
    "$appimagetool" --no-appstream "$appdir" "$image" >"$work/appimagetool.log" 2>&1 \
    || { tail -20 "$work/appimagetool.log"; return 1; }
  produced[appimage]="$image"
}

# --- snap --------------------------------------------------------------------

build_snap() {
  command -v snapcraft >/dev/null \
    || { echo "install snapcraft (sudo snap install snapcraft --classic) and LXD, or run on Ubuntu 26.04 with --destructive-mode"; return 1; }
  local project="$work/snap"
  rm -rf "$project"
  mkdir -p "$project/snap"
  cp "$repo_root/linux/packaging/snap/snapcraft.yaml" "$project/snap/snapcraft.yaml"
  sed -i "s/^version: .*/version: '$version'/" "$project/snap/snapcraft.yaml"
  cp -a "$stage" "$project/stage"
  (cd "$project" && snapcraft pack ${TOASTTY_SNAPCRAFT_ARGS:-} --output "$out/toastty_${version}_${arch_deb}.snap") \
    || return 1
  produced[snap]="$out/toastty_${version}_${arch_deb}.snap"
}

# --- Flatpak -----------------------------------------------------------------

build_flatpak() {
  command -v flatpak-builder >/dev/null \
    || { echo "install flatpak and flatpak-builder (sudo apt install flatpak flatpak-builder), then: flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"; return 1; }
  local manifest="$repo_root/linux/packaging/flatpak/$app_id.yml"
  local repo="$work/flatpak-repo"
  flatpak-builder --user --install-deps-from=flathub --force-clean --repo="$repo" \
    --default-branch="$version" "$work/flatpak-build" "$manifest" || return 1
  flatpak build-bundle "$repo" "$out/$app_id-$version.flatpak" "$app_id" "$version" || return 1
  produced[flatpak]="$out/$app_id-$version.flatpak"
}

for format in "${formats[@]}"; do
  log "Building $format"
  # Not in a subshell: build_* records its artifact in `produced`.
  if ! "build_$format" > "$work/$format.log" 2>&1; then
    failed[$format]=1
    printf 'warning: %s not built:\n' "$format" >&2
    tail -n 20 "$work/$format.log" >&2
  fi
done

{
  echo "TOASTTY_LINUX_VERSION=$version"
  echo "TOASTTY_LINUX_BUILD_NUMBER=$build_number"
  echo "TOASTTY_LINUX_SOURCE_COMMIT=$(git -C "$repo_root" rev-parse HEAD)"
  echo "TOASTTY_LINUX_SOURCE_DIRTY=$([[ -n "$(git -C "$repo_root" status --porcelain)" ]] && echo 1 || echo 0)"
  echo "TOASTTY_LINUX_GLIBC=$(ldd --version | head -n1 | awk '{print $NF}')"
  for format in "${!produced[@]}"; do
    echo "TOASTTY_LINUX_${format^^}=${produced[$format]#"$repo_root/"}"
  done
} > "$out/package-metadata.env"

rm -rf "$work"
for format in "${!produced[@]}"; do log "built ${produced[$format]#"$repo_root/"}"; done
[[ ${#failed[@]} -eq 0 ]]
