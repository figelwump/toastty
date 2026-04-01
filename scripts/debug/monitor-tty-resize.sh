#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: monitor-tty-resize.sh <tty-path> [interval-seconds]

Polls a TTY's winsize with `stty -f` and prints a line whenever it changes.
Use this from another terminal while reproducing a focus-mode resize issue in
Toastty or Ghostty.app to confirm whether the process-visible TTY size changed.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 64
fi

tty_path="$1"
interval_seconds="${2:-0.05}"

if [[ ! -e "$tty_path" ]]; then
  echo "error: tty path does not exist: $tty_path" >&2
  exit 66
fi

timestamp() {
  python3 - <<'PY'
from datetime import datetime
print(datetime.now().astimezone().isoformat(timespec="milliseconds"))
PY
}

last_size=""
echo "# monitoring $tty_path every ${interval_seconds}s"
echo "# started $(timestamp)"

while true; do
  if current_size="$(stty -f "$tty_path" size 2>/dev/null)"; then
    :
  else
    current_size="unavailable"
  fi

  if [[ "$current_size" != "$last_size" ]]; then
    printf '%s %s %s\n' "$(timestamp)" "$tty_path" "$current_size"
    last_size="$current_size"
  fi

  sleep "$interval_seconds"
done
