#!/usr/bin/env bash
# Fetches GTK4/libadwaita/WebKitGTK development headers and pkg-config files
# into linux/.sysroot without root. The runtime libraries come from the host;
# only -dev packages are downloaded and unpacked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYSROOT="${TOASTTY_LINUX_SYSROOT:-$ROOT/linux/.sysroot}"
DEBS="$SYSROOT/debs"
mkdir -p "$DEBS"

PACKAGES=(
  libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev libjavascriptcoregtk-6.0-dev
  libsoup-3.0-dev libglib2.0-dev libglib2.0-dev-bin libpango1.0-dev libcairo2-dev
  libgdk-pixbuf-2.0-dev libgraphene-1.0-dev libharfbuzz-dev libfreetype-dev
  libfontconfig-dev libepoxy-dev libvulkan-dev libx11-dev x11proto-dev libxext-dev
  libwayland-dev libpng-dev libffi-dev libmount-dev libsysprof-capture-4-dev
  libpcre2-dev zlib1g-dev libgl-dev libegl-dev libgles-dev libglx-dev libopengl-dev
  libxkbcommon-dev libfribidi-dev libpixman-1-dev libxrender-dev libxcb1-dev
  libxau-dev libxdmcp-dev libblkid-dev libselinux1-dev libsepol-dev libbrotli-dev
  libbz2-dev libexpat1-dev libthai-dev libdatrie-dev libxft-dev libgirepository-2.0-dev
  libsecret-1-dev libjson-glib-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
  libxi-dev libxrandr-dev libxfixes-dev libxcursor-dev libxinerama-dev libxdamage-dev
  libxcomposite-dev libdrm-dev libgbm-dev libsystemd-dev libudev-dev libatk1.0-dev
  libatk-bridge2.0-dev libdbus-1-dev libcloudproviders-dev libtiff-dev libjpeg-dev
  libwebp-dev liblzma-dev libzstd-dev libdeflate-dev libjbig-dev liblerc-dev
  libsharpyuv-dev libappstream-dev libonig-dev libsimdutf-dev libgles2-mesa-dev
  libicu-dev libsqlite3-dev libgcrypt20-dev libgpg-error-dev libxml2-dev libxslt1-dev
  libenchant-2-dev libhyphen-dev libmanette-0.2-dev libwoff-dev libavif-dev libjxl-dev
  krb5-multidev libselinux-dev libsasl2-dev libnghttp2-dev libpsl-dev libgssapi-krb5-2 libkrb5-dev uuid-dev
  libcap-dev libgudev-1.0-dev libevdev-dev libgraphite2-dev libxss-dev libxtst-dev
)

# Expand to every transitive -dev dependency so pkg-config Requires resolve.
mapfile -t RESOLVED < <(
  apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
    --no-breaks --no-replaces --no-enhances "${PACKAGES[@]}" 2>/dev/null \
    | sed -E 's/^ *(Pre)?Depends: //; s/[<>]//g' | grep -vE '^ ' \
    | grep -E '(-dev|-protocols|proto-dev|-dev-bin)$' | grep -v ':i386' | sort -u
)
PACKAGES+=("${RESOLVED[@]}")

cd "$DEBS"
for pkg in "${PACKAGES[@]}"; do
  if ! ls "${pkg}"_*.deb >/dev/null 2>&1; then
    apt-get download "$pkg" >/dev/null 2>&1 || echo "skip: $pkg" >&2
  fi
done

for deb in "$DEBS"/*.deb; do
  dpkg-deb -x "$deb" "$SYSROOT"
done

# Dev packages ship unversioned .so symlinks relative to /usr/lib; point the
# dangling ones at the host's runtime libraries.
LIBDIR="$SYSROOT/usr/lib/x86_64-linux-gnu"
find "$LIBDIR" -maxdepth 1 -type l -name '*.so' | while read -r link; do
  target="$(readlink "$link")"
  if [[ ! -e "$LIBDIR/$target" && -e "/usr/lib/x86_64-linux-gnu/$target" ]]; then
    ln -sf "/usr/lib/x86_64-linux-gnu/$target" "$link"
  fi
done

# Rewrite pkg-config prefixes so -I/-L resolve inside the sysroot.
for pc in "$LIBDIR"/pkgconfig/*.pc "$SYSROOT"/usr/share/pkgconfig/*.pc; do
  [[ -f "$pc" ]] || continue
  sed -i -E "s|^prefix=/usr$|prefix=$SYSROOT/usr|" "$pc"
done
echo "sysroot ready: $SYSROOT"
