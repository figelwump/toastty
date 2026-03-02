#!/usr/bin/env bash
set -euo pipefail

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  ARCH="arm64"
fi

run_tuist() {
  if command -v sv >/dev/null 2>&1; then
    sv exec -- tuist "$@"
  else
    tuist "$@"
  fi
}

if ! run_tuist generate --no-open; then
  exit 10
fi

if ! run_tuist build; then
  exit 10
fi

if ! xcodebuild test \
  -workspace toastty.xcworkspace \
  -scheme toastty-Workspace \
  -destination "platform=macOS,arch=${ARCH}"; then
  exit 11
fi
