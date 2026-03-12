#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_PATH="${GHOSTTY_XCFRAMEWORK_SOURCE:-}"
VARIANT="${GHOSTTY_XCFRAMEWORK_VARIANT:-debug}"

if [[ -z "$SOURCE_PATH" ]]; then
  for candidate in \
    "$ROOT_DIR/../ghostty/macos/GhosttyKit.xcframework" \
    "$ROOT_DIR/GhosttyKit.xcframework"; do
    if [[ -d "$candidate" ]]; then
      SOURCE_PATH="$candidate"
      break
    fi
  done
fi

case "$VARIANT" in
  debug)
    DEST_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Debug.xcframework"
    ;;
  release)
    DEST_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Release.xcframework"
    ;;
  *)
    echo "Invalid GHOSTTY_XCFRAMEWORK_VARIANT: $VARIANT" >&2
    echo "Expected one of: debug, release" >&2
    exit 1
    ;;
esac

if [[ ! -d "$SOURCE_PATH" ]]; then
  echo "Ghostty xcframework not found at: ${SOURCE_PATH:-<unset>}" >&2
  echo "Build Ghostty upstream with:" >&2
  echo "  zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=universal -Dsentry=false" >&2
  echo "Then set GHOSTTY_XCFRAMEWORK_SOURCE to the built GhosttyKit.xcframework path." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST_PATH")"
rm -rf "$DEST_PATH"
cp -R "$SOURCE_PATH" "$DEST_PATH"

echo "Installed GhosttyKit.xcframework to: $DEST_PATH"
echo "This variant is selected by build-configuration manifest settings when present."
echo "Run ./scripts/automation/check.sh to regenerate and validate with Ghostty enabled."
