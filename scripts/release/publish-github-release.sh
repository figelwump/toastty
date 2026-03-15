#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_NAME="Toastty"
PUBLISH_MODE="draft"
DRY_RUN=0
CREATE_TAG=0
NOTES_FILE=""
REPO=""
TAG=""
TITLE=""
RELEASE_METADATA_PATH=""
RELEASE_LABEL=""
RELEASE_DIR=""
DMG_PATH=""
RELEASE_VERSION=""
RELEASE_BUILD_NUMBER=""
RELEASE_SOURCE_COMMIT=""
RELEASE_SOURCE_COMMIT_SHORT=""
RELEASE_SOURCE_DIRTY=""
RELEASE_NOTES_PATH=""
RELEASE_DMG_PATH=""

usage() {
  cat <<'EOF'
Create a GitHub Release for an existing Toastty DMG.

Default behavior is to create a draft release. Pass --publish to publish immediately.

Required environment:
  TOASTTY_VERSION
  TOASTTY_BUILD_NUMBER

Options:
  --publish          Publish immediately instead of creating a draft release
  --create-tag       Create and push the release tag from recorded release metadata
  --dry-run          Print the git/gh commands without creating a tag or release
  --notes-file <path>
                     Override the release notes file
                     (default: artifacts/release/<version>-<build>/release-notes.md)
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
    --create-tag
EOF
}

log() {
  printf '[publish-release] %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

print_command() {
  printf '%q ' "$@"
  printf '\n'
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

validate_version_string() {
  if [[ ! "$TOASTTY_VERSION" =~ ^[0-9A-Za-z.+-]+$ ]]; then
    fail "TOASTTY_VERSION may only contain letters, numbers, dots, plus signs, and hyphens"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --publish)
        PUBLISH_MODE="publish"
        shift
        ;;
      --create-tag)
        CREATE_TAG=1
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
  RELEASE_METADATA_PATH="$RELEASE_DIR/release-metadata.env"

  if [[ -z "$NOTES_FILE" ]]; then
    NOTES_FILE="$RELEASE_DIR/release-notes.md"
  fi
}

load_release_metadata() {
  [[ -f "$RELEASE_METADATA_PATH" ]] || fail "release metadata file not found: $RELEASE_METADATA_PATH"

  # shellcheck disable=SC1090
  source "$RELEASE_METADATA_PATH"

  RELEASE_VERSION="${RELEASE_VERSION:-}"
  RELEASE_BUILD_NUMBER="${RELEASE_BUILD_NUMBER:-}"
  RELEASE_SOURCE_COMMIT="${RELEASE_SOURCE_COMMIT:-}"
  RELEASE_SOURCE_COMMIT_SHORT="${RELEASE_SOURCE_COMMIT_SHORT:-}"
  RELEASE_SOURCE_DIRTY="${RELEASE_SOURCE_DIRTY:-}"
  RELEASE_NOTES_PATH="${RELEASE_NOTES_PATH:-}"
  RELEASE_DMG_PATH="${RELEASE_DMG_PATH:-}"
}

verify_inputs() {
  if [[ ! -f "$NOTES_FILE" ]]; then
    fail "release notes file not found: $NOTES_FILE (author it before publishing; see .agents/skills/toastty-release/SKILL.md for the default workflow)"
  fi

  if [[ ! -s "$NOTES_FILE" ]]; then
    fail "release notes file is empty: $NOTES_FILE (author it before publishing; see .agents/skills/toastty-release/SKILL.md for the default workflow)"
  fi

  [[ -s "$DMG_PATH" ]] || fail "release DMG not found or empty: $DMG_PATH"
  [[ "$RELEASE_VERSION" == "$TOASTTY_VERSION" ]] || fail "release metadata version mismatch: expected $TOASTTY_VERSION, got ${RELEASE_VERSION:-<unset>}"
  [[ "$RELEASE_BUILD_NUMBER" == "$TOASTTY_BUILD_NUMBER" ]] || fail "release metadata build number mismatch: expected $TOASTTY_BUILD_NUMBER, got ${RELEASE_BUILD_NUMBER:-<unset>}"
  [[ -n "$RELEASE_SOURCE_COMMIT" ]] || fail "release metadata is missing RELEASE_SOURCE_COMMIT"
  [[ "$RELEASE_SOURCE_DIRTY" == "0" ]] || fail "release metadata reports a non-clean source snapshot (RELEASE_SOURCE_DIRTY=$RELEASE_SOURCE_DIRTY)"
  [[ "$DMG_PATH" == "$RELEASE_DMG_PATH" ]] || fail "release metadata DMG path mismatch: expected $RELEASE_DMG_PATH, got $DMG_PATH"

  git -C "$ROOT_DIR" cat-file -e "${RELEASE_SOURCE_COMMIT}^{commit}" 2>/dev/null \
    || fail "recorded release commit is not available in the current checkout: $RELEASE_SOURCE_COMMIT"
}

local_tag_commit() {
  git -C "$ROOT_DIR" rev-list -n1 "$1" 2>/dev/null || true
}

remote_tag_commit() {
  local tag_name="$1"
  local ls_remote_output=""
  local peeled_commit=""
  local direct_commit=""

  ls_remote_output="$(git -C "$ROOT_DIR" ls-remote --tags origin "refs/tags/${tag_name}" "refs/tags/${tag_name}^{}" 2>/dev/null || true)"
  [[ -n "$ls_remote_output" ]] || return 0

  peeled_commit="$(printf '%s\n' "$ls_remote_output" | awk '$2 ~ /\^\{\}$/ { print $1; exit }')"
  direct_commit="$(printf '%s\n' "$ls_remote_output" | awk '$2 !~ /\^\{\}$/ { print $1; exit }')"

  if [[ -n "$peeled_commit" ]]; then
    printf '%s\n' "$peeled_commit"
    return 0
  fi

  printf '%s\n' "$direct_commit"
}

ensure_tag_matches_release_commit() {
  local expected_commit="$RELEASE_SOURCE_COMMIT"
  local local_commit=""
  local remote_commit=""

  local_commit="$(local_tag_commit "$TAG")"
  remote_commit="$(remote_tag_commit "$TAG")"

  if [[ "$CREATE_TAG" != "1" ]]; then
    [[ -n "$local_commit" ]] || fail "git tag does not exist locally: $TAG"
    [[ -n "$remote_commit" ]] || fail "git tag does not exist on origin: $TAG"
  fi

  if [[ -n "$local_commit" && "$local_commit" != "$expected_commit" ]]; then
    fail "local tag $TAG points to $local_commit but release metadata expects $expected_commit"
  fi

  if [[ -n "$remote_commit" && "$remote_commit" != "$expected_commit" ]]; then
    fail "remote tag $TAG points to $remote_commit but release metadata expects $expected_commit"
  fi
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

wait_for_github_tag_visibility() {
  local attempts=0

  while (( attempts < 10 )); do
    if gh api "repos/$REPO/git/ref/tags/$TAG" >/dev/null 2>&1; then
      return 0
    fi

    attempts=$((attempts + 1))
    sleep 1
  done

  fail "tag $TAG was pushed but did not become visible to GitHub in time"
}

create_tag_if_requested() {
  local local_commit=""
  local remote_commit=""
  local create_command=(git -C "$ROOT_DIR" tag -a "$TAG" "$RELEASE_SOURCE_COMMIT" -m "Release $TAG")
  local push_command=(git -C "$ROOT_DIR" push origin "refs/tags/$TAG")

  [[ "$CREATE_TAG" == "1" ]] || return 0

  local_commit="$(local_tag_commit "$TAG")"
  remote_commit="$(remote_tag_commit "$TAG")"

  if [[ -z "$local_commit" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '%s\n' "Dry run tag command:"
      print_command "${create_command[@]}"
    else
      log "Creating annotated tag $TAG at $RELEASE_SOURCE_COMMIT_SHORT"
      "${create_command[@]}"
    fi
  fi

  if [[ -z "$remote_commit" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '%s\n' "Dry run push command:"
      print_command "${push_command[@]}"
    else
      log "Pushing tag $TAG to origin"
      "${push_command[@]}"
      wait_for_github_tag_visibility
    fi
  fi
}

create_release() {
  local command=(
    gh release create "$TAG"
    "$DMG_PATH"
    --repo "$REPO"
    --title "$TITLE"
    --notes-file "$NOTES_FILE"
    --verify-tag
  )

  if [[ "$PUBLISH_MODE" == "draft" ]]; then
    command+=(--draft)
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s\n' "Dry run release command:"
    print_command "${command[@]}"
    return 0
  fi

  log "Creating ${PUBLISH_MODE} GitHub release for $TAG in $REPO"
  "${command[@]}"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

require_command git
require_command gh
require_env TOASTTY_VERSION
require_env TOASTTY_BUILD_NUMBER

parse_args "$@"
validate_build_number
validate_version_string
resolve_defaults
load_release_metadata
verify_inputs
ensure_tag_matches_release_commit

if [[ "$DRY_RUN" != "1" ]]; then
  ensure_gh_auth
  ensure_release_absent
fi

create_tag_if_requested
create_release
