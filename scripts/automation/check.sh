#!/usr/bin/env bash
set -euo pipefail

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  ARCH="arm64"
fi

if ! tuist generate; then
  exit 10
fi

if ! tuist build; then
  exit 10
fi

if ! xcodebuild test \
  -workspace toastty.xcworkspace \
  -scheme toastty-Workspace \
  -destination "platform=macOS,arch=${ARCH}"; then
  exit 11
fi
