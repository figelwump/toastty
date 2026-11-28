#!/usr/bin/env bash
# Install distro-native headers and the same Swift release on both CI images.
set -euo pipefail

swift_version=6.4.1
. /etc/os-release
case "$ID:$VERSION_ID" in
  ubuntu:24.04|ubuntu:26.04) ;;
  *) echo "Unsupported hosted Linux image: $ID $VERSION_ID" >&2; exit 1 ;;
esac
test "$(uname -m)" = x86_64

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential pkg-config python3 bubblewrap dbus-daemon jq netcat-openbsd uuid-runtime \
  desktop-file-utils fakeroot fonts-dejavu-core libgtk-4-dev libgtk-4-bin libadwaita-1-dev \
  libwebkitgtk-6.0-dev libegl-dev libgl1-mesa-dri libegl-mesa0 \
  libcurl4-openssl-dev libedit-dev libicu-dev libsqlite3-dev libxml2-dev \
  libncurses-dev libzstd-dev zlib1g-dev

# Ubuntu 24.04's opt-in AppArmor profile lets WebKit's bubblewrap sandbox
# start on the hosted image without relaxing the system-wide restriction.
probe_bwrap() {
  bwrap --unshare-user --unshare-pid --ro-bind / / /usr/bin/true
}
if [[ "$VERSION_ID" == 24.04 && "${GITHUB_ACTIONS:-}" == true ]] && ! probe_bwrap; then
  sudo apt-get install -y --no-install-recommends apparmor-profiles
  sudo apparmor_parser -r -W /usr/share/apparmor/extra-profiles/bwrap-userns-restrict
  probe_bwrap
fi

swift_dir="${RUNNER_TEMP:?}/swift-$swift_version"
swift_dist="swift-$swift_version-RELEASE-ubuntu$VERSION_ID"
ubuntu_id="${VERSION_ID/./}"
swift_url="https://download.swift.org/swift-$swift_version-release/ubuntu$ubuntu_id/swift-$swift_version-RELEASE/$swift_dist.tar.gz"
mkdir -p "$swift_dir"
curl -fsSL --retry 3 "$swift_url" | tar -xz --strip-components=1 -C "$swift_dir"
"$swift_dir/usr/bin/swift" --version
printf 'TOASTTY_SWIFT_TOOLCHAIN=%s\n' "$swift_dir" >>"${GITHUB_ENV:?}"
printf '%s/usr/bin\n' "$swift_dir" >>"${GITHUB_PATH:?}"
