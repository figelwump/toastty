#!/usr/bin/env bash
# Build libghostty (embedded apprt, Linux/OpenGL platform) from Toastty's
# Ghostty fork plus linux/ghostty/patches, and the GTK4 widget library
# libtoastty-ghostty-gtk. Idempotent: reuses the toolchain, checkout, patch
# state and Zig cache when nothing changed.
#
# Output (linux/.deps/ghostty/):
#   include/ghostty.h, include/toastty-ghostty-gtk.h
#   lib/libghostty.so                (SONAME libghostty.so)
#   lib/libtoastty-ghostty-gtk.so    (RUNPATH $ORIGIN)
#   lib/pkgconfig/toastty-ghostty.pc
#   share/ghostty/{shell-integration,themes}, share/terminfo
#   bin/toastty-ghostty-demo, bin/toastty-ghostty-test
#
# Environment:
#   TOASTTY_GHOSTTY_OPTIMIZE  Zig optimize mode (default ReleaseFast; Debug for development)
#   TOASTTY_GHOSTTY_CPU       Zig -Dcpu (default baseline, for portable binaries; "native" for local speed)
#   TOASTTY_GHOSTTY_FORCE=1   re-apply patches even if the checkout has local changes
#   TOASTTY_GHOSTTY_SKIP_LIB=1  only rebuild the widget/demo/test (lib must already be installed)
set -euo pipefail

GHOSTTY_REPO="https://github.com/figelwump/ghostty.git"
GHOSTTY_BRANCH="toastty-downstream"
GHOSTTY_COMMIT="056ffe2a80aab09c478946406dc7ec1b489d4ac3"
ZIG_VERSION="0.16.0"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
linux_root="$(cd "$here/.." && pwd)"
deps="$linux_root/.deps"
src="$deps/ghostty-src"
zig_prefix="$deps/ghostty-zig-out"
out="$deps/ghostty"
optimize="${TOASTTY_GHOSTTY_OPTIMIZE:-ReleaseFast}"
cpu="${TOASTTY_GHOSTTY_CPU:-baseline}"

log() { printf '==> %s\n' "$*" >&2; }

# shellcheck source=../env.sh
source "$linux_root/env.sh"

# --- Zig -----------------------------------------------------------------
zig_dir="${TOASTTY_ZIG_TOOLCHAIN:-$HOME/.local/toolchains/zig-x86_64-linux-$ZIG_VERSION}"
if [[ ! -x "$zig_dir/zig" ]] || [[ "$("$zig_dir/zig" version)" != "$ZIG_VERSION" ]]; then
  log "installing Zig $ZIG_VERSION into $zig_dir"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 -o "$tmp/zig.tar.xz" \
    "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
  mkdir -p "$(dirname "$zig_dir")"
  tar -C "$tmp" -xf "$tmp/zig.tar.xz"
  rm -rf "$zig_dir"
  mv "$tmp/zig-x86_64-linux-$ZIG_VERSION" "$zig_dir"
fi
export PATH="$zig_dir:$PATH"

# --- Ghostty checkout + patches -------------------------------------------
mkdir -p "$deps"
if [[ ! -d "$src/.git" ]]; then
  log "cloning $GHOSTTY_REPO ($GHOSTTY_BRANCH)"
  git clone --filter=blob:none --branch "$GHOSTTY_BRANCH" "$GHOSTTY_REPO" "$src"
fi
if ! git -C "$src" cat-file -e "$GHOSTTY_COMMIT^{commit}" 2>/dev/null; then
  log "fetching $GHOSTTY_COMMIT"
  git -C "$src" fetch origin "$GHOSTTY_BRANCH"
fi

patches=("$here"/patches/*.patch)
stamp_file="$src/.git/toastty-patches.stamp"
want_stamp="$( { echo "$GHOSTTY_COMMIT"; cat "${patches[@]}"; } | sha256sum | cut -d' ' -f1)"
have_stamp="$(cat "$stamp_file" 2>/dev/null || true)"
head_tree="$(git -C "$src" rev-parse 'HEAD^{tree}')"
stamp_tree="$(cat "$stamp_file.tree" 2>/dev/null || true)"

if [[ "$want_stamp" != "$have_stamp" || "$head_tree" != "$stamp_tree" ]]; then
  if [[ -n "$(git -C "$src" status --porcelain --untracked-files=no)" && "${TOASTTY_GHOSTTY_FORCE:-0}" != 1 ]]; then
    echo "error: $src has uncommitted changes; commit them and run export-patches.sh," >&2
    echo "       or set TOASTTY_GHOSTTY_FORCE=1 to discard them." >&2
    exit 1
  fi
  log "applying ${#patches[@]} patches onto ${GHOSTTY_COMMIT:0:12}"
  git -C "$src" -c advice.detachedHead=false checkout --quiet --force --detach "$GHOSTTY_COMMIT"
  git -C "$src" -c user.name="Toastty Linux Port" -c user.email="toastty@localhost" \
    am --quiet --committer-date-is-author-date "${patches[@]}"
  echo "$want_stamp" > "$stamp_file"
  git -C "$src" rev-parse 'HEAD^{tree}' > "$stamp_file.tree"
fi

# --- libghostty ------------------------------------------------------------
zig_flags=(
  -Dapp-runtime=none
  -Dsentry=false
  -Demit-docs=false
  -Doptimize="$optimize"
  -Dcpu="$cpu"
)
if [[ "${TOASTTY_GHOSTTY_SKIP_LIB:-0}" != 1 ]]; then
  log "zig build ${zig_flags[*]}"
  (cd "$src" && zig build "${zig_flags[@]}" --prefix "$zig_prefix")

  log "installing libghostty into $out"
  rm -rf "$out/include" "$out/share"
  mkdir -p "$out/include" "$out/lib/pkgconfig" "$out/share/ghostty" "$out/bin"
  install -m 0644 "$zig_prefix/include/ghostty.h" "$out/include/ghostty.h"
  install -m 0755 "$zig_prefix/lib/ghostty-internal.so" "$out/lib/libghostty.so"
  cp -R "$zig_prefix/share/terminfo" "$out/share/terminfo"
  cp -R "$zig_prefix/share/ghostty/shell-integration" "$out/share/ghostty/shell-integration"
  if [[ -d "$zig_prefix/share/ghostty/themes" ]]; then
    cp -R "$zig_prefix/share/ghostty/themes" "$out/share/ghostty/themes"
  fi
  {
    echo "GHOSTTY_COMMIT=$GHOSTTY_COMMIT"
    echo "GHOSTTY_PATCHED_HEAD=$(git -C "$src" rev-parse HEAD)"
    echo "GHOSTTY_BUILD_FLAGS=${zig_flags[*]}"
    echo "GHOSTTY_PATCHES=$(cd "$here/patches" && ls ./*.patch | tr '\n' ' ')"
  } > "$out/ghostty-metadata.env"
fi

# --- widget library, demo, test -------------------------------------------
build="$deps/ghostty-widget-build"
mkdir -p "$build" "$out/include" "$out/lib/pkgconfig" "$out/bin"
python3 -I "$here/widget/gen-keymap.py" "$src" "$build/keymap-generated.h"
install -m 0644 "$here/widget/toastty-ghostty-gtk.h" "$out/include/toastty-ghostty-gtk.h"

cc="${CC:-cc}"
gtk_cflags="$(pkg-config --cflags gtk4)"
gtk_libs="$(pkg-config --libs gtk4)"
warn=(-Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers)
opt=(-O2 -g)
[[ "$optimize" == Debug ]] && opt=(-O0 -g)

log "building libtoastty-ghostty-gtk.so"
# shellcheck disable=SC2086
"$cc" -std=gnu11 -fPIC -shared "${opt[@]}" "${warn[@]}" -fvisibility=default \
  -I"$out/include" -I"$build" $gtk_cflags \
  "$here/widget/toastty-ghostty-gtk.c" \
  -o "$out/lib/libtoastty-ghostty-gtk.so" -Wl,-soname,libtoastty-ghostty-gtk.so \
  -L"$out/lib" -lghostty $gtk_libs -ldl -lm -Wl,-rpath,'$ORIGIN'

cat > "$out/lib/pkgconfig/toastty-ghostty.pc" <<EOF
prefix=$out
includedir=\${prefix}/include
libdir=\${prefix}/lib

Name: toastty-ghostty
Description: Ghostty terminal (libghostty, Linux/OpenGL embedded platform) with the Toastty GTK4 widget
Version: 0.0.0+${GHOSTTY_COMMIT:0:12}
Requires: gtk4
Cflags: -I\${includedir}
Libs: -L\${libdir} -ltoastty-ghostty-gtk -lghostty -Wl,-rpath,\${libdir}
EOF

export PKG_CONFIG_PATH="$out/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
tg_cflags="$(pkg-config --cflags toastty-ghostty)"
tg_libs="$(pkg-config --libs toastty-ghostty)"

log "building toastty-ghostty-demo"
# shellcheck disable=SC2086
"$cc" -std=gnu11 "${opt[@]}" "${warn[@]}" $tg_cflags "$here/demo/toastty-ghostty-demo.c" \
  -o "$out/bin/toastty-ghostty-demo" $tg_libs

log "building toastty-ghostty-test"
# shellcheck disable=SC2086
"$cc" -std=gnu11 "${opt[@]}" "${warn[@]}" $tg_cflags "$here/test/toastty-ghostty-test.c" \
  -o "$out/bin/toastty-ghostty-test" $tg_libs

log "done: $out"
