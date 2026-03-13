#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_NAME="Toastty"
PUBLISH_MODE="draft"
DRY_RUN=0
NOTES_FILE=""
REPO=""
TAG=""
TITLE=""

usage() {
  cat <<'EOF'
Create a GitHub Release for an existing Toastty DMG.

Default behavior is to create a draft release. Pass --publish to publish immediately.

Required environment:
  TOASTTY_VERSION
  TOASTTY_BUILD_NUMBER

Required options:
  --notes-file <path>

Options:
  --publish          Publish immediately instead of creating a draft release
  --dry-run          Print the gh command without creating a release
  --repo <owner/repo>
                     Override the target GitHub repository (required if origin is not a GitHub remote)
  --tag <tag>        Override the release tag (default: v$TOASTTY_VERSION)
  --title <title>    Override the release title (default: v$TOASTTY_VERSION)
  -h, --help         Show this help text

Recommended invocation:
  sv exec -- env \
    TOASTTY_VERSION=0.1.0 \
    TOASTTY_BUILD_NUMBER=1 \
    ./scripts/release/publish-github-release.sh \
    --notes-file /path/to/release-notes.md
EOF
}

log() {
  printf '[publish-release] %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "required command not found: $command_name"
  fi
}

require_env() {
  local variable_name="$1"
  if [[ -z "${!variable_name:-}" ]]; then
    fail "required environment variable is unset: $variable_name"
  fi
}

validate_build_number() {
  if [[ ! "$TOASTTY_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    fail "TOASTTY_BUILD_NUMBER must be a monotonically increasing integer"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --publish)
        PUBLISH_MODE="publish"
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --notes-file)
        [[ $# -ge 2 ]] || fail "missing value for --notes-file"
        NOTES_FILE="$2"
        shift 2
        ;;
      --repo)
        [[ $# -ge 2 ]] || fail "missing value for --repo"
        REPO="$2"
        shift 2
        ;;
      --tag)
        [[ $# -ge 2 ]] || fail "missing value for --tag"
        TAG="$2"
        shift 2
        ;;
      --title)
        [[ $# -ge 2 ]] || fail "missing value for --title"
        TITLE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
}

detect_default_repo() {
  local remote_url=""
  local parsed_repo=""

  remote_url="$(git -C "$ROOT_DIR" config --get remote.origin.url || true)"
  case "$remote_url" in
    https://github.com/*/*)
      parsed_repo="${remote_url#https://github.com/}"
      parsed_repo="${parsed_repo%.git}"
      ;;
    git@github.com:*/*)
      parsed_repo="${remote_url#git@github.com:}"
      parsed_repo="${parsed_repo%.git}"
      ;;
  esac

  printf '%s\n' "$parsed_repo"
}

resolve_defaults() {
  if [[ -z "$REPO" ]]; then
    REPO="$(detect_default_repo)"
    [[ -n "$REPO" ]] || fail "could not determine GitHub repository from origin; pass --repo <owner/repo>"
  fi

  if [[ -z "$TAG" ]]; then
    TAG="v${TOASTTY_VERSION}"
  fi

  if [[ -z "$TITLE" ]]; then
    TITLE="v${TOASTTY_VERSION}"
  fi

  RELEASE_LABEL="${TOASTTY_VERSION}-${TOASTTY_BUILD_NUMBER}"
  RELEASE_DIR="$ROOT_DIR/artifacts/release/$RELEASE_LABEL"
  DMG_PATH="$RELEASE_DIR/${APP_NAME}-${TOASTTY_VERSION}.dmg"
}

verify_inputs() {
  [[ -n "$NOTES_FILE" ]] || fail "--notes-file is required"
  [[ -f "$NOTES_FILE" ]] || fail "release notes file not found: $NOTES_FILE"
  [[ -s "$DMG_PATH" ]] || fail "release DMG not found or empty: $DMG_PATH"

  git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    || fail "git tag does not exist locally: $TAG"

  git -C "$ROOT_DIR" ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 \
    || fail "git tag does not exist on origin: $TAG"
}

ensure_gh_auth() {
  gh auth status >/dev/null 2>&1 \
    || fail "gh is not authenticated; run 'gh auth login' or provide GitHub credentials via sv exec"
}

ensure_release_absent() {
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    fail "a GitHub release already exists for $TAG in $REPO"
  fi
}

create_release() {
  local asset_arg="$DMG_PATH"
  local command=(
    gh release create "$TAG"
    "$asset_arg"
    --repo "$REPO"
    --title "$TITLE"
    --notes-file "$NOTES_FILE"
    --verify-tag
  )

  if [[ "$PUBLISH_MODE" == "draft" ]]; then
    command+=(--draft)
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s\n' "Dry run command:"
    printf '%q ' "${command[@]}"
    printf '\n'
    return 0
  fi

  log "Creating ${PUBLISH_MODE} GitHub release for $TAG in $REPO"
  "${command[@]}"
}

require_command git
require_command gh
require_env TOASTTY_VERSION
require_env TOASTTY_BUILD_NUMBER

parse_args "$@"
validate_build_number
resolve_defaults
verify_inputs

if [[ "$DRY_RUN" != "1" ]]; then
  ensure_gh_auth
  ensure_release_absent
fi

create_release
