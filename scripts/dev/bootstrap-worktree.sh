#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SOURCE_WORKTREE_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: ./scripts/dev/bootstrap-worktree.sh [--source-worktree /path/to/source-worktree]

Bootstraps the current Toastty worktree for local development:
- reuses installed Ghostty xcframeworks from another worktree when needed
- creates symlinks back to the source worktree's Ghostty artifacts
- keeps worktree-local Dependencies/ entries ignored by Git
- runs `tuist install` and `tuist generate --no-open`

When Ghostty integration is disabled via TUIST_DISABLE_GHOSTTY=1 or
TOASTTY_DISABLE_GHOSTTY=1, the script still regenerates the workspace and only
warns if no Ghostty artifact source can be found.
EOF
}

log() {
  printf '[bootstrap-worktree] %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

canonicalize_directory_path() {
  local input_path="$1"

  if [[ ! -d "$input_path" ]]; then
    fail "Directory does not exist: $input_path"
  fi

  (cd "$input_path" && pwd -P)
}

run_tuist() {
  if command -v sv >/dev/null 2>&1; then
    sv exec -- tuist "$@"
  else
    tuist "$@"
  fi
}

debug_xcframework_path() {
  printf '%s/Dependencies/GhosttyKit.Debug.xcframework' "$1"
}

release_xcframework_path() {
  printf '%s/Dependencies/GhosttyKit.Release.xcframework' "$1"
}

debug_metadata_path() {
  printf '%s/Dependencies/GhosttyKit.Debug.metadata.env' "$1"
}

release_metadata_path() {
  printf '%s/Dependencies/GhosttyKit.Release.metadata.env' "$1"
}

is_valid_xcframework() {
  local path="$1"
  [[ -f "$path/Info.plist" ]]
}

is_valid_metadata_file() {
  local path="$1"
  [[ -f "$path" ]]
}

prune_broken_artifact_link() {
  local path="$1"

  if [[ -L "$path" && ! -e "$path" ]]; then
    rm -f "$path"
    log "Removed broken Ghostty link: $path"
  fi
}

worktree_has_local_xcframework() {
  local root="$1"

  is_valid_xcframework "$(debug_xcframework_path "$root")" \
    || is_valid_xcframework "$(release_xcframework_path "$root")"
}

is_toastty_worktree_root() {
  local root="$1"
  [[ -f "$root/Project.swift" ]]
}

list_worktree_paths() {
  if ! git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 1
  fi

  git -C "$ROOT_DIR" worktree list --porcelain | while IFS= read -r line; do
    if [[ "$line" == worktree\ * ]]; then
      printf '%s\n' "${line#worktree }"
    fi
  done
}

select_source_worktree() {
  local current_root="$1"
  local preferred_candidate=""
  local fallback_candidate=""
  local candidate=""

  if [[ -n "$SOURCE_WORKTREE_OVERRIDE" ]]; then
    candidate="$(canonicalize_directory_path "$SOURCE_WORKTREE_OVERRIDE")"
    if [[ "$candidate" == "$current_root" ]]; then
      fail "--source-worktree must point to a different worktree than the current one"
    fi
    if ! is_toastty_worktree_root "$candidate"; then
      fail "Source worktree does not look like a Toastty checkout: $candidate"
    fi
    if ! worktree_has_local_xcframework "$candidate"; then
      fail "No Ghostty xcframework found in source worktree: $candidate"
    fi
    printf '%s\n' "$candidate"
    return 0
  fi

  while IFS= read -r candidate; do
    if [[ ! -d "$candidate" ]]; then
      continue
    fi
    candidate="$(canonicalize_directory_path "$candidate")"
    if [[ "$candidate" == "$current_root" ]]; then
      continue
    fi
    if ! is_toastty_worktree_root "$candidate"; then
      continue
    fi
    if ! worktree_has_local_xcframework "$candidate"; then
      continue
    fi
    if [[ -d "$candidate/.git" ]]; then
      preferred_candidate="$candidate"
      break
    fi
    if [[ -z "$fallback_candidate" ]]; then
      fallback_candidate="$candidate"
    fi
  done < <(list_worktree_paths)

  if [[ -n "$preferred_candidate" ]]; then
    printf '%s\n' "$preferred_candidate"
    return 0
  fi
  if [[ -n "$fallback_candidate" ]]; then
    printf '%s\n' "$fallback_candidate"
    return 0
  fi

  return 1
}

link_artifact_if_available() {
  local source_path="$1"
  local destination_path="$2"
  local artifact_kind="$3"

  if [[ "$artifact_kind" == "xcframework" ]]; then
    if is_valid_xcframework "$destination_path"; then
      return 0
    fi
    if ! is_valid_xcframework "$source_path"; then
      return 1
    fi
  else
    if is_valid_metadata_file "$destination_path"; then
      return 0
    fi
    if ! is_valid_metadata_file "$source_path"; then
      return 1
    fi
  fi

  if [[ -e "$destination_path" || -L "$destination_path" ]]; then
    fail "Refusing to overwrite unexpected existing path: $destination_path"
  fi

  mkdir -p "$(dirname "$destination_path")"
  ln -s "$source_path" "$destination_path"
  log "Linked $(basename "$destination_path") -> $source_path"
}

bootstrap_ghostty_artifacts_if_needed() {
  local current_root="$1"
  local source_root=""

  prune_broken_artifact_link "$(debug_xcframework_path "$current_root")"
  prune_broken_artifact_link "$(release_xcframework_path "$current_root")"
  prune_broken_artifact_link "$(debug_metadata_path "$current_root")"
  prune_broken_artifact_link "$(release_metadata_path "$current_root")"

  if worktree_has_local_xcframework "$current_root"; then
    log "Using existing local Ghostty artifact(s) in this worktree."
    return 0
  fi

  if ! source_root="$(select_source_worktree "$current_root")"; then
    warn "No Toastty source worktree with local Ghostty artifacts found. Continuing without local Ghostty artifacts."
    return 0
  fi

  log "Bootstrapping Ghostty artifacts from: $source_root"
  link_artifact_if_available "$(debug_xcframework_path "$source_root")" "$(debug_xcframework_path "$current_root")" "xcframework" || true
  link_artifact_if_available "$(release_xcframework_path "$source_root")" "$(release_xcframework_path "$current_root")" "xcframework" || true
  link_artifact_if_available "$(debug_metadata_path "$source_root")" "$(debug_metadata_path "$current_root")" "metadata" || true
  link_artifact_if_available "$(release_metadata_path "$source_root")" "$(release_metadata_path "$current_root")" "metadata" || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-worktree)
      if [[ $# -lt 2 ]]; then
        fail "--source-worktree requires a path argument"
      fi
      SOURCE_WORKTREE_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

bootstrap_ghostty_artifacts_if_needed "$ROOT_DIR"

log "Running tuist install"
run_tuist install >/dev/null
log "Running tuist generate --no-open"
run_tuist generate --no-open >/dev/null
log "Worktree bootstrap complete."
