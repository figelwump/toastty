#!/usr/bin/env bash
# End-to-end test for libghostty + libtoastty-ghostty-gtk under a private
# GDK Broadway display (no GL, so the offscreen renderer is exercised).
# Never opens windows on the user's session.
#
#   linux/ghostty/test/run-tests.sh            # build (incremental) then test
#   linux/ghostty/test/run-tests.sh --no-build # test the installed build
#
# Env: BROADWAY_DISPLAY_NUM (default 47), TOASTTY_GHOSTTY_ARTIFACTS
# (default <repo>/artifacts/manual/ghostty-linux).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
out="$repo/linux/.deps/ghostty"

if [[ "${1:-}" != "--no-build" ]]; then
  "$here/../build-libghostty.sh"
fi

test_bin="$out/bin/toastty-ghostty-test"
[[ -x "$test_bin" ]] || { echo "missing $test_bin; run build-libghostty.sh" >&2; exit 1; }

# Every ghostty_* function the shared Swift sources call must be exported by
# libghostty.so, or the Linux app will not link.
missing=()
exported="$(nm -D --defined-only "$out/lib/libghostty.so" | awk '{print $3}')"
while read -r fn; do
  grep -qE "\\b$fn\\(" "$out/include/ghostty.h" || continue
  grep -qx "$fn" <<<"$exported" || missing+=("$fn")
done < <(grep -rhoE "ghostty_[a-z_]+\\(" "$repo/Sources" --include='*.swift' | tr -d '(' | sort -u)
if ((${#missing[@]})); then
  echo "FAIL: libghostty.so does not export: ${missing[*]}" >&2
  exit 1
fi
echo "ok: libghostty.so exports every ghostty_* function used by Sources/"

num="${BROADWAY_DISPLAY_NUM:-47}"
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/toastty-ghostty-test.XXXXXX")"
chmod 700 "$runtime_dir"
artifacts="${TOASTTY_GHOSTTY_ARTIFACTS:-$repo/artifacts/manual/ghostty-linux}"
mkdir -p "$artifacts"

broadway_pid=""
cleanup() {
  if [[ -n "$broadway_pid" ]]; then
    kill "$broadway_pid" 2>/dev/null || true
    wait "$broadway_pid" 2>/dev/null || true
  fi
  rm -rf "$runtime_dir"
}
trap cleanup EXIT

# Isolated environment: no Wayland/X11, private runtime dir, no session bus
# or accessibility bus, so nothing touches the user's desktop session.
iso_env=(
  env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS
  XDG_RUNTIME_DIR="$runtime_dir"
  DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/no-bus"
  GTK_A11Y=none NO_AT_BRIDGE=1 GDK_DEBUG=no-portals GSETTINGS_BACKEND=memory
)

# Start a private broadwayd, trying successive display numbers when the
# HTTP port (8080 + N) is taken (e.g. by another test run).
start_broadway() {
  local n="$1"
  "${iso_env[@]}" gtk4-broadwayd ":$n" >"$runtime_dir/broadwayd.log" 2>&1 &
  broadway_pid=$!
  for _ in $(seq 1 100); do
    if ! kill -0 "$broadway_pid" 2>/dev/null; then
      wait "$broadway_pid" 2>/dev/null || true
      broadway_pid=""
      return 1
    fi
    # broadwayd reports "Listening on ..." once both sockets are bound.
    grep -q "Listening on" "$runtime_dir/broadwayd.log" 2>/dev/null && sleep 0.1 && kill -0 "$broadway_pid" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}
started=0
for attempt in $(seq 0 30); do
  if start_broadway "$((num + attempt))"; then
    num=$((num + attempt))
    started=1
    break
  fi
done
if [[ "$started" != 1 ]]; then
  echo "gtk4-broadwayd failed to start:" >&2
  cat "$runtime_dir/broadwayd.log" >&2
  exit 1
fi
echo "broadway display :$num"

set +e
"${iso_env[@]}" GDK_BACKEND=broadway BROADWAY_DISPLAY=":$num" \
  TOASTTY_GHOSTTY_ARTIFACTS="$artifacts" \
  timeout 120 "$test_bin"
status=$?
set -e
echo "artifacts: $artifacts"
exit "$status"
