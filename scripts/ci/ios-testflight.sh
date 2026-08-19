#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
IOS_ROOT="$ROOT_DIR/ios"
PLIST_BUDDY="${TOASTTY_IOS_PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
SCHEME_NAME="ToasttyMobileApp-Release"
APP_TARGET_NAME="ToasttyMobileApp"
DOMAIN_TARGET_NAME="ToasttyMobileDomain"
PROTOCOL_TARGET_NAME="RemoteProtocol"
CONFIGURATION="Release"
RELEASE_BUNDLE_ID="com.giantthings.toastty.mobile"
APP_PRODUCT_NAME="Toastty"
SIGNING_PROFILE_NAME=""
SIGNING_PROFILE_DESTINATION=""
SIGNING_PROFILE_BACKUP=""
SIGNING_KEYCHAIN_PATH=""
SIGNING_ASSETS_DIR=""
ASC_KEY_DIR=""
ORIGINAL_DEFAULT_KEYCHAIN=""
ORIGINAL_KEYCHAIN_LIST=()
UPLOAD_REQUESTED_ORIGINAL="0"
UPLOAD_SUPPRESSED_BY="none"

log() {
  printf '[ios-testflight] %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

assert_file_contains() {
  local path="$1"
  local expected="$2"
  local description="$3"
  grep -Fq "$expected" "$path" || fail "$description is not wired in $path"
}

validate_static_configuration() {
  local icon_contents="$IOS_ROOT/Resources/ToasttyMobileApp/Assets.xcassets/AppIcon.appiconset/Contents.json"
  local accent_contents="$IOS_ROOT/Resources/ToasttyMobileApp/Assets.xcassets/AccentColor.colorset/Contents.json"
  local privacy_manifest="$IOS_ROOT/Resources/ToasttyMobileApp/PrivacyInfo.xcprivacy"

  require_command node
  require_command sips
  [[ -f "$icon_contents" ]] || fail "missing AppIcon catalog at $icon_contents"
  [[ -f "$accent_contents" ]] || fail "missing AccentColor catalog at $accent_contents"
  [[ -f "$privacy_manifest" ]] || fail "missing privacy manifest at $privacy_manifest"
  node --input-type=module - "$icon_contents" "$accent_contents" <<'NODE'
import fs from "node:fs";

const catalogPath = process.argv[2];
const accentPath = process.argv[3];
const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
const catalogDirectory = new URL(`file://${catalogPath}`).pathname.replace(/\/Contents\.json$/, "");
const required = new Set([
  "iphone:20x20:2x", "iphone:20x20:3x",
  "iphone:29x29:2x", "iphone:29x29:3x",
  "iphone:40x40:2x", "iphone:40x40:3x",
  "iphone:60x60:2x", "iphone:60x60:3x",
  "ios-marketing:1024x1024:1x",
]);
for (const image of catalog.images ?? []) {
  required.delete(`${image.idiom}:${image.size}:${image.scale}`);
  if (!image.filename || !fs.existsSync(`${catalogDirectory}/${image.filename}`)) {
    throw new Error(`missing app icon file for ${image.idiom}:${image.size}:${image.scale}`);
  }
}
if (required.size > 0) throw new Error(`missing app icon slots: ${[...required].join(", ")}`);
const accent = JSON.parse(fs.readFileSync(accentPath, "utf8"));
const components = accent.colors?.[0]?.color?.components;
if (
  accent.colors?.[0]?.color?.["color-space"] !== "srgb"
  || components?.red !== "0.909804"
  || components?.green !== "0.576471"
  || components?.blue !== "0.047059"
  || components?.alpha !== "1.000000"
) {
  throw new Error("AccentColor must be the opaque Toastty amber sRGB color");
}
NODE
  while IFS=$'\t' read -r filename expected_pixels; do
    local icon_path="$IOS_ROOT/Resources/ToasttyMobileApp/Assets.xcassets/AppIcon.appiconset/$filename"
    local icon_properties
    icon_properties="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$icon_path" 2>/dev/null)"
    grep -Fq "pixelWidth: $expected_pixels" <<<"$icon_properties" \
      || fail "$filename has an unexpected pixel width"
    grep -Fq "pixelHeight: $expected_pixels" <<<"$icon_properties" \
      || fail "$filename has an unexpected pixel height"
    grep -Fq "hasAlpha: no" <<<"$icon_properties" \
      || fail "$filename must not contain an alpha channel"
  done < <(node --input-type=module - "$icon_contents" <<'NODE'
import fs from "node:fs";
const catalog = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
for (const image of catalog.images ?? []) {
  const points = Number.parseFloat(image.size.split("x")[0]);
  const scale = Number.parseInt(image.scale, 10);
  process.stdout.write(`${image.filename}\t${Math.round(points * scale)}\n`);
}
NODE
  )
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$privacy_manifest" >/dev/null
  fi
  assert_file_contains "$privacy_manifest" "NSPrivacyAccessedAPICategoryUserDefaults" "UserDefaults required-reason category"
  assert_file_contains "$privacy_manifest" "CA92.1" "UserDefaults required reason"
  assert_file_contains "$privacy_manifest" "NSPrivacyAccessedAPICategorySystemBootTime" "system boot-time required-reason category"
  assert_file_contains "$privacy_manifest" "35F9.1" "system boot-time required reason"
  assert_file_contains "$IOS_ROOT/Project.swift" '"ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"' "AppIcon build setting"
  assert_file_contains "$IOS_ROOT/Project.swift" '"CFBundleIconName": .string("AppIcon")' "AppIcon Info.plist setting"
  assert_file_contains "$IOS_ROOT/Project.swift" 'name: "ToasttyMobileApp-Release"' "release scheme"
  assert_file_contains "$IOS_ROOT/Project.swift" '"TUIST_TOASTTY_MOBILE_RELEASE_OTHER_CODE_SIGN_FLAGS"' "temporary keychain signing flag"
}

if [[ "${1:-}" == "--dry-run" ]]; then
  [[ $# -eq 1 ]] || fail "--dry-run does not accept additional arguments"
  validate_static_configuration
  log "Static release configuration is valid."
  log "Would generate $IOS_ROOT, archive $SCHEME_NAME as $RELEASE_BUNDLE_ID, export an IPA, and validate it with App Store Connect."
  log "Upload remains disabled unless TOASTTY_IOS_UPLOAD=1 is explicitly set."
  exit 0
fi
[[ $# -eq 0 ]] || fail "unexpected argument: $1"

decode_base64_to_file() {
  local value="$1"
  local output_path="$2"
  local label="$3"

  if printf '%s' "$value" | base64 --decode >"$output_path" 2>/dev/null; then
    return
  fi
  if printf '%s' "$value" | base64 -D >"$output_path" 2>/dev/null; then
    return
  fi
  fail "$label must be base64 encoded"
}

default_build_number() {
  if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
    if [[ -n "${GITHUB_RUN_ATTEMPT:-}" ]]; then
      printf '%s.%s' "$GITHUB_RUN_NUMBER" "$GITHUB_RUN_ATTEMPT"
    else
      printf '%s' "$GITHUB_RUN_NUMBER"
    fi
    return
  fi
  date -u +%Y%m%d%H%M%S
}

validate_marketing_version() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] \
    || fail "TUIST_TOASTTY_MOBILE_VERSION must be a two- or three-component numeric version; got '$value'"
}

validate_build_number() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] \
    || fail "TUIST_TOASTTY_MOBILE_BUILD_NUMBER must be one to three dot-separated numeric components; got '$value'"
}

write_app_store_connect_key() {
  local key_id="$1"
  local key_dir="$2"
  local key_path="$key_dir/AuthKey_${key_id}.p8"

  mkdir -p "$key_dir"
  chmod 700 "$key_dir"
  if [[ -n "${APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64:-}" ]]; then
    decode_base64_to_file "$APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64" "$key_path" "APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64"
  elif [[ -n "${APP_STORE_CONNECT_API_PRIVATE_KEY:-}" ]]; then
    local key_value="${APP_STORE_CONNECT_API_PRIVATE_KEY//\\n/$'\n'}"
    printf '%s\n' "$key_value" >"$key_path"
  else
    fail "APP_STORE_CONNECT_API_PRIVATE_KEY or APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64 is required"
  fi
  chmod 600 "$key_path"
}

plist_value() {
  "$PLIST_BUDDY" -c "Print :$2" "$1"
}

plist_value_or_empty() {
  "$PLIST_BUDDY" -c "Print :$2" "$1" 2>/dev/null || true
}

assert_plist_value() {
  local plist_path="$1"
  local key_path="$2"
  local expected="$3"
  local actual
  actual="$(plist_value "$plist_path" "$key_path")"
  [[ "$actual" == "$expected" ]] \
    || fail "$key_path mismatch in $plist_path: expected '$expected', found '$actual'"
}

assert_plist_key() {
  local plist_path="$1"
  local key_path="$2"
  plist_value "$plist_path" "$key_path" >/dev/null \
    || fail "$key_path is missing in $plist_path"
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

setup_manual_signing_assets() {
  local cert_path="$SIGNING_ASSETS_DIR/distribution.p12"
  local profile_path="$SIGNING_ASSETS_DIR/appstore.mobileprovision"
  local profile_plist_path="$SIGNING_ASSETS_DIR/appstore-profile.plist"
  local profile_uuid
  local profile_team_identifier
  local profile_app_identifier
  local profile_get_task_allow
  local profile_provisioned_devices
  local profile_provisions_all_devices
  local keychain
  local keychain_password

  decode_base64_to_file "$IOS_DISTRIBUTION_CERTIFICATE_BASE64" "$cert_path" "IOS_DISTRIBUTION_CERTIFICATE_BASE64"
  decode_base64_to_file "$IOS_APPSTORE_PROVISIONING_PROFILE_BASE64" "$profile_path" "IOS_APPSTORE_PROVISIONING_PROFILE_BASE64"
  security cms -D -i "$profile_path" >"$profile_plist_path" \
    || fail "IOS_APPSTORE_PROVISIONING_PROFILE_BASE64 must decode to a valid .mobileprovision file"

  profile_uuid="$(plist_value "$profile_plist_path" "UUID")"
  SIGNING_PROFILE_NAME="$(plist_value "$profile_plist_path" "Name")"
  profile_team_identifier="$(plist_value "$profile_plist_path" "TeamIdentifier:0")"
  profile_app_identifier="$(plist_value "$profile_plist_path" "Entitlements:application-identifier")"
  profile_get_task_allow="$(plist_value "$profile_plist_path" "Entitlements:get-task-allow")"
  profile_provisioned_devices="$(plist_value_or_empty "$profile_plist_path" "ProvisionedDevices")"
  profile_provisions_all_devices="$(plist_value_or_empty "$profile_plist_path" "ProvisionsAllDevices")"

  [[ "$profile_team_identifier" == "$TOASTTY_IOS_DEVELOPMENT_TEAM" ]] \
    || fail "provisioning profile team does not match TOASTTY_IOS_DEVELOPMENT_TEAM"
  [[ "$profile_app_identifier" == "$TOASTTY_IOS_DEVELOPMENT_TEAM.$RELEASE_BUNDLE_ID" ]] \
    || fail "provisioning profile application identifier does not match the production app"
  [[ "$profile_get_task_allow" == "false" ]] \
    || fail "provisioning profile must set get-task-allow to false"
  [[ -z "$profile_provisioned_devices" ]] \
    || fail "provisioning profile must be App Store distribution, not development or Ad Hoc"
  [[ "$profile_provisions_all_devices" != "true" ]] \
    || fail "provisioning profile must be App Store distribution, not Enterprise"

  SIGNING_KEYCHAIN_PATH="$SIGNING_ASSETS_DIR/toastty-signing.keychain-db"
  keychain_password="$(uuidgen)"
  ORIGINAL_DEFAULT_KEYCHAIN="$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  while IFS= read -r keychain; do
    keychain="${keychain//\"/}"
    keychain="${keychain#"${keychain%%[![:space:]]*}"}"
    keychain="${keychain%"${keychain##*[![:space:]]}"}"
    [[ -n "$keychain" ]] && ORIGINAL_KEYCHAIN_LIST+=("$keychain")
  done < <(security list-keychains -d user)

  security create-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN_PATH"
  security unlock-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN_PATH"
  security list-keychains -d user -s "$SIGNING_KEYCHAIN_PATH" "${ORIGINAL_KEYCHAIN_LIST[@]}"
  security default-keychain -d user -s "$SIGNING_KEYCHAIN_PATH"
  security import "$cert_path" -k "$SIGNING_KEYCHAIN_PATH" -P "$IOS_DISTRIBUTION_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security \
    || fail "distribution certificate or password is invalid"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$SIGNING_KEYCHAIN_PATH" >/dev/null
  security find-identity -v -p codesigning "$SIGNING_KEYCHAIN_PATH" | grep -Fq 'Apple Distribution' \
    || fail "temporary keychain has no Apple Distribution signing identity"

  mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
  SIGNING_PROFILE_DESTINATION="$HOME/Library/MobileDevice/Provisioning Profiles/$profile_uuid.mobileprovision"
  if [[ -e "$SIGNING_PROFILE_DESTINATION" ]]; then
    SIGNING_PROFILE_BACKUP="$SIGNING_ASSETS_DIR/existing-$profile_uuid.mobileprovision"
    cp "$SIGNING_PROFILE_DESTINATION" "$SIGNING_PROFILE_BACKUP"
  fi
  cp "$profile_path" "$SIGNING_PROFILE_DESTINATION"
  log "Installed temporary App Store signing assets for $RELEASE_BUNDLE_ID."
}

write_export_options_plist() {
  local escaped_team_id
  local escaped_bundle_id
  local escaped_profile_name
  escaped_team_id="$(xml_escape "$TOASTTY_IOS_DEVELOPMENT_TEAM")"
  escaped_bundle_id="$(xml_escape "$RELEASE_BUNDLE_ID")"
  escaped_profile_name="$(xml_escape "$SIGNING_PROFILE_NAME")"

  cat >"$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key><string>export</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>method</key><string>app-store-connect</string>
  <key>provisioningProfiles</key>
  <dict><key>$escaped_bundle_id</key><string>$escaped_profile_name</string></dict>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>stripSwiftSymbols</key><true/>
  <key>teamID</key><string>$escaped_team_id</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
  assert_plist_value "$EXPORT_OPTIONS_PLIST" "method" "app-store-connect"
  assert_plist_value "$EXPORT_OPTIONS_PLIST" "signingStyle" "manual"
  assert_plist_value "$EXPORT_OPTIONS_PLIST" "teamID" "$TOASTTY_IOS_DEVELOPMENT_TEAM"
  assert_plist_value "$EXPORT_OPTIONS_PLIST" "provisioningProfiles:$RELEASE_BUNDLE_ID" "$SIGNING_PROFILE_NAME"
}

assert_release_build_setting() {
  local settings_path="$1"
  local expected_line="$2"
  local description="$3"
  grep -Fqx "$expected_line" "$settings_path" \
    || fail "expected $description build setting: $expected_line"
}

assert_ci_signing_build_settings() {
  local app_settings_path="$OUTPUT_DIR/app-build-settings.txt"
  local framework_settings_path="$OUTPUT_DIR/framework-build-settings.txt"
  local protocol_settings_path="$OUTPUT_DIR/protocol-build-settings.txt"

  xcodebuild -project "$IOS_ROOT/ToasttyMobile.xcodeproj" -target "$APP_TARGET_NAME" -configuration "$CONFIGURATION" -showBuildSettings >"$app_settings_path"
  xcodebuild -project "$IOS_ROOT/ToasttyMobile.xcodeproj" -target "$DOMAIN_TARGET_NAME" -configuration "$CONFIGURATION" -showBuildSettings >"$framework_settings_path"
  xcodebuild -project "$IOS_ROOT/ToasttyMobile.xcodeproj" -target "$PROTOCOL_TARGET_NAME" -configuration "$CONFIGURATION" -showBuildSettings >"$protocol_settings_path"

  assert_release_build_setting "$app_settings_path" "    PRODUCT_BUNDLE_IDENTIFIER = $RELEASE_BUNDLE_ID" "production bundle identifier"
  assert_release_build_setting "$app_settings_path" "    CODE_SIGN_IDENTITY = Apple Distribution" "app signing identity"
  assert_release_build_setting "$app_settings_path" "    CODE_SIGN_STYLE = Manual" "app manual signing"
  assert_release_build_setting "$app_settings_path" "    PROVISIONING_PROFILE_SPECIFIER = $SIGNING_PROFILE_NAME" "app provisioning profile"
  assert_release_build_setting "$app_settings_path" "    OTHER_CODE_SIGN_FLAGS = --keychain $SIGNING_KEYCHAIN_PATH" "temporary keychain"

  if grep -Fq "PROVISIONING_PROFILE_SPECIFIER =" "$framework_settings_path" "$protocol_settings_path"; then
    fail "framework targets must not receive the app provisioning profile"
  fi
  if grep -Fq "OTHER_CODE_SIGN_FLAGS = --keychain" "$framework_settings_path" "$protocol_settings_path"; then
    fail "framework targets must not receive the app temporary-keychain signing flag"
  fi
}

verify_archive_configuration() {
  local app_path="$ARCHIVE_PATH/Products/Applications/$APP_PRODUCT_NAME.app"
  local app_plist="$app_path/Info.plist"
  local privacy_manifest="$app_path/PrivacyInfo.xcprivacy"

  [[ -f "$app_plist" ]] || fail "expected archived app Info.plist at $app_plist"
  [[ -s "$app_path/Assets.car" ]] || fail "archived app is missing compiled app-icon assets"
  [[ -f "$privacy_manifest" ]] || fail "archived app is missing PrivacyInfo.xcprivacy"

  assert_plist_value "$app_plist" "CFBundleIdentifier" "$RELEASE_BUNDLE_ID"
  assert_plist_value "$app_plist" "CFBundleShortVersionString" "$TUIST_TOASTTY_MOBILE_VERSION"
  assert_plist_value "$app_plist" "CFBundleVersion" "$TUIST_TOASTTY_MOBILE_BUILD_NUMBER"
  assert_plist_value "$app_plist" "CFBundleIconName" "AppIcon"
  assert_plist_value "$app_plist" "ITSAppUsesNonExemptEncryption" "false"
  assert_plist_value "$privacy_manifest" "NSPrivacyTracking" "false"
  assert_plist_value "$privacy_manifest" "NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategoryUserDefaults"
  assert_plist_value "$privacy_manifest" "NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPITypeReasons:0" "CA92.1"
  assert_plist_value "$privacy_manifest" "NSPrivacyAccessedAPITypes:1:NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategorySystemBootTime"
  assert_plist_value "$privacy_manifest" "NSPrivacyAccessedAPITypes:1:NSPrivacyAccessedAPITypeReasons:0" "35F9.1"
  assert_plist_key "$privacy_manifest" "NSPrivacyCollectedDataTypes"
  assert_plist_key "$privacy_manifest" "NSPrivacyTrackingDomains"
  log "Verified production archive $RELEASE_BUNDLE_ID $TUIST_TOASTTY_MOBILE_VERSION ($TUIST_TOASTTY_MOBILE_BUILD_NUMBER), AppIcon, encryption declaration, and privacy manifest."
}

find_exported_ipa() {
  local ipa_path
  ipa_path="$(find "$EXPORT_PATH" -maxdepth 2 -type f -name '*.ipa' -size +0c -print -quit)"
  [[ -n "$ipa_path" ]] || fail "export completed but no non-empty IPA was found under $EXPORT_PATH"
  printf '%s' "$ipa_path"
}

write_release_metadata() {
  local status="$1"
  local upload_requested="$2"
  local commit_sha="${GITHUB_SHA:-unknown}"
  local ci_run_url=""
  if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
    ci_run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  fi
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'STATUS=%s\n' "$status"
    printf 'GIT_SHA=%s\n' "$commit_sha"
    printf 'CI_RUN_URL=%s\n' "$ci_run_url"
    printf 'SCHEME=%s\n' "$SCHEME_NAME"
    printf 'CONFIGURATION=%s\n' "$CONFIGURATION"
    printf 'BUNDLE_ID=%s\n' "$RELEASE_BUNDLE_ID"
    printf 'MARKETING_VERSION=%s\n' "$TUIST_TOASTTY_MOBILE_VERSION"
    printf 'BUILD_NUMBER=%s\n' "$TUIST_TOASTTY_MOBILE_BUILD_NUMBER"
    printf 'UPLOAD_REQUESTED_ORIGINAL=%s\n' "$UPLOAD_REQUESTED_ORIGINAL"
    printf 'UPLOAD_REQUESTED=%s\n' "$upload_requested"
    printf 'UPLOAD_SUPPRESSED_BY=%s\n' "$UPLOAD_SUPPRESSED_BY"
  } >"$RELEASE_METADATA_PATH"
}

cleanup() {
  if [[ -n "$SIGNING_PROFILE_DESTINATION" ]]; then
    if [[ -n "$SIGNING_PROFILE_BACKUP" && -f "$SIGNING_PROFILE_BACKUP" ]]; then
      cp "$SIGNING_PROFILE_BACKUP" "$SIGNING_PROFILE_DESTINATION" >/dev/null 2>&1 || true
    else
      rm -f "$SIGNING_PROFILE_DESTINATION"
    fi
  fi
  if [[ -n "$ORIGINAL_DEFAULT_KEYCHAIN" ]]; then
    security default-keychain -d user -s "$ORIGINAL_DEFAULT_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  if ((${#ORIGINAL_KEYCHAIN_LIST[@]} > 0)); then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAIN_LIST[@]}" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SIGNING_KEYCHAIN_PATH" ]]; then
    security delete-keychain "$SIGNING_KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi
  [[ -z "$ASC_KEY_DIR" ]] || rm -rf "$ASC_KEY_DIR"
  [[ -z "$SIGNING_ASSETS_DIR" ]] || rm -rf "$SIGNING_ASSETS_DIR"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

validate_static_configuration
for command_name in base64 find security sed sips tee tuist uuidgen xcodebuild xcrun; do
  require_command "$command_name"
done
[[ -x "$PLIST_BUDDY" ]] || fail "$PLIST_BUDDY is required"

require_env APP_STORE_CONNECT_API_KEY_ID
require_env APP_STORE_CONNECT_API_ISSUER_ID
require_env TOASTTY_IOS_DEVELOPMENT_TEAM
require_env IOS_DISTRIBUTION_CERTIFICATE_BASE64
require_env IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
require_env IOS_APPSTORE_PROVISIONING_PROFILE_BASE64
if [[ -n "${APP_STORE_CONNECT_API_PRIVATE_KEY:-}" && -n "${APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64:-}" ]]; then
  fail "set exactly one of APP_STORE_CONNECT_API_PRIVATE_KEY or APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64, not both"
fi
if [[ -z "${APP_STORE_CONNECT_API_PRIVATE_KEY:-}" && -z "${APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64:-}" ]]; then
  fail "set exactly one of APP_STORE_CONNECT_API_PRIVATE_KEY or APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64"
fi

export TUIST_TOASTTY_MOBILE_VERSION="${TUIST_TOASTTY_MOBILE_VERSION:-${TOASTTY_MOBILE_VERSION:-0.1.0}}"
export TUIST_TOASTTY_MOBILE_BUILD_NUMBER="${TUIST_TOASTTY_MOBILE_BUILD_NUMBER:-${TOASTTY_MOBILE_BUILD_NUMBER:-$(default_build_number)}}"
validate_marketing_version "$TUIST_TOASTTY_MOBILE_VERSION"
validate_build_number "$TUIST_TOASTTY_MOBILE_BUILD_NUMBER"

UPLOAD_REQUESTED="${TOASTTY_IOS_UPLOAD:-0}"
[[ "$UPLOAD_REQUESTED" == "0" || "$UPLOAD_REQUESTED" == "1" ]] \
  || fail "TOASTTY_IOS_UPLOAD must be 0 or 1"
UPLOAD_REQUESTED_ORIGINAL="$UPLOAD_REQUESTED"
DOCUMENTED_SKIP_UPLOAD="${SKIP_UPLOAD-0}"
[[ "$DOCUMENTED_SKIP_UPLOAD" == "0" || "$DOCUMENTED_SKIP_UPLOAD" == "1" ]] \
  || fail "SKIP_UPLOAD must be 0 or 1"
SCOPED_SKIP_UPLOAD="${TOASTTY_IOS_SKIP_UPLOAD-0}"
[[ "$SCOPED_SKIP_UPLOAD" == "0" || "$SCOPED_SKIP_UPLOAD" == "1" ]] \
  || fail "TOASTTY_IOS_SKIP_UPLOAD must be 0 or 1"
if [[ "$DOCUMENTED_SKIP_UPLOAD" == "1" || "$SCOPED_SKIP_UPLOAD" == "1" ]]; then
  UPLOAD_REQUESTED=0
  if [[ "$DOCUMENTED_SKIP_UPLOAD" == "1" && "$SCOPED_SKIP_UPLOAD" == "1" ]]; then
    UPLOAD_SUPPRESSED_BY="both"
  elif [[ "$DOCUMENTED_SKIP_UPLOAD" == "1" ]]; then
    UPLOAD_SUPPRESSED_BY="SKIP_UPLOAD"
  else
    UPLOAD_SUPPRESSED_BY="TOASTTY_IOS_SKIP_UPLOAD"
  fi
  log "Upload request suppressed by validate-only skip input."
fi
if [[ "$UPLOAD_REQUESTED" == "1" && "${GITHUB_REF:-}" != "refs/heads/main" ]]; then
  fail "TestFlight upload is allowed only from refs/heads/main; current ref is '${GITHUB_REF:-unset}'"
fi

OUTPUT_DIR="${TOASTTY_IOS_RELEASE_OUTPUT_DIR:-$ROOT_DIR/artifacts/ios-release/$TUIST_TOASTTY_MOBILE_VERSION-$TUIST_TOASTTY_MOBILE_BUILD_NUMBER}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
case "$OUTPUT_DIR" in
  /|"$ROOT_DIR"|"$IOS_ROOT") fail "refusing unsafe TOASTTY_IOS_RELEASE_OUTPUT_DIR: $OUTPUT_DIR" ;;
esac
ARCHIVE_PATH="$OUTPUT_DIR/Toastty.xcarchive"
EXPORT_PATH="$OUTPUT_DIR/export"
DERIVED_DATA_PATH="$OUTPUT_DIR/DerivedData"
EXPORT_OPTIONS_PLIST="$OUTPUT_DIR/ExportOptions.plist"
RELEASE_METADATA_PATH="$OUTPUT_DIR/release-metadata.txt"
for path in "$ARCHIVE_PATH" "$EXPORT_PATH" "$DERIVED_DATA_PATH" "$EXPORT_OPTIONS_PLIST"; do
  [[ ! -e "$path" ]] || fail "release output already exists; choose a fresh build number or output directory: $path"
done
write_release_metadata "preparing" "$UPLOAD_REQUESTED"

ASC_KEY_DIR="$(mktemp -d "/tmp/toastty-asc-key.XXXXXX")"
ASC_PRIVATE_KEYS_DIR="$ASC_KEY_DIR/private_keys"
write_app_store_connect_key "$APP_STORE_CONNECT_API_KEY_ID" "$ASC_PRIVATE_KEYS_DIR"
export API_PRIVATE_KEYS_DIR="$ASC_PRIVATE_KEYS_DIR"
ALTOOL_AUTH_ARGS=(
  --api-key "$APP_STORE_CONNECT_API_KEY_ID"
  --api-issuer "$APP_STORE_CONNECT_API_ISSUER_ID"
)

SIGNING_ASSETS_DIR="$(mktemp -d "/tmp/toastty-ios-signing.XXXXXX")"
setup_manual_signing_assets
export TUIST_TOASTTY_MOBILE_DEVELOPMENT_TEAM="$TOASTTY_IOS_DEVELOPMENT_TEAM"
export TUIST_TOASTTY_MOBILE_RELEASE_CODE_SIGN_IDENTITY="Apple Distribution"
export TUIST_TOASTTY_MOBILE_RELEASE_PROVISIONING_PROFILE_SPECIFIER="$SIGNING_PROFILE_NAME"
export TUIST_TOASTTY_MOBILE_RELEASE_OTHER_CODE_SIGN_FLAGS="--keychain $SIGNING_KEYCHAIN_PATH"
export TUIST_TOASTTY_MOBILE_PROD_TEST=0

log "Generating the production iOS workspace."
(
  cd "$IOS_ROOT"
  tuist install
  tuist generate --no-open
) 2>&1 | tee "$OUTPUT_DIR/generate.log"
assert_ci_signing_build_settings

log "Archiving $SCHEME_NAME $CONFIGURATION."
xcodebuild \
  -workspace "$IOS_ROOT/ToasttyMobile.xcworkspace" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "DEVELOPMENT_TEAM=$TOASTTY_IOS_DEVELOPMENT_TEAM" \
  archive 2>&1 | tee "$OUTPUT_DIR/archive.log"
verify_archive_configuration
write_export_options_plist

log "Exporting the signed IPA."
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" 2>&1 | tee "$OUTPUT_DIR/export.log"
IPA_PATH="$(find_exported_ipa)"

log "Validating the IPA with App Store Connect."
xcrun altool \
  --validate-app \
  -f "$IPA_PATH" \
  "${ALTOOL_AUTH_ARGS[@]}" \
  --output-format normal 2>&1 | tee "$OUTPUT_DIR/validation.log"
write_release_metadata "validated" "$UPLOAD_REQUESTED"

if [[ "$UPLOAD_REQUESTED" != "1" ]]; then
  log "Validation succeeded; upload remains disabled. Set TOASTTY_IOS_UPLOAD=1 explicitly to upload."
  exit 0
fi

log "Uploading the IPA to App Store Connect."
xcrun altool \
  --upload-app \
  -f "$IPA_PATH" \
  "${ALTOOL_AUTH_ARGS[@]}" \
  --output-format normal 2>&1 | tee "$OUTPUT_DIR/upload.log"
write_release_metadata "uploaded" "$UPLOAD_REQUESTED"
log "Upload submitted; App Store Connect processing must complete before TestFlight shows the build."
