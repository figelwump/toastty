#!/usr/bin/env bash

toastty_sanitize_runtime_label() {
  local raw="${1:-}"
  local label
  label="$(printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^[:alnum:]]+/-/g; s/-+/-/g; s/^-+//; s/-+$//' \
    | cut -c 1-80 \
    | sed -E 's/^-+//; s/-+$//')"
  if [[ -z "$label" ]]; then
    label="run"
  fi
  printf '%s' "$label"
}

toastty_canonical_path() {
  local input_path="$1"
  if [[ -d "$input_path" ]]; then
    (cd "$input_path" && pwd -P)
    return
  fi

  local directory
  local basename
  directory="$(dirname "$input_path")"
  basename="$(basename "$input_path")"
  if [[ -d "$directory" ]]; then
    (cd "$directory" && printf '%s/%s\n' "$(pwd -P)" "$basename")
    return
  fi

  printf '%s\n' "$input_path"
}

toastty_assert_run_owned_instance() {
  local instance_json="$1"
  local run_id="$2"
  local runtime_home="$3"
  local socket_path="${4:-}"
  local require_run_id="${5:-0}"

  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required to verify Toastty runtime ownership" >&2
    return 1
  fi
  if [[ ! -f "$instance_json" ]]; then
    echo "error: instance manifest not found: $instance_json" >&2
    return 1
  fi

  local expected_label
  local actual_label
  expected_label="$(toastty_sanitize_runtime_label "$run_id")"
  actual_label="$(jq -r '.runtimeLabel // empty' "$instance_json")"
  if [[ "$actual_label" != "$expected_label" ]]; then
    echo "error: refusing to target Toastty runtime without run-owned label" >&2
    echo "  expected runtimeLabel: $expected_label" >&2
    echo "  actual runtimeLabel:   ${actual_label:-<empty>}" >&2
    echo "  manifest:              $instance_json" >&2
    return 1
  fi

  local expected_runtime_home
  local actual_runtime_home
  expected_runtime_home="$(toastty_canonical_path "$runtime_home")"
  actual_runtime_home="$(jq -r '.runtimeHomePath // empty' "$instance_json")"
  if [[ -n "$actual_runtime_home" ]]; then
    actual_runtime_home="$(toastty_canonical_path "$actual_runtime_home")"
  fi
  if [[ "$actual_runtime_home" != "$expected_runtime_home" ]]; then
    echo "error: refusing to target Toastty runtime from a different runtime home" >&2
    echo "  expected runtimeHomePath: $expected_runtime_home" >&2
    echo "  actual runtimeHomePath:   ${actual_runtime_home:-<empty>}" >&2
    echo "  manifest:                 $instance_json" >&2
    return 1
  fi

  if [[ -n "$socket_path" ]]; then
    local expected_socket_path
    local actual_socket_path
    expected_socket_path="$(toastty_canonical_path "$socket_path")"
    actual_socket_path="$(jq -r '.socketPath // empty' "$instance_json")"
    if [[ -n "$actual_socket_path" ]]; then
      actual_socket_path="$(toastty_canonical_path "$actual_socket_path")"
    fi
    if [[ "$actual_socket_path" != "$expected_socket_path" ]]; then
      echo "error: refusing to target Toastty runtime with a different socket" >&2
      echo "  expected socketPath: $expected_socket_path" >&2
      echo "  actual socketPath:   ${actual_socket_path:-<empty>}" >&2
      echo "  manifest:            $instance_json" >&2
      return 1
    fi
  fi

  if [[ "$require_run_id" == "1" ]]; then
    local actual_run_id
    actual_run_id="$(jq -r '.runID // empty' "$instance_json")"
    if [[ "$actual_run_id" != "$run_id" ]]; then
      echo "error: refusing to target Toastty automation runtime with a different run id" >&2
      echo "  expected runID: $run_id" >&2
      echo "  actual runID:   ${actual_run_id:-<empty>}" >&2
      echo "  manifest:       $instance_json" >&2
      return 1
    fi
  fi

  local pid
  pid="$(jq -r '.pid // empty' "$instance_json")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" >/dev/null 2>&1; then
    echo "error: refusing to target stale Toastty runtime manifest; pid is not live: $pid" >&2
    echo "  manifest: $instance_json" >&2
    return 1
  fi
}
