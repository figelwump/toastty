#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEME="ToasttyApp-Release"
WORKSPACE_PATH="$ROOT_DIR/toastty.xcworkspace"
APP_NAME="Toastty"
APP_BUNDLE_NAME="${APP_NAME}.app"
CLI_NAME="toastty"
ARCHIVED_CLI_RELATIVE_PATH="usr/local/bin/${CLI_NAME}"
BUNDLED_CLI_RELATIVE_PATH="Contents/MacOS/${CLI_NAME}"
GHOSTTY_RELEASE_XCFRAMEWORK_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Release.xcframework"
GHOSTTY_RELEASE_METADATA_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Release.metadata.env"
SPARKLE_TOOLS_DIRECTORY=""
SIGNING_IDENTITY=""
ATTACHED_DEVICE=""
MOUNT_POINT=""
MOUNTED_VOLUME_NAME=""
DS_STORE_PATH=""
RW_DMG_PATH=""
SOURCE_COMMIT=""
SOURCE_COMMIT_SHORT=""
SOURCE_COMMIT_DATE=""
SOURCE_BRANCH=""
PREVIOUS_RELEASE_TAG=""
PREVIOUS_RELEASE_COMMIT=""
PREVIOUS_RELEASE_COMMIT_SHORT=""
GHOSTTY_COMMIT=""
GHOSTTY_COMMIT_SHORT=""
GHOSTTY_SOURCE_PATH=""
GHOSTTY_SOURCE_REPO=""
GHOSTTY_SOURCE_DIRTY=""
GHOSTTY_BUILD_FLAGS=""
GHOSTTY_INSTALLED_AT=""
GHOSTTY_METADATA_SNAPSHOT_PATH=""
SPARKLE_METADATA_PATH=""
SPARKLE_FEED_URL=""
SPARKLE_PUBLIC_ED_KEY=""
SPARKLE_MINIMUM_SYSTEM_VERSION=""
SPARKLE_ED_SIGNATURE=""
SPARKLE_ENCLOSURE_LENGTH=""
RELEASE_NOTES_PATH=""
RELEASE_METADATA_PATH=""

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
  TOASTTY_SPARKLE_PRIVATE_KEY

Additional requirements:
  - clean Toastty git working tree
  - Dependencies/GhosttyKit.Release.metadata.env with clean Ghostty provenance

Outputs:
  artifacts/release/<version>-<build>/release-metadata.env
  artifacts/release/<version>-<build>/ghostty-metadata.env
  artifacts/release/<version>-<build>/sparkle-metadata.env
  artifacts/release/<version>-<build>/Toastty-<version>.dmg

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

write_env_assignment() {
  local file_path="$1"
  local variable_name="$2"
  local value="$3"

  printf '%s=%q\n' "$variable_name" "$value" >>"$file_path"
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

validate_version_string() {
  if [[ ! "$TOASTTY_VERSION" =~ ^[0-9A-Za-z.+-]+$ ]]; then
    fail "TOASTTY_VERSION may only contain letters, numbers, dots, plus signs, and hyphens"
  fi
}

ensure_clean_worktree() {
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    fail "release builds require a clean git working tree"
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
  local identities=""

  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if [[ "$identities" != *"Developer ID Application"* ]]; then
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
  done < <(find -L "$GHOSTTY_RELEASE_XCFRAMEWORK_PATH" -type f \( -path '*/macos-*/*.a' \) | sort)

  [[ -n "$library_path" ]] || fail "Ghostty release XCFramework does not include a universal macOS static library slice (arm64 and x86_64)"
  log "Using Ghostty release library: $library_path"
}

load_ghostty_release_metadata() {
  # shellcheck disable=SC1090
  source "$GHOSTTY_RELEASE_METADATA_PATH"

  GHOSTTY_COMMIT="${GHOSTTY_COMMIT:-}"
  GHOSTTY_COMMIT_SHORT="${GHOSTTY_COMMIT_SHORT:-}"
  GHOSTTY_SOURCE_PATH="${GHOSTTY_SOURCE_PATH:-}"
  GHOSTTY_SOURCE_REPO="${GHOSTTY_SOURCE_REPO:-}"
  GHOSTTY_SOURCE_DIRTY="${GHOSTTY_SOURCE_DIRTY:-}"
  GHOSTTY_BUILD_FLAGS="${GHOSTTY_BUILD_FLAGS:-}"
  GHOSTTY_INSTALLED_AT="${GHOSTTY_INSTALLED_AT:-}"
}

ensure_ghostty_release_metadata() {
  [[ -f "$GHOSTTY_RELEASE_METADATA_PATH" ]] || fail "Ghostty release metadata not found at $GHOSTTY_RELEASE_METADATA_PATH; reinstall the artifact with ./scripts/ghostty/install-local-xcframework.sh"

  load_ghostty_release_metadata

  [[ -n "$GHOSTTY_COMMIT" ]] || fail "Ghostty release metadata is missing GHOSTTY_COMMIT; reinstall the artifact from a Ghostty checkout or pass GHOSTTY_COMMIT"
  [[ -n "$GHOSTTY_BUILD_FLAGS" ]] || fail "Ghostty release metadata is missing GHOSTTY_BUILD_FLAGS; reinstall the artifact with GHOSTTY_BUILD_FLAGS set"
  [[ "$GHOSTTY_SOURCE_DIRTY" == "0" ]] || fail "Ghostty release metadata reports a non-clean source snapshot (GHOSTTY_SOURCE_DIRTY=$GHOSTTY_SOURCE_DIRTY); rebuild/install Ghostty from a clean source tree"

  if [[ -z "$GHOSTTY_COMMIT_SHORT" ]]; then
    GHOSTTY_COMMIT_SHORT="${GHOSTTY_COMMIT:0:12}"
  fi
}

resolve_sparkle_tools_directory() {
  local candidate=""

  for candidate in \
    "$ROOT_DIR/Tuist/.build/artifacts/sparkle/Sparkle/bin" \
    "$ROOT_DIR/Tuist/.build/checkouts/Sparkle/bin"
  do
    if [[ -x "$candidate/sign_update" ]]; then
      SPARKLE_TOOLS_DIRECTORY="$candidate"
      return 0
    fi
  done

  fail "Sparkle tools not found; run 'tuist install' and ensure Sparkle artifacts are available under Tuist/.build"
}

resolve_source_provenance() {
  local exact_tag=""

  SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  SOURCE_COMMIT_SHORT="$(git -C "$ROOT_DIR" rev-parse --short=12 "$SOURCE_COMMIT")"
  SOURCE_COMMIT_DATE="$(git -C "$ROOT_DIR" show -s --format=%cI "$SOURCE_COMMIT")"
  SOURCE_BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
  exact_tag="$(git -C "$ROOT_DIR" describe --tags --exact-match "$SOURCE_COMMIT" 2>/dev/null || true)"

  if [[ -n "$exact_tag" ]]; then
    if git -C "$ROOT_DIR" rev-parse "${SOURCE_COMMIT}^" >/dev/null 2>&1; then
      PREVIOUS_RELEASE_TAG="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 "${SOURCE_COMMIT}^" 2>/dev/null || true)"
    fi
  else
    PREVIOUS_RELEASE_TAG="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 "$SOURCE_COMMIT" 2>/dev/null || true)"
  fi

  if [[ -n "$PREVIOUS_RELEASE_TAG" ]]; then
    PREVIOUS_RELEASE_COMMIT="$(git -C "$ROOT_DIR" rev-list -n1 "$PREVIOUS_RELEASE_TAG")"
    PREVIOUS_RELEASE_COMMIT_SHORT="$(git -C "$ROOT_DIR" rev-parse --short=12 "$PREVIOUS_RELEASE_COMMIT")"
  fi
}

snapshot_ghostty_metadata() {
  log "Snapshotting Ghostty release metadata"
  : >"$GHOSTTY_METADATA_SNAPSHOT_PATH"
  write_env_assignment "$GHOSTTY_METADATA_SNAPSHOT_PATH" "GHOSTTY_XCFRAMEWORK_VARIANT" "release"
  write_env_assignment "$GHOSTTY_METADATA_SNAPSHOT_PATH" "GHOSTTY_SOURCE_PATH" "$GHOSTTY_SOURCE_PATH"
  write_env_assignment "$GHOSTTY_METADATA_SNAPSHOT_PATH" "GHOSTTY_SOURCE_REPO" "$GHOSTTY_SOURCE_REPO"
  write_env_assignment "$GHOSTTY_METADATA_SNAPSHOT_PATH" "GHOSTTY_COMMIT" "$GHOSTTY_COMMIT"
  write_env_assignment "$GHOSTTY_METADATA_SNAPSHOT_PATH" "GHOSTTY_COMMIT_SHORT" "$GHOSTTY_COMMIT_SHORT"
  write_env_assignment "$GHOSTTY_METADATA_SNAPSHOT_PATH" "GHOSTTY_SOURCE_DIRTY" "$GHOSTTY_SOURCE_DIRTY"
  write_env_assignment "$GHOSTTY_METADATA_SNAPSHOT_PATH" "GHOSTTY_BUILD_FLAGS" "$GHOSTTY_BUILD_FLAGS"
  write_env_assignment "$GHOSTTY_METADATA_SNAPSHOT_PATH" "GHOSTTY_INSTALLED_AT" "$GHOSTTY_INSTALLED_AT"
}

snapshot_sparkle_metadata() {
  log "Snapshotting Sparkle release metadata"
  : >"$SPARKLE_METADATA_PATH"
  write_env_assignment "$SPARKLE_METADATA_PATH" "SPARKLE_FEED_URL" "$SPARKLE_FEED_URL"
  write_env_assignment "$SPARKLE_METADATA_PATH" "SPARKLE_PUBLIC_ED_KEY" "$SPARKLE_PUBLIC_ED_KEY"
  write_env_assignment "$SPARKLE_METADATA_PATH" "SPARKLE_MINIMUM_SYSTEM_VERSION" "$SPARKLE_MINIMUM_SYSTEM_VERSION"
  write_env_assignment "$SPARKLE_METADATA_PATH" "SPARKLE_DMG_PATH" "$DMG_PATH"
  write_env_assignment "$SPARKLE_METADATA_PATH" "SPARKLE_DMG_FILENAME" "$(basename "$DMG_PATH")"
  write_env_assignment "$SPARKLE_METADATA_PATH" "SPARKLE_ENCLOSURE_LENGTH" "$SPARKLE_ENCLOSURE_LENGTH"
  write_env_assignment "$SPARKLE_METADATA_PATH" "SPARKLE_ED_SIGNATURE" "$SPARKLE_ED_SIGNATURE"
}

write_release_metadata() {
  : >"$RELEASE_METADATA_PATH"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_VERSION" "$TOASTTY_VERSION"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_BUILD_NUMBER" "$TOASTTY_BUILD_NUMBER"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_LABEL" "$RELEASE_LABEL"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_CREATED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_SOURCE_COMMIT" "$SOURCE_COMMIT"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_SOURCE_COMMIT_SHORT" "$SOURCE_COMMIT_SHORT"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_SOURCE_COMMIT_DATE" "$SOURCE_COMMIT_DATE"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_SOURCE_BRANCH" "$SOURCE_BRANCH"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_SOURCE_DIRTY" "0"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_PREVIOUS_TAG" "$PREVIOUS_RELEASE_TAG"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_PREVIOUS_COMMIT" "$PREVIOUS_RELEASE_COMMIT"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_PREVIOUS_COMMIT_SHORT" "$PREVIOUS_RELEASE_COMMIT_SHORT"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_DMG_PATH" "$DMG_PATH"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_NOTES_PATH" "$RELEASE_NOTES_PATH"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_GHOSTTY_METADATA_PATH" "$GHOSTTY_METADATA_SNAPSHOT_PATH"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_SPARKLE_METADATA_PATH" "$SPARKLE_METADATA_PATH"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_GHOSTTY_COMMIT" "$GHOSTTY_COMMIT"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_GHOSTTY_COMMIT_SHORT" "$GHOSTTY_COMMIT_SHORT"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_GHOSTTY_SOURCE_REPO" "$GHOSTTY_SOURCE_REPO"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_GHOSTTY_SOURCE_DIRTY" "$GHOSTTY_SOURCE_DIRTY"
  write_env_assignment "$RELEASE_METADATA_PATH" "RELEASE_GHOSTTY_BUILD_FLAGS" "$GHOSTTY_BUILD_FLAGS"
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

install_tuist_dependencies() {
  log "Installing Tuist dependencies"
  tuist install

  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    fail "tuist install changed tracked files; commit dependency resolution updates before building a release"
  fi

  resolve_sparkle_tools_directory
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
  local archived_app_path="$ARCHIVE_PATH/Products/Applications/$APP_BUNDLE_NAME"

  [[ -d "$archived_app_path" ]] || fail "archived app not found at $archived_app_path"
  log "Copying signed app bundle from archive"
  rm -rf "$EXPORT_PATH"
  mkdir -p "$EXPORT_PATH"
  ditto "$archived_app_path" "$EXPORTED_APP_PATH"
}

bundle_cli_into_exported_app() {
  local archived_cli_path="$ARCHIVE_PATH/Products/$ARCHIVED_CLI_RELATIVE_PATH"
  local bundled_cli_path="$EXPORTED_APP_PATH/$BUNDLED_CLI_RELATIVE_PATH"

  [[ -x "$archived_cli_path" ]] || fail "archived CLI not found at $archived_cli_path"
  log "Bundling ${CLI_NAME} CLI into exported app"
  ditto "$archived_cli_path" "$bundled_cli_path"
  chmod 755 "$bundled_cli_path"
  [[ -x "$bundled_cli_path" ]] || fail "failed to bundle CLI into exported app at $bundled_cli_path"
}

verify_exported_app() {
  local exported_build_number=""
  local exported_feed_url=""
  local exported_minimum_system_version=""
  local exported_public_ed_key=""
  local exported_version=""

  [[ -d "$EXPORTED_APP_PATH" ]] || fail "exported app not found at $EXPORTED_APP_PATH"
  log "Verifying exported app signature"
  codesign --verify --deep --strict --verbose=2 "$EXPORTED_APP_PATH"

  exported_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXPORTED_APP_PATH/Contents/Info.plist")"
  exported_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXPORTED_APP_PATH/Contents/Info.plist")"
  exported_feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$EXPORTED_APP_PATH/Contents/Info.plist")"
  exported_minimum_system_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$EXPORTED_APP_PATH/Contents/Info.plist")"
  exported_public_ed_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$EXPORTED_APP_PATH/Contents/Info.plist")"
  [[ "$exported_version" == "$TOASTTY_VERSION" ]] || fail "exported app version mismatch: expected $TOASTTY_VERSION, got $exported_version"
  [[ "$exported_build_number" == "$TOASTTY_BUILD_NUMBER" ]] || fail "exported app build number mismatch: expected $TOASTTY_BUILD_NUMBER, got $exported_build_number"
  [[ -n "$exported_feed_url" ]] || fail "exported app is missing SUFeedURL"
  [[ -n "$exported_minimum_system_version" ]] || fail "exported app is missing LSMinimumSystemVersion"
  [[ -n "$exported_public_ed_key" ]] || fail "exported app is missing SUPublicEDKey"

  SIGNING_IDENTITY="$(codesign -dv --verbose=4 "$EXPORTED_APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | grep -m1 '^Developer ID Application:' || true)"
  [[ -n "$SIGNING_IDENTITY" ]] || fail "failed to determine exported app signing identity"
  SPARKLE_FEED_URL="$exported_feed_url"
  SPARKLE_MINIMUM_SYSTEM_VERSION="$exported_minimum_system_version"
  SPARKLE_PUBLIC_ED_KEY="$exported_public_ed_key"
}

resign_exported_app_for_distribution() {
  local bundled_cli_path="$EXPORTED_APP_PATH/$BUNDLED_CLI_RELATIVE_PATH"

  [[ -x "$bundled_cli_path" ]] || fail "exported app is missing bundled CLI at $bundled_cli_path"
  # Copying the archived app preserves ad-hoc signatures on Sparkle's nested
  # helper binaries, so re-sign the copied bundle recursively before packaging.
  log "Re-signing exported app bundle for distribution"
  codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$EXPORTED_APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$EXPORTED_APP_PATH"
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

sign_dmg_for_sparkle() {
  local sign_update_path="$SPARKLE_TOOLS_DIRECTORY/sign_update"

  log "Signing DMG for Sparkle updates"
  SPARKLE_ED_SIGNATURE="$(
    printf '%s\n' "$TOASTTY_SPARKLE_PRIVATE_KEY" \
      | "$sign_update_path" --ed-key-file - -p "$DMG_PATH" \
      | tr -d '\n'
  )"
  SPARKLE_ENCLOSURE_LENGTH="$(stat -f '%z' "$DMG_PATH")"

  [[ "$SPARKLE_ED_SIGNATURE" =~ ^[A-Za-z0-9+/=]+$ ]] \
    || fail "Sparkle signature output is empty or malformed"
  [[ "$SPARKLE_ENCLOSURE_LENGTH" =~ ^[0-9]+$ && "$SPARKLE_ENCLOSURE_LENGTH" -gt 0 ]] \
    || fail "failed to determine Sparkle enclosure length for $DMG_PATH"

  printf '%s\n' "$TOASTTY_SPARKLE_PRIVATE_KEY" \
    | "$sign_update_path" --ed-key-file - --verify "$DMG_PATH" "$SPARKLE_ED_SIGNATURE" >/dev/null
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
require_command git

require_env TOASTTY_VERSION
require_env TOASTTY_BUILD_NUMBER
require_env TUIST_DEVELOPMENT_TEAM
require_env TOASTTY_APPLE_ID
require_env TOASTTY_NOTARY_PASSWORD
require_env TOASTTY_TEAM_ID
require_env TOASTTY_SPARKLE_PRIVATE_KEY

validate_build_number
validate_version_string
ensure_clean_worktree
ensure_distribution_signing_inputs
ensure_notarytool_available
ensure_developer_id_identity
ensure_ghostty_release_artifact
ensure_ghostty_release_metadata
resolve_source_provenance

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
GHOSTTY_METADATA_SNAPSHOT_PATH="$RELEASE_DIR/ghostty-metadata.env"
SPARKLE_METADATA_PATH="$RELEASE_DIR/sparkle-metadata.env"
RELEASE_NOTES_PATH="$RELEASE_DIR/release-notes.md"
RELEASE_METADATA_PATH="$RELEASE_DIR/release-metadata.env"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

cd "$ROOT_DIR"

install_tuist_dependencies
write_export_options_plist
generate_workspace
archive_app
export_app
verify_exported_app
bundle_cli_into_exported_app
resign_exported_app_for_distribution
stage_dmg_contents
create_dmg
sign_dmg
notarize_dmg
staple_dmg
verify_final_artifacts
sign_dmg_for_sparkle
snapshot_ghostty_metadata
snapshot_sparkle_metadata
write_release_metadata

log "Release DMG ready: $DMG_PATH"
log "Release metadata snapshot: $RELEASE_METADATA_PATH"
log "Sparkle metadata snapshot: $SPARKLE_METADATA_PATH"
log "Author release notes before publish: $RELEASE_NOTES_PATH"
