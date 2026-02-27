#!/usr/bin/env bash
set -euo pipefail

if ! tuist generate; then
  exit 10
fi

if ! tuist build; then
  exit 10
fi

if ! xcodebuild test \
  -workspace toastty.xcworkspace \
  -scheme toastty-Workspace \
  -destination 'platform=macOS,arch=arm64'; then
  exit 11
fi
