#!/usr/bin/env bash

# Run-owned iOS Simulator lifecycle helpers for scripts/remote/test.sh.
# The caller keeps `set -euo pipefail`; helpers return non-zero on any safety
# ambiguity so cleanup never broadens beyond the recorded run.

TOASTTY_IOS_SIMULATOR_TEMPLATE_NAME="${TOASTTY_IOS_SIMULATOR_TEMPLATE_NAME:-Toastty Remote Template}"
TOASTTY_IOS_OWNED_SIMULATOR_UDID=""
TOASTTY_IOS_OWNED_SIMULATOR_NAME=""
TOASTTY_IOS_SIMCTL_PID=""
TOASTTY_IOS_BOUNDED_OUTPUT=""

toastty_ios_run_bounded() {
  local timeout_seconds="$1"
  shift
  local output_path
  local started_epoch
  local command_status=0

  [[ "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" != "0" ]] || return 1
  output_path="$(mktemp "${TMPDIR:-/tmp}/toastty-simctl-output.XXXXXX")" || return 1
  TOASTTY_IOS_BOUNDED_OUTPUT=""
  "$@" >"$output_path" &
  TOASTTY_IOS_SIMCTL_PID=$!
  started_epoch="$(date +%s)"

  while kill -0 "$TOASTTY_IOS_SIMCTL_PID" >/dev/null 2>&1; do
    if (( $(date +%s) - started_epoch >= timeout_seconds )); then
      kill -TERM "$TOASTTY_IOS_SIMCTL_PID" >/dev/null 2>&1 || true
      sleep 1
      kill -KILL "$TOASTTY_IOS_SIMCTL_PID" >/dev/null 2>&1 || true
      wait "$TOASTTY_IOS_SIMCTL_PID" >/dev/null 2>&1 || true
      TOASTTY_IOS_SIMCTL_PID=""
      rm -f -- "$output_path"
      return 124
    fi
    sleep 1
  done

  if wait "$TOASTTY_IOS_SIMCTL_PID"; then
    command_status=0
  else
    command_status=$?
  fi
  TOASTTY_IOS_SIMCTL_PID=""
  TOASTTY_IOS_BOUNDED_OUTPUT="$(<"$output_path")"
  rm -f -- "$output_path"
  return "$command_status"
}

toastty_ios_cancel_bounded_simctl() {
  local pid="${TOASTTY_IOS_SIMCTL_PID:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill -TERM "$pid" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
  wait "$pid" >/dev/null 2>&1 || true
  TOASTTY_IOS_SIMCTL_PID=""
}

toastty_ios_simulator_log() {
  printf '[remote-test] %s\n' "$*" >&2
}

toastty_ios_simulator_sanitize_component() {
  local raw="$1"
  local value
  value="$(printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^[:alnum:]]+/-/g; s/-+/-/g; s/^-+//; s/-+$//' \
    | cut -c 1-40 \
    | sed -E 's/^-+//; s/-+$//')"
  [[ -n "$value" ]] || value="run"
  printf '%s\n' "$value"
}

toastty_ios_simulator_runtime_record() {
  xcrun simctl list runtimes available --json \
    | jq -cer '
      [
        .runtimes[]
        | select(.isAvailable != false)
        | select(
            .platform == "iOS"
            or ((.identifier // "") | contains(".SimRuntime.iOS-"))
          )
        | select((.version // "") | test("^[0-9]+(\\.[0-9]+){0,2}$"))
        | . + {versionParts: (.version | split(".") | map(tonumber))}
        | select(.versionParts[0] >= 18)
      ]
      | sort_by(.versionParts)
      | last
      | select(type == "object")
    '
}

toastty_ios_simulator_preferred_device_type() {
  local runtime_record="$1"
  jq -er '
    [(.supportedDeviceTypes // [])[] | select(.productFamily == "iPhone")]
    | (
        (map(select(.name == "iPhone 17 Pro")) | first)
        // (map(select(.name == "iPhone 17")) | first)
        // (map(select(.name == "iPhone 16e")) | first)
        // first
      )
    | .identifier
    | select(type == "string" and length > 0)
  ' <<<"$runtime_record"
}

toastty_ios_simulator_find_template() {
  local runtime_identifier="$1"
  local devices_json
  devices_json="$(xcrun simctl list devices available --json)" || return 1
  jq -cer \
    --arg runtime "$runtime_identifier" \
    --arg name "$TOASTTY_IOS_SIMULATOR_TEMPLATE_NAME" '
      [(.devices[$runtime] // [])[] | select(.name == $name)]
      | select(length == 1)
      | .[0]
    ' <<<"$devices_json"
}

toastty_ios_template_lock_is_stale() {
  local lock_dir="$1"
  local owner_path="$lock_dir/owner.json"
  local now_epoch="$(date +%s)"
  local created_epoch
  local owner_pid
  local owner_started_at
  local actual_started_at

  if [[ -f "$owner_path" && ! -L "$owner_path" ]] \
    && created_epoch="$(jq -er '.createdAtEpoch | select(type == "number" and floor == .)' "$owner_path" 2>/dev/null)" \
    && owner_pid="$(jq -er '.pid | select(type == "number" and floor == . and . > 0)' "$owner_path" 2>/dev/null)" \
    && owner_started_at="$(jq -er '.startedAt | select(type == "string" and length > 0)' "$owner_path" 2>/dev/null)"; then
    (( now_epoch - created_epoch >= 900 )) || return 1
    actual_started_at="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$owner_pid" 2>/dev/null | awk '{$1=$1; print}' || true)"
    [[ -z "$actual_started_at" || "$actual_started_at" != "$owner_started_at" ]]
    return
  fi

  created_epoch="$(stat -f %m "$lock_dir" 2>/dev/null || true)"
  [[ "$created_epoch" =~ ^[0-9]+$ ]] || return 1
  (( now_epoch - created_epoch >= 900 ))
}

toastty_ios_release_template_lock() {
  local lock_dir="$1"
  rm -f -- "$lock_dir/owner.json"
  rmdir "$lock_dir" 2>/dev/null || true
}

toastty_ios_simulator_ensure_template() {
  local remote_gui_root="$1"
  local lock_dir="$remote_gui_root/.ios-simulator-template.lock"
  local runtime_record
  local runtime_identifier
  local template_record
  local device_type_identifier
  local template_udid
  local attempt
  local lock_acquired=0
  local stale_lock_dir

  runtime_record="$(toastty_ios_simulator_runtime_record)" || return 1
  runtime_identifier="$(jq -er '.identifier' <<<"$runtime_record")" || return 1

  template_record="$(toastty_ios_simulator_find_template "$runtime_identifier" 2>/dev/null || true)"
  if [[ -z "$template_record" ]]; then
    for ((attempt = 0; attempt < 100; attempt += 1)); do
      if mkdir "$lock_dir" 2>/dev/null; then
        lock_acquired=1
        if ! jq -n \
          --argjson pid "$$" \
          --arg startedAt "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$$" | awk '{$1=$1; print}')" \
          --argjson createdAtEpoch "$(date +%s)" \
          '{pid:$pid,startedAt:$startedAt,createdAtEpoch:$createdAtEpoch}' \
          >"$lock_dir/owner.json"; then
          toastty_ios_release_template_lock "$lock_dir"
          return 1
        fi
        break
      fi
      if toastty_ios_template_lock_is_stale "$lock_dir"; then
        stale_lock_dir="${lock_dir}.stale-$$-${RANDOM}"
        if mv "$lock_dir" "$stale_lock_dir" 2>/dev/null; then
          rm -rf -- "$stale_lock_dir"
          continue
        fi
      fi
      sleep 0.1
    done
    [[ "$lock_acquired" == "1" ]] || {
      printf 'error: timed out acquiring iOS Simulator template lock: %s\n' "$lock_dir" >&2
      return 1
    }

    template_record="$(toastty_ios_simulator_find_template "$runtime_identifier" 2>/dev/null || true)"
    if [[ -z "$template_record" ]]; then
      device_type_identifier="$(toastty_ios_simulator_preferred_device_type "$runtime_record")" || {
        toastty_ios_release_template_lock "$lock_dir"
        return 1
      }
      toastty_ios_simulator_log "Creating clean simulator template on iOS $(jq -r '.version' <<<"$runtime_record")"
      if ! toastty_ios_run_bounded 120 xcrun simctl create \
        "$TOASTTY_IOS_SIMULATOR_TEMPLATE_NAME" \
        "$device_type_identifier" \
        "$runtime_identifier"; then
        toastty_ios_release_template_lock "$lock_dir"
        return 1
      fi
      template_record="$(toastty_ios_simulator_find_template "$runtime_identifier")" || {
        toastty_ios_release_template_lock "$lock_dir"
        return 1
      }
    fi
    toastty_ios_release_template_lock "$lock_dir"
  fi

  [[ "$(jq -r '.state' <<<"$template_record")" == "Shutdown" ]] || {
    printf 'error: refusing to clone booted simulator template: %s\n' \
      "$TOASTTY_IOS_SIMULATOR_TEMPLATE_NAME" >&2
    return 1
  }
  template_udid="$(jq -er '.udid | select(type == "string" and length > 0)' <<<"$template_record")" \
    || return 1
  printf '%s\n' "$template_udid"
}

toastty_ios_simulator_write_ownership() {
  local manifest_path="$1"
  local run_label="$2"
  local remote_run_root="$3"
  local remote_worktree_dir="$4"
  local derived_path="$5"
  local runtime_home="$6"
  local simulator_udid="$7"
  local simulator_name="$8"
  local owner_pid="$$"
  local owner_pgid
  local temporary_path
  local created_at

  owner_pgid="$(ps -o pgid= -p "$owner_pid" | tr -d '[:space:]')" || return 1
  [[ "$owner_pgid" =~ ^[0-9]+$ ]] || return 1
  created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  temporary_path="${manifest_path}.tmp-${owner_pid}-${RANDOM}"

  jq -n \
    --arg ownership "toastty-remote-test" \
    --arg runLabel "$run_label" \
    --arg remoteRunRoot "$remote_run_root" \
    --arg remoteWorktreePath "$remote_worktree_dir" \
    --arg derivedDataPath "$derived_path" \
    --arg runtimeHomePath "$runtime_home" \
    --arg simulatorUDID "$simulator_udid" \
    --arg simulatorName "$simulator_name" \
    --argjson ownerPID "$owner_pid" \
    --argjson ownerPGID "$owner_pgid" \
    --arg ownerStartedAt "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$owner_pid" | awk '{$1=$1; print}')" \
    --arg createdAt "$created_at" '
      {
        schemaVersion: 1,
        ownership: $ownership,
        runLabel: $runLabel,
        remoteRunRoot: $remoteRunRoot,
        remoteWorktreePath: $remoteWorktreePath,
        derivedDataPath: $derivedDataPath,
        runtimeHomePath: $runtimeHomePath,
        simulator: {udid: $simulatorUDID, name: $simulatorName},
        owner: {pid: $ownerPID, pgid: $ownerPGID, startedAt: $ownerStartedAt},
        createdAt: $createdAt
      }
    ' >"$temporary_path" || {
      rm -f -- "$temporary_path"
      return 1
  }
  if ! chmod 0444 "$temporary_path"; then
    rm -f -- "$temporary_path"
    return 1
  fi
  if ! ln "$temporary_path" "$manifest_path"; then
    rm -f -- "$temporary_path"
    return 1
  fi
  rm -f -- "$temporary_path"
  : >"$remote_run_root/STARTED"
}

toastty_ios_simulator_create_owned_clone() {
  local run_label="$1"
  local remote_run_root="$2"
  local remote_worktree_dir="$3"
  local derived_path="$4"
  local runtime_home="$5"
  local remote_gui_root
  local template_udid
  local run_component
  local run_digest
  local clone_name
  local clone_udid
  local manifest_path="$remote_run_root/simulator-ownership.json"

  command -v jq >/dev/null 2>&1 || {
    printf 'error: jq is required for run-owned simulator isolation\n' >&2
    return 1
  }
  remote_gui_root="$(cd "$(dirname "$remote_run_root")/.." && pwd -P)" || return 1
  template_udid="$(toastty_ios_simulator_ensure_template "$remote_gui_root")" || return 1
  run_component="$(toastty_ios_simulator_sanitize_component "$run_label")"
  run_digest="$(printf '%s' "$remote_run_root" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
  clone_name="Toastty Remote test-${run_component}-${run_digest}"

  toastty_ios_simulator_log "Cloning run-owned simulator: $clone_name"
  toastty_ios_run_bounded 120 xcrun simctl clone "$template_udid" "$clone_name" || return 1
  clone_udid="$TOASTTY_IOS_BOUNDED_OUTPUT"
  clone_udid="$(printf '%s' "$clone_udid" | tr -d '[:space:]')"
  [[ "$clone_udid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
    printf 'error: simctl clone returned an invalid simulator identifier\n' >&2
    return 1
  }

  TOASTTY_IOS_OWNED_SIMULATOR_UDID="$clone_udid"
  TOASTTY_IOS_OWNED_SIMULATOR_NAME="$clone_name"
  toastty_ios_simulator_write_ownership \
    "$manifest_path" \
    "$run_label" \
    "$remote_run_root" \
    "$remote_worktree_dir" \
    "$derived_path" \
    "$runtime_home" \
    "$clone_udid" \
    "$clone_name" || return 1

  toastty_ios_run_bounded 120 xcrun simctl boot "$clone_udid" || return 1
  toastty_ios_run_bounded 180 xcrun simctl bootstatus "$clone_udid" -b || return 1
}

toastty_ios_simulator_manifest_is_owned() {
  local manifest_path="$1"
  local run_label="$2"
  local remote_run_root="$3"
  local remote_worktree_dir="$4"
  local derived_path="$5"
  local runtime_home="$6"
  local simulator_udid="$7"
  local simulator_name="$8"

  [[ -f "$manifest_path" && ! -L "$manifest_path" ]] || return 1
  jq -e \
    --arg runLabel "$run_label" \
    --arg remoteRunRoot "$remote_run_root" \
    --arg remoteWorktreePath "$remote_worktree_dir" \
    --arg derivedDataPath "$derived_path" \
    --arg runtimeHomePath "$runtime_home" \
    --arg simulatorUDID "$simulator_udid" \
    --arg simulatorName "$simulator_name" '
      .schemaVersion == 1
      and .ownership == "toastty-remote-test"
      and .runLabel == $runLabel
      and .remoteRunRoot == $remoteRunRoot
      and .remoteWorktreePath == $remoteWorktreePath
      and .derivedDataPath == $derivedDataPath
      and .runtimeHomePath == $runtimeHomePath
      and .simulator.udid == $simulatorUDID
      and .simulator.name == $simulatorName
    ' "$manifest_path" >/dev/null
}

toastty_ios_simulator_delete_owned_clone() {
  local run_label="$1"
  local remote_run_root="$2"
  local remote_worktree_dir="$3"
  local derived_path="$4"
  local runtime_home="$5"
  local simulator_udid="$6"
  local simulator_name="$7"
  local manifest_path="$remote_run_root/simulator-ownership.json"
  local device_record
  local device_count

  [[ -n "$simulator_udid" && -n "$simulator_name" ]] || return 0
  toastty_ios_simulator_manifest_is_owned \
    "$manifest_path" "$run_label" "$remote_run_root" "$remote_worktree_dir" \
    "$derived_path" "$runtime_home" "$simulator_udid" "$simulator_name" || {
      printf 'error: refusing to delete simulator without matching immutable run ownership\n' >&2
      return 1
    }

  device_record="$(xcrun simctl list devices --json | jq -c \
    --arg udid "$simulator_udid" '[.devices[][] | select(.udid == $udid)]')" || return 1
  device_count="$(jq -r 'length' <<<"$device_record")"
  if [[ "$device_count" == "0" ]]; then
    return 0
  fi
  [[ "$device_count" == "1" ]] || return 1
  [[ "$(jq -r '.[0].name' <<<"$device_record")" == "$simulator_name" ]] || return 1

  if [[ "$(jq -r '.[0].state' <<<"$device_record")" == "Booted" ]]; then
    toastty_ios_run_bounded 60 xcrun simctl shutdown "$simulator_udid" || return 1
  fi
  toastty_ios_run_bounded 120 xcrun simctl delete "$simulator_udid"
}

toastty_command_is_run_owned_host_app() {
  local command_line="$1"
  local derived_path="$2"
  [[ -n "$derived_path" && "$derived_path" == /* && "$derived_path" == */Derived ]] || return 1
  case "$command_line" in
    "$derived_path"/*/Toastty.app/Contents/MacOS/Toastty|\
    "$derived_path"/*/Toastty.app/Contents/MacOS/Toastty\ *) return 0 ;;
    *) return 1 ;;
  esac
}

toastty_cleanup_run_owned_host_apps() {
  local derived_path="$1"
  local pid
  local command_line
  local current_command
  local attempt
  local failures=0

  [[ -n "$derived_path" && "$derived_path" == /* && "$derived_path" == */Derived ]] || {
    printf 'error: refusing host cleanup with an unsafe DerivedData path: %s\n' "$derived_path" >&2
    return 1
  }

  while read -r pid command_line; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    toastty_command_is_run_owned_host_app "$command_line" "$derived_path" || continue
    current_command="$(ps -p "$pid" -o command= 2>/dev/null | sed -E 's/^[[:space:]]+//' || true)"
    toastty_command_is_run_owned_host_app "$current_command" "$derived_path" || continue
    kill -TERM "$pid" >/dev/null 2>&1 || true
    for ((attempt = 0; attempt < 20; attempt += 1)); do
      kill -0 "$pid" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if kill -0 "$pid" >/dev/null 2>&1; then
      current_command="$(ps -p "$pid" -o command= 2>/dev/null | sed -E 's/^[[:space:]]+//' || true)"
      if toastty_command_is_run_owned_host_app "$current_command" "$derived_path"; then
        kill -KILL "$pid" >/dev/null 2>&1 || true
        for ((attempt = 0; attempt < 20; attempt += 1)); do
          kill -0 "$pid" >/dev/null 2>&1 || break
          sleep 0.1
        done
      fi
    fi
    if kill -0 "$pid" >/dev/null 2>&1; then
      current_command="$(ps -p "$pid" -o command= 2>/dev/null | sed -E 's/^[[:space:]]+//' || true)"
      if toastty_command_is_run_owned_host_app "$current_command" "$derived_path"; then
        failures=$((failures + 1))
      fi
    fi
  done < <(ps -axww -o pid=,command=)

  [[ "$failures" == "0" ]]
}

toastty_run_paths_have_live_process() {
  local derived_path="$1"
  local runtime_home="$2"
  local pid
  local command_line
  local ancestor_pid="$$"
  local ancestor_pids=""
  local parent_pid

  [[ -n "$derived_path" && "$derived_path" == /* && "$derived_path" == */Derived ]] || return 0
  [[ -n "$runtime_home" && "$runtime_home" == /* && "$runtime_home" == */runtime-home ]] || return 0

  while [[ "$ancestor_pid" =~ ^[0-9]+$ && "$ancestor_pid" != "0" ]]; do
    ancestor_pids+=" $ancestor_pid"
    [[ "$ancestor_pid" == "1" ]] && break
    parent_pid="$(ps -o ppid= -p "$ancestor_pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$parent_pid" =~ ^[0-9]+$ ]] || break
    ancestor_pid="$parent_pid"
  done

  while read -r pid command_line; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    case " $ancestor_pids " in
      *" $pid "*) continue ;;
    esac
    case "$command_line" in
      *"$derived_path"/*|*"$derived_path "*|*"$derived_path"|\
      *"$runtime_home"/*|*"$runtime_home "*|*"$runtime_home") return 0 ;;
    esac
  done < <(ps -axww -o pid=,command=)
  return 1
}
