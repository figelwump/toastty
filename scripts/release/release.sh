#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEME="ToasttyApp-Release"
WORKSPACE_PATH="$ROOT_DIR/toastty.xcworkspace"
APP_NAME="Toastty"
APP_BUNDLE_NAME="${APP_NAME}.app"
GHOSTTY_RELEASE_XCFRAMEWORK_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Release.xcframework"
SIGNING_IDENTITY=""
ATTACHED_DEVICE=""
MOUNT_POINT=""
MOUNTED_VOLUME_NAME=""
DS_STORE_PATH=""
RW_DMG_PATH=""

usage() {
  cat <<'EOF'
Build a signed, notarized Toastty DMG.

Required environment:
  TOASTTY_VERSION
  TOASTTY_BUILD_NUMBER
  TUIST_DEVELOPMENT_TEAM
  TOASTTY_APPLE_ID
  TOASTTY_NOTARY_PASSWORD
  TOASTTY_TEAM_ID

Recommended invocation:
  sv exec -- ./scripts/release/release.sh
EOF
}

log() {
  printf '[release] %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?

  if [[ -n "$ATTACHED_DEVICE" ]]; then
    hdiutil detach "$ATTACHED_DEVICE" -quiet >/dev/null 2>&1 \
      || hdiutil detach "$ATTACHED_DEVICE" -force -quiet >/dev/null 2>&1 \
      || true
  fi

  if [[ -n "$RW_DMG_PATH" && -f "$RW_DMG_PATH" ]]; then
    rm -f "$RW_DMG_PATH"
  fi

  return "$exit_code"
}

trap cleanup EXIT

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "required command not found: $command_name"
  fi
}

require_env() {
  local variable_name="$1"
  if [[ -z "${!variable_name:-}" ]]; then
    fail "required environment variable is unset: $variable_name"
  fi
}

validate_build_number() {
  if [[ ! "$TOASTTY_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    fail "TOASTTY_BUILD_NUMBER must be a monotonically increasing integer"
  fi
}

ensure_distribution_signing_inputs() {
  if [[ "${TUIST_DISABLE_GHOSTTY:-0}" == "1" || "${TOASTTY_DISABLE_GHOSTTY:-0}" == "1" ]]; then
    fail "release builds require Ghostty integration and cannot run with TUIST_DISABLE_GHOSTTY/TOASTTY_DISABLE_GHOSTTY enabled"
  fi
}

ensure_notarytool_available() {
  if ! xcrun notarytool --help >/dev/null 2>&1; then
    fail "xcrun notarytool is unavailable in the active Xcode installation"
  fi
}

ensure_developer_id_identity() {
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "Developer ID Application"; then
    fail "no Developer ID Application signing identity is installed in the local keychain"
  fi
}

ensure_ghostty_release_artifact() {
  local library_path=""

  [[ -d "$GHOSTTY_RELEASE_XCFRAMEWORK_PATH" ]] || fail "Ghostty release XCFramework not found at $GHOSTTY_RELEASE_XCFRAMEWORK_PATH"

  while IFS= read -r candidate; do
    if \
      lipo "$candidate" -verify_arch arm64 >/dev/null 2>&1 \
      && lipo "$candidate" -verify_arch x86_64 >/dev/null 2>&1
    then
      library_path="$candidate"
      break
    fi
  done < <(find "$GHOSTTY_RELEASE_XCFRAMEWORK_PATH" -type f \( -path '*/macos-*/*.a' \) | sort)

  [[ -n "$library_path" ]] || fail "Ghostty release XCFramework does not include a universal macOS static library slice (arm64 and x86_64)"
  log "Using Ghostty release library: $library_path"
}

write_export_options_plist() {
  cat >"$EXPORT_OPTIONS_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>${TUIST_DEVELOPMENT_TEAM}</string>
</dict>
</plist>
EOF
}

generate_workspace() {
  log "Generating workspace with distribution signing enabled"
  TUIST_TOASTTY_VERSION="$TOASTTY_VERSION" \
  TUIST_TOASTTY_BUILD_NUMBER="$TOASTTY_BUILD_NUMBER" \
  TUIST_DISTRIBUTION_SIGNING=1 \
  TUIST_DEVELOPMENT_TEAM="$TUIST_DEVELOPMENT_TEAM" \
  tuist generate --no-open
}

archive_app() {
  log "Archiving ${APP_NAME}"
  xcodebuild archive \
    -workspace "$WORKSPACE_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA_PATH"
}

export_app() {
  log "Exporting signed app bundle"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST_PATH"
}

verify_exported_app() {
  local exported_build_number=""
  local exported_version=""

  [[ -d "$EXPORTED_APP_PATH" ]] || fail "exported app not found at $EXPORTED_APP_PATH"
  log "Verifying exported app signature"
  codesign --verify --deep --strict --verbose=2 "$EXPORTED_APP_PATH"

  exported_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXPORTED_APP_PATH/Contents/Info.plist")"
  exported_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXPORTED_APP_PATH/Contents/Info.plist")"
  [[ "$exported_version" == "$TOASTTY_VERSION" ]] || fail "exported app version mismatch: expected $TOASTTY_VERSION, got $exported_version"
  [[ "$exported_build_number" == "$TOASTTY_BUILD_NUMBER" ]] || fail "exported app build number mismatch: expected $TOASTTY_BUILD_NUMBER, got $exported_build_number"

  SIGNING_IDENTITY="$(codesign -dv --verbose=4 "$EXPORTED_APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | grep -m1 '^Developer ID Application:' || true)"
  [[ -n "$SIGNING_IDENTITY" ]] || fail "failed to determine exported app signing identity"
}

stage_dmg_contents() {
  log "Staging DMG contents"
  mkdir -p "$DMG_STAGING_PATH"
  ditto "$EXPORTED_APP_PATH" "$DMG_STAGING_PATH/$APP_BUNDLE_NAME"
  ln -s /Applications "$DMG_STAGING_PATH/Applications"
}

create_writable_dmg() {
  log "Creating writable DMG"
  hdiutil create \
    -quiet \
    -format UDRW \
    -ov \
    -fs HFS+ \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING_PATH" \
    "$RW_DMG_PATH"
}

mount_writable_dmg() {
  local attach_output=""

  log "Mounting writable DMG"
  attach_output="$(hdiutil attach -readwrite -noautoopen "$RW_DMG_PATH")"
  ATTACHED_DEVICE="$(printf '%s\n' "$attach_output" | awk 'NR == 1 { print $1; exit }')"
  MOUNT_POINT="$(printf '%s\n' "$attach_output" | awk 'match($0, /\/Volumes\/.*/) { print substr($0, RSTART); exit }')"
  MOUNTED_VOLUME_NAME="$(basename "$MOUNT_POINT")"
  DS_STORE_PATH="$MOUNT_POINT/.DS_Store"

  [[ -n "$ATTACHED_DEVICE" ]] || fail "failed to determine mounted DMG device"
  [[ -n "$MOUNT_POINT" ]] || fail "failed to determine mounted DMG path"
  [[ -n "$MOUNTED_VOLUME_NAME" ]] || fail "failed to determine mounted DMG volume name"
}

customize_dmg_layout() {
  log "Customizing DMG Finder layout"
  if ! osascript - "$MOUNTED_VOLUME_NAME" "$APP_BUNDLE_NAME" <<'EOF'
on run argv
  set volumeName to item 1 of argv
  set appBundleName to item 2 of argv

  tell application "Finder"
    tell disk volumeName
      open
      delay 1

      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 780, 430}

      set theViewOptions to the icon view options of container window
      set arrangement of theViewOptions to not arranged
      set icon size of theViewOptions to 128
      set text size of theViewOptions to 16

      set position of item appBundleName of container window to {175, 135}
      set position of item "Applications" of container window to {435, 135}

      update without registering applications
      delay 2
      close container window
    end tell
  end tell
end run
EOF
  then
    fail "failed to customize DMG Finder layout; allow Terminal to control Finder and rerun"
  fi

  sync
}

wait_for_finder_layout_persistence() {
  local attempts=0
  local previous_snapshot=""
  local stable_snapshot_count=0
  local current_snapshot=""

  log "Waiting for Finder layout metadata to persist"

  while (( attempts < 15 )); do
    if [[ -f "$DS_STORE_PATH" ]]; then
      current_snapshot="$(stat -f '%m:%z' "$DS_STORE_PATH")"
      if [[ "$current_snapshot" == "$previous_snapshot" ]]; then
        stable_snapshot_count=$((stable_snapshot_count + 1))
      else
        previous_snapshot="$current_snapshot"
        stable_snapshot_count=0
      fi

      if (( stable_snapshot_count >= 2 )); then
        return 0
      fi
    fi

    attempts=$((attempts + 1))
    sleep 1
  done

  fail "Finder did not persist DMG layout metadata before detach"
}

detach_writable_dmg() {
  [[ -n "$ATTACHED_DEVICE" ]] || return 0

  log "Detaching writable DMG"
  hdiutil detach "$ATTACHED_DEVICE" -quiet \
    || hdiutil detach "$ATTACHED_DEVICE" -force -quiet \
    || fail "failed to detach writable DMG"

  ATTACHED_DEVICE=""
  MOUNT_POINT=""
  MOUNTED_VOLUME_NAME=""
  DS_STORE_PATH=""
}

create_dmg() {
  create_writable_dmg
  mount_writable_dmg
  customize_dmg_layout
  wait_for_finder_layout_persistence
  detach_writable_dmg

  log "Compressing DMG"
  hdiutil convert \
    -quiet \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$RW_DMG_PATH" \
    -o "$DMG_PATH"
}

sign_dmg() {
  log "Signing DMG"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp --verbose=2 "$DMG_PATH"
}

notarize_dmg() {
  log "Submitting DMG for notarization"
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$TOASTTY_APPLE_ID" \
    --password "$TOASTTY_NOTARY_PASSWORD" \
    --team-id "$TOASTTY_TEAM_ID" \
    --wait \
    --output-format json | tee "$NOTARIZATION_RESULT_PATH"
}

staple_dmg() {
  log "Stapling DMG"
  xcrun stapler staple -v "$DMG_PATH"
}

verify_final_artifacts() {
  log "Running final verification checks"
  codesign --verify --strict --verbose=2 "$DMG_PATH"
  spctl --assess --verbose=4 --type open --context context:primary-signature "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

require_command tuist
require_command xcodebuild
require_command codesign
require_command spctl
require_command hdiutil
require_command xcrun
require_command lipo
require_command security
require_command ditto
require_command osascript

require_env TOASTTY_VERSION
require_env TOASTTY_BUILD_NUMBER
require_env TUIST_DEVELOPMENT_TEAM
require_env TOASTTY_APPLE_ID
require_env TOASTTY_NOTARY_PASSWORD
require_env TOASTTY_TEAM_ID

validate_build_number
ensure_distribution_signing_inputs
ensure_notarytool_available
ensure_developer_id_identity
ensure_ghostty_release_artifact

RELEASE_LABEL="${TOASTTY_VERSION}-${TOASTTY_BUILD_NUMBER}"
RELEASE_DIR="$ROOT_DIR/artifacts/release/$RELEASE_LABEL"
DERIVED_DATA_PATH="$RELEASE_DIR/Derived"
ARCHIVE_PATH="$RELEASE_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$RELEASE_DIR/export"
EXPORTED_APP_PATH="$EXPORT_PATH/$APP_BUNDLE_NAME"
DMG_STAGING_PATH="$RELEASE_DIR/dmg"
DMG_PATH="$RELEASE_DIR/${APP_NAME}-${TOASTTY_VERSION}.dmg"
RW_DMG_PATH="$RELEASE_DIR/${APP_NAME}-${TOASTTY_VERSION}.rw.dmg"
EXPORT_OPTIONS_PLIST_PATH="$RELEASE_DIR/export-options.plist"
NOTARIZATION_RESULT_PATH="$RELEASE_DIR/notarization-result.json"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

cd "$ROOT_DIR"

write_export_options_plist
generate_workspace
archive_app
export_app
verify_exported_app
stage_dmg_contents
create_dmg
sign_dmg
notarize_dmg
staple_dmg
verify_final_artifacts

log "Release DMG ready: $DMG_PATH"
