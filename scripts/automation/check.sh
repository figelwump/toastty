#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP_WORKTREE_SCRIPT="$ROOT_DIR/scripts/dev/bootstrap-worktree.sh"
ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  ARCH="arm64"
fi
MANIFEST_VALIDATION_VERSION="9.9.9"
MANIFEST_VALIDATION_BUILD_NUMBER="42"
MANIFEST_VALIDATE_LOG=""
MANIFEST_EMPTY_VALUE_LOG=""

cleanup() {
  rm -f "$MANIFEST_VALIDATE_LOG" "$MANIFEST_EMPTY_VALUE_LOG"
}

trap cleanup EXIT

run_tuist() {
  if command -v sv >/dev/null 2>&1; then
    sv exec -- tuist "$@"
  else
    tuist "$@"
  fi
}

restore_default_workspace() {
  "$BOOTSTRAP_WORKTREE_SCRIPT" >/dev/null 2>&1 || true
}

validate_manifest_version_inputs() {
  MANIFEST_VALIDATE_LOG="$(mktemp -t toastty-manifest-validate.XXXXXX.log)"
  MANIFEST_EMPTY_VALUE_LOG="$(mktemp -t toastty-manifest-empty.XXXXXX.log)"

  if ! TUIST_TOASTTY_VERSION="$MANIFEST_VALIDATION_VERSION" \
    TUIST_TOASTTY_BUILD_NUMBER="$MANIFEST_VALIDATION_BUILD_NUMBER" \
    "$BOOTSTRAP_WORKTREE_SCRIPT" >"$MANIFEST_VALIDATE_LOG" 2>&1; then
    cat "$MANIFEST_VALIDATE_LOG" >&2
    return 1
  fi

  if ! rg -q "MARKETING_VERSION = ${MANIFEST_VALIDATION_VERSION};" toastty.xcodeproj/project.pbxproj; then
    echo "expected MARKETING_VERSION ${MANIFEST_VALIDATION_VERSION} in generated project" >&2
    return 1
  fi

  if ! rg -q "CURRENT_PROJECT_VERSION = ${MANIFEST_VALIDATION_BUILD_NUMBER};" toastty.xcodeproj/project.pbxproj; then
    echo "expected CURRENT_PROJECT_VERSION ${MANIFEST_VALIDATION_BUILD_NUMBER} in generated project" >&2
    return 1
  fi

  if TUIST_TOASTTY_VERSION="" \
    "$BOOTSTRAP_WORKTREE_SCRIPT" >"$MANIFEST_EMPTY_VALUE_LOG" 2>&1; then
    echo "expected empty manifest version input to fail generation" >&2
    return 1
  fi

  if ! rg -q "TUIST_TOASTTY_VERSION must not be empty" "$MANIFEST_EMPTY_VALUE_LOG"; then
    cat "$MANIFEST_EMPTY_VALUE_LOG" >&2
    return 1
  fi
}

if ! validate_manifest_version_inputs; then
  restore_default_workspace
  exit 10
fi

if ! "$BOOTSTRAP_WORKTREE_SCRIPT"; then
  exit 10
fi

if ! run_tuist build; then
  exit 10
fi

if ! xcodebuild test \
  -workspace toastty.xcworkspace \
  -scheme ToasttyApp \
  -destination "platform=macOS,arch=${ARCH}"; then
  exit 11
fi
