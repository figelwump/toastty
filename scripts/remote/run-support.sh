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

toastty_allocate_local_artifacts() {
  mkdir -p "$(dirname "$1")" || return 1
  mkdir "$1" || {
    printf 'error: artifact directory already exists or cannot be created: %s; choose a new run label\n' "$1" >&2
    return 1
  }
}

# This definition is sent over SSH: the remote source checkout may be older.
toastty_allocate_remote_run() {
  local repo="$1" worktree="$2" run_root="$3"
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null || return 1
  mkdir -p "$(dirname "$worktree")" "$(dirname "$run_root")" || return 1
  mkdir "$run_root" || {
    printf 'error: remote run already exists or cannot be created: %s; choose a new run label\n' "$run_root" >&2
    return 1
  }
  if ! mkdir "$worktree"; then
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
}

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

toastty_copy_run_artifacts() {
  local source="$1" destination="$2" full="$3"
  local filters=() root subtree
  if [[ "$full" != 1 ]]; then
    # Exclude heavy subtrees, not Derived itself: keep Logs and result bundles.
    for root in /Derived /run/Derived; do
      for subtree in Build/Intermediates.noindex Build/Products Index.noindex ModuleCache.noindex SourcePackages SDKStatCaches.noindex SDKExplicitPrecompiledModules CompilationCache.noindex; do
        filters+=(--exclude "$root/$subtree/")
      done
    done
  fi
  rsync -a ${filters[@]+"${filters[@]}"} \
    -e 'ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3' \
    "$source/" "$destination/"
}

toastty_begin_run_metadata() {
  local kind="$1" platform="$2" selection="$3"
  local ref=HEAD dirty=false worktree_status
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
    --argjson fullArtifacts "$FULL_ARTIFACTS" '{
      schemaVersion: 1, runLabel: $runLabel, kind: $kind, platform: $platform,
      selection: $selection, requestedTarget: "remote", executionTarget: null,
      source: {commit: $commit, dirty: $dirty, scope: $scope,
        contentIdentity: (if $scope == "working-tree" then "mutable-working-tree" else "git-archive" end),
        ignoredDependenciesPinned: false},
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
    --argjson removed "${TOASTTY_METADATA_REMOTE_REMOVED:-false}" '
      $metadata + {exitCode: $exitCode, lastPhase: $lastPhase, durationSeconds: $duration,
        status: (if $exitCode == 0 then ($result.status // "pass") else "fail" end),
        executionTarget: ($result.executionTarget // (if $remoteRunRoot != "" then "remote" else null end)),
        fallbackReason: ($result.fallbackReason // null),
        remoteRunRoot: (if $remoteRunRoot == "" then null else $remoteRunRoot end),
        remoteWorktree: (if $remoteWorktree == "" then null else $remoteWorktree end),
        remoteAllocationConfirmed: $allocated, remoteRemoved: $removed}
    ' >"$temporary" && mv "$temporary" "$LOCAL_ARTIFACTS_DIR/run-metadata.json"; then
    TOASTTY_RUN_METADATA_WRITTEN=1
  else
    rm -f "$temporary"
    return 1
  fi
  [[ "$invalid_result" == 0 ]]
}
