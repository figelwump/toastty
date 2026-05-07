#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SOURCE_SKILLS_DIR="$ROOT_DIR/.agents/skills"

declare -a REQUESTED_TARGETS=()
declare -a REQUESTED_SKILLS=()
FORCE=0

usage() {
  cat <<'EOF'
Usage: scripts/agents/link-global-skills.sh [--target agents|claude|codex|all] [--skill name] [--force]

Links Toastty repo skills into global agent skill directories.

Targets:
  agents   ~/.agents/skills
  claude   ~/.claude/skills
  codex    ~/.codex/skills
  all      agents and claude (default)

Options:
  --skill name  Link only the named skill. May be repeated.
  --force       Replace existing non-symlink paths after moving them aside as backups.
  -h, --help    Show this help.
EOF
}

log() {
  printf '[link-global-skills] %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

append_target() {
  local target="$1"
  case "$target" in
    all)
      REQUESTED_TARGETS+=("agents" "claude")
      ;;
    agents|claude|codex)
      REQUESTED_TARGETS+=("$target")
      ;;
    *)
      fail "unknown target: $target"
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || fail "--target requires a value"
      append_target "$2"
      shift 2
      ;;
    --skill)
      [[ $# -ge 2 ]] || fail "--skill requires a value"
      REQUESTED_SKILLS+=("$2")
      shift 2
      ;;
    --force)
      FORCE=1
      shift
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

if [[ ! -d "$SOURCE_SKILLS_DIR" ]]; then
  fail "source skills directory not found: $SOURCE_SKILLS_DIR"
fi

if [[ "${#REQUESTED_TARGETS[@]}" -eq 0 ]]; then
  append_target all
fi

target_directory() {
  case "$1" in
    agents)
      printf '%s/.agents/skills\n' "$HOME"
      ;;
    claude)
      printf '%s/.claude/skills\n' "$HOME"
      ;;
    codex)
      printf '%s/.codex/skills\n' "$HOME"
      ;;
    *)
      fail "unknown target: $1"
      ;;
  esac
}

unique_lines() {
  awk '!seen[$0]++'
}

discover_skills() {
  if [[ "${#REQUESTED_SKILLS[@]}" -gt 0 ]]; then
    printf '%s\n' "${REQUESTED_SKILLS[@]}" | unique_lines
    return
  fi

  find "$SOURCE_SKILLS_DIR" -mindepth 2 -maxdepth 2 -name SKILL.md -print \
    | while IFS= read -r skill_file; do
        basename "$(dirname "$skill_file")"
      done \
    | sort
}

backup_path_for() {
  local path="$1"
  local timestamp candidate index

  timestamp="$(date +%Y%m%d-%H%M%S)"
  candidate="${path}.backup-${timestamp}"
  index=1
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    candidate="${path}.backup-${timestamp}-${index}"
    index=$((index + 1))
  done

  printf '%s\n' "$candidate"
}

link_skill() {
  local target_name="$1"
  local skill_name="$2"
  local source_path destination_dir destination_path current_target backup_path

  source_path="$SOURCE_SKILLS_DIR/$skill_name"
  if [[ ! -f "$source_path/SKILL.md" ]]; then
    fail "skill not found: $skill_name ($source_path/SKILL.md)"
  fi

  destination_dir="$(target_directory "$target_name")"
  destination_path="$destination_dir/$skill_name"
  mkdir -p "$destination_dir"

  if [[ -L "$destination_path" ]]; then
    current_target="$(readlink "$destination_path")"
    if [[ "$current_target" == "$source_path" ]]; then
      log "$target_name/$skill_name already linked"
      return
    fi
    rm "$destination_path"
  elif [[ -e "$destination_path" ]]; then
    if [[ "$FORCE" != "1" ]]; then
      fail "refusing to replace existing path without --force: $destination_path"
    fi
    backup_path="$(backup_path_for "$destination_path")"
    mv "$destination_path" "$backup_path"
    log "moved existing $destination_path to $backup_path"
  fi

  ln -s "$source_path" "$destination_path"
  log "linked $target_name/$skill_name -> $source_path"
}

declare -a TARGETS=()
declare -a SKILLS=()

while IFS= read -r target; do
  [[ -n "$target" ]] && TARGETS+=("$target")
done < <(printf '%s\n' "${REQUESTED_TARGETS[@]}" | unique_lines)

while IFS= read -r skill; do
  [[ -n "$skill" ]] && SKILLS+=("$skill")
done < <(discover_skills)

if [[ "${#SKILLS[@]}" -eq 0 ]]; then
  fail "no skills selected"
fi

for target in "${TARGETS[@]}"; do
  for skill in "${SKILLS[@]}"; do
    link_skill "$target" "$skill"
  done
done
