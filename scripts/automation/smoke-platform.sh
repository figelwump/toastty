#!/usr/bin/env bash
# Platform layer for the smoke scripts. The scripts drive the app through
# its socket and CLI, which are shared code; only building, locating the
# binaries and the display differ.
#
#   macOS: bootstrap + xcodebuild, the user's GUI session (the scripts hand
#          focus back to the previous front app).
#   Linux: scripts/linux/build.sh and a private GDK Broadway display, so
#          nothing appears on the user's desktop.
#
# Source it after setting ROOT_DIR.

toastty_smoke_platform() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux) printf 'linux' ;;
    *) printf 'unsupported' ;;
  esac
}

TOASTTY_SMOKE_PLATFORM="$(toastty_smoke_platform)"
TOASTTY_SMOKE_BROADWAY_PID=""
if [[ "$TOASTTY_SMOKE_PLATFORM" == "linux" ]]; then
  # The Ghostty fallback switches select a macOS project variant; the Linux
  # build always links libghostty.
  unset TUIST_DISABLE_GHOSTTY TOASTTY_DISABLE_GHOSTTY
fi

toastty_smoke_app_binary() {
  local derived_path="$1"
  if [[ "$TOASTTY_SMOKE_PLATFORM" == "linux" ]]; then
    printf '%s/linux/.build/debug/toastty-linux' "$ROOT_DIR"
  else
    printf '%s/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty' "$derived_path"
  fi
}

toastty_smoke_cli_binary() {
  local derived_path="$1"
  if [[ "$TOASTTY_SMOKE_PLATFORM" == "linux" ]]; then
    printf '%s/linux/.build/debug/toastty' "$ROOT_DIR"
  else
    printf '%s/Build/Products/Debug/toastty' "$derived_path"
  fi
}

# Whether the build has a real Ghostty terminal (terminal input readiness
# checks only apply then). macOS uses the local xcframework when present;
# the Linux build always links libghostty.
toastty_smoke_ghostty_artifact() {
  if [[ "$TOASTTY_SMOKE_PLATFORM" == "linux" ]]; then
    printf '%s/linux/.deps/ghostty' "$ROOT_DIR"
    return
  fi
  local variant
  for variant in Debug Release; do
    if [[ -f "$ROOT_DIR/Dependencies/GhosttyKit.$variant.xcframework/Info.plist" ]]; then
      printf '%s/Dependencies/GhosttyKit.%s.xcframework' "$ROOT_DIR" "$variant"
      return
    fi
  done
}

# Prepares the worktree (macOS only: links Ghostty artifacts and generates
# the project). Linux has no generate step.
toastty_smoke_bootstrap() {
  if [[ "$TOASTTY_SMOKE_PLATFORM" == "linux" ]]; then
    return 0
  fi
  "$ROOT_DIR/scripts/dev/bootstrap-worktree.sh" >/dev/null
}

# Builds the debug app and CLI. Output goes to stdout; callers redirect it.
toastty_smoke_build() {
  local derived_path="$1"
  local arch="$2"
  if [[ "$TOASTTY_SMOKE_PLATFORM" == "linux" ]]; then
    "$ROOT_DIR/scripts/linux/build.sh" --product toastty-linux --product toastty --product toastty-agent-shim
    return
  fi
  xcodebuild \
    -workspace "$ROOT_DIR/toastty.xcworkspace" \
    -scheme ToasttyApp \
    -configuration Debug \
    -destination "platform=macOS,arch=${arch}" \
    -derivedDataPath "$derived_path" \
    build
}

# Linux: starts a private Broadway display and exports the GDK settings the
# app inherits. broadwayd and the app share XDG_RUNTIME_DIR, where the
# display socket lives. macOS: nothing to do.
toastty_smoke_start_display() {
  [[ "$TOASTTY_SMOKE_PLATFORM" == "linux" ]] || return 0
  if ! command -v gtk4-broadwayd >/dev/null 2>&1; then
    echo "error: gtk4-broadwayd is required for Linux smoke runs (libgtk-4-bin)" >&2
    return 1
  fi
  local runtime_dir="${XDG_RUNTIME_DIR:-}"
  if [[ -z "$runtime_dir" || ! -d "$runtime_dir" ]]; then
    echo "error: XDG_RUNTIME_DIR must name an existing directory for Broadway" >&2
    return 1
  fi
  local log_file="${1:-/dev/null}"
  local display attempt
  for attempt in $(seq 1 20); do
    display=$((60 + RANDOM % 30))
    # broadwayd :N listens on $XDG_RUNTIME_DIR/broadway<N+1>.socket. A socket
    # with no broadwayd behind it is left over from a killed run: reuse it.
    if [[ -e "$runtime_dir/broadway$((display + 1)).socket" ]]; then
      pgrep -u "$(id -u)" -f "^gtk4-broadwayd :$display( |\$)" >/dev/null 2>&1 && continue
      rm -f "$runtime_dir/broadway$((display + 1)).socket"
    fi
    gtk4-broadwayd ":$display" >"$log_file" 2>&1 &
    TOASTTY_SMOKE_BROADWAY_PID=$!
    local _
    for _ in $(seq 1 50); do
      [[ -S "$runtime_dir/broadway$((display + 1)).socket" ]] && break
      kill -0 "$TOASTTY_SMOKE_BROADWAY_PID" 2>/dev/null || break
      sleep 0.1
    done
    if [[ -S "$runtime_dir/broadway$((display + 1)).socket" ]]; then
      export GDK_BACKEND=broadway BROADWAY_DISPLAY=":$display"
      export GTK_A11Y=none NO_AT_BRIDGE=1 GDK_DEBUG=no-portals GSETTINGS_BACKEND=memory
      # The viewer, for watching a run: http://127.0.0.1:$((8080 + display))
      TOASTTY_SMOKE_BROADWAY_DISPLAY="$display"
      return 0
    fi
    kill "$TOASTTY_SMOKE_BROADWAY_PID" >/dev/null 2>&1 || true
    wait "$TOASTTY_SMOKE_BROADWAY_PID" >/dev/null 2>&1 || true
    TOASTTY_SMOKE_BROADWAY_PID=""
  done
  echo "error: could not start a Broadway display" >&2
  return 1
}

toastty_smoke_stop_display() {
  if [[ -n "$TOASTTY_SMOKE_BROADWAY_PID" ]]; then
    kill "$TOASTTY_SMOKE_BROADWAY_PID" >/dev/null 2>&1 || true
    wait "$TOASTTY_SMOKE_BROADWAY_PID" >/dev/null 2>&1 || true
    TOASTTY_SMOKE_BROADWAY_PID=""
  fi
  # broadwayd leaves its socket behind when killed.
  if [[ -n "${TOASTTY_SMOKE_BROADWAY_DISPLAY:-}" ]]; then
    rm -f "${XDG_RUNTIME_DIR:-/nonexistent}/broadway$((TOASTTY_SMOKE_BROADWAY_DISPLAY + 1)).socket"
    TOASTTY_SMOKE_BROADWAY_DISPLAY=""
  fi
}
