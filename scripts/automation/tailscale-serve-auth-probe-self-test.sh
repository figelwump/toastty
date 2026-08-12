#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PROBE_SCRIPT="$ROOT_DIR/scripts/automation/tailscale-serve-auth-probe.mjs"
TEST_ROOT="$(mktemp -d /tmp/toastty-tailscale-auth-probe.XXXXXX)"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_TAILSCALE="$FAKE_BIN/tailscale"
SERVE_STATE="$TEST_ROOT/serve-state.json"
BASELINE_STATE="$TEST_ROOT/serve-state-baseline.json"
COMMAND_LOG="$TEST_ROOT/commands.log"

cleanup() {
  local cleanup_exit_code=$?
  rm -rf "$TEST_ROOT"
  return "$cleanup_exit_code"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"

cat >"$FAKE_TAILSCALE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_path="${TOASTTY_FAKE_TAILSCALE_STATE:?}"
command_log="${TOASTTY_FAKE_TAILSCALE_COMMAND_LOG:?}"

if [[ "$1" == "serve" && "$2" == "status" && "$3" == "--json" ]]; then
  printf 'serve-status\n' >>"$command_log"
  post_config_status_failure_marker="${state_path}.post-config-status-failed"
  post_config_status_returned_marker="${state_path}.post-config-status-returned"
  configure_seen=0
  while IFS= read -r logged_command || [[ -n "$logged_command" ]]; do
    if [[ "$logged_command" == "serve-configure" ]]; then
      configure_seen=1
      break
    fi
  done <"$command_log"
  if [[ "${TOASTTY_FAKE_TAILSCALE_POST_CONFIGURE_STATUS_FAIL:-0}" == "1" ]] \
    && [[ "$configure_seen" == "1" ]] \
    && [[ ! -e "$post_config_status_failure_marker" ]]; then
    : >"$post_config_status_failure_marker"
    exit 3
  fi
  off_seen=0
  while IFS= read -r logged_command || [[ -n "$logged_command" ]]; do
    if [[ "$logged_command" == "serve-off" ]]; then
      off_seen=1
      break
    fi
  done <"$command_log"
  if [[ "${TOASTTY_FAKE_TAILSCALE_TERMINAL_STATUS_FAIL:-0}" == "1" ]] \
    && [[ "$off_seen" == "1" ]]; then
    exit 3
  fi
  if [[ "${TOASTTY_FAKE_TAILSCALE_INJECT_COTENANT_ON_CLEANUP:-0}" == "1" ]] \
    && [[ -e "$post_config_status_returned_marker" ]] \
    && [[ ! -e "${state_path}.cotenant-injected" ]]; then
    jq -S '
      .Web["probe.test.ts.net:10443"].Handlers["/co-tenant"] = {
        "Proxy": "http://127.0.0.1:9"
      }
    ' "$state_path" >"${state_path}.tmp"
    mv "${state_path}.tmp" "$state_path"
    : >"${state_path}.cotenant-injected"
  fi
  jq -S . "$state_path"
  if [[ "$configure_seen" == "1" ]]; then
    : >"$post_config_status_returned_marker"
  fi
  exit 0
fi
if [[ "$1" == "funnel" && "$2" == "status" && "$3" == "--json" ]]; then
  printf 'funnel-status\n' >>"$command_log"
  unrelated_funnel_port=""
  if [[ -e "${state_path}.unrelated-funnel-mutation" ]]; then
    unrelated_funnel_port="8443"
  fi
  jq -S --arg unrelated_port "$unrelated_funnel_port" '
    {
      "TCP": (
        {"443": {"HTTPS": true}}
        + ((.TCP // {}) | with_entries(.value = {"HTTPS": true}))
        + (if $unrelated_port == "" then {} else {
            ($unrelated_port): {"HTTPS": true}
          } end)
      ),
      "Web": (
        ((.Web // {}) | with_entries(.value = {"HTTPS": true}))
        + (if $unrelated_port == "" then {} else {
            ("probe.test.ts.net:" + $unrelated_port): {"HTTPS": true}
          } end)
      ),
      "AllowFunnel": (.AllowFunnel // {})
    }
    | if .Web == {} then del(.Web) else . end
    | if .AllowFunnel == {} then del(.AllowFunnel) else . end
  ' "$state_path"
  exit 0
fi
if [[ "$1" == "status" && "$2" == "--json" ]]; then
  printf 'node-status\n' >>"$command_log"
  printf '{"Self":{"DNSName":"probe.test.ts.net."}}\n'
  exit 0
fi

https_port=""
for argument in "$@"; do
  if [[ "$argument" == --https=* ]]; then
    https_port="${argument#--https=}"
  fi
done
[[ "$https_port" =~ ^[0-9]+$ ]] || exit 2

temporary_state="${state_path}.tmp"
if [[ "${*: -1}" == "off" ]]; then
  printf 'serve-off\n' >>"$command_log"
  if [[ "${TOASTTY_FAKE_TAILSCALE_OFF_FAIL:-0}" == "1" ]]; then
    exit 3
  fi
  jq -S --arg port "$https_port" '
    del(.TCP[$port])
    | .Web |= with_entries(select(.key | endswith(":" + $port) | not))
    | .AllowFunnel = ((.AllowFunnel // {})
        | with_entries(select(.key | endswith(":" + $port) | not)))
    | if .TCP == {} then del(.TCP) else . end
    | if .Web == {} then del(.Web) else . end
    | if .AllowFunnel == {} then del(.AllowFunnel) else . end
  ' "$state_path" >"$temporary_state"
else
  printf 'serve-configure\n' >>"$command_log"
  if [[ "${TOASTTY_FAKE_TAILSCALE_CONFIGURE_FAIL:-0}" == "1" ]] \
    && [[ "${TOASTTY_FAKE_TAILSCALE_CONFIGURE_PARTIAL_FAIL:-0}" != "1" ]]; then
    exit 3
  fi
  target="${*: -1}"
  jq -S --arg port "$https_port" --arg target "$target" '
    .TCP[$port] = {"HTTPS": true}
    | .Web["probe.test.ts.net:" + $port] = {
        "Handlers": {"/": {"Proxy": $target}}
      }
    | if $ENV.TOASTTY_FAKE_TAILSCALE_DUPLICATE_TARGET_OUTSIDE_PORT == "1" then
        .Web["probe.test.ts.net:443"].Handlers["/duplicate"].Proxy = $target
      else
        .
      end
    | if $ENV.TOASTTY_FAKE_TAILSCALE_ALLOW_FUNNEL_SELECTED_PORT == "1" then
        .AllowFunnel["probe.test.ts.net:" + $port] = true
      else
        .
      end
    | if $ENV.TOASTTY_FAKE_TAILSCALE_MUTATE_UNRELATED_SAME_NUMBER == "1" then
        .Metadata[$port].Concurrent = true
        | .ConcurrentEmpty = {}
      else
        .
      end
  ' "$state_path" >"$temporary_state"
  if [[ "${TOASTTY_FAKE_TAILSCALE_MUTATE_UNRELATED_FUNNEL:-0}" == "1" ]]; then
    : >"${state_path}.unrelated-funnel-mutation"
  fi
fi
mv "$temporary_state" "$state_path"
if [[ "${TOASTTY_FAKE_TAILSCALE_CONFIGURE_PARTIAL_FAIL:-0}" == "1" ]] \
  && [[ "${*: -1}" != "off" ]]; then
  exit 3
fi
EOF
chmod +x "$FAKE_TAILSCALE"

write_baseline_state() {
  jq -Sn '{
    "TCP": {"443": {"HTTPS": true}},
    "Web": {
      "probe.test.ts.net:443": {
        "Handlers": {"/": {"Proxy": "http://127.0.0.1:42871"}}
      }
    },
    "Metadata": {
      "10443": {"Unrelated": true},
      "Empty": {}
    }
  }' >"$SERVE_STATE"
  cp "$SERVE_STATE" "$BASELINE_STATE"
  rm -f "${SERVE_STATE}.post-config-status-failed"
  rm -f "${SERVE_STATE}.post-config-status-returned"
  rm -f "${SERVE_STATE}.unrelated-funnel-mutation"
  rm -f "${SERVE_STATE}.cotenant-injected"
  : >"$COMMAND_LOG"
}

write_empty_baseline_state() {
  # `tailscale serve status --json` omits TCP/Web before the first mapping.
  jq -Sn '{}' >"$SERVE_STATE"
  cp "$SERVE_STATE" "$BASELINE_STATE"
  rm -f "${SERVE_STATE}.post-config-status-failed"
  rm -f "${SERVE_STATE}.post-config-status-returned"
  rm -f "${SERVE_STATE}.unrelated-funnel-mutation"
  rm -f "${SERVE_STATE}.cotenant-injected"
  : >"$COMMAND_LOG"
}

assert_privacy_safe_output() {
  local result_path="$1"
  local stdout_path="$2"
  local stderr_path="$3"

  jq -e '
    [paths(scalars) as $path | getpath($path) | type]
    | all(. == "boolean" or . == "number")
  ' "$result_path" >/dev/null
  jq -e 'keys == [
    "failureCode",
    "funnelConfigurationUnchanged",
    "funnelMatchesBaselineAtConfigure",
    "ignoredRequestCount",
    "listenerClosed",
    "probeSucceeded",
    "restAuthorizationHeaderCount",
    "restAuthorizationUnchanged",
    "restIdentityHeaderCount",
    "restIdentityPresent",
    "restRequestCount",
    "restTLSVerified",
    "schemaVersion",
    "serveConfigurationRestored",
    "serveConfigureCommandSucceeded",
    "serveMappingConfigured",
    "serveMappingRemoved",
    "serveOwnedTargetOccurrenceCount",
    "serveResidualMatchesBaseline",
    "serveTotalTargetOccurrenceCount",
    "testMode",
    "webSocketAuthorizationHeaderCount",
    "webSocketAuthorizationUnchanged",
    "webSocketClientSawSwitchingProtocols",
    "webSocketIdentityHeaderCount",
    "webSocketIdentityPresent",
    "webSocketTLSVerified",
    "webSocketUpgradeCount"
  ]' "$result_path" >/dev/null
  local output_path
  local output_line
  for output_path in "$result_path" "$stdout_path" "$stderr_path"; do
    while IFS= read -r output_line || [[ -n "$output_line" ]]; do
      case "$output_line" in
        *"Bearer "*|*"@"*|*".ts.net"*|*"test-identity"*)
          echo "error: probe output included a raw security value" >&2
          exit 1
          ;;
      esac
    done <"$output_path"
  done
}

assert_command_log_is_categorical() {
  local logged_command
  while IFS= read -r logged_command || [[ -n "$logged_command" ]]; do
    case "$logged_command" in
      serve-status|funnel-status|node-status|serve-configure|serve-off)
        ;;
      *)
        echo "error: fake Tailscale command log included non-categorical output" >&2
        exit 1
        ;;
    esac
  done <"$COMMAND_LOG"
}

assert_command_count() {
  local expected_command="$1"
  local expected_count="$2"
  local actual_count=0
  local logged_command

  while IFS= read -r logged_command || [[ -n "$logged_command" ]]; do
    if [[ "$logged_command" == "$expected_command" ]]; then
      actual_count=$((actual_count + 1))
    fi
  done <"$COMMAND_LOG"

  if [[ "$actual_count" != "$expected_count" ]]; then
    echo "error: expected $expected_count $expected_command command(s), observed $actual_count" >&2
    exit 1
  fi
}

assert_command_absent() {
  local unexpected_command="$1"
  local logged_command

  while IFS= read -r logged_command || [[ -n "$logged_command" ]]; do
    if [[ "$logged_command" == "$unexpected_command" ]]; then
      echo "error: configure failure attempted destructive Serve cleanup" >&2
      exit 1
    fi
  done <"$COMMAND_LOG"
}

assert_serve_state_matches_baseline() {
  if ! diff -u <(jq -S . "$BASELINE_STATE") <(jq -S . "$SERVE_STATE") >/dev/null; then
    echo "error: probe did not restore the baseline Serve configuration" >&2
    exit 1
  fi
}

assert_serve_state_differs_from_baseline() {
  if diff -u <(jq -S . "$BASELINE_STATE") <(jq -S . "$SERVE_STATE") >/dev/null; then
    echo "error: probe did not detect an unrelated Serve configuration change" >&2
    exit 1
  fi
}

run_probe() {
  local case_name="$1"
  local fail_after_serve="$2"
  local configure_fails="${3:-0}"
  local off_fails="${4:-0}"
  local post_config_status_fails="${5:-0}"
  local duplicate_target_outside_port="${6:-0}"
  local mutate_unrelated_funnel="${7:-0}"
  local configure_partial_fails="${8:-0}"
  local inject_cotenant_on_cleanup="${9:-0}"
  local allow_funnel_selected_port="${10:-0}"
  local mutate_unrelated_same_number="${11:-0}"
  local terminal_status_fails="${12:-0}"
  local case_root="$TEST_ROOT/$case_name"
  local exit_code=0

  mkdir -p "$case_root/artifacts"
  if TOASTTY_ARTIFACTS_DIR="$case_root/artifacts" \
    TOASTTY_TAILSCALE_CLI="$FAKE_TAILSCALE" \
    TOASTTY_TAILSCALE_PROBE_TEST_MODE=1 \
    TOASTTY_TAILSCALE_PROBE_TEST_FAIL_AFTER_SERVE="$fail_after_serve" \
    TOASTTY_TAILSCALE_PROBE_TIMEOUT_MS=10000 \
    TOASTTY_FAKE_TAILSCALE_STATE="$SERVE_STATE" \
    TOASTTY_FAKE_TAILSCALE_COMMAND_LOG="$COMMAND_LOG" \
    TOASTTY_FAKE_TAILSCALE_CONFIGURE_FAIL="$configure_fails" \
    TOASTTY_FAKE_TAILSCALE_OFF_FAIL="$off_fails" \
    TOASTTY_FAKE_TAILSCALE_POST_CONFIGURE_STATUS_FAIL="$post_config_status_fails" \
    TOASTTY_FAKE_TAILSCALE_DUPLICATE_TARGET_OUTSIDE_PORT="$duplicate_target_outside_port" \
    TOASTTY_FAKE_TAILSCALE_MUTATE_UNRELATED_FUNNEL="$mutate_unrelated_funnel" \
    TOASTTY_FAKE_TAILSCALE_CONFIGURE_PARTIAL_FAIL="$configure_partial_fails" \
    TOASTTY_FAKE_TAILSCALE_INJECT_COTENANT_ON_CLEANUP="$inject_cotenant_on_cleanup" \
    TOASTTY_FAKE_TAILSCALE_ALLOW_FUNNEL_SELECTED_PORT="$allow_funnel_selected_port" \
    TOASTTY_FAKE_TAILSCALE_MUTATE_UNRELATED_SAME_NUMBER="$mutate_unrelated_same_number" \
    TOASTTY_FAKE_TAILSCALE_TERMINAL_STATUS_FAIL="$terminal_status_fails" \
    node "$PROBE_SCRIPT" >"$case_root/stdout.log" 2>"$case_root/stderr.log"; then
    exit_code=0
  else
    exit_code=$?
  fi

  printf '%s\n' "$exit_code" >"$case_root/exit-code"
}

write_empty_baseline_state
run_probe "success" 0
if [[ "$(cat "$TEST_ROOT/success/exit-code")" != "0" ]]; then
  echo "error: success probe failed" >&2
  exit 1
fi
SUCCESS_RESULT="$TEST_ROOT/success/artifacts/tailscale-serve-auth-probe-result.json"
jq -e '
  .probeSucceeded == true
  and .testMode == true
  and .restRequestCount == 1
  and .restAuthorizationHeaderCount == 1
  and .restAuthorizationUnchanged == true
  and .restIdentityHeaderCount == 1
  and .restIdentityPresent == true
  and .webSocketUpgradeCount == 1
  and .webSocketAuthorizationHeaderCount == 1
  and .webSocketAuthorizationUnchanged == true
  and .webSocketIdentityHeaderCount == 1
  and .webSocketIdentityPresent == true
  and .webSocketClientSawSwitchingProtocols == true
  and .serveConfigureCommandSucceeded == true
  and .serveMappingConfigured == true
  and .serveOwnedTargetOccurrenceCount == 1
  and .serveTotalTargetOccurrenceCount == 1
  and .serveResidualMatchesBaseline == true
  and .funnelMatchesBaselineAtConfigure == true
  and .serveMappingRemoved == true
  and .serveConfigurationRestored == true
  and .funnelConfigurationUnchanged == true
  and .listenerClosed == true
  and .failureCode == 0
' "$SUCCESS_RESULT" >/dev/null
assert_privacy_safe_output \
  "$SUCCESS_RESULT" \
  "$TEST_ROOT/success/stdout.log" \
  "$TEST_ROOT/success/stderr.log"
assert_serve_state_matches_baseline
assert_command_count "serve-configure" 1
assert_command_count "serve-off" 1
assert_command_log_is_categorical

write_baseline_state
run_probe "unrelated-funnel-change" 0 0 0 0 0 1
if [[ "$(cat "$TEST_ROOT/unrelated-funnel-change/exit-code")" == "0" ]]; then
  echo "error: unrelated-funnel-change probe unexpectedly passed" >&2
  exit 1
fi
UNRELATED_FUNNEL_CHANGE_RESULT="$TEST_ROOT/unrelated-funnel-change/artifacts/tailscale-serve-auth-probe-result.json"
jq -e '
  .probeSucceeded == false
  and .serveConfigureCommandSucceeded == true
  and .serveMappingConfigured == false
  and .serveOwnedTargetOccurrenceCount == 1
  and .serveTotalTargetOccurrenceCount == 1
  and .serveResidualMatchesBaseline == true
  and .funnelMatchesBaselineAtConfigure == false
  and .serveMappingRemoved == true
  and .serveConfigurationRestored == true
  and .funnelConfigurationUnchanged == false
  and .listenerClosed == true
  and .failureCode == 24
' "$UNRELATED_FUNNEL_CHANGE_RESULT" >/dev/null
assert_privacy_safe_output \
  "$UNRELATED_FUNNEL_CHANGE_RESULT" \
  "$TEST_ROOT/unrelated-funnel-change/stdout.log" \
  "$TEST_ROOT/unrelated-funnel-change/stderr.log"
assert_serve_state_matches_baseline
if [[ ! -e "${SERVE_STATE}.unrelated-funnel-mutation" ]]; then
  echo "error: cleanup removed an unrelated Funnel configuration change" >&2
  exit 1
fi
assert_command_count "serve-configure" 1
assert_command_count "serve-off" 1
assert_command_log_is_categorical

write_baseline_state
run_probe "target-outside-selected-port" 0 0 0 0 1
if [[ "$(cat "$TEST_ROOT/target-outside-selected-port/exit-code")" == "0" ]]; then
  echo "error: target-outside-selected-port probe unexpectedly passed" >&2
  exit 1
fi
TARGET_OUTSIDE_SELECTED_PORT_RESULT="$TEST_ROOT/target-outside-selected-port/artifacts/tailscale-serve-auth-probe-result.json"
jq -e '
  .probeSucceeded == false
  and .serveConfigureCommandSucceeded == true
  and .serveMappingConfigured == false
  and .serveOwnedTargetOccurrenceCount == 1
  and .serveTotalTargetOccurrenceCount == 2
  and .serveResidualMatchesBaseline == false
  and .funnelMatchesBaselineAtConfigure == true
  and .serveMappingRemoved == true
  and .serveConfigurationRestored == false
  and .funnelConfigurationUnchanged == true
  and .listenerClosed == true
  and .failureCode == 24
' "$TARGET_OUTSIDE_SELECTED_PORT_RESULT" >/dev/null
assert_privacy_safe_output \
  "$TARGET_OUTSIDE_SELECTED_PORT_RESULT" \
  "$TEST_ROOT/target-outside-selected-port/stdout.log" \
  "$TEST_ROOT/target-outside-selected-port/stderr.log"
assert_serve_state_differs_from_baseline
if ! jq -e '
  .TCP["443"].HTTPS == true
  and .Web["probe.test.ts.net:443"].Handlers["/"].Proxy == "http://127.0.0.1:42871"
  and (.Web["probe.test.ts.net:443"].Handlers["/duplicate"].Proxy | type == "string")
  and (.Web["probe.test.ts.net:443"].Handlers["/duplicate"].Proxy | startswith("http://127.0.0.1:"))
  and .TCP["10443"] == null
  and .Web["probe.test.ts.net:10443"] == null
' "$SERVE_STATE" >/dev/null; then
  echo "error: cleanup changed an unrelated Serve mapping" >&2
  exit 1
fi
assert_command_count "serve-configure" 1
assert_command_count "serve-off" 1
assert_command_log_is_categorical

write_baseline_state
run_probe "failure-cleanup" 1
if [[ "$(cat "$TEST_ROOT/failure-cleanup/exit-code")" == "0" ]]; then
  echo "error: injected-failure probe unexpectedly passed" >&2
  exit 1
fi
FAILURE_RESULT="$TEST_ROOT/failure-cleanup/artifacts/tailscale-serve-auth-probe-result.json"
jq -e '
  .probeSucceeded == false
  and .serveConfigureCommandSucceeded == true
  and .serveMappingConfigured == true
  and .serveOwnedTargetOccurrenceCount == 1
  and .serveTotalTargetOccurrenceCount == 1
  and .serveResidualMatchesBaseline == true
  and .funnelMatchesBaselineAtConfigure == true
  and .serveMappingRemoved == true
  and .serveConfigurationRestored == true
  and .funnelConfigurationUnchanged == true
  and .listenerClosed == true
  and .failureCode == 90
' "$FAILURE_RESULT" >/dev/null
assert_privacy_safe_output \
  "$FAILURE_RESULT" \
  "$TEST_ROOT/failure-cleanup/stdout.log" \
  "$TEST_ROOT/failure-cleanup/stderr.log"
assert_serve_state_matches_baseline
assert_command_count "serve-configure" 1
assert_command_count "serve-off" 1
assert_command_log_is_categorical

write_baseline_state
run_probe "post-config-status-failure" 0 0 0 1
if [[ "$(cat "$TEST_ROOT/post-config-status-failure/exit-code")" == "0" ]]; then
  echo "error: post-config-status-failure probe unexpectedly passed" >&2
  exit 1
fi
POST_CONFIG_STATUS_FAILURE_RESULT="$TEST_ROOT/post-config-status-failure/artifacts/tailscale-serve-auth-probe-result.json"
jq -e '
  .probeSucceeded == false
  and .serveConfigureCommandSucceeded == true
  and .serveMappingConfigured == false
  and .serveOwnedTargetOccurrenceCount == 0
  and .serveTotalTargetOccurrenceCount == 0
  and .serveResidualMatchesBaseline == false
  and .funnelMatchesBaselineAtConfigure == false
  and .serveMappingRemoved == true
  and .serveConfigurationRestored == true
  and .funnelConfigurationUnchanged == true
  and .listenerClosed == true
  and .failureCode == 24
' "$POST_CONFIG_STATUS_FAILURE_RESULT" >/dev/null
assert_privacy_safe_output \
  "$POST_CONFIG_STATUS_FAILURE_RESULT" \
  "$TEST_ROOT/post-config-status-failure/stdout.log" \
  "$TEST_ROOT/post-config-status-failure/stderr.log"
assert_serve_state_matches_baseline
assert_command_count "serve-configure" 1
assert_command_count "serve-off" 1
assert_command_log_is_categorical

write_baseline_state
run_probe "partial-configure-status-failure" 0 0 0 1 0 0 1
if [[ "$(cat "$TEST_ROOT/partial-configure-status-failure/exit-code")" == "0" ]]; then
  echo "error: partial-configure-status-failure probe unexpectedly passed" >&2
  exit 1
fi
PARTIAL_CONFIGURE_STATUS_FAILURE_RESULT="$TEST_ROOT/partial-configure-status-failure/artifacts/tailscale-serve-auth-probe-result.json"
jq -e '
  .probeSucceeded == false
  and .serveConfigureCommandSucceeded == false
  and .serveMappingConfigured == false
  and .serveOwnedTargetOccurrenceCount == 0
  and .serveTotalTargetOccurrenceCount == 0
  and .serveResidualMatchesBaseline == false
  and .funnelMatchesBaselineAtConfigure == false
  and .serveMappingRemoved == true
  and .serveConfigurationRestored == true
  and .funnelConfigurationUnchanged == true
  and .listenerClosed == true
  and .failureCode == 24
' "$PARTIAL_CONFIGURE_STATUS_FAILURE_RESULT" >/dev/null
assert_privacy_safe_output \
  "$PARTIAL_CONFIGURE_STATUS_FAILURE_RESULT" \
  "$TEST_ROOT/partial-configure-status-failure/stdout.log" \
  "$TEST_ROOT/partial-configure-status-failure/stderr.log"
assert_serve_state_matches_baseline
assert_command_count "serve-configure" 1
assert_command_count "serve-off" 1
assert_command_log_is_categorical

write_baseline_state
run_probe "cleanup-cotenant" 0 0 0 0 0 0 0 1
if [[ "$(cat "$TEST_ROOT/cleanup-cotenant/exit-code")" == "0" ]]; then
  echo "error: cleanup-cotenant probe unexpectedly passed" >&2
  exit 1
fi
CLEANUP_COTENANT_RESULT="$TEST_ROOT/cleanup-cotenant/artifacts/tailscale-serve-auth-probe-result.json"
jq -e '
  .probeSucceeded == false
  and .serveConfigureCommandSucceeded == true
  and .serveMappingConfigured == true
  and .serveOwnedTargetOccurrenceCount == 1
  and .serveTotalTargetOccurrenceCount == 1
  and .serveResidualMatchesBaseline == true
  and .funnelMatchesBaselineAtConfigure == true
  and .serveMappingRemoved == false
  and .serveConfigurationRestored == false
  and .funnelConfigurationUnchanged == false
  and .listenerClosed == true
  and .failureCode == 28
' "$CLEANUP_COTENANT_RESULT" >/dev/null
assert_privacy_safe_output \
  "$CLEANUP_COTENANT_RESULT" \
  "$TEST_ROOT/cleanup-cotenant/stdout.log" \
  "$TEST_ROOT/cleanup-cotenant/stderr.log"
if ! jq -e '
  .TCP["10443"].HTTPS == true
  and (.Web["probe.test.ts.net:10443"].Handlers["/"].Proxy | type == "string")
  and .Web["probe.test.ts.net:10443"].Handlers["/co-tenant"].Proxy == "http://127.0.0.1:9"
' "$SERVE_STATE" >/dev/null; then
  echo "error: cleanup removed a concurrent selected-port co-tenant" >&2
  exit 1
fi
assert_command_count "serve-configure" 1
assert_command_absent "serve-off"
assert_command_log_is_categorical

write_baseline_state
run_probe "selected-port-funnel-grant" 0 0 0 0 0 0 0 0 1
if [[ "$(cat "$TEST_ROOT/selected-port-funnel-grant/exit-code")" == "0" ]]; then
  echo "error: selected-port-funnel-grant probe unexpectedly passed" >&2
  exit 1
fi
SELECTED_PORT_FUNNEL_GRANT_RESULT="$TEST_ROOT/selected-port-funnel-grant/artifacts/tailscale-serve-auth-probe-result.json"
jq -e '
  .probeSucceeded == false
  and .serveConfigureCommandSucceeded == true
  and .serveMappingConfigured == false
  and .serveOwnedTargetOccurrenceCount == 1
  and .serveTotalTargetOccurrenceCount == 1
  and .serveResidualMatchesBaseline == false
  and .funnelMatchesBaselineAtConfigure == false
  and .serveMappingRemoved == false
  and .serveConfigurationRestored == false
  and .funnelConfigurationUnchanged == false
  and .listenerClosed == true
  and .failureCode == 24
' "$SELECTED_PORT_FUNNEL_GRANT_RESULT" >/dev/null
assert_privacy_safe_output \
  "$SELECTED_PORT_FUNNEL_GRANT_RESULT" \
  "$TEST_ROOT/selected-port-funnel-grant/stdout.log" \
  "$TEST_ROOT/selected-port-funnel-grant/stderr.log"
jq -e '.AllowFunnel["probe.test.ts.net:10443"] == true' "$SERVE_STATE" >/dev/null
assert_command_count "serve-configure" 1
assert_command_absent "serve-off"
assert_command_log_is_categorical

write_baseline_state
run_probe "unrelated-same-number-state" 0 0 0 0 0 0 0 0 0 1
if [[ "$(cat "$TEST_ROOT/unrelated-same-number-state/exit-code")" == "0" ]]; then
  echo "error: unrelated-same-number-state probe unexpectedly passed" >&2
  exit 1
fi
UNRELATED_SAME_NUMBER_RESULT="$TEST_ROOT/unrelated-same-number-state/artifacts/tailscale-serve-auth-probe-result.json"
jq -e '
  .probeSucceeded == false
  and .serveConfigureCommandSucceeded == true
  and .serveMappingConfigured == false
  and .serveOwnedTargetOccurrenceCount == 1
  and .serveTotalTargetOccurrenceCount == 1
  and .serveResidualMatchesBaseline == false
  and .funnelMatchesBaselineAtConfigure == true
  and .serveMappingRemoved == true
  and .serveConfigurationRestored == false
  and .funnelConfigurationUnchanged == true
  and .listenerClosed == true
  and .failureCode == 24
' "$UNRELATED_SAME_NUMBER_RESULT" >/dev/null
assert_privacy_safe_output \
  "$UNRELATED_SAME_NUMBER_RESULT" \
  "$TEST_ROOT/unrelated-same-number-state/stdout.log" \
  "$TEST_ROOT/unrelated-same-number-state/stderr.log"
if ! jq -e '
  .Metadata["10443"].Concurrent == true
  and .ConcurrentEmpty == {}
  and .TCP["10443"] == null
  and .Web["probe.test.ts.net:10443"] == null
' "$SERVE_STATE" >/dev/null; then
  echo "error: selected-port cleanup masked unrelated same-number state" >&2
  exit 1
fi
assert_command_count "serve-configure" 1
assert_command_count "serve-off" 1
assert_command_log_is_categorical

write_baseline_state
run_probe "configure-failure" 0 1
if [[ "$(cat "$TEST_ROOT/configure-failure/exit-code")" == "0" ]]; then
  echo "error: configure-failure probe unexpectedly passed" >&2
  exit 1
fi
CONFIGURE_FAILURE_RESULT="$TEST_ROOT/configure-failure/artifacts/tailscale-serve-auth-probe-result.json"
if ! jq -e '
  .probeSucceeded == false
  and .serveConfigureCommandSucceeded == false
  and .serveMappingConfigured == false
  and .serveOwnedTargetOccurrenceCount == 0
  and .serveTotalTargetOccurrenceCount == 0
  and .serveResidualMatchesBaseline == false
  and .funnelMatchesBaselineAtConfigure == false
  and .serveMappingRemoved == true
  and .serveConfigurationRestored == true
  and .funnelConfigurationUnchanged == true
  and .listenerClosed == true
  and .failureCode == 24
' "$CONFIGURE_FAILURE_RESULT" >/dev/null; then
  jq '{
    probeSucceeded,
    serveConfigureCommandSucceeded,
    serveMappingConfigured,
    serveOwnedTargetOccurrenceCount,
    serveTotalTargetOccurrenceCount,
    serveResidualMatchesBaseline,
    funnelMatchesBaselineAtConfigure,
    serveMappingRemoved,
    serveConfigurationRestored,
    funnelConfigurationUnchanged,
    listenerClosed,
    failureCode
  }' "$CONFIGURE_FAILURE_RESULT" >&2
  exit 1
fi
assert_privacy_safe_output \
  "$CONFIGURE_FAILURE_RESULT" \
  "$TEST_ROOT/configure-failure/stdout.log" \
  "$TEST_ROOT/configure-failure/stderr.log"
assert_serve_state_matches_baseline
assert_command_count "serve-configure" 1
assert_command_absent "serve-off"
assert_command_log_is_categorical

write_baseline_state
run_probe "terminal-status-failure" 0 0 0 0 0 0 0 0 0 0 1
if [[ "$(cat "$TEST_ROOT/terminal-status-failure/exit-code")" == "0" ]]; then
  echo "error: terminal-status-failure probe unexpectedly passed" >&2
  exit 1
fi
TERMINAL_STATUS_FAILURE_RESULT="$TEST_ROOT/terminal-status-failure/artifacts/tailscale-serve-auth-probe-result.json"
jq -e '
  .probeSucceeded == false
  and .serveConfigureCommandSucceeded == true
  and .serveMappingConfigured == true
  and .serveOwnedTargetOccurrenceCount == 1
  and .serveTotalTargetOccurrenceCount == 1
  and .serveResidualMatchesBaseline == true
  and .funnelMatchesBaselineAtConfigure == true
  and .serveMappingRemoved == false
  and .serveConfigurationRestored == false
  and .funnelConfigurationUnchanged == false
  and .listenerClosed == true
  and .failureCode == 28
' "$TERMINAL_STATUS_FAILURE_RESULT" >/dev/null
assert_privacy_safe_output \
  "$TERMINAL_STATUS_FAILURE_RESULT" \
  "$TEST_ROOT/terminal-status-failure/stdout.log" \
  "$TEST_ROOT/terminal-status-failure/stderr.log"
assert_serve_state_matches_baseline
assert_command_count "serve-configure" 1
assert_command_count "serve-off" 1
assert_command_log_is_categorical

write_baseline_state
run_probe "cleanup-failure" 0 0 1
if [[ "$(cat "$TEST_ROOT/cleanup-failure/exit-code")" == "0" ]]; then
  echo "error: cleanup-failure probe unexpectedly passed" >&2
  exit 1
fi
CLEANUP_FAILURE_RESULT="$TEST_ROOT/cleanup-failure/artifacts/tailscale-serve-auth-probe-result.json"
jq -e '
  .probeSucceeded == false
  and .serveConfigureCommandSucceeded == true
  and .serveMappingConfigured == true
  and .serveOwnedTargetOccurrenceCount == 1
  and .serveTotalTargetOccurrenceCount == 1
  and .serveResidualMatchesBaseline == true
  and .funnelMatchesBaselineAtConfigure == true
  and .serveMappingRemoved == false
  and .serveConfigurationRestored == false
  and .funnelConfigurationUnchanged == false
  and .listenerClosed == true
  and .failureCode == 28
' "$CLEANUP_FAILURE_RESULT" >/dev/null
assert_privacy_safe_output \
  "$CLEANUP_FAILURE_RESULT" \
  "$TEST_ROOT/cleanup-failure/stdout.log" \
  "$TEST_ROOT/cleanup-failure/stderr.log"
assert_command_count "serve-configure" 1
assert_command_count "serve-off" 3
assert_command_log_is_categorical

echo "ok: Tailscale Serve authorization probe self-test passed"
