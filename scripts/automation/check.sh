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

resolve_app_path() {
  local scheme="$1"
  local configuration="$2"
  local build_settings
  local target_build_dir
  local full_product_name

  build_settings="$(
    xcodebuild \
      -workspace toastty.xcworkspace \
      -scheme "$scheme" \
      -configuration "$configuration" \
      -showBuildSettings
  )"
  target_build_dir="$(printf '%s\n' "$build_settings" | awk -F ' = ' '/ TARGET_BUILD_DIR = / { print $2; exit }')"
  full_product_name="$(printf '%s\n' "$build_settings" | awk -F ' = ' '/ FULL_PRODUCT_NAME = / { print $2; exit }')"

  if [[ -z "$target_build_dir" || -z "$full_product_name" ]]; then
    echo "error: failed to resolve app path for scheme ${scheme} (${configuration})" >&2
    return 1
  fi

  printf '%s/%s\n' "$target_build_dir" "$full_product_name"
}

verify_child_process_tcc_metadata() {
  local scheme="$1"
  local configuration="$2"
  local app_path
  local info_plist
  local camera_usage
  local microphone_usage
  local entitlements_summary

  app_path="$(resolve_app_path "$scheme" "$configuration")" || return 1
  info_plist="$app_path/Contents/Info.plist"

  if [[ ! -f "$info_plist" ]]; then
    echo "error: expected Info.plist at ${info_plist}" >&2
    return 1
  fi

  camera_usage="$(plutil -extract NSCameraUsageDescription raw -o - "$info_plist" 2>/dev/null || true)"
  microphone_usage="$(plutil -extract NSMicrophoneUsageDescription raw -o - "$info_plist" 2>/dev/null || true)"

  if [[ -z "$camera_usage" ]]; then
    echo "error: missing NSCameraUsageDescription in ${info_plist}" >&2
    return 1
  fi

  if [[ -z "$microphone_usage" ]]; then
    echo "error: missing NSMicrophoneUsageDescription in ${info_plist}" >&2
    return 1
  fi

  entitlements_summary="$(
    codesign -d --entitlements :- "$app_path" 2>/dev/null | plutil -p - 2>/dev/null || true
  )"

  if [[ -z "$entitlements_summary" ]]; then
    echo "error: failed to read entitlements from ${app_path}" >&2
    return 1
  fi

  if ! printf '%s\n' "$entitlements_summary" | rg -q '"com.apple.security.device.camera" => true'; then
    echo "error: missing camera entitlement in ${app_path}" >&2
    return 1
  fi

  if ! printf '%s\n' "$entitlements_summary" | rg -q '"com.apple.security.device.audio-input" => true'; then
    echo "error: missing microphone entitlement in ${app_path}" >&2
    return 1
  fi
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

if ! verify_child_process_tcc_metadata "ToasttyApp" "Debug"; then
  exit 10
fi

if ! verify_child_process_tcc_metadata "ToasttyApp-Release" "Release"; then
  exit 10
fi

if ! "$ROOT_DIR/scripts/automation/workspace-tabs-smoke.sh"; then
  exit 10
fi

if ! xcodebuild test \
  -workspace toastty.xcworkspace \
  -scheme ToasttyApp \
  -destination "platform=macOS,arch=${ARCH}"; then
  exit 11
fi
