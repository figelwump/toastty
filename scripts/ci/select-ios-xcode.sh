#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPECTED="$(cat "$ROOT_DIR/.github/ios-xcode-version")"
VERSION="$(sed -n 's/^Xcode //p' "$ROOT_DIR/.github/ios-xcode-version")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo 'Invalid iOS Xcode version pin.' >&2; exit 1; }
export DEVELOPER_DIR="/Applications/Xcode_${VERSION}.app/Contents/Developer"
ACTUAL="$(xcodebuild -version)" || { echo "Pinned Xcode $VERSION is unavailable." >&2; exit 1; }
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  printf 'Xcode does not match .github/ios-xcode-version.\nExpected:\n%s\nActual:\n%s\n' "$EXPECTED" "$ACTUAL" >&2
  exit 1
fi
printf '%s\n' "$ACTUAL"
printf 'DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR" >>"${GITHUB_ENV:?GITHUB_ENV is required}"
