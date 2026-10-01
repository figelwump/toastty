#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: publish-scratchpad-html.sh [--title <title>] [--purpose <purpose>] [--file <html-file>] [--expected-revision <revision>] [--document-id <id> | --additional | --new]

Publishes a complete HTML document to the current Toastty Scratchpad session.
Reads HTML from stdin unless --file is provided.
EOF
}

title="Scratchpad"
title_set=0
file_path=""
expected_revision=""
create_policy=""
document_id=""
purpose=""
purpose_set=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: --title requires a value" >&2
        exit 64
      fi
      title="$2"
      title_set=1
      shift 2
      ;;
    --file)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: --file requires a value" >&2
        exit 64
      fi
      file_path="$2"
      shift 2
      ;;
    --purpose)
      if [[ $# -lt 2 ]]; then
        echo "error: --purpose requires a value" >&2
        exit 64
      fi
      purpose="$2"
      purpose_set=1
      shift 2
      ;;
    --document-id)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: --document-id requires a value" >&2
        exit 64
      fi
      document_id="$2"
      shift 2
      ;;
    --expected-revision)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: --expected-revision requires a value" >&2
        exit 64
      fi
      expected_revision="$2"
      shift 2
      ;;
    --new)
      if [[ "$create_policy" == "additional" ]]; then
        echo "error: --new and --additional are mutually exclusive" >&2
        exit 64
      fi
      create_policy="new"
      shift
      ;;
    --additional)
      if [[ "$create_policy" == "new" ]]; then
        echo "error: --new and --additional are mutually exclusive" >&2
        exit 64
      fi
      create_policy="additional"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if [[ -n "$document_id" && -n "$create_policy" ]]; then
  echo "error: --document-id cannot be combined with --new or --additional" >&2
  exit 64
fi

if [[ -z "${TOASTTY_CLI_PATH:-}" ]]; then
  echo "error: TOASTTY_CLI_PATH is required; run this from a Toastty-managed agent session" >&2
  exit 1
fi
if [[ ! -x "${TOASTTY_CLI_PATH}" ]]; then
  echo "error: TOASTTY_CLI_PATH is not executable: ${TOASTTY_CLI_PATH}" >&2
  exit 1
fi
if [[ -z "${TOASTTY_SESSION_ID:-}" ]]; then
  echo "error: TOASTTY_SESSION_ID is required; run this from a Toastty-managed agent session" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

if [[ -n "$expected_revision" && ! "$expected_revision" =~ ^[0-9]+$ ]]; then
  echo "error: --expected-revision must be a non-negative integer" >&2
  exit 64
fi

html_file="$file_path"
temp_file=""
if [[ -n "$html_file" ]]; then
  if [[ ! -f "$html_file" ]]; then
    echo "error: HTML file not found: $html_file" >&2
    exit 1
  fi
else
  temp_file="$(mktemp "${TMPDIR:-/tmp}/toastty-scratchpad.XXXXXX.html")"
  html_file="$temp_file"
  cat > "$html_file"
fi

cleanup() {
  if [[ -n "$temp_file" ]]; then
    rm -f "$temp_file"
  fi
}
trap cleanup EXIT

byte_count="$(wc -c < "$html_file" | tr -d '[:space:]')"
if [[ "$byte_count" -eq 0 ]]; then
  echo "error: Scratchpad HTML content is empty" >&2
  exit 64
fi
if [[ "$byte_count" -gt 1048576 ]]; then
  echo "error: Scratchpad HTML is ${byte_count} bytes; maximum is 1048576 bytes" >&2
  exit 64
fi

args=(
  --json
  action run panel.scratchpad.set-content
  --stdin content
  "sessionID=${TOASTTY_SESSION_ID}"
)
if [[ "$title_set" == "1" ]]; then
  args+=("title=${title}")
fi
if [[ -n "$expected_revision" ]]; then
  args+=("expectedRevision=${expected_revision}")
fi
if [[ -n "$create_policy" ]]; then
  args+=("createPolicy=${create_policy}")
fi
if [[ -n "$document_id" ]]; then
  args+=("documentID=${document_id}")
fi
if [[ "$purpose_set" == "1" ]]; then
  args+=("purpose=${purpose}")
fi

response="$("$TOASTTY_CLI_PATH" "${args[@]}" < "$html_file")"

python3 - "$response" <<'PY'
import json
import sys

envelope = json.loads(sys.argv[1])
if not envelope.get("ok"):
    error = envelope.get("error") or {}
    raise SystemExit(f"error: request failed: {error.get('code', '<unknown>')}: {error.get('message', '<no message>')}")

result = envelope.get("result") or {}
required = ["windowID", "workspaceID", "panelID", "documentID", "revision", "created"]
missing = [key for key in required if key not in result]
if missing:
    raise SystemExit(f"error: response missing fields: {', '.join(missing)}")

print("scratchpad published")
print(f"windowID={result['windowID']}")
print(f"workspaceID={result['workspaceID']}")
print(f"panelID={result['panelID']}")
print(f"documentID={result['documentID']}")
print(f"revision={result['revision']}")
print(f"created={str(result['created']).lower()}")
PY
