#!/usr/bin/env bash
#
# Probe how the `pi` coding agent CLI (github.com/badlogic/pi-mono,
# @mariozechner/pi-coding-agent) loads session-scoped skills, so Toastty can
# decide how to inject managed skills at launch.
#
# Every scenario runs against a temporary HOME, a temporary
# PI_CODING_AGENT_DIR (pi's per-user "~/.pi/agent" equivalent, honored via
# the PI_CODING_AGENT_DIR env var), and a temporary project cwd. No probe
# writes to the developer's real ~/.pi, ~/.claude, ~/.codex, ~/.agents, or
# ~/.config, and no probe runs `pi install`/`pi remove`/`pi config`.
#
# pi has no non-interactive "dump what would load" debug command (unlike
# `codex debug prompt-input`). Skill-loading diagnostics (bad --skill path,
# missing description, name collisions) are only ever printed by pi's
# interactive TUI banner, which this probe cannot drive non-interactively.
# So the default (no --with-model) run instead uses a black-box technique:
# it compares stderr/exit-code between a "control" invocation and a
# "variant" invocation (bad skill path, empty skill dir, ...) that both fail
# identically on the (missing/isolated) API key. Byte-identical failure
# output proves the skill-loading step did not itself error, warn visibly,
# or change the exit code.
#
# Pass --with-model to additionally run real model calls (via the ambient
# environment's ANTHROPIC_API_KEY, e.g. `sv exec --`) confirming skills are
# actually visible to the model: skill argument shapes, repeatability,
# --no-skills interplay, auto-discovery roots, name-collision winner, and
# missing-description exclusion. These are skipped by default so the script
# runs without secrets.
#
# Usage:
#   scripts/agents/probe-pi-session-scoped-skills.sh [--pi <path>] [--with-model]
#
set -uo pipefail

PI_BIN="${PI_BIN:-$(command -v pi || true)}"
WITH_MODEL=0
MODEL_PATTERN="claude-haiku-4-5"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pi)
      PI_BIN="$2"
      shift 2
      ;;
    --with-model)
      WITH_MODEL=1
      shift
      ;;
    --model)
      MODEL_PATTERN="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--pi <path>] [--with-model] [--model <pattern>]"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$PI_BIN" ]]; then
  echo "error: pi must be installed or passed via --pi / PI_BIN" >&2
  exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_NAMES=()

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_NAMES+=("$1")
  echo "FAIL: $1 -- $2"
}

skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  echo "SKIP: $1 -- $2"
}

ROOT="$(mktemp -d -t toastty-pi-session-skills-probe.XXXXXX)"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

HOME_DIR="$ROOT/home"
AGENT_DIR="$ROOT/agent-dir"
WORKSPACE="$ROOT/workspace"
EXTERNAL="$ROOT/external"
mkdir -p "$HOME_DIR" "$AGENT_DIR" "$WORKSPACE" "$EXTERNAL"

write_skill() {
  # write_skill <dir> <name> <description>
  local dir="$1" name="$2" description="$3"
  mkdir -p "$dir"
  cat > "$dir/SKILL.md" <<EOF
---
name: ${name}
description: ${description}
---

Marker: ${name}
EOF
}

# --- Argument-shape fixtures (question 1) ---
write_skill "$EXTERNAL/shape-a-dir" "shape-a-dir" "Probe skill loaded via a directory containing SKILL.md directly."
write_skill "$EXTERNAL/shape-b-parent/child-one" "child-one" "Probe skill child-one under a multi-skill parent directory."
write_skill "$EXTERNAL/shape-b-parent/child-two" "child-two" "Probe skill child-two under a multi-skill parent directory."
write_skill "$EXTERNAL/shape-c-dir" "shape-c-dir" "Probe skill loaded by passing the SKILL.md file path directly."
write_skill "$EXTERNAL/repeat-a" "repeat-a" "First skill for repeatable --skill flag probe."
write_skill "$EXTERNAL/repeat-b" "repeat-b" "Second skill for repeatable --skill flag probe."
mkdir -p "$EXTERNAL/empty-dir"

# --- Frontmatter validation fixture (question 6) ---
mkdir -p "$EXTERNAL/bad-frontmatter-missing-desc"
cat > "$EXTERNAL/bad-frontmatter-missing-desc/SKILL.md" <<'EOF'
---
name: bad-frontmatter-missing-desc
---

Marker: bad-frontmatter-missing-desc
EOF

# --- Discovery-root fixtures (question 4) ---
write_skill "$WORKSPACE/.pi/skills/project-pi-skill" "project-pi-skill" "Discovered from project .pi/skills directory."
write_skill "$WORKSPACE/.agents/skills/project-agents-skill" "project-agents-skill" "Discovered from project .agents/skills directory."
write_skill "$AGENT_DIR/skills/user-pi-skill" "user-pi-skill" "Discovered from PI_CODING_AGENT_DIR/skills directory."
write_skill "$HOME_DIR/.agents/skills/user-agents-skill" "user-agents-skill" "Discovered from HOME/.agents/skills directory."
write_skill "$HOME_DIR/.claude/skills/claude-decoy-skill" "claude-decoy-skill" "Decoy under HOME/.claude/skills -- expected NOT discovered by pi."

# --- Name-collision fixtures (question 5): same name, discovered vs explicit ---
write_skill "$WORKSPACE/.pi/skills/collide-name" "collide-name" "DISCOVERED version of the colliding skill name (project .pi/skills)."
write_skill "$EXTERNAL/collide-name-explicit" "collide-name" "EXPLICIT --skill version of the colliding skill name."

run_pi() {
  # run_pi <extra pi args...> -- runs with isolated HOME/PI_CODING_AGENT_DIR,
  # cwd=$WORKSPACE, no real API key, non-interactive, bounded timeout.
  env -i \
    HOME="$HOME_DIR" \
    PI_CODING_AGENT_DIR="$AGENT_DIR" \
    PATH="$PATH" \
    "$PI_BIN" --no-session --print "$@" < /dev/null
}

run_pi_cwd() (
  cd "$WORKSPACE" || exit 99
  run_pi "$@"
)

# ============================================================================
# Question 9: version / env vars (no model call)
# ============================================================================
VERSION_OUT="$(env -i HOME="$HOME_DIR" PATH="$PATH" "$PI_BIN" --version 2>&1)"
if [[ "$VERSION_OUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "version_reports_semver ($VERSION_OUT)"
else
  fail "version_reports_semver" "unexpected --version output: $VERSION_OUT"
fi

# ============================================================================
# Question 1 + 8: --skill flag documented, argv placement (no model call)
# ============================================================================
HELP_OUT="$(env -i HOME="$HOME_DIR" PATH="$PATH" "$PI_BIN" --help 2>&1)"
if grep -q -- '--skill <path>.*can be used multiple times' <<<"$HELP_OUT"; then
  pass "help_documents_repeatable_skill_flag"
else
  fail "help_documents_repeatable_skill_flag" "--help did not document --skill as repeatable"
fi

# Baseline (control): no skill flags at all, no auth. Establishes the
# reference stderr for the "silent failure" oracle used below.
BASELINE_OUT="$(run_pi_cwd -p "hi" 2>&1)"
BASELINE_CODE=$?

skill_error_output_matches_baseline() {
  # skill_error_output_matches_baseline <label> <extra pi args...>
  local label="$1"
  shift
  local out code
  out="$(run_pi_cwd "$@" -p "hi" 2>&1)"
  code=$?
  if [[ "$out" == "$BASELINE_OUT" && "$code" -eq "$BASELINE_CODE" ]]; then
    pass "$label"
  else
    fail "$label" "stderr/exit diverged from baseline (code=$code, baseline_code=$BASELINE_CODE)"
  fi
}

# --skill placed after the positional message token still parses (same
# generic downstream failure as the control -- proves the flag was
# recognized regardless of position, since parseArgs scans every token).
skill_error_output_matches_baseline "skill_flag_after_positional_message_parses" -p "hi" --skill "$EXTERNAL/shape-a-dir"
OUT_AFTER_MSG="$(run_pi_cwd -p "hi" --skill "$EXTERNAL/shape-a-dir" 2>&1)"
CODE_AFTER_MSG=$?
if [[ "$OUT_AFTER_MSG" == "$BASELINE_OUT" && "$CODE_AFTER_MSG" -eq "$BASELINE_CODE" ]]; then
  pass "skill_flag_after_positional_message_reaches_same_stage"
else
  fail "skill_flag_after_positional_message_reaches_same_stage" "diverged from baseline"
fi

# A literal "--" token is NOT a supported end-of-flags separator: pi's flat
# argv scanner treats it as an (invalid, empty-named) long flag and fails
# fast with a distinct, pre-model error -- before any prompt is attempted.
DASH_OUT="$(run_pi_cwd -p "hi" -- 2>&1)"
DASH_CODE=$?
if [[ "$DASH_OUT" == *"Unknown option: --"* && "$DASH_CODE" -ne 0 && "$DASH_OUT" != "$BASELINE_OUT" ]]; then
  pass "literal_double_dash_is_hard_error_distinct_from_baseline"
else
  fail "literal_double_dash_is_hard_error_distinct_from_baseline" "expected distinct 'Unknown option: --' failure, got: $DASH_OUT"
fi

# ============================================================================
# Question 7: failure modes for bad --skill paths (no model call)
# ============================================================================
skill_error_output_matches_baseline "nonexistent_skill_path_fails_open_silently" --skill "/nonexistent/toastty-probe-path"
skill_error_output_matches_baseline "skill_dir_without_SKILL_md_fails_open_silently" --skill "$EXTERNAL/empty-dir"

# ============================================================================
# Question 3: --no-skills / --skill interplay parses without a distinct error
# (full discovery-suppression + explicit-path-still-loads assertion runs
# under --with-model below, since it requires seeing what the model has).
# ============================================================================
skill_error_output_matches_baseline "no_skills_plus_explicit_skill_flag_parses" --no-skills --skill "$EXTERNAL/shape-a-dir"

if [[ "$WITH_MODEL" -ne 1 ]]; then
  skip "model_visible_shape_a_single_skill_dir" "requires --with-model"
  skip "model_visible_shape_b_parent_dir_multi_skill" "requires --with-model"
  skip "model_visible_shape_c_skill_md_file_path" "requires --with-model"
  skip "model_visible_repeatable_skill_flags" "requires --with-model"
  skip "no_skills_suppresses_discovery_keeps_explicit" "requires --with-model"
  skip "discovery_roots_match_expected_set" "requires --with-model"
  skip "discovery_excludes_claude_skills_dir" "requires --with-model"
  skip "name_collision_discovered_skill_wins_over_explicit" "requires --with-model"
  skip "missing_description_skill_excluded_without_crash" "requires --with-model"
  echo ""
  echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped (model-gated)"
  [[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
fi

# ============================================================================
# --with-model checks: real anthropic model calls via the ambient
# environment (expects ANTHROPIC_API_KEY already injected, e.g. by
# `sv exec --`). No secret values are read, echoed, or logged.
# ============================================================================
LIST_PROMPT="List the names of every skill available to you, one per line, and nothing else. Do not use any tools."

run_pi_model() {
  # run_pi_model <extra pi args...> -- <prompt>
  # Only HOME and PI_CODING_AGENT_DIR are overridden (isolation); everything
  # else -- including ANTHROPIC_API_KEY -- is inherited unmodified from the
  # ambient environment (e.g. injected by `sv exec --`). This script never
  # reads, echoes, or reconstructs the key value itself.
  # Uses default tools (read tool must stay enabled: pi only injects the
  # <available_skills> system-prompt block when the read tool is selected).
  (
    export HOME="$HOME_DIR"
    export PI_CODING_AGENT_DIR="$AGENT_DIR"
    "$PI_BIN" --no-session --print --provider anthropic --model "$MODEL_PATTERN" "$@" < /dev/null
  )
}

run_pi_model_cwd() (
  cd "$WORKSPACE" || exit 99
  run_pi_model "$@"
)

model_lists_contains() {
  # model_lists_contains <label> <needle> <output>
  local label="$1" needle="$2" output="$3"
  if grep -qx -- "$needle" <<<"$output"; then
    pass "$label"
  else
    fail "$label" "expected '$needle' in model skill list, got:\n$output"
  fi
}

model_lists_excludes() {
  local label="$1" needle="$2" output="$3"
  if grep -qx -- "$needle" <<<"$output"; then
    fail "$label" "expected '$needle' absent from model skill list, got:\n$output"
  else
    pass "$label"
  fi
}

# --- Shapes (a)/(c) + discovery roots + collision-presence, all in one call:
# ambient project/user discovery is ON (no --no-skills), one explicit
# --skill(shape-a-dir) is added.
SHAPE_A_OUT="$(run_pi_model_cwd --skill "$EXTERNAL/shape-a-dir" -p "$LIST_PROMPT")"
model_lists_contains "model_visible_shape_a_single_skill_dir" "shape-a-dir" "$SHAPE_A_OUT"
model_lists_contains "discovery_roots_project_pi_skills" "project-pi-skill" "$SHAPE_A_OUT"
model_lists_contains "discovery_roots_project_agents_skills" "project-agents-skill" "$SHAPE_A_OUT"
model_lists_contains "discovery_roots_user_pi_agent_skills" "user-pi-skill" "$SHAPE_A_OUT"
model_lists_contains "discovery_roots_user_home_agents_skills" "user-agents-skill" "$SHAPE_A_OUT"
model_lists_excludes "discovery_excludes_claude_skills_dir" "claude-decoy-skill" "$SHAPE_A_OUT"
COLLIDE_COUNT="$(grep -cx "collide-name" <<<"$SHAPE_A_OUT")"
if [[ "$COLLIDE_COUNT" -eq 1 ]]; then
  pass "name_collision_produces_single_entry_not_duplicate"
else
  fail "name_collision_produces_single_entry_not_duplicate" "expected exactly one 'collide-name' line, saw $COLLIDE_COUNT"
fi
pass "discovery_roots_match_expected_set"

# --- Shapes (b)/(c) + repeatable flags, with discovery suppressed via
# --no-skills so only the explicit paths can be the source of any name.
NO_SKILLS_OUT="$(run_pi_model_cwd --no-skills \
  --skill "$EXTERNAL/shape-b-parent" \
  --skill "$EXTERNAL/shape-c-dir/SKILL.md" \
  --skill "$EXTERNAL/repeat-a" \
  --skill "$EXTERNAL/repeat-b" \
  -p "$LIST_PROMPT")"
model_lists_contains "model_visible_shape_b_parent_dir_multi_skill" "child-one" "$NO_SKILLS_OUT"
model_lists_contains "model_visible_shape_b_parent_dir_multi_skill_2" "child-two" "$NO_SKILLS_OUT"
model_lists_contains "model_visible_shape_c_skill_md_file_path" "shape-c-dir" "$NO_SKILLS_OUT"
model_lists_contains "model_visible_repeatable_skill_flags" "repeat-a" "$NO_SKILLS_OUT"
model_lists_contains "model_visible_repeatable_skill_flags_2" "repeat-b" "$NO_SKILLS_OUT"
model_lists_excludes "no_skills_suppresses_discovery_keeps_explicit" "project-pi-skill" "$NO_SKILLS_OUT"

# --- Name-collision winner: discovered workspace/.pi/skills/collide-name
# vs explicit --skill of the same name. Source-level precedence (skills.js
# addSkills: first-registered-in-skillMap wins; resource-loader.js merges
# discovered paths before additionalSkillPaths) predicts the DISCOVERED
# skill wins and the explicit one is silently dropped.
COLLIDE_OUT="$(run_pi_model_cwd --skill "$EXTERNAL/collide-name-explicit" \
  -p "Find the skill named exactly collide-name in your available_skills list. Quote its <description> value verbatim, and nothing else.")"
if grep -qi "DISCOVERED version" <<<"$COLLIDE_OUT"; then
  pass "name_collision_discovered_skill_wins_over_explicit"
elif grep -qi "EXPLICIT --skill version" <<<"$COLLIDE_OUT"; then
  fail "name_collision_discovered_skill_wins_over_explicit" "explicit --skill won instead of discovered (source-level prediction was wrong): $COLLIDE_OUT"
else
  fail "name_collision_discovered_skill_wins_over_explicit" "could not determine winner from model output: $COLLIDE_OUT"
fi

# --- Missing description: skill is silently excluded (not crashed, not
# listed) per skills.js loadSkillFromFile returning skill:null.
BAD_FRONTMATTER_OUT="$(run_pi_model_cwd --skill "$EXTERNAL/bad-frontmatter-missing-desc" -p "$LIST_PROMPT")"
model_lists_excludes "missing_description_skill_excluded_without_crash" "bad-frontmatter-missing-desc" "$BAD_FRONTMATTER_OUT"

echo ""
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "Failed checks: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
