#!/bin/bash
# scripts/init.sh — bootstrap the pipeline plugin into a fresh (non-subtree) repo.
#
# The greenfield inverse of migrate-from-subtree.sh: where migrate retires a
# legacy subtree install, init stands up a brand-new one. It composes existing
# primitives rather than reimplementing them — label seeding delegates to
# doctor.sh --fix labels, and the final audit is the read-only doctor.sh.
#
# Phases:
#   1. preflight  — dependency checks (gh/jq/bash>=4/tmux + Windows jq probe)
#   2. config     — detect repo/base-branch, generate pipeline.config
#   3. gitignore  — append pipeline.config (host-specific; idempotent)
#   4. labels     — seed the canonical GitHub labels (doctor.sh --fix labels)
#   5. doctor     — read-only audit tail so init ends in a known state
#
# Each preflight check emits exactly one line (mirrors doctor's CHECK: contract):
#   PREFLIGHT: <name> status=<pass|fail|warn> detail=<msg>
# gh / jq / bash are hard deps (fail-fast before any config write); tmux and the
# Windows-jq-on-bash-PATH probe are advisory warns.
#
# Modes:
#   init.sh                  — full bootstrap (preflight → config → gitignore → labels → doctor)
#   init.sh --preflight-only — run preflight and exit (non-zero on hard-dep fail)
#   init.sh --config-only    — preflight + config generation, then stop
#   init.sh --force          — overwrite an existing pipeline.config
#
# Non-interactive (CI / test) mode: set INIT_NON_INTERACTIVE=1 and supply
# answers via INIT_BASE_BRANCH / INIT_HAS_TESTS / INIT_HAS_CI / INIT_TEST_CMD /
# INIT_TYPECHECK_CMD / INIT_INSTALL_CMD.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --------------------------------------------------------------------------
# Platform detection. INIT_PLATFORM_OVERRIDE wins (test hook); else uname -s.
# --------------------------------------------------------------------------
platform() {
  if [ -n "${INIT_PLATFORM_OVERRIDE:-}" ]; then
    printf '%s' "$INIT_PLATFORM_OVERRIDE"
    return
  fi
  case "$(uname -s 2>/dev/null)" in
    Linux)                 printf 'linux' ;;
    Darwin)                printf 'macos' ;;
    MINGW*|MSYS*|CYGWIN*)  printf 'windows' ;;
    *)                     printf 'linux' ;;
  esac
}

jq_install_hint() {
  case "$(platform)" in
    macos)   printf 'brew install jq' ;;
    windows) printf 'winget install jqlang.jq (then copy onto the Git-Bash PATH: cp jq.exe /usr/bin/)' ;;
    *)       printf 'apt-get install jq' ;;
  esac
}

gh_install_hint() {
  case "$(platform)" in
    macos)   printf 'brew install gh' ;;
    windows) printf 'winget install GitHub.cli' ;;
    *)       printf 'apt-get install gh (see https://cli.github.com)' ;;
  esac
}

# Windows-only: is jq resolvable on a Windows-style dir even though it's not on
# the bash PATH? Probes INIT_WIN_JQ_DIRS (colon-separated, test hook) or the
# common Git-Bash / System32 locations.
win_jq_found() {
  local dirs="${INIT_WIN_JQ_DIRS:-/c/Program Files/Git/usr/bin:/c/Windows/System32:/c/ProgramData/chocolatey/bin}"
  local oldifs="$IFS" d
  IFS=:
  for d in $dirs; do
    if [ -x "$d/jq.exe" ] || [ -x "$d/jq" ]; then
      IFS="$oldifs"; return 0
    fi
  done
  IFS="$oldifs"
  return 1
}

preflight_line() {
  printf 'PREFLIGHT: %s status=%s detail=%s\n' "$1" "$2" "$3"
}

# --------------------------------------------------------------------------
# Phase 1: preflight. Returns non-zero when any HARD dependency fails.
# --------------------------------------------------------------------------
preflight() {
  local hard_fail=0

  # gh — hard dep.
  if command -v gh >/dev/null 2>&1; then
    preflight_line gh pass "gh CLI on PATH"
  else
    preflight_line gh fail "gh CLI not found — install: $(gh_install_hint)"
    hard_fail=1
  fi

  # jq — hard dep, with a Windows-PATH advisory carve-out.
  if command -v jq >/dev/null 2>&1; then
    preflight_line jq pass "jq on PATH"
  elif [ "$(platform)" = "windows" ] && win_jq_found; then
    preflight_line jq warn "jq found on the Windows PATH but not the bash PATH — copy it onto the bash PATH, e.g. cp jq.exe /usr/bin/"
  else
    preflight_line jq fail "jq not found — install: $(jq_install_hint)"
    hard_fail=1
  fi

  # bash >= 4 — hard dep (associative arrays, etc.).
  local bmajor="${BASH_VERSINFO[0]:-0}"
  if [ "$bmajor" -ge 4 ] 2>/dev/null; then
    preflight_line bash pass "bash $bmajor (>= 4)"
  else
    preflight_line bash fail "bash >= 4 required (found ${bmajor:-unknown}); upgrade via your package manager"
    hard_fail=1
  fi

  # tmux — advisory warn (queue runner degrades, init still proceeds).
  if command -v tmux >/dev/null 2>&1; then
    preflight_line tmux pass "tmux on PATH"
  else
    preflight_line tmux warn "tmux not found — the autonomous queue runner (run-queue.sh) is unavailable; run the pipeline from a Linux container"
  fi

  return "$hard_fail"
}

# --------------------------------------------------------------------------
# Phase 2: config generation. Detects repo + default branch via gh, prompts (or
# reads env in non-interactive mode), and writes pipeline.config. Refuses to
# clobber an existing config unless FORCE=1.
# --------------------------------------------------------------------------
generate_config() {
  if [ -f pipeline.config ] && [ "${FORCE:-0}" != "1" ]; then
    echo "init: pipeline.config already exists — re-run with --force to overwrite." >&2
    return 1
  fi

  local repo base_detected
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  base_detected="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
  [ -z "$base_detected" ] && base_detected="staging"

  local base has_tests has_ci test_cmd typecheck_cmd install_cmd
  if [ "${INIT_NON_INTERACTIVE:-0}" = "1" ]; then
    base="${INIT_BASE_BRANCH:-$base_detected}"
    has_tests="${INIT_HAS_TESTS:-y}"
    has_ci="${INIT_HAS_CI:-y}"
    test_cmd="${INIT_TEST_CMD:-npm test}"
    typecheck_cmd="${INIT_TYPECHECK_CMD:-npx tsc --noEmit}"
    install_cmd="${INIT_INSTALL_CMD:-npm ci}"
  else
    printf 'Detected repo: %s\n' "${repo:-<unknown>}"
    read -r -p "PR base branch [$base_detected]: " base;            base="${base:-$base_detected}"
    read -r -p "Does this project have a test suite? [Y/n]: " has_tests; has_tests="${has_tests:-y}"
    read -r -p "Does this project have blocking CI? [Y/n]: " has_ci;    has_ci="${has_ci:-y}"
    read -r -p "Test command [npm test]: " test_cmd;                test_cmd="${test_cmd:-npm test}"
    read -r -p "Typecheck command [npx tsc --noEmit]: " typecheck_cmd; typecheck_cmd="${typecheck_cmd:-npx tsc --noEmit}"
    read -r -p "Install command [npm ci]: " install_cmd;            install_cmd="${install_cmd:-npm ci}"
  fi

  # No-op defaults: a docs/infra repo with no suite must not wedge stage gates.
  local ci_enabled="true"
  case "$has_tests" in
    n|N|no|NO|false|FALSE) test_cmd="true"; typecheck_cmd="true" ;;
  esac
  case "$has_ci" in
    n|N|no|NO|false|FALSE) ci_enabled="" ;;
  esac

  # Write the config. Operational vars are seeded from the answers above; the
  # remainder carry the same sane defaults as pipeline.config.example.
  cat > pipeline.config <<EOF
# pipeline.config — generated by /pipeline:init. Host-specific; gitignored.
# Edit values to match this project. Sourced by shell scripts at runtime.

PIPELINE_REPO="$repo"
PIPELINE_BASE_BRANCH="$base"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_INSTALL_CMD="$install_cmd"
PIPELINE_SEED_CMD=""
PIPELINE_TEST_CMD="$test_cmd"
PIPELINE_TYPECHECK_CMD="$typecheck_cmd"
PIPELINE_CONTEXT_FILES="CLAUDE.md"
PIPELINE_SYNC_ENVS=""
PIPELINE_SYNC_VENVS=""
PIPELINE_SYNC_DOCS="CLAUDE.md"
PIPELINE_SYNC_FILES=".mcp.json"
PIPELINE_FRONTEND_PORT_OFFSET=4000
PIPELINE_LABELS_EXCLUDED="excluded"
PIPELINE_LABELS_LATER="later"
PIPELINE_LABELS_HUMAN="human"
PIPELINE_LABELS_BRAINSTORM="brainstorm"
PIPELINE_WIN_TEMP=""
PIPELINE_TMUX_SESSION="dev"
PIPELINE_CI_CHECK_ENABLED="$ci_enabled"
PIPELINE_RELEASE_PR_AUTO_MERGE="false"
PIPELINE_RELEASE_PR_LABEL="autorelease: pending"
PIPELINE_FULL_SEND_WAVE_PLANNING_ENABLED="true"
PIPELINE_GROUPING_DETECTION_ENABLED="true"
PIPELINE_LOGS_ENABLED=false
PIPELINE_STALL_POLL_THRESHOLD=5
PIPELINE_USE_LOCAL_PLUGIN=false
PIPELINE_CI_FIX_LOOP_ENABLED="true"
PIPELINE_CI_FIX_RETRY_BUDGET="2"
PIPELINE_CI_FIX_LOG_LINES="200"
PIPELINE_VISUAL_PROOF_PORT_BASE="8080"

# --- Per-model token pricing (issue #721) ---
#
# Per-1M-token USD rates consumed by \`scripts/cost-latency-report.sh
# --tokenomics\` to price the dogfood agent-cost logs (gated by
# PIPELINE_LOGS_ENABLED above). Shape: PIPELINE_PRICE_<MODEL>_<BUCKET>, where
# <BUCKET> is INPUT, OUTPUT, CACHE_CREATION, or CACHE_READ. Any bucket left
# unset falls back to the per-model list-price defaults baked into the report
# script. The lines below are COMMENTED OUT: they match the baked defaults, so
# uncomment + edit only to OVERRIDE a baked rate (no behavior change otherwise).
#PIPELINE_PRICE_CLAUDE_OPUS_4_8_INPUT=15
#PIPELINE_PRICE_CLAUDE_OPUS_4_8_OUTPUT=75
#PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_CREATION=18.75
#PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_READ=1.50
#PIPELINE_PRICE_CLAUDE_SONNET_4_6_INPUT=3
#PIPELINE_PRICE_CLAUDE_SONNET_4_6_OUTPUT=15
#PIPELINE_PRICE_CLAUDE_SONNET_4_6_CACHE_CREATION=3.75
#PIPELINE_PRICE_CLAUDE_SONNET_4_6_CACHE_READ=0.30
#PIPELINE_PRICE_CLAUDE_HAIKU_4_5_INPUT=1
#PIPELINE_PRICE_CLAUDE_HAIKU_4_5_OUTPUT=5
#PIPELINE_PRICE_CLAUDE_HAIKU_4_5_CACHE_CREATION=1.25
#PIPELINE_PRICE_CLAUDE_HAIKU_4_5_CACHE_READ=0.10
EOF

  echo "init: wrote pipeline.config (PIPELINE_REPO=${repo:-<unknown>}, PIPELINE_BASE_BRANCH=$base)"
  return 0
}

# --------------------------------------------------------------------------
# Phase 3: append pipeline.config to .gitignore (idempotent — grep -Fxq guard).
# --------------------------------------------------------------------------
ensure_gitignore() {
  local entry="pipeline.config"
  if [ -f .gitignore ] && grep -Fxq "$entry" .gitignore; then
    echo "init: .gitignore already ignores $entry"
    return 0
  fi
  # Guarantee a trailing newline before appending so we never glue onto a line.
  if [ -f .gitignore ] && [ -n "$(tail -c1 .gitignore 2>/dev/null)" ]; then
    printf '\n' >> .gitignore
  fi
  printf '%s\n' "$entry" >> .gitignore
  echo "init: appended $entry to .gitignore"
}

# --------------------------------------------------------------------------
# Phase 4: seed canonical labels (delegates to doctor.sh --fix labels).
# --------------------------------------------------------------------------
seed_labels() {
  echo "init: seeding canonical GitHub labels..."
  bash "$SCRIPT_DIR/doctor.sh" --fix labels
}

# --------------------------------------------------------------------------
# Phase 5: read-only doctor audit tail (never gates init's exit).
# --------------------------------------------------------------------------
doctor_tail() {
  echo "init: running doctor audit..."
  bash "$SCRIPT_DIR/doctor.sh" || true
}

usage() {
  cat <<'USAGE'
Usage: init.sh [--preflight-only|--config-only] [--force]
  --preflight-only  Run dependency preflight and exit (non-zero on hard-dep fail).
  --config-only     Run preflight + generate pipeline.config, then stop.
  --force           Overwrite an existing pipeline.config.
  (no flag)         Full bootstrap: preflight → config → gitignore → labels → doctor.
USAGE
}

# --------------------------------------------------------------------------
# Arg parsing + orchestration.
# --------------------------------------------------------------------------
MODE=full
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --preflight-only) MODE=preflight; shift ;;
    --config-only)    MODE=config; shift ;;
    --force)          FORCE=1; shift ;;
    --help|-h)        usage; exit 0 ;;
    *) echo "init: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

preflight
pf_rc=$?

if [ "$MODE" = "preflight" ]; then
  exit "$pf_rc"
fi

if [ "$pf_rc" -ne 0 ]; then
  echo "init: preflight failed — resolve the hard dependencies above before continuing. No config written." >&2
  exit "$pf_rc"
fi

generate_config
gc_rc=$?
if [ "$gc_rc" -ne 0 ]; then
  exit "$gc_rc"
fi

if [ "$MODE" = "config" ]; then
  exit 0
fi

ensure_gitignore
seed_labels
doctor_tail

echo "init: bootstrap complete. Re-run /pipeline:status to start the workflow."
exit 0
