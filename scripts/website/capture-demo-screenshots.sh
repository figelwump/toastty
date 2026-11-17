#!/usr/bin/env bash
# Captures real Toastty screenshots for the README and the website from a
# made-up "lumen" demo with real tasks, a coordinator, quick entry and the
# Tasks view. scripts/website/capture-demo-screenshots.py does the work; see
# its header for what it writes and what it needs (Accessibility permission
# and an unlocked screen, no Screen Recording).
#
# Usage: scripts/website/capture-demo-screenshots.sh [--build] [--app PATH] [--out DIR]
#          [--hidpi-display WIDTHxHEIGHT] [--keep] [--crop-only]
#   --build          build the Debug app into artifacts/website-capture/Derived first
#   --app            Toastty.app to launch (default: that Derived build)
#   --out            new or empty output directory (default: artifacts/website-capture/run-<timestamp>)
#   --hidpi-display  add a temporary 2x display, for a Mac whose display is 1x
#   --keep           leave the demo app running after capturing
#   --crop-only      crop the captures in --out/raw again, without the app

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED="$ROOT/artifacts/website-capture/Derived"
APP="$DERIVED/Build/Products/Debug/Toastty.app"
OUT="$ROOT/artifacts/website-capture/run-$(date +%Y%m%d-%H%M%S)"
BUILD=0
PASS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=1 ;;
    --app) APP="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --hidpi-display) PASS+=("$1" "$2"); shift ;;
    --keep|--crop-only) PASS+=("$1") ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "$BUILD" == 1 ]]; then
  mkdir -p "$ROOT/artifacts/website-capture"
  xcodebuild -workspace "$ROOT/toastty.xcworkspace" -scheme ToasttyApp -configuration Debug \
    -destination "platform=macOS,arch=arm64" -derivedDataPath "$DERIVED" build >"$ROOT/artifacts/website-capture/build.log"
fi

exec /usr/bin/python3 "$ROOT/scripts/website/capture-demo-screenshots.py" --app "$APP" --out "$OUT" ${PASS[@]+"${PASS[@]}"}
