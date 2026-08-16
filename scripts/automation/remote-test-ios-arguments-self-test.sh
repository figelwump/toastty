#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WRAPPER="$ROOT_DIR/scripts/remote/test.sh"
TEST_ROOT="$(mktemp -d /tmp/toastty-remote-test-ios-arguments.XXXXXX)"
FAKE_BIN="$TEST_ROOT/bin"
RECORDER="$TEST_ROOT/xcodebuild-arguments.log"
SIMULATOR_STATE="$TEST_ROOT/simulator-state"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

encode_args() {
  local payload=""
  local arg
  for arg in "$@"; do
    payload+="$arg"$'\n'
  done
  printf '%s' "$payload" | base64 | tr -d '\n'
}

run_remote_fixture() {
  local run_name="$1"
  local destination_mode="$2"
  shift 2
  local run_root="$TEST_ROOT/remote-gui/test-runs/$run_name"
  local encoded_args
  encoded_args="$(encode_args "$@")"

  mkdir -p "$run_root"
  : >"$RECORDER"
  printf 'template\n' >"$SIMULATOR_STATE"
  PATH="$FAKE_BIN:$PATH" \
  FAKE_XCODEBUILD_ARGUMENTS_LOG="$RECORDER" \
  FAKE_DESTINATION_MODE="$destination_mode" \
  FAKE_SIMULATOR_STATE="$SIMULATOR_STATE" \
  TOASTTY_REMOTE_TEST_RUN_LABEL="$run_name" \
  TOASTTY_REMOTE_TEST_REMOTE_RUN_ROOT="$run_root" \
  TOASTTY_REMOTE_TEST_REMOTE_WORKTREE_DIR="$ROOT_DIR" \
  TOASTTY_REMOTE_TEST_XCODEBUILD_ARGS_B64="$encoded_args" \
  TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS=30 \
  TOASTTY_REMOTE_TEST_PLATFORM=ios \
    /bin/bash "$WRAPPER" --remote-exec
}

mkdir -p "$FAKE_BIN"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "node %s\\n" "$*" >>"$FAKE_XCODEBUILD_ARGUMENTS_LOG"' \
  'exit 0' \
  >"$FAKE_BIN/node"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'kind=test' \
  'for arg in "$@"; do' \
  '  if [[ "$arg" == "-showdestinations" ]]; then kind=probe; fi' \
  'done' \
  'printf "%s %s\\n" "$kind" "$*" >>"$FAKE_XCODEBUILD_ARGUMENTS_LOG"' \
  'if [[ "$kind" == probe ]]; then' \
  '  if [[ "$FAKE_DESTINATION_MODE" == fail ]]; then' \
  '    printf "xcodebuild: invalid destination probe fixture\\n" >&2' \
  '    exit 66' \
  '  fi' \
  '  printf "Available destinations for the scheme:\\n"' \
  '  printf "{ platform:iOS Simulator, arch:arm64, id:SIMULATOR-1, OS:26.3, name:iPhone 17 }\\n"' \
  'fi' \
  'exit 0' \
  >"$FAKE_BIN/xcodebuild"
cat >"$FAKE_BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >>"$FAKE_XCODEBUILD_ARGUMENTS_LOG"
state="$(cat "$FAKE_SIMULATOR_STATE")"
clone_name="Toastty Remote test-focused-fixture"
if [[ -f "$FAKE_SIMULATOR_STATE.name" ]]; then
  clone_name="$(cat "$FAKE_SIMULATOR_STATE.name")"
fi
template_id="AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
clone_id="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
if [[ "$*" == "simctl list runtimes available --json" ]]; then
  jq -nc '{runtimes:[{
    identifier:"com.apple.CoreSimulator.SimRuntime.iOS-26-3",
    version:"26.3",
    platform:"iOS",
    isAvailable:true,
    supportedDeviceTypes:[{
      name:"iPhone 17 Pro",
      identifier:"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
      productFamily:"iPhone"
    }]
  }]}'
  exit 0
fi
if [[ "$*" == "simctl list devices available --json" || "$*" == "simctl list devices --json" ]]; then
  jq -nc \
    --arg template "$template_id" \
    --arg clone "$clone_id" \
    --arg state "$state" \
    --arg cloneName "$clone_name" '{
      devices:{"com.apple.CoreSimulator.SimRuntime.iOS-26-3":(
        [{name:"Toastty Remote Template",udid:$template,state:"Shutdown",isAvailable:true}]
        + (if $state == "template" or $state == "deleted" then [] else [{
          name:$cloneName,
          udid:$clone,
          state:(if $state == "booted" then "Booted" else "Shutdown" end),
          isAvailable:true
        }] end)
      )}
    }'
  exit 0
fi
if [[ "$1" == simctl && "$2" == clone ]]; then
  if [[ "$FAKE_DESTINATION_MODE" == fail ]]; then
    printf 'simctl: clone fixture failed\n' >&2
    exit 66
  fi
  printf '%s\n' "$4" >"$FAKE_SIMULATOR_STATE.name"
  printf 'cloned\n' >"$FAKE_SIMULATOR_STATE"
  printf '%s\n' "$clone_id"
  exit 0
fi
if [[ "$1" == simctl && "$2" == boot && "$3" == "$clone_id" ]]; then
  printf 'booted\n' >"$FAKE_SIMULATOR_STATE"
  exit 0
fi
if [[ "$1" == simctl && "$2" == bootstatus && "$3" == "$clone_id" ]]; then
  exit 0
fi
if [[ "$1" == simctl && "$2" == shutdown && "$3" == "$clone_id" ]]; then
  printf 'shutdown\n' >"$FAKE_SIMULATOR_STATE"
  exit 0
fi
if [[ "$1" == simctl && "$2" == delete && "$3" == "$clone_id" ]]; then
  printf 'deleted\n' >"$FAKE_SIMULATOR_STATE"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/node" "$FAKE_BIN/xcodebuild" "$FAKE_BIN/xcrun"

# shellcheck source=../remote/test.sh
source "$WRAPPER"

TEST_PLATFORM=ios
focused_display="$(build_display_command -only-testing:ToasttyMobileDomainTests/GatewayCompatibilityDecoderTests)"
[[ "$focused_display" == *'-workspace ios/ToasttyMobile.xcworkspace'* ]] \
  || fail_test "focused display command omitted the default iOS workspace"
[[ "$focused_display" == *'-scheme ToasttyMobileApp'* ]] \
  || fail_test "focused display command omitted the default iOS scheme"
[[ "$focused_display" == *'-configuration Debug'* ]] \
  || fail_test "focused display command omitted the default configuration"
[[ "$focused_display" == *'-parallel-testing-enabled NO'* ]] \
  || fail_test "focused display command omitted the default parallel-testing policy"

TEST_PLATFORM=macos
ARCH=arm64
focused_macos_display="$(build_display_command -only-testing:ToasttyAppTests/FocusedTests)"
[[ "$focused_macos_display" == *'-workspace toastty.xcworkspace'* ]] \
  || fail_test "focused macOS display command omitted the default workspace"
[[ "$focused_macos_display" == *'-scheme ToasttyApp'* ]] \
  || fail_test "focused macOS display command omitted the default scheme"
[[ "$focused_macos_display" == *'-destination platform=macOS\,arch=arm64'* ]] \
  || fail_test "focused macOS display command omitted the default arm64 destination"
TEST_PLATFORM=ios

if (validate_paired_xcodebuild_args -scheme) >/dev/null 2>&1; then
  fail_test "accepted -scheme without a value"
fi
if (validate_paired_xcodebuild_args -workspace One.xcworkspace -project Two.xcodeproj) >/dev/null 2>&1; then
  fail_test "accepted conflicting workspace and project containers"
fi
for forbidden_path_option in -derivedDataPath=/tmp/derived -resultBundlePath=/tmp/results.xcresult; do
  if (assert_supported_xcodebuild_args "$forbidden_path_option") >/dev/null 2>&1; then
    fail_test "accepted wrapper-owned path option: $forbidden_path_option"
  fi
done

run_remote_fixture \
  focused \
  success \
  -only-testing:ToasttyMobileDomainTests/GatewayCompatibilityDecoderTests

focused_test="$(grep '^test ' "$RECORDER")"
for required in \
  '-workspace ios/ToasttyMobile.xcworkspace' \
  '-scheme ToasttyMobileApp' \
  '-configuration Debug' \
  '-parallel-testing-enabled NO' \
  '-only-testing:ToasttyMobileDomainTests/GatewayCompatibilityDecoderTests'; do
  [[ "$focused_test" == *"$required"* ]] \
    || fail_test "focused test command omitted: $required"
done
[[ "$focused_test" == *'-destination platform=iOS Simulator,id=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB'* ]] \
  || fail_test "focused test command omitted the run-owned simulator"
[[ "$(cat "$SIMULATOR_STATE")" == "deleted" ]] \
  || fail_test "focused test did not delete its run-owned simulator"
[[ -f "$TEST_ROOT/remote-gui/test-runs/focused/COMPLETED" ]] \
  || fail_test "focused test did not record completed cleanup"

run_remote_fixture \
  explicit \
  success \
  -project Custom.xcodeproj \
  -scheme CustomScheme \
  -configuration Release \
  -parallel-testing-enabled YES \
  -destination 'platform=iOS Simulator,id=EXPLICIT-SIMULATOR' \
  -only-testing:CustomTests

if grep -q '^xcrun ' "$RECORDER"; then
  fail_test "an explicit destination still allocated a run-owned simulator"
fi
explicit_test="$(grep '^test ' "$RECORDER")"
for required in \
  '-project Custom.xcodeproj' \
  '-scheme CustomScheme' \
  '-configuration Release' \
  '-parallel-testing-enabled YES' \
  '-destination platform=iOS Simulator,id=EXPLICIT-SIMULATOR'; do
  [[ "$explicit_test" == *"$required"* ]] \
    || fail_test "explicit test command did not preserve: $required"
done
[[ "$explicit_test" != *'-workspace '* ]] \
  || fail_test "explicit project was combined with the default workspace"

if run_remote_fixture clone-failure fail -only-testing:CustomTests; then
  fail_test "simulator clone failure unexpectedly passed"
else
  clone_status=$?
fi
[[ "$clone_status" == "78" ]] \
  || fail_test "simulator clone failure returned $clone_status instead of setup-error status 78"
jq -e '
  .schemaVersion == 2
  and .status == "setup_error"
  and (.testFailureSummary | contains("run-owned iPhone Simulator clone"))
  and .cleanupFailureSummary == null
' "$TEST_ROOT/remote-gui/test-runs/clone-failure/result.json" >/dev/null \
  || fail_test "simulator clone failure was not categorized in result.json"
grep -q 'clone fixture failed' "$TEST_ROOT/remote-gui/test-runs/clone-failure/xcodebuild.log" \
  || fail_test "simulator clone diagnostics were not retained"

printf 'ok: remote iOS test argument self-test passed\n'
