#!/usr/bin/env bash
# Install the Toastty Linux build into the user's home (no root needed).
#
# Usage: scripts/linux/install.sh [--prefix DIR] [--debug] [--no-build] [--build-dir DIR] [--uninstall] [--dry-run]
#
#   --prefix DIR     install root (default: ~/.local)
#   --debug          install the debug build (default: release)
#   --no-build       do not build; install what is already in the build dir
#   --build-dir DIR  SwiftPM products directory (default: linux/.build/<config>)
#   --uninstall      remove a previous install from the prefix
#   --dry-run        print what would happen
#
# Layout (PREFIX=~/.local):
#   PREFIX/lib/toastty/bin/{toastty-linux,toastty,toastty-agent-shim}
#   PREFIX/lib/toastty/lib/      libghostty.so, libtoastty-ghostty-gtk.so, Swift runtime
#   PREFIX/lib/toastty/share/toastty/Resources/   (Sources/App/Resources: WebPanels, setup docs, …,
#                                                  ToasttyAgentPluginBundle/, WorkflowExamples/skills/)
#   PREFIX/lib/toastty/share/{ghostty,terminfo}/  (Ghostty shell integration + terminfo)
#   PREFIX/bin/{toastty-linux,toastty} -> ../lib/toastty/bin/…
#   PREFIX/share/applications/com.GiantThings.toastty.desktop
#   PREFIX/share/metainfo/com.GiantThings.toastty.metainfo.xml
#   PREFIX/share/icons/hicolor/<size>/apps/com.GiantThings.toastty.{png,svg}
#
# The app finds its resources relative to the executable
# (<exe>/../share/toastty/Resources, see LinuxAppLogic.defaultAppResourcesPath
# and WebPanelResources), libghostty finds share/ghostty the same way, and the
# binaries' RUNPATH includes $ORIGIN and $ORIGIN/../lib.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prefix="${HOME}/.local"
configuration=release
build=1
build_dir=""
uninstall=0
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) prefix="$2"; shift ;;
    --debug) configuration=debug ;;
    --release) configuration=release ;;
    --no-build) build=0 ;;
    --build-dir) build_dir="$2"; shift ;;
    --uninstall) uninstall=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

app_id=com.GiantThings.toastty
libdir="$prefix/lib/toastty"
run() {
  if [[ "$dry_run" == "1" ]]; then echo "+ $*"; else "$@"; fi
}

if [[ "$uninstall" == "1" ]]; then
  run rm -rf "$libdir"
  for name in toastty-linux toastty toastty-agent-shim; do
    if [[ -L "$prefix/bin/$name" && "$(readlink "$prefix/bin/$name")" == *"/lib/toastty/bin/"* ]]; then run rm -f "$prefix/bin/$name"; fi
  done
  run rm -f "$prefix/share/applications/$app_id.desktop" "$prefix/share/metainfo/$app_id.metainfo.xml"
  run find "$prefix/share/icons/hicolor" -name "$app_id.*" -delete
  command -v update-desktop-database >/dev/null && run update-desktop-database -q "$prefix/share/applications" || true
  echo "Removed Toastty from $prefix"
  exit 0
fi

# shellcheck source=/dev/null
source "$repo_root/linux/env.sh"
if [[ -z "$build_dir" ]]; then
  build_dir="$repo_root/linux/.build/$configuration"
fi
if [[ "$build" == "1" ]]; then
  run "$repo_root/scripts/linux/build.sh" "--$configuration" \
    --product toastty-linux --product toastty --product toastty-agent-shim
fi
for name in toastty-linux toastty toastty-agent-shim; do
  if [[ ! -x "$build_dir/$name" && "$dry_run" != "1" ]]; then
    echo "install.sh: $build_dir/$name is missing; build first or pass --build-dir" >&2
    exit 1
  fi
done

ghostty_prefix="${TOASTTY_GHOSTTY_PREFIX:-$repo_root/linux/.deps/ghostty}"
resources="$repo_root/Sources/App/Resources"
data="$repo_root/linux/data"

run mkdir -p "$libdir/bin" "$libdir/lib" "$libdir/share/toastty" "$prefix/bin" \
  "$prefix/share/applications" "$prefix/share/metainfo" "$prefix/share/icons/hicolor"

# Executables.
for name in toastty-linux toastty toastty-agent-shim; do
  run install -m 0755 "$build_dir/$name" "$libdir/bin/$name"
done

# Shared libraries: Ghostty, plus the Swift runtime the binaries link
# against (so the install keeps working without the toolchain).
for lib in "$ghostty_prefix"/lib/*.so*; do
  [[ -e "$lib" ]] && run install -m 0644 "$lib" "$libdir/lib/"
done
if [[ "$dry_run" != "1" ]]; then
  for name in toastty-linux toastty toastty-agent-shim; do
    ldd "$libdir/bin/$name" | awk '/=> \// {print $3}' | while read -r path; do
      case "$path" in
        */usr/lib/swift/linux/*|*/PackageFrameworks/*) install -m 0644 "$path" "$libdir/lib/" ;;
      esac
    done
  done
  # The CLI and agent shim only search $ORIGIN: link the runtime next to them.
  for lib in "$libdir"/lib/*.so*; do
    ln -sf "../lib/$(basename "$lib")" "$libdir/bin/$(basename "$lib")"
  done
fi

# Resources (web panel bundles, setup docs, remote web client, scripts).
run rm -rf "$libdir/share/toastty/Resources"
run mkdir -p "$libdir/share/toastty/Resources"
for entry in "$resources"/*; do
  [[ "$(basename "$entry")" == "Assets.xcassets" ]] && continue
  run cp -R "$entry" "$libdir/share/toastty/Resources/"
done

# Toastty agent skills (ToasttyAgentPluginBundle) and the workflow example
# skills, laid out as Project.swift bundles them on macOS.
plugin_bundle="$libdir/share/toastty/Resources/ToasttyAgentPluginBundle"
run mkdir -p "$plugin_bundle/.agents/plugins" "$plugin_bundle/plugins" \
  "$libdir/share/toastty/Resources/WorkflowExamples"
run cp "$repo_root/.agents/plugins/marketplace.json" "$plugin_bundle/.agents/plugins/"
run cp -R "$repo_root/plugins/toastty" "$plugin_bundle/plugins/"
run cp -R "$repo_root/examples/skills" "$libdir/share/toastty/Resources/WorkflowExamples/"

# SetupResourceResolver (CLI `toastty setup …`) looks at <exe>/../Resources.
run ln -sfn "share/toastty/Resources" "$libdir/Resources"

# Ghostty shell integration, themes and terminfo.
if [[ -d "$ghostty_prefix/share" ]]; then
  for entry in ghostty terminfo; do
    if [[ -d "$ghostty_prefix/share/$entry" ]]; then
      run rm -rf "$libdir/share/$entry"
      run cp -R "$ghostty_prefix/share/$entry" "$libdir/share/$entry"
    fi
  done
fi

# Command-line entry points.
run ln -sfn "../lib/toastty/bin/toastty-linux" "$prefix/bin/toastty-linux"
run ln -sfn "../lib/toastty/bin/toastty" "$prefix/bin/toastty"

# Desktop integration.
if [[ "$dry_run" == "1" ]]; then
  echo "+ install $app_id.desktop (Exec=$libdir/bin/toastty-linux)"
else
  sed -e "s|^Exec=.*|Exec=$libdir/bin/toastty-linux|" -e "s|^TryExec=.*|TryExec=$libdir/bin/toastty-linux|" \
    "$data/$app_id.desktop" > "$prefix/share/applications/$app_id.desktop"
  chmod 0644 "$prefix/share/applications/$app_id.desktop"
fi
run install -m 0644 "$data/$app_id.metainfo.xml" "$prefix/share/metainfo/$app_id.metainfo.xml"
run cp -R "$data/icons/hicolor/." "$prefix/share/icons/hicolor/"
# A private copy the app adds to its icon theme (AppIcon), for prefixes
# outside XDG_DATA_DIRS.
run mkdir -p "$libdir/share/icons/hicolor"
run cp -R "$data/icons/hicolor/." "$libdir/share/icons/hicolor/"

if command -v update-desktop-database >/dev/null; then run update-desktop-database -q "$prefix/share/applications" || true; fi
if [[ -f "$prefix/share/icons/hicolor/index.theme" ]]; then
  if command -v gtk4-update-icon-cache >/dev/null; then run gtk4-update-icon-cache -q -t -f "$prefix/share/icons/hicolor" || true
  elif command -v gtk-update-icon-cache >/dev/null; then run gtk-update-icon-cache -q -t -f "$prefix/share/icons/hicolor" || true
  fi
fi

echo "Installed Toastty from $build_dir to $libdir"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "note: $prefix/bin is not on PATH; the desktop launcher still works" ;;
esac
