#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

printf 'warning: scripts/remote/gui-validate.sh is deprecated; use scripts/remote/validate.sh instead.\n' >&2
exec /bin/bash "$ROOT_DIR/scripts/remote/validate.sh" "$@"
