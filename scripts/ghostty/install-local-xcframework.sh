#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_PATH="${GHOSTTY_XCFRAMEWORK_SOURCE:-/tmp/toastty-ghostty-spike/ghostty/macos/GhosttyKit.xcframework}"
DEST_PATH="$ROOT_DIR/Dependencies/GhosttyKit.xcframework"

if [[ ! -d "$SOURCE_PATH" ]]; then
  echo "Ghostty xcframework not found at: $SOURCE_PATH" >&2
  echo "Set GHOSTTY_XCFRAMEWORK_SOURCE to the built GhosttyKit.xcframework path." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST_PATH")"
rm -rf "$DEST_PATH"
cp -R "$SOURCE_PATH" "$DEST_PATH"

echo "Installed GhosttyKit.xcframework to: $DEST_PATH"
echo "Run ./scripts/automation/check.sh to regenerate and validate with Ghostty enabled."
