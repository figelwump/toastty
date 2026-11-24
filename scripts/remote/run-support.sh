#!/usr/bin/env bash
# Shared by the local entry points. Keep this compatible with macOS Bash 3.2.

toastty_default_run_label() {
  printf '%s-%s-%s\n' "$1" "$(date -u +%Y%m%dT%H%M%SZ)" "$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c 1-16)"
}

toastty_validate_run_label() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
    printf 'error: --run-label must use 1-128 letters, numbers, dots, underscores, or hyphens\n' >&2
    return 1
  }
}

toastty_mkdir_exclusive() {
  # Use mkdir(2) directly. uutils mkdir 0.10 can report success after
  # another process creates the directory (uutils/coreutils#13970).
  /usr/bin/python3 -I -c '
import os
import sys

try:
    os.mkdir(sys.argv[1])
except OSError as error:
    sys.exit(str(error))
' "$1"
}

toastty_allocate_local_artifacts() {
  mkdir -p "$(dirname "$1")" || return 1
  toastty_mkdir_exclusive "$1" || {
    printf 'error: artifact directory already exists or cannot be created: %s; choose a new run label\n' "$1" >&2
    return 1
  }
}

# This definition is sent over SSH: the remote source checkout may be older.
toastty_allocate_remote_run() (
  local repo="$1" worktree="$2" run_root="$3"
  local allocation_lock="$2.allocation-lock"
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null || return 1
  mkdir -p "$(dirname "$worktree")" "$(dirname "$run_root")" || return 1
  # Git may remove an empty destination while creating its worktree. Keep
  # ownership outside that directory until allocation has finished.
  toastty_mkdir_exclusive "$allocation_lock" || {
    printf 'error: remote worktree allocation already exists: %s; choose a new run label or inspect the incomplete allocation\n' "$allocation_lock" >&2
    return 1
  }
  trap 'rmdir "$allocation_lock"' EXIT
  toastty_mkdir_exclusive "$run_root" || {
    printf 'error: remote run already exists or cannot be created: %s; choose a new run label\n' "$run_root" >&2
    return 1
  }
  if [[ -e "$worktree" || -L "$worktree" ]]; then
    rmdir "$run_root" || true
    printf 'error: remote worktree already exists or cannot be created: %s; choose a new run label\n' "$worktree" >&2
    return 1
  fi
  if ! git -C "$repo" worktree add --detach "$worktree" >/dev/null; then
    # rmdir cannot remove a partial checkout or another run's files.
    rmdir "$worktree" "$run_root" 2>/dev/null || true
    printf 'error: could not create remote worktree: %s; inspect partial files and git worktree list for stale registrations\n' "$worktree" >&2
    return 1
  fi
)

toastty_remove_remote_run() {
  local repo="$1" worktree="$2" run_root="$3"
  # Do not fall back to rm: failed Git removal needs inspection, not a stale registration.
  git -C "$repo" worktree remove --force "$worktree" || return 1
  rm -rf "$run_root" || return 1
  [[ ! -e "$worktree" && ! -L "$worktree" && ! -e "$run_root" && ! -L "$run_root" ]]
}

toastty_record_infrastructure_failure() {
  local path="$1" message="$2" failure_status="${3:-fail}"
  local temporary="$path.tmp"
  if jq --arg message "$message" --arg status "$failure_status" \
    '.infrastructureFailureSummary = $message | if .status == "pass" then .status = $status else . end' \
    "$path" >"$temporary"; then
    mv "$temporary" "$path" || return 1
  else
    rm -f "$temporary"
    return 1
  fi
}

# A run's build caches: the DerivedData folders (Derived and run/Derived)
# that the evidence copy skips. Logs and result bundles are evidence and stay.
# These definitions are sent over SSH.
toastty_run_cache_paths() {
  local base subtree
  for base in Derived run/Derived; do
    for subtree in Build/Intermediates.noindex Build/Products Index.noindex ModuleCache.noindex SourcePackages SDKStatCaches.noindex SDKExplicitPrecompiledModules CompilationCache.noindex; do
      printf '%s/%s\n' "$base" "$subtree"
    done
  done
}

# Copies a run's evidence, then checks that the destination matches the source.
# The second pass lists any file that differs; it ignores folder times only.
toastty_copy_run_artifacts() {
  local source="$1" destination="$2" full="$3"
  local filters=() path differences
  local ssh_command='ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3'
  if [[ "$full" != 1 ]]; then
    while IFS= read -r path; do
      filters+=(--exclude "/$path/")
    done < <(toastty_run_cache_paths)
  fi
  rsync -a ${filters[@]+"${filters[@]}"} -e "$ssh_command" "$source/" "$destination/" || return 1
  differences="$(rsync -a --omit-dir-times --dry-run --itemize-changes ${filters[@]+"${filters[@]}"} \
    -e "$ssh_command" "$source/" "$destination/")" || return 1
  if [[ -n "$differences" ]]; then
    printf 'error: copied evidence differs from the remote run:\n%s\n' "$differences" >&2
    return 1
  fi
}

toastty_run_paths_have_live_process() {
  local derived_path="$1"
  local runtime_home="$2"
  local pid
  local command_line
  local ancestor_pid="$$"
  local ancestor_pids=""
  local parent_pid
  local process_inventory

  [[ -n "$derived_path" && "$derived_path" == /* && "$derived_path" == */Derived ]] || return 0
  [[ -n "$runtime_home" && "$runtime_home" == /* && "$runtime_home" == */runtime-home ]] || return 0

  while [[ "$ancestor_pid" =~ ^[0-9]+$ && "$ancestor_pid" != "0" ]]; do
    ancestor_pids+=" $ancestor_pid"
    [[ "$ancestor_pid" == "1" ]] && break
    parent_pid="$(ps -o ppid= -p "$ancestor_pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$parent_pid" =~ ^[0-9]+$ ]] || break
    ancestor_pid="$parent_pid"
  done

  # A failed inventory is unknown ownership, not evidence that the run is idle.
  process_inventory="$(ps -axww -o pid=,command=)" || return 0
  while read -r pid command_line; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    case " $ancestor_pids " in
      *" $pid "*) continue ;;
    esac
    case "$command_line" in
      *"$derived_path"/*|*"$derived_path "*|*"$derived_path"|\
      *"$runtime_home"/*|*"$runtime_home "*|*"$runtime_home") return 0 ;;
    esac
  done <<<"$process_inventory"
  return 1
}

# Build and test helper processes can take a few seconds to exit after their
# xcodebuild is stopped. Wait a bounded time before cleanup counts a process
# as left behind, which keeps the desktop reserved.
toastty_wait_run_paths_idle() {
  local derived_path="$1" runtime_home="$2" seconds="${3:-15}" waited=0
  while toastty_run_paths_have_live_process "$derived_path" "$runtime_home"; do
    if (( waited >= seconds * 2 )); then
      return 1
    fi
    sleep 0.5
    waited=$((waited + 1))
  done
  return 0
}

# Removes the build caches of one run on the host that holds it. Call it only
# for a run whose evidence was copied and verified, or that nobody copies.
# The run must have ended, and no process may refer to its DerivedData or
# runtime home. Everything else in the run folder stays.
toastty_remove_run_caches() {
  local run_root="$1" base path
  [[ "$run_root" == /* && -d "$run_root" && ! -L "$run_root" ]] || {
    printf 'error: not a run folder: %s\n' "$run_root" >&2
    return 1
  }
  if [[ -e "$run_root/detached.json" && ! -e "$run_root/detached-exit.json" ]]; then
    printf 'error: the run has not ended; its build caches stay: %s\n' "$run_root" >&2
    return 1
  fi
  for base in Derived run/Derived; do
    [[ -e "$run_root/$base" || -L "$run_root/$base" ]] || continue
    if [[ -L "$run_root/$base" || ! -d "$run_root/$base" || -L "$(dirname "$run_root/$base")" ]]; then
      printf 'error: unexpected DerivedData entry; its build caches stay: %s\n' "$run_root/$base" >&2
      return 1
    fi
    if ! toastty_wait_run_paths_idle "$run_root/$base" "$(dirname "$run_root/$base")/runtime-home" 15; then
      printf 'error: a process still refers to %s; its build caches stay\n' "$run_root/$base" >&2
      return 1
    fi
  done
  while IFS= read -r path; do
    # Only real folders: the evidence copy keeps any link at these paths.
    [[ -d "$run_root/$path" && ! -L "$run_root/$path" ]] || continue
    # Never follow a link out of the run folder.
    [[ ! -L "$(dirname "$run_root/$path")" ]] || return 1
    rm -rf -- "$run_root/$path" || return 1
  done < <(toastty_run_cache_paths)
}

# The run's options that keep its build caches, for cancel.sh. Printed as a
# remote command that runs after allocation.
toastty_emit_cache_policy() {
  printf 'printf %%s %q >"$REMOTE_RUN_ROOT/cache-policy.json"\n' \
    "$(jq -cn --argjson full "$FULL_ARTIFACTS" --argjson keep "$KEEP_REMOTE" \
      '{fullArtifacts: ($full == 1), keepRemote: ($keep == 1)}')"
}

# Sends toastty_remove_run_caches to the remote host for this wrapper's run.
toastty_remove_remote_run_caches() {
  log "Removing the remote run's build caches"
  if ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "$REMOTE_HOST" /bin/bash -l -s <<EOF
set -euo pipefail
$(declare -f toastty_run_cache_paths toastty_run_paths_have_live_process toastty_wait_run_paths_idle toastty_remove_run_caches)
toastty_remove_run_caches $(printf '%q' "$1")
EOF
  then
    TOASTTY_METADATA_REMOTE_CACHES_REMOVED=true
  else
    warn "Could not remove the remote run's build caches: $1"
    return 1
  fi
}

# Keep the selected source export unchanged. The current wrapper and its helpers
# are a separate controller, including when --scope ref selects older source.
toastty_stage_remote_controller() {
  (cd "$ROOT_DIR" && rsync -a --relative \
    -e 'ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3' \
    scripts/remote/ scripts/automation/runtime-ownership.sh \
    "$REMOTE_HOST:$1/controller/")
}

toastty_begin_run_metadata() {
  local kind="$1" platform="$2" selection="$3"
  local ref=HEAD dirty=false worktree_status controller_commit controller_dirty=false
  controller_commit="$(git -C "$ROOT_DIR" rev-parse --verify 'HEAD^{commit}')" || return 1
  worktree_status="$(git --no-optional-locks -C "$ROOT_DIR" status --porcelain --untracked-files=normal --ignore-submodules=none)" || return 1
  [[ -z "$worktree_status" ]] || controller_dirty=true
  [[ "$VALIDATION_SCOPE" != ref ]] || ref="${REF_SPEC:?--ref is required for ref scope}"
  TOASTTY_SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify "$ref^{commit}")" || return 1
  case "$VALIDATION_SCOPE" in
    working-tree)
      worktree_status="$(git --no-optional-locks -C "$ROOT_DIR" status --porcelain --untracked-files=normal --ignore-submodules=none)" || return 1
      [[ -z "$worktree_status" ]] || dirty=true
      ;;
    head|ref) ;;
    *) printf 'error: unsupported scope: %s\n' "$VALIDATION_SCOPE" >&2; return 1 ;;
  esac
  TOASTTY_RUN_METADATA="$(jq -cn \
    --arg kind "$kind" --arg platform "$platform" --arg selection "$selection" \
    --arg runLabel "$RUN_LABEL" --arg scope "$VALIDATION_SCOPE" \
    --arg commit "$TOASTTY_SOURCE_COMMIT" --argjson dirty "$dirty" \
    --arg controllerCommit "$controller_commit" --argjson controllerDirty "$controller_dirty" \
    --argjson fullArtifacts "$FULL_ARTIFACTS" '{
      schemaVersion: 1, runLabel: $runLabel, kind: $kind, platform: $platform,
      selection: $selection, requestedTarget: "remote", executionTarget: null,
      source: {commit: $commit, dirty: $dirty, scope: $scope,
        contentIdentity: (if $scope == "working-tree" then "mutable-working-tree" else "git-archive" end),
        ignoredDependenciesPinned: false},
      controller: {commit: $controllerCommit, dirty: $controllerDirty},
      artifactMode: (if $fullArtifacts == 1 then "full" else "evidence" end),
      wrapperRetryCount: 0, testAttemptCount: null, phaseSeconds: {}, timingResolutionSeconds: 1
    }')" || return 1
  TOASTTY_RUN_STARTED_SECONDS="$(date +%s)"
  TOASTTY_PHASE_STARTED_SECONDS="$TOASTTY_RUN_STARTED_SECONDS"
  TOASTTY_RUN_PHASE=setup
  trap 'rc=$?; toastty_finish_run_metadata "$rc" || { [[ "$rc" != 0 ]] || rc=1; }; exit "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

toastty_run_phase() {
  local now elapsed updated
  now="$(date +%s)"
  elapsed=$((now - TOASTTY_PHASE_STARTED_SECONDS))
  updated="$(jq -c --arg phase "$TOASTTY_RUN_PHASE" --argjson elapsed "$elapsed" \
    '.phaseSeconds[$phase] = ((.phaseSeconds[$phase] // 0) + $elapsed)' <<<"$TOASTTY_RUN_METADATA")" || return 1
  TOASTTY_RUN_METADATA="$updated"
  TOASTTY_RUN_PHASE="$1"
  TOASTTY_PHASE_STARTED_SECONDS="$now"
}

toastty_finish_run_metadata() {
  [[ -n "${TOASTTY_RUN_METADATA:-}" && "${TOASTTY_RUN_METADATA_WRITTEN:-0}" != 1 ]] || return 0
  local rc="$1" last_phase="$TOASTTY_RUN_PHASE" now result='{}'
  local invalid_result=0
  toastty_run_phase finished || return 1
  now="$(date +%s)"
  if [[ -f "$LOCAL_ARTIFACTS_DIR/result.json" ]]; then
    if ! result="$(jq -cs 'if length == 1 and (.[0] | type) == "object" then .[0] else error("Invalid result object") end' "$LOCAL_ARTIFACTS_DIR/result.json")"; then
      result='{}'
      invalid_result=1
      [[ "$rc" != 0 ]] || rc=1
    fi
  fi
  local temporary="$LOCAL_ARTIFACTS_DIR/run-metadata.json.tmp"
  if jq -n --argjson metadata "$TOASTTY_RUN_METADATA" --argjson result "$result" \
    --argjson exitCode "$rc" --arg lastPhase "$last_phase" \
    --argjson duration "$((now - TOASTTY_RUN_STARTED_SECONDS))" \
    --arg remoteRunRoot "${TOASTTY_METADATA_REMOTE_RUN_ROOT:-}" \
    --arg remoteWorktree "${TOASTTY_METADATA_REMOTE_WORKTREE:-}" \
    --argjson allocated "${TOASTTY_METADATA_REMOTE_ALLOCATED:-false}" \
    --argjson removed "${TOASTTY_METADATA_REMOTE_REMOVED:-false}" \
    --argjson cachesRemoved "${TOASTTY_METADATA_REMOTE_CACHES_REMOVED:-false}" '
      $metadata + {exitCode: $exitCode, lastPhase: $lastPhase, durationSeconds: $duration,
        status: (if $exitCode == 0 then ($result.status // "pass") else "fail" end),
        executionTarget: ($result.executionTarget // (if $remoteRunRoot != "" then "remote" else null end)),
        fallbackReason: ($result.fallbackReason // null),
        remoteRunRoot: (if $remoteRunRoot == "" then null else $remoteRunRoot end),
        remoteWorktree: (if $remoteWorktree == "" then null else $remoteWorktree end),
        remoteAllocationConfirmed: $allocated, remoteRemoved: $removed,
        remoteCachesRemoved: ($removed or $cachesRemoved)}
    ' >"$temporary" && mv "$temporary" "$LOCAL_ARTIFACTS_DIR/run-metadata.json"; then
    TOASTTY_RUN_METADATA_WRITTEN=1
  else
    rm -f "$temporary"
    return 1
  fi
  [[ "$invalid_result" == 0 ]]
}

# A remote run is detached from its SSH session, so it keeps going when the
# local wrapper stops (for example when Toastty quits). The same command run
# again from the same worktree reattaches to it instead of queueing a new run.
# The identity covers the worktree, the selected source content and every
# option that changes what the run checks. Ignored files are not part of it.
toastty_source_identity() {
  case "$VALIDATION_SCOPE" in
    head|ref)
      local ref=HEAD
      [[ "$VALIDATION_SCOPE" != ref ]] || ref="${REF_SPEC:?--ref is required for ref scope}"
      git -C "$ROOT_DIR" rev-parse --verify "$ref^{commit}"
      ;;
    working-tree)
      local index scratch tree status=0
      index="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-path index)" || return 1
      scratch="$(mktemp -d)" || return 1
      [[ ! -f "$index" ]] || cp "$index" "$scratch/index" || status=1
      if [[ "$status" == 0 ]] \
        && GIT_INDEX_FILE="$scratch/index" git -C "$ROOT_DIR" add -A -- . >/dev/null 2>&1 \
        && tree="$(GIT_INDEX_FILE="$scratch/index" git -C "$ROOT_DIR" write-tree)"; then
        printf '%s\n' "$tree"
      else
        status=1
      fi
      rm -rf "$scratch"
      return "$status"
      ;;
    *) return 1 ;;
  esac
}

toastty_request_key() {
  printf '%s\0' "$@" | shasum -a 256 | cut -c 1-64
}

toastty_process_start() {
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'
}

# Records that this wrapper owns the detached run, for a later reattach.
toastty_write_attach_record() {
  local dir="$1" key="$2" temporary="$1/attach.env.tmp"
  {
    printf 'requestKey=%s\n' "$key"
    printf 'ownerPid=%s\n' "$$"
    printf 'ownerStart=%s\n' "$(toastty_process_start "$$")"
  } >"$temporary" && mv "$temporary" "$dir/attach.env"
}

toastty_attach_value() {
  sed -n "s/^$2=//p" "$1/attach.env" | head -n 1
}

# Prints the label of the newest local run with this identity that has no
# result yet and whose wrapper has stopped. With an explicit label, only that
# run is a candidate.
toastty_find_reattachable_run() {
  local parent="$1" key="$2" explicit_label="$3" dir pid
  local candidates=()
  if [[ -n "$explicit_label" ]]; then
    candidates=("$parent/$explicit_label")
  elif [[ -d "$parent" ]]; then
    while IFS= read -r dir; do
      candidates+=("$parent/$dir")
    done < <(ls -t "$parent" 2>/dev/null)
  fi
  for dir in ${candidates[@]+"${candidates[@]}"}; do
    [[ -f "$dir/attach.env" && ! -L "$dir/attach.env" && ! -e "$dir/result.json" ]] || continue
    [[ "$(toastty_attach_value "$dir" requestKey)" == "$key" ]] || continue
    pid="$(toastty_attach_value "$dir" ownerPid)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$(toastty_process_start "$pid")" == "$(toastty_attach_value "$dir" ownerStart)" ]]; then
      continue
    fi
    basename "$dir"
    return 0
  done
  return 1
}

# Runs the probe or follow action of admission.py for one remote run. The
# local copy is sent over stdin, so a probe also works after the run folder,
# and the controller staged in it, were removed.
toastty_remote_detached() {
  local action="$1" run_root="$2"
  {
    printf '%s\n' 'set -euo pipefail' \
      'exec /usr/bin/python3 - "$1" --root "$(dirname "$(dirname "$2")")" --dir "$2" <<'"'"'TOASTTY_ADMISSION_PY'"'"
    cat "$ROOT_DIR/scripts/remote/admission.py"
    printf '%s\n' TOASTTY_ADMISSION_PY
  } | ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "$REMOTE_HOST" /bin/bash -l -s -- \
    "$action" "$run_root"
}

toastty_remote_run_reattachable() {
  local state
  state="$(toastty_remote_detached probe "$1" 2>/dev/null)" || return 1
  # A follower can still hold the lock for a few seconds after its wrapper was
  # killed; follow waits for it. A live local owner was already excluded.
  jq -e '.detached == true and .cancelled != true' <<<"$state" >/dev/null 2>&1
}

# Wraps a remote session script (printed by the function named in $1) so that
# it runs detached from SSH, then follows its output. The session gets the
# same arguments; $2 is always the remote run root.
toastty_emit_detached_launcher() {
  cat <<'EOF'
set -euo pipefail
remote_run_root="$2"
session_script="$remote_run_root/remote-session.sh"
(umask 077 && cat >"$session_script") <<'TOASTTY_REMOTE_SESSION'
EOF
  "$1"
  cat <<'EOF'
TOASTTY_REMOTE_SESSION
admission="$remote_run_root/controller/scripts/remote/admission.py"
gui_root="$(dirname "$(dirname "$remote_run_root")")"
/usr/bin/python3 "$admission" detach --root "$gui_root" --dir "$remote_run_root" -- /bin/bash "$session_script" "$@"
exec /usr/bin/python3 "$admission" follow --root "$gui_root" --dir "$remote_run_root"
EOF
}

# Succeeds when the wrapper must stop without a result: the detached run is
# still going (only the connection was lost) or its state cannot be read.
toastty_remote_run_continues() {
  local state
  state="$(toastty_remote_detached probe "$1" 2>/dev/null)" || return 0
  jq -e '.detached == true and .finished != true' <<<"$state" >/dev/null 2>&1
}

# Succeeds when the run folder is gone, as after a cancel before it started.
toastty_remote_run_removed() {
  local state
  state="$(toastty_remote_detached probe "$1" 2>/dev/null)" || return 1
  jq -e '.exists == false' <<<"$state" >/dev/null 2>&1
}

# Files that the wrapper stages as the remote controller. A rerun with other
# controller files is a different run.
toastty_controller_identity() {
  (cd "$ROOT_DIR" && find scripts/remote scripts/automation/runtime-ownership.sh -type f -print \
    | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done) | shasum -a 256 | cut -c 1-64
}

toastty_detached_run_notice() {
  printf '[remote] %s runs detached on the remote host. If this command stops early, run it again from this worktree to reattach, or stop the run with: scripts/remote/cancel.sh %s\n' "$1" "$1" >&2
}
