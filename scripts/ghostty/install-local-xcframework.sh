#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_PATH="${GHOSTTY_XCFRAMEWORK_SOURCE:-}"
VARIANT="${GHOSTTY_XCFRAMEWORK_VARIANT:-debug}"
SOURCE_REPO=""
SOURCE_COMMIT="${GHOSTTY_COMMIT:-}"
SOURCE_COMMIT_SHORT=""
SOURCE_DIRTY="${GHOSTTY_SOURCE_DIRTY:-}"
BUILD_FLAGS="${GHOSTTY_BUILD_FLAGS:-}"
METADATA_PATH=""

log() {
  printf '[ghostty-install] %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

write_env_assignment() {
  local file_path="$1"
  local variable_name="$2"
  local value="$3"

  printf '%s=%q\n' "$variable_name" "$value" >>"$file_path"
}

canonicalize_directory_path() {
  local input_path="$1"
  local parent_dir=""
  local base_name=""

  parent_dir="$(cd "$(dirname "$input_path")" && pwd)"
  base_name="$(basename "$input_path")"
  printf '%s/%s\n' "$parent_dir" "$base_name"
}

resolve_source_repo() {
  if [[ -n "${GHOSTTY_SOURCE_REPO:-}" ]]; then
    SOURCE_REPO="${GHOSTTY_SOURCE_REPO}"
  else
    SOURCE_REPO="$(git -C "$SOURCE_PATH" rev-parse --show-toplevel 2>/dev/null || true)"
  fi
}

resolve_source_commit() {
  if [[ -z "$SOURCE_COMMIT" && -n "$SOURCE_REPO" ]]; then
    SOURCE_COMMIT="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
  fi

  if [[ -n "$SOURCE_COMMIT" ]]; then
    if [[ -n "$SOURCE_REPO" ]]; then
      SOURCE_COMMIT_SHORT="$(git -C "$SOURCE_REPO" rev-parse --short=12 "$SOURCE_COMMIT" 2>/dev/null || true)"
    fi

    if [[ -z "$SOURCE_COMMIT_SHORT" ]]; then
      SOURCE_COMMIT_SHORT="${SOURCE_COMMIT:0:12}"
    fi
  fi
}

resolve_source_dirty_flag() {
  if [[ -n "$SOURCE_DIRTY" ]]; then
    return
  fi

  if [[ -n "$SOURCE_REPO" ]]; then
    if [[ -n "$(git -C "$SOURCE_REPO" status --porcelain 2>/dev/null)" ]]; then
      SOURCE_DIRTY="1"
    else
      SOURCE_DIRTY="0"
    fi
    return
  fi

  SOURCE_DIRTY="unknown"
}

write_metadata() {
  : >"$METADATA_PATH"
  write_env_assignment "$METADATA_PATH" "GHOSTTY_XCFRAMEWORK_VARIANT" "$VARIANT"
  write_env_assignment "$METADATA_PATH" "GHOSTTY_SOURCE_PATH" "$SOURCE_PATH"
  write_env_assignment "$METADATA_PATH" "GHOSTTY_SOURCE_REPO" "$SOURCE_REPO"
  write_env_assignment "$METADATA_PATH" "GHOSTTY_COMMIT" "$SOURCE_COMMIT"
  write_env_assignment "$METADATA_PATH" "GHOSTTY_COMMIT_SHORT" "$SOURCE_COMMIT_SHORT"
  write_env_assignment "$METADATA_PATH" "GHOSTTY_SOURCE_DIRTY" "$SOURCE_DIRTY"
  write_env_assignment "$METADATA_PATH" "GHOSTTY_BUILD_FLAGS" "$BUILD_FLAGS"
  write_env_assignment "$METADATA_PATH" "GHOSTTY_INSTALLED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

report_metadata_status() {
  local has_missing_metadata=0

  if [[ -z "$SOURCE_COMMIT" ]]; then
    warn "Ghostty commit metadata is missing. Set GHOSTTY_COMMIT or install from a Ghostty git checkout."
    has_missing_metadata=1
  fi

  if [[ -z "$BUILD_FLAGS" ]]; then
    warn "Ghostty build flags metadata is missing. Set GHOSTTY_BUILD_FLAGS when installing the artifact."
    has_missing_metadata=1
  fi

  if [[ "$SOURCE_DIRTY" != "0" ]]; then
    warn "Ghostty source cleanliness is recorded as '$SOURCE_DIRTY'. Release builds require a clean Ghostty source snapshot."
    has_missing_metadata=1
  fi

  if [[ "$has_missing_metadata" == "1" && "$VARIANT" == "release" ]]; then
    warn "Release DMG builds will fail until Ghostty release metadata is complete."
  fi
}

if [[ -z "$SOURCE_PATH" ]]; then
  for candidate in \
    "$ROOT_DIR/../ghostty/macos/GhosttyKit.xcframework" \
    "$ROOT_DIR/GhosttyKit.xcframework"; do
    if [[ -d "$candidate" ]]; then
      SOURCE_PATH="$candidate"
      break
    fi
  done
fi

case "$VARIANT" in
  debug)
    DEST_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Debug.xcframework"
    ;;
  release)
    DEST_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Release.xcframework"
    ;;
  *)
    echo "Invalid GHOSTTY_XCFRAMEWORK_VARIANT: $VARIANT" >&2
    echo "Expected one of: debug, release" >&2
    exit 1
    ;;
esac

if [[ ! -d "$SOURCE_PATH" ]]; then
  fail "Ghostty xcframework not found at: ${SOURCE_PATH:-<unset>}"
fi

SOURCE_PATH="$(canonicalize_directory_path "$SOURCE_PATH")"
DEST_PATH="$(canonicalize_directory_path "$DEST_PATH")"
METADATA_PATH="${DEST_PATH%.xcframework}.metadata.env"

mkdir -p "$(dirname "$DEST_PATH")"
rm -rf "$DEST_PATH"
cp -R "$SOURCE_PATH" "$DEST_PATH"

resolve_source_repo
resolve_source_commit
resolve_source_dirty_flag
write_metadata

log "Installed GhosttyKit.xcframework to: $DEST_PATH"
log "Wrote Ghostty metadata sidecar to: $METADATA_PATH"
log "This variant is selected by build-configuration manifest settings when present."
log "Run ./scripts/automation/check.sh to regenerate and validate with Ghostty enabled."

report_metadata_status
