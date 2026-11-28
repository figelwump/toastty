# Source this file to build the Linux port without root:
#   source linux/env.sh
_toastty_linux_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export TOASTTY_LINUX_ROOT="$_toastty_linux_root"
export TOASTTY_LINUX_SYSROOT="${TOASTTY_LINUX_SYSROOT:-$_toastty_linux_root/.sysroot}"
_toastty_swift="${TOASTTY_SWIFT_TOOLCHAIN:-$HOME/.local/toolchains/swift-6.4.1-RELEASE-ubuntu26.04}"
if [[ -d "$_toastty_swift/usr/bin" ]]; then
  export PATH="$_toastty_swift/usr/bin:$PATH"
fi
_toastty_zig="${TOASTTY_ZIG_TOOLCHAIN:-$HOME/.local/toolchains/zig-x86_64-linux-0.16.0}"
if [[ -d "$_toastty_zig" ]]; then
  export PATH="$_toastty_zig:$PATH"
fi
export TOASTTY_GHOSTTY_PREFIX="${TOASTTY_GHOSTTY_PREFIX:-$TOASTTY_LINUX_ROOT/.deps/ghostty}"
export PKG_CONFIG_PATH="$TOASTTY_GHOSTTY_PREFIX/lib/pkgconfig:$TOASTTY_LINUX_SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig:$TOASTTY_LINUX_SYSROOT/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
unset _toastty_linux_root _toastty_swift _toastty_zig
