#!/usr/bin/env bash

# Shared validation and serialization for the opt-in live iOS gateway suite.
# Callers must disable xtrace before reading or passing credential values.

toastty_live_gateway_url_is_valid() {
  local value="$1"
  local hostname_label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'

  [[ -n "$value" ]] || return 1
  ((${#value} <= 255)) || return 1
  [[ "$value" =~ ^https://(${hostname_label}\.)+ts\.net$ ]]
}

toastty_live_gateway_credential_is_valid() {
  local value="$1"

  [[ ${#value} -eq 43 ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

toastty_emit_live_gateway_remote_setup() {
  local gateway_url="$1"
  local credential="$2"
  local allow_destructive="$3"
  local destructive_value

  toastty_live_gateway_url_is_valid "$gateway_url" || return 1
  toastty_live_gateway_credential_is_valid "$credential" || return 1
  case "$allow_destructive" in
    0) destructive_value="false" ;;
    1) destructive_value="true" ;;
    *) return 1 ;;
  esac

  # Both values have already been restricted to alphabets that exclude a
  # single quote, so these in-memory shell assignments are safe to feed to a
  # fresh Bash stdin. They are consumed by the loopback broker and never
  # exported into xcodebuild, which persists test-runner environment settings.
  printf "live_gateway_url='%s'\n" "$gateway_url"
  printf "live_gateway_credential='%s'\n" "$credential"
  printf "live_gateway_allow_destructive='%s'\n" "$destructive_value"
  printf "export TEST_RUNNER_TOASTTY_MOBILE_LIVE_FORWARDING_PROBE='1'\n"
}
