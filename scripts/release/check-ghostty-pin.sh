#!/usr/bin/env bash
# Stops a release whose installed Ghostty artifact is not the Ghostty commit
# that this checkout documents.
#
# The pin is the one `git -C ../ghostty checkout <commit>` line in
# docs/ghostty-integration.md, the command a person runs to build the artifact.
# The installed commit is GHOSTTY_COMMIT in the release artifact's metadata,
# written by scripts/ghostty/install-local-xcframework.sh.
#
# Usage: scripts/release/check-ghostty-pin.sh [<installed-commit>]
#   With no argument, reads Dependencies/GhosttyKit.Release.metadata.env.
#   TOASTTY_GHOSTTY_PIN_DOC overrides the document path (for tests).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN_DOC="${TOASTTY_GHOSTTY_PIN_DOC:-$ROOT_DIR/docs/ghostty-integration.md}"
METADATA_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Release.metadata.env"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $# -le 1 ]] || fail "usage: scripts/release/check-ghostty-pin.sh [<installed-commit>]"

if [[ $# -eq 1 ]]; then
  installed_commit="$1"
else
  [[ -f "$METADATA_PATH" ]] || fail "Ghostty release metadata not found at $METADATA_PATH; install the release artifact with ./scripts/ghostty/install-local-xcframework.sh"
  installed_commit="$(
    # shellcheck disable=SC1090
    source "$METADATA_PATH"
    printf '%s' "${GHOSTTY_COMMIT:-}"
  )"
fi
[[ -n "$installed_commit" ]] || fail "the installed Ghostty commit is unknown; reinstall the release artifact from a Ghostty checkout"

[[ -f "$PIN_DOC" ]] || fail "Ghostty pin document not found: $PIN_DOC"
pins="$(
  grep -E '^git -C \.\./ghostty checkout [0-9a-f]{40}[[:space:]]*$' "$PIN_DOC" \
    | awk '{ print $5 }' | sort -u || true
)"
pin_count="$(printf '%s' "$pins" | grep -c . || true)"
[[ "$pin_count" == "1" ]] \
  || fail "expected one 'git -C ../ghostty checkout <40-character commit>' line in $PIN_DOC, found $pin_count distinct commits"

installed_lower="$(printf '%s' "$installed_commit" | tr '[:upper:]' '[:lower:]')"
if [[ "$installed_lower" != "$pins" ]]; then
  fail "the installed Ghostty artifact is from $installed_commit, but $PIN_DOC pins $pins. Build Ghostty at the pinned commit and reinstall the release artifact, or update the pin in a reviewed change first."
fi

printf 'Ghostty artifact matches the documented pin: %s\n' "$pins"
