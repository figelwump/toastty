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
RELEASE_SPARKLE_METADATA_PATH=""
SPARKLE_METADATA_PATH=""
SPARKLE_FEED_REPO=""
SPARKLE_FEED_BRANCH="main"
SPARKLE_FEED_URL=""
SPARKLE_PUBLIC_ED_KEY=""
SPARKLE_MINIMUM_SYSTEM_VERSION=""
SPARKLE_DMG_PATH=""
SPARKLE_DMG_FILENAME=""
SPARKLE_ENCLOSURE_LENGTH=""
SPARKLE_ED_SIGNATURE=""
APPCAST_CONTENT_SHA=""

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

detect_default_sparkle_feed_repo() {
  local repo_owner="${REPO%%/*}"
  [[ "$repo_owner" != "$REPO" ]] || return 1
  printf '%s/toastty-updates\n' "$repo_owner"
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
  SPARKLE_METADATA_PATH="$RELEASE_DIR/sparkle-metadata.env"

  if [[ -z "$NOTES_FILE" ]]; then
    NOTES_FILE="$RELEASE_DIR/release-notes.md"
  fi

  if [[ -z "$SPARKLE_FEED_REPO" ]]; then
    SPARKLE_FEED_REPO="$(detect_default_sparkle_feed_repo || true)"
    [[ -n "$SPARKLE_FEED_REPO" ]] || fail "could not determine Sparkle feed repository from $REPO"
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
  RELEASE_SPARKLE_METADATA_PATH="${RELEASE_SPARKLE_METADATA_PATH:-}"
}

load_sparkle_metadata() {
  local resolved_metadata_path="$SPARKLE_METADATA_PATH"

  if [[ -n "$RELEASE_SPARKLE_METADATA_PATH" ]]; then
    resolved_metadata_path="$RELEASE_SPARKLE_METADATA_PATH"
  fi

  [[ -f "$resolved_metadata_path" ]] || fail "Sparkle metadata file not found: $resolved_metadata_path"
  SPARKLE_METADATA_PATH="$resolved_metadata_path"

  # shellcheck disable=SC1090
  source "$SPARKLE_METADATA_PATH"

  SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
  SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
  SPARKLE_MINIMUM_SYSTEM_VERSION="${SPARKLE_MINIMUM_SYSTEM_VERSION:-}"
  SPARKLE_DMG_PATH="${SPARKLE_DMG_PATH:-}"
  SPARKLE_DMG_FILENAME="${SPARKLE_DMG_FILENAME:-}"
  SPARKLE_ENCLOSURE_LENGTH="${SPARKLE_ENCLOSURE_LENGTH:-}"
  SPARKLE_ED_SIGNATURE="${SPARKLE_ED_SIGNATURE:-}"
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
  [[ -n "$SPARKLE_FEED_URL" ]] || fail "Sparkle metadata is missing SPARKLE_FEED_URL"
  [[ "$SPARKLE_FEED_URL" == */appcast.xml ]] || fail "Sparkle feed URL must point to appcast.xml: $SPARKLE_FEED_URL"
  [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] || fail "Sparkle metadata is missing SPARKLE_PUBLIC_ED_KEY"
  [[ -n "$SPARKLE_MINIMUM_SYSTEM_VERSION" ]] || fail "Sparkle metadata is missing SPARKLE_MINIMUM_SYSTEM_VERSION"
  [[ -n "$SPARKLE_DMG_PATH" ]] || fail "Sparkle metadata is missing SPARKLE_DMG_PATH"
  [[ -n "$SPARKLE_DMG_FILENAME" ]] || fail "Sparkle metadata is missing SPARKLE_DMG_FILENAME"
  [[ -n "$SPARKLE_ENCLOSURE_LENGTH" ]] || fail "Sparkle metadata is missing SPARKLE_ENCLOSURE_LENGTH"
  [[ -n "$SPARKLE_ED_SIGNATURE" ]] || fail "Sparkle metadata is missing SPARKLE_ED_SIGNATURE"
  [[ "$SPARKLE_DMG_PATH" == "$DMG_PATH" ]] || fail "Sparkle metadata DMG path mismatch: expected $DMG_PATH, got $SPARKLE_DMG_PATH"
  [[ "$SPARKLE_DMG_FILENAME" == "$(basename "$DMG_PATH")" ]] || fail "Sparkle metadata DMG filename mismatch: expected $(basename "$DMG_PATH"), got $SPARKLE_DMG_FILENAME"
  [[ "$SPARKLE_ENCLOSURE_LENGTH" =~ ^[0-9]+$ ]] || fail "Sparkle enclosure length is not a positive integer: $SPARKLE_ENCLOSURE_LENGTH"
  [[ "$SPARKLE_ED_SIGNATURE" =~ ^[A-Za-z0-9+/=]+$ ]] || fail "Sparkle signature is empty or malformed"

  git -C "$ROOT_DIR" cat-file -e "${RELEASE_SOURCE_COMMIT}^{commit}" 2>/dev/null \
    || fail "recorded release commit is not available in the current checkout: $RELEASE_SOURCE_COMMIT"
}

validate_appcast_file() {
  local appcast_path="$1"

  /usr/bin/python3 - "$appcast_path" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET

appcast_path = pathlib.Path(sys.argv[1])
ET.parse(appcast_path)
PY
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

fetch_existing_appcast() {
  local output_path="$1"
  local appcast_payload=""

  appcast_payload="$(gh api "repos/$SPARKLE_FEED_REPO/contents/appcast.xml?ref=$SPARKLE_FEED_BRANCH" 2>/dev/null || true)"
  if [[ -n "$appcast_payload" ]]; then
    APPCAST_CONTENT_SHA="$(printf '%s' "$appcast_payload" | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["sha"])')"
    printf '%s' "$appcast_payload" \
      | /usr/bin/python3 - "$output_path" <<'PY'
import base64
import json
import sys

payload = json.load(sys.stdin)

with open(sys.argv[1], "wb") as appcast_file:
    appcast_file.write(base64.b64decode(payload["content"]))
PY
    return 0
  fi

  APPCAST_CONTENT_SHA=""
  cat >"$output_path" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss
    version="2.0"
    xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Toastty Updates</title>
        <link>${SPARKLE_FEED_URL}</link>
        <description>Toastty Sparkle update feed.</description>
        <language>en</language>
    </channel>
</rss>
EOF
}

generate_updated_appcast() {
  local current_appcast_path="$1"
  local updated_appcast_path="$2"
  local release_page_url="$3"
  local download_url="$4"
  local published_at="$5"

  /usr/bin/python3 - "$current_appcast_path" "$updated_appcast_path" "$TOASTTY_VERSION" "$TOASTTY_BUILD_NUMBER" "$download_url" "$SPARKLE_ED_SIGNATURE" "$SPARKLE_ENCLOSURE_LENGTH" "$SPARKLE_MINIMUM_SYSTEM_VERSION" "$SPARKLE_FEED_URL" "$release_page_url" "$published_at" <<'PY'
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)

(
    current_path,
    output_path,
    short_version,
    build_number,
    download_url,
    signature,
    length,
    minimum_system_version,
    feed_url,
    release_url,
    published_at,
) = sys.argv[1:]

tree = ET.parse(current_path)
root = tree.getroot()
channel = root.find("channel")
if channel is None:
    channel = ET.SubElement(root, "channel")

def ensure_text_element(parent, tag, text):
    element = parent.find(tag)
    if element is None:
        element = ET.SubElement(parent, tag)
    element.text = text
    return element

ensure_text_element(channel, "title", "Toastty Updates")
ensure_text_element(channel, "link", feed_url)
ensure_text_element(channel, "description", "Toastty Sparkle update feed.")
ensure_text_element(channel, "language", "en")

def build_number_for_item(item):
    enclosure = item.find("enclosure")
    if enclosure is None:
        return -1
    value = enclosure.get(f"{{{SPARKLE_NS}}}version", "-1")
    try:
        return int(value)
    except ValueError:
        return -1

existing_items = [child for child in list(channel) if child.tag == "item"]
for child in existing_items:
    channel.remove(child)

filtered_items = [item for item in existing_items if build_number_for_item(item) != int(build_number)]

new_item = ET.Element("item")
ET.SubElement(new_item, "title").text = f"Version {short_version}"
ET.SubElement(new_item, "pubDate").text = published_at
ET.SubElement(new_item, "link").text = release_url
ET.SubElement(new_item, "description").text = f"Toastty {short_version} is available."
ET.SubElement(
    new_item,
    "enclosure",
    {
        "url": download_url,
        "length": length,
        "type": "application/x-apple-diskimage",
        f"{{{SPARKLE_NS}}}version": build_number,
        f"{{{SPARKLE_NS}}}shortVersionString": short_version,
        f"{{{SPARKLE_NS}}}minimumSystemVersion": minimum_system_version,
        f"{{{SPARKLE_NS}}}edSignature": signature,
    },
)

items = filtered_items + [new_item]
items.sort(key=build_number_for_item, reverse=True)

for item in items:
    channel.append(item)

ET.indent(tree, space="    ")
tree.write(output_path, encoding="utf-8", xml_declaration=True)
PY
}

publish_sparkle_appcast() {
  local release_page_url="https://github.com/$REPO/releases/tag/$TAG"
  local download_url="https://github.com/$REPO/releases/download/$TAG/$SPARKLE_DMG_FILENAME"

  if [[ "$PUBLISH_MODE" != "publish" ]]; then
    log "Skipping Sparkle appcast publication for draft GitHub release"
    return 0
  fi

  (
    current_appcast_path="$(mktemp /tmp/toastty-appcast-current.XXXXXX.xml)"
    updated_appcast_path="$(mktemp /tmp/toastty-appcast-updated.XXXXXX.xml)"
    trap 'rm -f "$current_appcast_path" "$updated_appcast_path"' EXIT

    fetch_existing_appcast "$current_appcast_path"
    published_at="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    generate_updated_appcast "$current_appcast_path" "$updated_appcast_path" "$release_page_url" "$download_url" "$published_at"
    validate_appcast_file "$updated_appcast_path"

    if [[ "$DRY_RUN" == "1" ]]; then
      printf '%s\n' "Dry run appcast update:"
      printf '  feed repo: %s\n' "$SPARKLE_FEED_REPO"
      printf '  feed URL: %s\n' "$SPARKLE_FEED_URL"
      printf '  release URL: %s\n' "$release_page_url"
      printf '  download URL: %s\n' "$download_url"
      return 0
    fi

    encoded_content="$(base64 <"$updated_appcast_path" | tr -d '\n')"
    if [[ -n "$APPCAST_CONTENT_SHA" ]]; then
      gh api -X PUT "repos/$SPARKLE_FEED_REPO/contents/appcast.xml" \
        -f message="Update Toastty appcast for $TAG" \
        -f content="$encoded_content" \
        -f sha="$APPCAST_CONTENT_SHA" \
        -f branch="$SPARKLE_FEED_BRANCH" >/dev/null
    else
      gh api -X PUT "repos/$SPARKLE_FEED_REPO/contents/appcast.xml" \
        -f message="Create Toastty appcast for $TAG" \
        -f content="$encoded_content" \
        -f branch="$SPARKLE_FEED_BRANCH" >/dev/null
    fi

    log "Published Sparkle appcast to $SPARKLE_FEED_URL via $SPARKLE_FEED_REPO"
  )
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

require_command git
require_command gh
require_command base64
require_env TOASTTY_VERSION
require_env TOASTTY_BUILD_NUMBER

parse_args "$@"
validate_build_number
validate_version_string
resolve_defaults
load_release_metadata
load_sparkle_metadata
verify_inputs
ensure_tag_matches_release_commit

if [[ "$DRY_RUN" != "1" ]]; then
  ensure_gh_auth
  ensure_release_absent
fi

create_tag_if_requested
create_release
publish_sparkle_appcast
