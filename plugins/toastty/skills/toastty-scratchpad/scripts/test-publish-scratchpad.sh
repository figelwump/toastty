#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/toastty-scratchpad-helper-test.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

cat > "$fixture_dir/fake-cli" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["SCRATCHPAD_TEST_REQUEST"], "w", encoding="utf-8") as output:
    json.dump({"args": sys.argv[1:], "content": sys.stdin.read()}, output)
print(json.dumps({"ok": True, "result": {
    "windowID": "window", "workspaceID": "workspace", "panelID": "panel",
    "documentID": "created-id", "revision": 1, "created": True,
}}))
PY
chmod +x "$fixture_dir/fake-cli"
export TOASTTY_CLI_PATH="$fixture_dir/fake-cli"
export TOASTTY_SESSION_ID="session"
export SCRATCHPAD_TEST_REQUEST="$fixture_dir/request.json"

printf '<!doctype html><title>Test</title>' | "$script_dir/publish-scratchpad-html.sh" \
  --additional --purpose 'Option comparison' --title 'Comparison' > "$fixture_dir/result"
python3 - "$fixture_dir/request.json" "$fixture_dir/result" <<'PY'
import json
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
assert "createPolicy=additional" in request["args"]
assert "purpose=Option comparison" in request["args"]
assert "title=Comparison" in request["args"]
assert "documentID=" not in " ".join(request["args"])
assert request["content"].startswith("<!doctype html>")
assert "documentID=created-id" in open(sys.argv[2], encoding="utf-8").read()
PY

printf '<!doctype html><title>Target</title>' | "$script_dir/publish-scratchpad-html.sh" \
  --document-id target-id > /dev/null
python3 - "$fixture_dir/request.json" <<'PY'
import json
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
assert "documentID=target-id" in request["args"]
assert not any(arg.startswith("createPolicy=") for arg in request["args"])
assert not any(arg.startswith("title=") for arg in request["args"])
assert not any(arg.startswith("purpose=") for arg in request["args"])
PY

printf '<!doctype html><title>Target</title>' | "$script_dir/publish-scratchpad-html.sh" \
  --document-id target-id --purpose '' > /dev/null
python3 - "$fixture_dir/request.json" <<'PY'
import json
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
assert "purpose=" in request["args"]
PY

"$script_dir/publish-scratchpad-outline.sh" --document-id target-id \
  --purpose 'Updated plan' 'Plan' > /dev/null
python3 - "$fixture_dir/request.json" <<'PY'
import json
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
assert "documentID=target-id" in request["args"]
assert "purpose=Updated plan" in request["args"]
assert "title=Plan" in request["args"]
assert "Preparing visual" in request["content"]
PY

"$script_dir/publish-scratchpad-outline.sh" --additional 'Separate plan' > /dev/null
python3 - "$fixture_dir/request.json" <<'PY'
import json
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
assert "createPolicy=additional" in request["args"]
assert not any(arg.startswith("documentID=") for arg in request["args"])
PY

printf x | "$script_dir/publish-scratchpad-html.sh" --new > /dev/null
python3 - "$fixture_dir/request.json" <<'PY'
import json
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
assert "createPolicy=new" in request["args"]
PY

if printf x | "$script_dir/publish-scratchpad-html.sh" --new --additional > /dev/null 2> "$fixture_dir/error"; then
  echo 'error: --new and --additional were accepted together' >&2
  exit 1
fi
grep -q 'mutually exclusive' "$fixture_dir/error"
if printf x | "$script_dir/publish-scratchpad-html.sh" --document-id id --additional > /dev/null 2> "$fixture_dir/error"; then
  echo 'error: --document-id and --additional were accepted together' >&2
  exit 1
fi
grep -q 'cannot be combined' "$fixture_dir/error"
if "$script_dir/publish-scratchpad-outline.sh" --document-id id --new > /dev/null 2> "$fixture_dir/error"; then
  echo 'error: outline accepted --document-id and --new together' >&2
  exit 1
fi
grep -q 'cannot be combined' "$fixture_dir/error"
if "$script_dir/publish-scratchpad-outline.sh" --additional --new > /dev/null 2> "$fixture_dir/error"; then
  echo 'error: outline accepted --additional and --new together' >&2
  exit 1
fi
grep -q 'mutually exclusive' "$fixture_dir/error"

echo 'scratchpad helper fixtures passed'
