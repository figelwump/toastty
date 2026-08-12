#!/usr/bin/env bash
set -euo pipefail
umask 077

IOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REPO_ROOT="$(cd "$IOS_ROOT/.." && pwd -P)"
RUN_ID="${TOASTTY_NATIVE_DEVICE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_ROOT="${TOASTTY_NATIVE_DEVICE_RUN_ROOT:-$IOS_ROOT/.build-runs/native-device/$RUN_ID}"
DERIVED_DATA_PATH="${TOASTTY_NATIVE_DEVICE_DERIVED_DATA_PATH:-$RUN_ROOT/DerivedData}"
RUN_LOCK_DIR="$IOS_ROOT/.build-runs/native-device/device-run.lock"
LOG_DIR="$RUN_ROOT/logs"
STATE_DIR="$RUN_ROOT/state"
GENERATED_BACKUP_DIR="$STATE_DIR/generated-project-backup"
DEVICE_LIST_PATH="$STATE_DIR/physical-devices.json"
DEVICE_INFO_PATH="$STATE_DIR/physical-device.json"
PREFLIGHT_PATH="$STATE_DIR/preflight.json"
INSTANCE_PATH="$RUN_ROOT/instance.json"
BUILD_SETTINGS_PATH="$STATE_DIR/debug-build-settings.json"
DEVICE_HELPER="$IOS_ROOT/scripts/lib/physical-device.mjs"
BUILD_VALIDATOR="$IOS_ROOT/scripts/lib/validate-device-build.mjs"

BUILD_CONFIGURATION="${TOASTTY_NATIVE_DEVICE_BUILD_CONFIGURATION:-Debug}"
BUILD_ONLY="${TOASTTY_NATIVE_DEVICE_BUILD_ONLY:-0}"
BUNDLE_ID="${TOASTTY_NATIVE_DEVICE_BUNDLE_ID:-}"
DEVELOPMENT_TEAM="${TOASTTY_NATIVE_DEVICE_DEVELOPMENT_TEAM:-}"
DISPLAY_NAME="${TOASTTY_NATIVE_DEVICE_DISPLAY_NAME:-}"
PREFLIGHT_ONLY="${TOASTTY_NATIVE_DEVICE_PREFLIGHT_ONLY:-0}"
REQUESTED_DEVICE="${TOASTTY_NATIVE_DEVICE_REQUESTED:-}"
URL_SCHEME="${TOASTTY_NATIVE_DEVICE_URL_SCHEME:-}"
APP_PATH=""
ACTIVE_CHILD_PID=""
GENERATED_STATE_CAPTURED=0
RUN_LOCK_HELD=0
GENERATED_PATHS=(ToasttyMobile.xcodeproj ToasttyMobile.xcworkspace Derived)

log() {
  printf '[toastty-native-device] %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    fail "$name is required for physical iPhone deployment"
  fi
}

require_value() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "$name is required; run this helper through 'node ios/scripts/toastty-ios.mjs native-device'"
  fi
}

validate_flag() {
  local name="$1"
  case "${!name}" in
    0|1) ;;
    *) fail "$name must be 0 or 1" ;;
  esac
}

validate_paths() {
  if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [[ "$RUN_ID" == *..* ]]; then
    fail "TOASTTY_NATIVE_DEVICE_RUN_ID may contain only letters, numbers, dot, underscore, and hyphen"
  fi
  case "$RUN_ROOT" in /*) ;; *) fail "TOASTTY_NATIVE_DEVICE_RUN_ROOT must be an absolute path" ;; esac
  case "$RUN_ROOT" in *"/../"*|*"/./"*|*/..|*/.) fail "TOASTTY_NATIVE_DEVICE_RUN_ROOT must not contain dot path components" ;; esac
  case "$DERIVED_DATA_PATH" in "$RUN_ROOT/"*) ;; *) fail "TOASTTY_NATIVE_DEVICE_DERIVED_DATA_PATH must be inside $RUN_ROOT" ;; esac
  case "$DERIVED_DATA_PATH" in *"/../"*|*"/./"*|*/..|*/.) fail "TOASTTY_NATIVE_DEVICE_DERIVED_DATA_PATH must not contain dot path components" ;; esac
  case "$RUN_ROOT" in
    /|"$REPO_ROOT"|"$IOS_ROOT") fail "TOASTTY_NATIVE_DEVICE_RUN_ROOT is too broad: $RUN_ROOT" ;;
  esac
  case "$DERIVED_DATA_PATH" in
    /|"$REPO_ROOT"|"$IOS_ROOT"|"$RUN_ROOT")
      fail "TOASTTY_NATIVE_DEVICE_DERIVED_DATA_PATH is too broad: $DERIVED_DATA_PATH"
      ;;
  esac
}

capture_generated_project_state() {
  local relative_path source_path
  mkdir -p "$GENERATED_BACKUP_DIR"
  for relative_path in "${GENERATED_PATHS[@]}"; do
    source_path="$IOS_ROOT/$relative_path"
    if [[ -e "$source_path" || -L "$source_path" ]]; then
      cp -Rp "$source_path" "$GENERATED_BACKUP_DIR/$relative_path"
      touch "$GENERATED_BACKUP_DIR/$relative_path.existed"
    fi
  done
  GENERATED_STATE_CAPTURED=1
}

restore_generated_project_state() {
  local relative_path destination_path backup_path restore_path restore_failed=0
  if [[ "$GENERATED_STATE_CAPTURED" != "1" ]]; then
    return 0
  fi

  for relative_path in "${GENERATED_PATHS[@]}"; do
    destination_path="$IOS_ROOT/$relative_path"
    if [[ -f "$GENERATED_BACKUP_DIR/$relative_path.existed" ]]; then
      backup_path="$GENERATED_BACKUP_DIR/$relative_path"
      restore_path="$IOS_ROOT/.toastty-native-device-restore-$RUN_ID-$relative_path"
      if [[ ! -e "$backup_path" && ! -L "$backup_path" ]]; then
        printf 'error: generated-project backup is incomplete: %s\n' "$backup_path" >&2
        restore_failed=1
        continue
      fi
      rm -rf "$restore_path"
      if ! cp -Rp "$backup_path" "$restore_path"; then
        restore_failed=1
        continue
      fi
      if ! rm -rf "$destination_path" || ! mv "$restore_path" "$destination_path"; then
        restore_failed=1
      fi
    elif ! rm -rf "$destination_path"; then
      restore_failed=1
    fi
  done

  if ((restore_failed != 0)); then
    return 1
  fi
  GENERATED_STATE_CAPTURED=0
  rm -rf "$GENERATED_BACKUP_DIR"
}

acquire_run_lock() {
  local owner_pid="" stale_lock=""
  mkdir -p "$(dirname "$RUN_LOCK_DIR")"
  if mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
    RUN_LOCK_HELD=1
  elif [[ -f "$RUN_LOCK_DIR/owner.pid" ]]; then
    IFS= read -r owner_pid <"$RUN_LOCK_DIR/owner.pid" || true
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && [[ -z "$(ps -p "$owner_pid" -o pid= 2>/dev/null)" ]]; then
      stale_lock="$RUN_LOCK_DIR.stale-$RUN_ID"
    fi
  elif find "$RUN_LOCK_DIR" -maxdepth 0 -mmin +10 -print -quit 2>/dev/null | grep -q .; then
    stale_lock="$RUN_LOCK_DIR.stale-$RUN_ID"
  fi
  if [[ -n "$stale_lock" ]] && mv "$RUN_LOCK_DIR" "$stale_lock" 2>/dev/null; then
    rm -rf "$stale_lock"
    if mkdir "$RUN_LOCK_DIR" 2>/dev/null; then RUN_LOCK_HELD=1; fi
  fi

  if [[ "$RUN_LOCK_HELD" != "1" ]]; then
    fail "another Toastty native-device run owns $RUN_LOCK_DIR; wait for it to finish"
  fi
  printf '%s\n' "$$" >"$RUN_LOCK_DIR/owner.pid"
  printf 'pid=%s run_id=%s started_at=%s\n' \
    "$$" "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$RUN_LOCK_DIR/owner.txt"
}

release_run_lock() {
  local owner_pid=""
  if [[ "$RUN_LOCK_HELD" != "1" ]]; then
    return 0
  fi
  if [[ -f "$RUN_LOCK_DIR/owner.pid" ]]; then
    IFS= read -r owner_pid <"$RUN_LOCK_DIR/owner.pid" || true
  fi
  if [[ "$owner_pid" != "$$" ]]; then
    printf 'error: refusing to remove native-device lock owned by pid %s: %s\n' \
      "${owner_pid:-unknown}" "$RUN_LOCK_DIR" >&2
    return 1
  fi
  rm -rf "$RUN_LOCK_DIR"
  RUN_LOCK_HELD=0
}

cleanup_native_device_run() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$ACTIVE_CHILD_PID" =~ ^[0-9]+$ ]] && kill -0 "$ACTIVE_CHILD_PID" 2>/dev/null; then
    kill "$ACTIVE_CHILD_PID" 2>/dev/null || true
    wait "$ACTIVE_CHILD_PID" 2>/dev/null || true
  fi
  ACTIVE_CHILD_PID=""
  if ! restore_generated_project_state; then
    printf 'error: failed to restore the generated Xcode workspace; backup: %s\n' \
      "$GENERATED_BACKUP_DIR" >&2
    if ((status == 0)); then status=1; fi
  fi
  if ! release_run_lock; then
    if ((status == 0)); then status=1; fi
  fi
  exit "$status"
}

run_logged_command() {
  local log_path="$1"
  shift
  (
    cd "$IOS_ROOT"
    exec "$@"
  ) >"$log_path" 2>&1 &
  ACTIVE_CHILD_PID=$!
  local command_status=0
  wait "$ACTIVE_CHILD_PID" || command_status=$?
  ACTIVE_CHILD_PID=""
  return "$command_status"
}

refresh_selected_device_services() {
  local phase="$1"
  log "Refreshing CoreDevice services after failed $phase attempt" >&2
  xcrun devicectl device info details \
    --device "$DEVICE_IDENTIFIER" \
    --timeout 20 \
    --json-output "$STATE_DIR/device-$phase-reconnect.json" \
    --log-output "$LOG_DIR/devicectl-device-$phase-reconnect.log" \
    --quiet >/dev/null 2>&1 || true
  sleep 1
}

install_signed_app() {
  local attempt
  for ((attempt = 1; attempt <= 2; attempt += 1)); do
    if xcrun devicectl device install app \
      --device "$DEVICE_IDENTIFIER" \
      --timeout 120 \
      "$APP_PATH" \
      --json-output "$STATE_DIR/install-attempt-$attempt.json" \
      --log-output "$LOG_DIR/devicectl-install-attempt-$attempt.log"; then
      return 0
    fi
    if ((attempt < 2)); then refresh_selected_device_services install; fi
  done
  return 1
}

launch_installed_app() {
  local attempt
  for ((attempt = 1; attempt <= 2; attempt += 1)); do
    if xcrun devicectl device process launch \
      --device "$DEVICE_IDENTIFIER" \
      --timeout 30 \
      --terminate-existing \
      "$BUNDLE_ID" \
      --json-output "$STATE_DIR/launch-attempt-$attempt.json" \
      --log-output "$LOG_DIR/devicectl-launch-attempt-$attempt.log"; then
      return 0
    fi
    if ((attempt < 2)); then refresh_selected_device_services launch; fi
  done
  return 1
}

list_is_usable() {
  node "$DEVICE_HELPER" validate-list --input "$DEVICE_LIST_PATH" >/dev/null 2>&1
}

list_physical_devices() {
  local attempt
  for ((attempt = 1; attempt <= 2; attempt += 1)); do
    rm -f "$DEVICE_LIST_PATH"
    xcrun devicectl list devices \
      --json-output "$DEVICE_LIST_PATH" \
      --quiet >/dev/null 2>"$LOG_DIR/devicectl-list-attempt-$attempt.log" || true
    if [[ -f "$DEVICE_LIST_PATH" ]] && list_is_usable; then
      return 0
    fi
    if ((attempt < 2)); then
      log "CoreDevice did not return a usable device list; retrying" >&2
      sleep 1
    fi
  done
  return 0
}

warm_connect_devices() {
  local targets target name safe_target
  local args=(warm-targets --input "$DEVICE_LIST_PATH")
  if [[ -n "$REQUESTED_DEVICE" ]]; then args+=(--requested "$REQUESTED_DEVICE"); fi
  targets="$(node "$DEVICE_HELPER" "${args[@]}" 2>/dev/null || true)"
  if [[ -z "$targets" ]]; then return 1; fi

  while IFS=$'\t' read -r target name; do
    [[ -z "$target" ]] && continue
    safe_target="$(printf '%s' "$target" | tr -c '[:alnum:]._-' '-')"
    log "Refreshing CoreDevice services for ${name:-physical iPhone}" >&2
    xcrun devicectl device info details \
      --device "$target" \
      --timeout 20 \
      --json-output "$STATE_DIR/device-warm-connect-$safe_target.json" \
      --log-output "$LOG_DIR/devicectl-device-warm-connect-$safe_target.log" \
      --quiet >/dev/null 2>&1 || true
  done <<<"$targets"
  return 0
}

select_physical_device() {
  local mode="$1"
  local args=(select --input "$DEVICE_LIST_PATH" --output "$DEVICE_INFO_PATH")
  if [[ -n "$REQUESTED_DEVICE" ]]; then args+=(--requested "$REQUESTED_DEVICE"); fi
  if [[ "$mode" == "probe" ]]; then args+=(--probe); fi
  node "$DEVICE_HELPER" "${args[@]}"
}

resolve_physical_device() {
  local device_spec
  list_physical_devices
  if device_spec="$(select_physical_device probe)"; then
    printf '%s' "$device_spec"
    return 0
  fi
  if warm_connect_devices; then
    list_physical_devices
    if device_spec="$(select_physical_device probe)"; then
      printf '%s' "$device_spec"
      return 0
    fi
  fi
  select_physical_device final
}

assert_selected_device_still_ready() {
  local refreshed_spec refreshed_identifier refreshed_udid refreshed_name refreshed_os_version
  list_physical_devices
  refreshed_spec="$(
    node "$DEVICE_HELPER" select \
      --input "$DEVICE_LIST_PATH" \
      --output "$STATE_DIR/physical-device-before-install.json" \
      --requested "$DEVICE_IDENTIFIER"
  )"
  IFS=$'\t' read -r refreshed_identifier refreshed_udid refreshed_name refreshed_os_version <<<"$refreshed_spec"
  if [[ "$refreshed_identifier" != "$DEVICE_IDENTIFIER" || "$refreshed_udid" != "$DEVICE_UDID" ]]; then
    fail "selected iPhone identity changed before install; refusing to continue"
  fi
}

write_preflight_summary() {
  TOASTTY_PREFLIGHT_PATH="$PREFLIGHT_PATH" \
  TOASTTY_DEVICE_INFO_PATH="$DEVICE_INFO_PATH" \
  TOASTTY_BUILD_ONLY="$BUILD_ONLY" \
  TOASTTY_BUNDLE_ID="$BUNDLE_ID" \
  TOASTTY_BUILD_CONFIGURATION="$BUILD_CONFIGURATION" \
  TOASTTY_DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  TOASTTY_PREFLIGHT_ONLY="$PREFLIGHT_ONLY" \
  node --input-type=commonjs <<'NODE'
const fs = require("node:fs");
let physicalDevice = null;
try {
  physicalDevice = JSON.parse(fs.readFileSync(process.env.TOASTTY_DEVICE_INFO_PATH, "utf8"));
} catch {}
fs.writeFileSync(process.env.TOASTTY_PREFLIGHT_PATH, `${JSON.stringify({
  ok: physicalDevice?.ok === true,
  command: "native-device",
  buildConfiguration: process.env.TOASTTY_BUILD_CONFIGURATION,
  buildOnly: process.env.TOASTTY_BUILD_ONLY === "1",
  bundleID: process.env.TOASTTY_BUNDLE_ID,
  developmentTeam: process.env.TOASTTY_DEVELOPMENT_TEAM,
  preflightOnly: process.env.TOASTTY_PREFLIGHT_ONLY === "1",
  physicalDevice,
  generatedAt: new Date().toISOString(),
}, null, 2)}\n`);
NODE
}

write_instance_summary() {
  local phase="$1"
  TOASTTY_INSTANCE_PATH="$INSTANCE_PATH" \
  TOASTTY_RUN_ID="$RUN_ID" \
  TOASTTY_RUN_ROOT="$RUN_ROOT" \
  TOASTTY_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
  TOASTTY_BUNDLE_ID="$BUNDLE_ID" \
  TOASTTY_BUILD_CONFIGURATION="$BUILD_CONFIGURATION" \
  TOASTTY_DEVICE_IDENTIFIER="$DEVICE_IDENTIFIER" \
  TOASTTY_DEVICE_UDID="$DEVICE_UDID" \
  TOASTTY_DEVICE_NAME="$DEVICE_NAME" \
  TOASTTY_DEVICE_OS_VERSION="$DEVICE_OS_VERSION" \
  TOASTTY_INSTANCE_PHASE="$phase" \
  TOASTTY_APP_PATH="$APP_PATH" \
  node --input-type=commonjs <<'NODE'
const fs = require("node:fs");
fs.writeFileSync(process.env.TOASTTY_INSTANCE_PATH, `${JSON.stringify({
  schemaVersion: 1,
  command: "native-device",
  runId: process.env.TOASTTY_RUN_ID,
  runRoot: process.env.TOASTTY_RUN_ROOT,
  derivedDataPath: process.env.TOASTTY_DERIVED_DATA_PATH,
  bundleID: process.env.TOASTTY_BUNDLE_ID,
  buildConfiguration: process.env.TOASTTY_BUILD_CONFIGURATION,
  physicalDeviceIdentifier: process.env.TOASTTY_DEVICE_IDENTIFIER,
  physicalDeviceUDID: process.env.TOASTTY_DEVICE_UDID,
  physicalDeviceName: process.env.TOASTTY_DEVICE_NAME,
  physicalDeviceOSVersion: process.env.TOASTTY_DEVICE_OS_VERSION,
  phase: process.env.TOASTTY_INSTANCE_PHASE,
  appPath: process.env.TOASTTY_APP_PATH || undefined,
  generatedAt: new Date().toISOString(),
}, null, 2)}\n`);
NODE
}

require_value BUNDLE_ID
require_value DISPLAY_NAME
require_value URL_SCHEME
validate_flag BUILD_ONLY
validate_flag PREFLIGHT_ONLY
validate_paths
if [[ "$PREFLIGHT_ONLY" == "1" && "$BUILD_ONLY" == "1" ]]; then
  fail "TOASTTY_NATIVE_DEVICE_PREFLIGHT_ONLY and TOASTTY_NATIVE_DEVICE_BUILD_ONLY cannot both be 1"
fi
if [[ "$PREFLIGHT_ONLY" != "1" ]]; then
  require_value DEVELOPMENT_TEAM
fi
if [[ "$BUILD_CONFIGURATION" != "Debug" ]]; then
  fail "TOASTTY_NATIVE_DEVICE_BUILD_CONFIGURATION must be Debug"
fi

require_command bash
require_command codesign
require_command grep
require_command node
require_command plutil
require_command ps
require_command security
require_command tail
require_command tuist
require_command xcodebuild
require_command xcrun

mkdir -p "$DERIVED_DATA_PATH" "$LOG_DIR" "$STATE_DIR"

if ! xcodebuild -checkFirstLaunchStatus >"$LOG_DIR/xcode-first-launch-status.log" 2>&1; then
  fail "Xcode first-launch setup or license acceptance is incomplete; run 'sudo xcodebuild -runFirstLaunch'"
fi
if ! xcrun devicectl --version >"$LOG_DIR/devicectl-version.log" 2>&1; then
  fail "devicectl is unavailable in the selected Xcode toolchain"
fi

set +e
device_spec="$(resolve_physical_device)"
device_status=$?
set -e
if ((device_status != 0)); then
  write_preflight_summary
  fail "physical iPhone preflight failed; details: $DEVICE_INFO_PATH"
fi

IFS=$'\t' read -r DEVICE_IDENTIFIER DEVICE_UDID DEVICE_NAME DEVICE_OS_VERSION <<<"$device_spec"
write_preflight_summary
write_instance_summary preflight-complete
log "device: $DEVICE_NAME ($DEVICE_OS_VERSION) $DEVICE_UDID"
log "bundle: $BUNDLE_ID"
log "run root: $RUN_ROOT"

if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
  log "Preflight complete: $PREFLIGHT_PATH"
  log "Instance evidence: $INSTANCE_PATH"
  exit 0
fi

unset TUIST_TOASTTY_MOBILE_PROD_TEST
unset TUIST_TOASTTY_MOBILE_RELEASE_CODE_SIGN_IDENTITY
unset TUIST_TOASTTY_MOBILE_RELEASE_PROVISIONING_PROFILE_SPECIFIER
export TUIST_TOASTTY_MOBILE_BUNDLE_SUFFIX=".dev.local"
export TUIST_TOASTTY_MOBILE_DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
export TUIST_TOASTTY_MOBILE_PHYSICAL_DEVICE=1

trap cleanup_native_device_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
acquire_run_lock
capture_generated_project_state

log "Installing Tuist packages for the physical-device graph"
if ! run_logged_command "$LOG_DIR/tuist-install.log" tuist install; then
  tail -n 80 "$LOG_DIR/tuist-install.log" >&2
  fail "tuist install failed; full log: $LOG_DIR/tuist-install.log"
fi

log "Generating the fixed-identity physical-device workspace"
if ! run_logged_command "$LOG_DIR/tuist-generate.log" tuist generate --no-open; then
  tail -n 80 "$LOG_DIR/tuist-generate.log" >&2
  fail "tuist generate failed; full log: $LOG_DIR/tuist-generate.log"
fi

log "Confirming Xcode can address the selected phone"
xcodebuild \
  -workspace "$IOS_ROOT/ToasttyMobile.xcworkspace" \
  -scheme ToasttyMobileApp \
  -showdestinations >"$STATE_DIR/xcode-destinations.txt" 2>"$LOG_DIR/xcode-destinations.log"
if ! node "$DEVICE_HELPER" validate-destination \
  --input "$STATE_DIR/xcode-destinations.txt" \
  --udid "$DEVICE_UDID"; then
  fail "selected iPhone $DEVICE_UDID is not a ToasttyMobileApp xcodebuild destination; see $STATE_DIR/xcode-destinations.txt"
fi

BUILD_DESTINATION="id=$DEVICE_UDID"
SIGNING_ARGS=(
  "CODE_SIGN_STYLE=Automatic"
  "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
  "PROVISIONING_PROFILE_SPECIFIER="
)

write_instance_summary building
log "Building ToasttyMobileApp Debug with automatic development signing"
if ! run_logged_command "$LOG_DIR/xcodebuild-build.log" xcodebuild \
  -workspace "$IOS_ROOT/ToasttyMobile.xcworkspace" \
  -scheme ToasttyMobileApp \
  -configuration "$BUILD_CONFIGURATION" \
  -destination "$BUILD_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -allowProvisioningUpdates \
  "${SIGNING_ARGS[@]}" \
  build; then
  tail -n 80 "$LOG_DIR/xcodebuild-build.log" >&2
  fail "ToasttyMobileApp Debug build failed; full log: $LOG_DIR/xcodebuild-build.log"
fi
log "Debug build succeeded"

log "Resolving and validating the signed app"
xcodebuild \
  -workspace "$IOS_ROOT/ToasttyMobile.xcworkspace" \
  -scheme ToasttyMobileApp \
  -configuration "$BUILD_CONFIGURATION" \
  -destination "$BUILD_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "${SIGNING_ARGS[@]}" \
  -showBuildSettings \
  -json >"$BUILD_SETTINGS_PATH" 2>"$LOG_DIR/xcodebuild-settings.log"

APP_PATH="$(node "$BUILD_VALIDATOR" \
  --settings "$BUILD_SETTINGS_PATH" \
  --bundle-id "$BUNDLE_ID" \
  --device-udid "$DEVICE_UDID" \
  --display-name "$DISPLAY_NAME" \
  --team "$DEVELOPMENT_TEAM" \
  --url-scheme "$URL_SCHEME")"
write_instance_summary build-validated
log "validated app: $APP_PATH"

if [[ "$BUILD_ONLY" == "1" ]]; then
  log "Build complete; skipping install and launch"
  exit 0
fi

log "Installing $BUNDLE_ID on $DEVICE_NAME"
assert_selected_device_still_ready
if ! install_signed_app; then
  fail "failed to install $BUNDLE_ID after 2 attempts; logs: $LOG_DIR/devicectl-install-attempt-*.log"
fi
write_instance_summary installed

log "Launching $BUNDLE_ID on $DEVICE_NAME"
if ! launch_installed_app; then
  fail "failed to launch $BUNDLE_ID after 2 attempts; logs: $LOG_DIR/devicectl-launch-attempt-*.log"
fi
write_instance_summary launched

log "Toastty Dev is running on $DEVICE_NAME"
log "Run artifacts: $RUN_ROOT"
