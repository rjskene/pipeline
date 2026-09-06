#!/bin/bash
set -uo pipefail
#
# calibration-run.sh — DOGFOOD-ONLY driver for the §8 calibration slate
# (issue #1280, tracker #1271, spec
# docs/superpowers/specs/2026-09-05-harness-evolve-loop-design.md §8).
#
# Real-work retros cannot isolate cause: the workload differs every cycle.
# The calibration slate holds the INPUTS fixed (five template issues at tag
# `calib-base` in a purpose-built consumer sandbox) so the harness version is
# the only variable, and doubles as the end-to-end regression suite the unit
# tests are not.
#
# Modes (mutually exclusive):
#   --bootstrap  Create/adopt the sandbox repo, clone it, sync the harness
#                template into it, seed labels, tag `calib-base`. Idempotent:
#                every step is guarded, so a re-run is a no-op.
#   --reset      Force the sandbox back to `calib-base`, reap stale calib
#                issues, recreate the five slate issues. Prints `CALIB-ISSUES`.
#   --dry-run    Print the headless launch command that --run would execute
#                and exit 0. Makes NO network call and launches NO claude.
#   --run        --reset, then run the launch for real under `timeout`, then
#                emit the per-issue `CALIB` block + `CALIB-TOTAL`, tee'd to
#                $HARNESS/docs/retros/calib/<UTC date>.txt for the retro to
#                ingest (scripts/run-retro.sh).
#
# EVERY network / launch call goes through the single dispatch() seam below,
# which --dry-run replaces with a printf. That is what makes the test suite
# hermetic: tests/test-calibration-run.sh needs neither a real `gh` nor a real
# `claude`, and --dry-run short-circuits before any side effect.
#
# Env seams (all optional):
#   PIPELINE_CALIB_REPO      sandbox repo slug        (default rjskene/pipeline-calib)
#   PIPELINE_CALIB_DIR       sandbox clone dir        (default $HOME/.claude/calib/pipeline-calib)
#   PIPELINE_CALIB_REMOTE    git URL to clone         (default: `gh repo clone`)
#   PIPELINE_CALIB_TIMEOUT   headless run cap, sec    (default 5400)
#   PIPELINE_CALIB_BASE_TAG  reset anchor tag         (default calib-base)
#   PIPELINE_CALIB_ISSUE_IDS pre-resolved slate ids   (default: --reset's output)
# Plus PIPELINE_CALIB_PROFILE, which this script EXPORTS (never reads) into the
# headless run's environment so the sandbox session knows which profile is
# under test.
#
# Usage:
#   bash scripts/calibration-run.sh --bootstrap
#   bash scripts/calibration-run.sh --reset
#   bash scripts/calibration-run.sh --dry-run [--profile strict|lean] [--model sonnet|opus]
#   bash scripts/calibration-run.sh --run --profile strict --model sonnet
#   bash scripts/calibration-run.sh --help
#
# Exit codes: 0 ok · 1 runtime failure · 2 invalid arguments.
#

print_usage() {
  cat <<'USAGE'
Usage: scripts/calibration-run.sh (--bootstrap|--reset|--dry-run|--run) [options]

Drives the §8 calibration slate: a fixed five-issue workload run against a
purpose-built consumer sandbox so the harness version is the only variable.

Modes (exactly one, mutually exclusive):
  --bootstrap      Create/adopt + clone the sandbox, sync the harness
                   template, seed labels, tag calib-base. Idempotent.
  --reset          Force the sandbox back to calib-base and recreate the five
                   slate issues. Prints `CALIB-ISSUES <n1> ... <n5>`.
  --dry-run        Print the headless launch command and exit. No network
                   call, no claude launch, no sandbox mutation.
  --run            --reset, then run the launch for real, then emit the
                   per-issue CALIB summary block + CALIB-TOTAL.

Options:
  --profile P      strict|lean  (default strict) — harness profile under test.
  --model M        sonnet|opus  (default sonnet) — model for the headless run.
  --harness DIR    Harness (pipeline repo) under test; becomes both
                   CLAUDE_PLUGIN_ROOT and --plugin-dir for the headless run.
                   Default: the repo containing this script.
  --help           Print this banner and exit 0.
USAGE
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

MODE=""
PROFILE="strict"
MODEL="sonnet"
HARNESS_ARG=""

die_usage() { echo "calibration-run: ERROR: $1" >&2; exit 2; }
die_run()   { echo "calibration-run: ERROR: $1" >&2; exit 1; }
warn()      { echo "calibration-run: WARN: $1" >&2; }

set_mode() {
  if [ -n "$MODE" ]; then
    die_usage "--$MODE and --$1 are mutually exclusive (pick one of --bootstrap|--reset|--dry-run|--run)"
  fi
  MODE="$1"
}

# require_value "$@" — guards every `shift 2` below. Without it a value-taking
# flag in LAST position leaves `shift 2` with $#=1: the shift fails, the token
# is never consumed, and the parser spins forever printing nothing. Call it as
# `require_value "$@"` so $1 is the flag name and $# is what remains.
require_value() { [ $# -ge 2 ] || die_usage "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)    print_usage; exit 0 ;;
    --bootstrap)  set_mode bootstrap; shift ;;
    --reset)      set_mode reset; shift ;;
    --dry-run)    set_mode dry-run; shift ;;
    --run)        set_mode run; shift ;;
    --profile)    require_value "$@"; PROFILE="$2"; shift 2 ;;
    --profile=*)  PROFILE="${1#--profile=}"; shift ;;
    --model)      require_value "$@"; MODEL="$2"; shift 2 ;;
    --model=*)    MODEL="${1#--model=}"; shift ;;
    --harness)    require_value "$@"; HARNESS_ARG="$2"; shift 2 ;;
    --harness=*)  HARNESS_ARG="${1#--harness=}"; shift ;;
    *)            die_usage "unknown arg: $1" ;;
  esac
done

case "$PROFILE" in
  strict|lean) ;;
  *) die_usage "--profile must be one of strict|lean (got: ${PROFILE:-<empty>})" ;;
esac
case "$MODEL" in
  sonnet|opus) ;;
  *) die_usage "--model must be one of sonnet|opus (got: ${MODEL:-<empty>})" ;;
esac
if [ -z "$MODE" ]; then
  die_usage "one of --bootstrap|--reset|--dry-run|--run is required"
fi

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HARNESS_ARG:-$(cd "$SCRIPT_DIR/.." && pwd)}"
[ -d "$HARNESS" ] || die_usage "--harness is not a directory: $HARNESS"

CALIB_REPO="${PIPELINE_CALIB_REPO:-rjskene/pipeline-calib}"
SANDBOX="${PIPELINE_CALIB_DIR:-$HOME/.claude/calib/pipeline-calib}"
CALIB_REMOTE="${PIPELINE_CALIB_REMOTE:-}"
CALIB_TIMEOUT="${PIPELINE_CALIB_TIMEOUT:-5400}"
BASE_TAG="${PIPELINE_CALIB_BASE_TAG:-calib-base}"
ISSUE_IDS="${PIPELINE_CALIB_ISSUE_IDS:-}"

TEMPLATE_DIR="$HARNESS/dev/calib/template"
SLATE_DIR="$HARNESS/dev/calib/slate"
CALIB_OUT_DIR="$HARNESS/docs/retros/calib"

# abs_path <dir> — the resolved, symlink-free path of a directory; the input
# unchanged when it does not exist. Avoids depending on `realpath`.
abs_path() { ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"; }

# needs_staging — TRUE when the harness lives OUTSIDE ~/.claude. The sandbox
# session's own restrict_paths hook allows exactly two roots: the session's
# project dir (the sandbox) and ~/.claude. A --plugin-dir anywhere else has its
# own scripts blocked from inside the run — run #1 died 87 s in that way. See
# stage_harness().
needs_staging() {
  local h c
  h="$(abs_path "$HARNESS")"
  c="$(abs_path "$HOME/.claude")"
  case "$h/" in "$c"/*) return 1 ;; esac
  return 0
}

# TWO HARNESS ROLES, one variable each. HARNESS is the ORIGINAL checkout and
# stays the source of the template, the slate, doctor.sh,
# cost-latency-report.sh and CALIB_OUT_DIR — which is why the run's .txt/.log
# substrate lands in the original by construction. LAUNCH_HARNESS is only what
# the sandbox session loads. The stage is a sibling of the sandbox clone inside
# the calib dir (default $HOME/.claude/calib/harness), derived rather than
# configured so it needs no knob and follows PIPELINE_CALIB_DIR in tests.
STAGE_DIR="$(dirname "$SANDBOX")/harness"
LAUNCH_HARNESS="$HARNESS"
needs_staging && LAUNCH_HARNESS="$STAGE_DIR"

# The template ships the sandbox's Claude local-settings file FLAT (a normal
# tracked file); --bootstrap materializes it under the sandbox's own .claude/
# dir. Destination is composed from $SANDBOX at runtime — never a literal path.
TEMPLATE_SETTINGS_BASENAME="claude-settings.local.json"
LOCAL_SETTINGS_BASENAME="settings.local.json"

DRY=0
[ "$MODE" = "dry-run" ] && DRY=1

SLATE_DIRS=()
LAUNCH=()

# ---------------------------------------------------------------------------
# dispatch() — THE single network / launch seam
# ---------------------------------------------------------------------------
# Under --dry-run every call is replaced by one `CALIB-LAUNCH` preview line
# (which also carries the resolved sandbox cwd), so nothing leaves the box.
dispatch() {
  if [ "$DRY" -eq 1 ]; then
    printf 'CALIB-LAUNCH cwd=%s %s\n' "$SANDBOX" "$*"
    return 0
  fi
  "$@"
}

build_launch() {
  local ids="$ISSUE_IDS"
  if [ -z "$ids" ]; then
    ids="N1 N2 N3 N4 N5"   # --dry-run preview before --reset has resolved ids
  fi
  LAUNCH=(env "CLAUDE_PLUGIN_ROOT=$LAUNCH_HARNESS" "PIPELINE_CALIB_PROFILE=$PROFILE"
          timeout "$CALIB_TIMEOUT"
          claude -p "/pipeline:fullsend $ids"
          --plugin-dir "$LAUNCH_HARNESS" --model "$MODEL" --dangerously-skip-permissions)
}

# ---------------------------------------------------------------------------
# --bootstrap (every step guarded: a re-run is a no-op)
# ---------------------------------------------------------------------------

ensure_remote_repo() {
  if dispatch gh repo view "$CALIB_REPO" >/dev/null 2>&1; then
    echo "calib: sandbox repo $CALIB_REPO already exists — adopting"
    return 0
  fi
  dispatch gh repo create "$CALIB_REPO" --private \
    || { warn "could not create $CALIB_REPO — assuming it exists"; return 0; }
}

ensure_clone() {
  [ -d "$SANDBOX/.git" ] && return 0
  mkdir -p "$(dirname "$SANDBOX")" || return 1
  if [ -n "$CALIB_REMOTE" ]; then
    dispatch git clone --quiet "$CALIB_REMOTE" "$SANDBOX" || return 1
  else
    dispatch gh repo clone "$CALIB_REPO" "$SANDBOX" || return 1
  fi
}

sync_template() {
  if [ ! -d "$TEMPLATE_DIR" ]; then
    warn "no template at $TEMPLATE_DIR — nothing to sync"
    return 0
  fi
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude '.git' "$TEMPLATE_DIR"/ "$SANDBOX"/ || return 1
  else
    ( cd "$TEMPLATE_DIR" && tar cf - . ) | ( cd "$SANDBOX" && tar xf - ) || return 1
  fi
}

materialize_local_settings() {
  local flat="$SANDBOX/$TEMPLATE_SETTINGS_BASENAME"
  [ -f "$flat" ] || return 0
  local dest_dir="$SANDBOX/.claude"
  mkdir -p "$dest_dir" || return 1
  mv -f "$flat" "$dest_dir/$LOCAL_SETTINGS_BASENAME" || return 1
}

commit_sandbox() {
  git -C "$SANDBOX" add --all -- . || return 1
  if git -C "$SANDBOX" diff --cached --quiet 2>/dev/null; then
    return 0   # already in sync — no commit, no churn
  fi
  git -C "$SANDBOX" commit --quiet -m "chore(calib): seed sandbox from harness template" || return 1
}

push_main() {
  dispatch git -C "$SANDBOX" push --quiet origin HEAD:refs/heads/main
}

tag_base() {
  if git -C "$SANDBOX" rev-parse -q --verify "refs/tags/$BASE_TAG" >/dev/null 2>&1; then
    return 0   # tag already anchored — never re-tag, never duplicate
  fi
  git -C "$SANDBOX" tag "$BASE_TAG" || return 1
  dispatch git -C "$SANDBOX" push --quiet origin "refs/tags/$BASE_TAG"
}

# Seed the canonical labels ON THE SANDBOX REPO. Scoping here is load-bearing
# (#1280): doctor.sh --fix labels sources ./pipeline.config from its OWN cwd and
# seeds whatever PIPELINE_REPO it ends up with, and this script runs from the
# harness — whose pipeline.config (or the operator's exported shell env) names
# the harness repo. Unscoped, the seed silently labels the HARNESS and leaves
# the sandbox with only GitHub's default labels. So: cd into the sandbox AND
# pin PIPELINE_REPO / PIPELINE_PROJECT_ROOT / PIPELINE_BASE_BRANCH explicitly,
# in a subshell so the harness-side environment is left untouched. Idempotent —
# doctor seeds with `gh label create --force`.
seed_labels() {
  local doctor="$HARNESS/scripts/doctor.sh"
  if [ ! -f "$doctor" ]; then
    warn "no doctor.sh at $doctor — skipping label seed"
    return 0
  fi
  ( cd "$SANDBOX" \
    && PIPELINE_REPO="$CALIB_REPO" \
       PIPELINE_PROJECT_ROOT="$SANDBOX" \
       PIPELINE_BASE_BRANCH=main \
       bash "$doctor" --fix labels ) || return 1
  echo "calib: labels seeded on $CALIB_REPO"
}

cmd_bootstrap() {
  ensure_remote_repo          || return 1
  ensure_clone                || die_run "could not clone the sandbox into $SANDBOX"
  sync_template               || die_run "template sync failed"
  materialize_local_settings  || die_run "could not materialize the sandbox local-settings file"
  commit_sandbox              || die_run "sandbox commit failed"
  push_main                   || die_run "could not push the sandbox main branch"
  tag_base                    || die_run "could not anchor the $BASE_TAG tag"
  seed_labels                 || warn "label seed reported a failure"
  echo "calib: bootstrap complete — sandbox=$SANDBOX repo=$CALIB_REPO tag=$BASE_TAG"
}

# ---------------------------------------------------------------------------
# --reset
# ---------------------------------------------------------------------------

# guard_sandbox_repo — --reset force-pushes a branch back to a tag and DELETES
# issues. Aimed at the harness repo (one wrong char in PIPELINE_CALIB_REPO, or
# an unset knob inheriting a stale export) that is unrecoverable, so refuse on
# both readings of "this is not a sandbox": the repo the harness itself drives,
# and the slug of the checkout the driver is running in. The PIPELINE_REPO
# comparison comes FIRST so the common slip costs no network call at all.
guard_sandbox_repo() {
  local own
  if [ -n "${PIPELINE_REPO:-}" ] && [ "$CALIB_REPO" = "$PIPELINE_REPO" ]; then
    die_run "refusing to --reset $CALIB_REPO: it is PIPELINE_REPO — the calibration sandbox must never be the harness repo"
  fi
  own="$(dispatch gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$own" ] && [ "$CALIB_REPO" = "$own" ]; then
    die_run "refusing to --reset $CALIB_REPO: it is this checkout's own repo — the calibration sandbox must be a separate repo"
  fi
}

# slate_titles — the exact titles create_slate_issues() creates, one per line.
# This is the reap's scope (see below).
slate_titles() {
  local d
  [ -d "$SLATE_DIR" ] || return 0
  for d in "$SLATE_DIR"/*/; do
    [ -f "${d}title.txt" ] || continue
    head -1 "${d}title.txt"
  done
}

# reap_stale_issues — close+delete PRIOR RUNS' slate issues, and nothing else.
# Scoped by exact title match against the slate rather than by a `calib` label,
# so the sandbox needs no extra label seeded at create time; an issue a human
# (or the run under test) filed in the sandbox survives. `--limit 200` because
# `gh issue list` defaults to 30 — silent truncation would leave prior slates
# half-reaped and the next run reading two generations of issues.
reap_stale_issues() {
  local titles n t
  titles="$(slate_titles)"
  if [ -z "$titles" ]; then
    warn "no slate titles resolved from $SLATE_DIR — skipping the issue reap"
    return 0
  fi
  while IFS="$(printf '\t')" read -r n t; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$titles" | grep -qxF -- "$t" || continue
    dispatch gh issue close "$n" --repo "$CALIB_REPO" >/dev/null 2>&1
    dispatch gh issue delete "$n" --repo "$CALIB_REPO" --yes >/dev/null 2>&1
  done < <(dispatch gh issue list --repo "$CALIB_REPO" --state all --limit 200 \
             --json number,title --jq '.[] | [.number, .title] | @tsv' 2>/dev/null)
}

create_slate_issues() {
  local d url n ids=""
  SLATE_DIRS=()
  [ -d "$SLATE_DIR" ] || die_run "no calibration slate at $SLATE_DIR"
  for d in "$SLATE_DIR"/*/; do
    d="${d%/}"
    [ -f "$d/title.txt" ] || continue
    url="$(dispatch gh issue create --repo "$CALIB_REPO" \
             --title "$(cat "$d/title.txt")" --body-file "$d/body.md")"
    n="${url##*/}"
    n="${n%$'\r'}"
    case "$n" in
      ''|*[!0-9]*) warn "unparsable issue url for $d: $url"; continue ;;
    esac
    ids="$ids $n"
    SLATE_DIRS+=("$d")
  done
  ISSUE_IDS="${ids# }"
  [ -n "$ISSUE_IDS" ] || die_run "no slate issues were created from $SLATE_DIR"
  printf 'CALIB-ISSUES %s\n' "$ISSUE_IDS"
}

cmd_reset() {
  guard_sandbox_repo
  [ -d "$SANDBOX/.git" ] || die_run "sandbox is not bootstrapped at $SANDBOX (run --bootstrap first)"
  dispatch git -C "$SANDBOX" fetch --quiet --tags origin || warn "sandbox fetch failed — resetting against the local $BASE_TAG"
  git -C "$SANDBOX" rev-parse -q --verify "refs/tags/$BASE_TAG" >/dev/null 2>&1 \
    || die_run "$BASE_TAG does not exist in $SANDBOX (run --bootstrap first)"
  git -C "$SANDBOX" checkout --quiet -B main "$BASE_TAG" || die_run "could not check out main at $BASE_TAG"
  git -C "$SANDBOX" reset --hard --quiet "$BASE_TAG" || die_run "could not reset the sandbox to $BASE_TAG"
  dispatch git -C "$SANDBOX" push --quiet --force-with-lease origin main \
    || die_run "could not force the sandbox main branch back to $BASE_TAG"
  reap_stale_issues
  create_slate_issues
}

# ---------------------------------------------------------------------------
# --run harness staging
# ---------------------------------------------------------------------------

# stage_harness — materialize the harness under the calib dir as a DETACHED
# worktree at the harness's current HEAD, so the sandbox session can actually
# read the plugin tree it is measuring (see needs_staging).
#
# A worktree rather than a copy: it shares the harness's object store, so the
# refresh is one `checkout --force --detach` and the stage can never drift into
# a stale copy of something. Consequence, and it is the point: UNCOMMITTED
# harness edits are NOT under test — commit first.
#
# Called by --run only. --dry-run computes the staged PATH (LAUNCH_HARNESS
# above) but creates nothing; --bootstrap / --reset never launch a session.
stage_harness() {
  needs_staging || return 0
  local sha stage_common harness_common
  sha="$(git -C "$HARNESS" rev-parse HEAD 2>/dev/null)"
  [ -n "$sha" ] || die_run "harness staging needs --harness to be a git checkout: $HARNESS"
  git -C "$HARNESS" worktree prune 2>/dev/null
  if [ -e "$STAGE_DIR/.git" ]; then
    # Adopt an existing checkout ONLY if it is a worktree of this same clone
    # (the operator may already have made one by hand at this path). Anything
    # else is somebody's repo: refuse by name, never rm -rf.
    stage_common="$( cd "$STAGE_DIR" 2>/dev/null && abs_path "$(git rev-parse --git-common-dir 2>/dev/null)" )"
    harness_common="$( cd "$HARNESS" 2>/dev/null && abs_path "$(git rev-parse --git-common-dir 2>/dev/null)" )"
    if [ -z "$stage_common" ] || [ "$stage_common" != "$harness_common" ]; then
      die_run "$STAGE_DIR is a checkout of a different repo — remove it and re-run"
    fi
    git -C "$STAGE_DIR" checkout --quiet --force --detach "$sha" \
      || die_run "could not refresh the staged harness at $STAGE_DIR"
  elif [ -d "$STAGE_DIR" ] && [ -n "$(ls -A "$STAGE_DIR" 2>/dev/null)" ]; then
    die_run "$STAGE_DIR exists and is not a git checkout — remove it and re-run"
  else
    mkdir -p "$(dirname "$STAGE_DIR")" || die_run "could not create $(dirname "$STAGE_DIR")"
    git -C "$HARNESS" worktree add --quiet --detach "$STAGE_DIR" "$sha" \
      || die_run "could not stage the harness worktree at $STAGE_DIR"
  fi
  # pipeline.config is gitignored and host-specific, so no checkout carries it.
  # Without this copy the staged harness runs with no config at all.
  [ -f "$HARNESS/pipeline.config" ] && cp -f "$HARNESS/pipeline.config" "$STAGE_DIR/"
  echo "calib: staged harness $sha at $STAGE_DIR"
}

# ---------------------------------------------------------------------------
# --run reporting helpers
# ---------------------------------------------------------------------------

CAPTURE_LOG=""
RUN_LOG=""
RUN_RC=0
ABORT_REASON=""
ROWS_JSON=""
PRICING_TOTAL=""
PRS_JSON=""
MERGED_JSON=""
ISSUE_JSON="{}"
ISSUE_JSON_FOR=""

load_run_substrate() {
  CAPTURE_LOG="$SANDBOX/.claude/logs/agent-costs.jsonl"
  local clr="$HARNESS/scripts/cost-latency-report.sh"
  ROWS_JSON="[]"
  PRICING_TOTAL=""
  if [ -f "$clr" ]; then
    # SCOPING IS LOAD-BEARING (#1280): cost-latency-report.sh joins merged PRs
    # against issue numbers and reads PIPELINE_REPO to know whose PRs. Run from
    # the harness it would either error out (`ROWS_JSON=[]`) or join the
    # HARNESS's PRs against sandbox issue ids — silently wrong rows. Pin both
    # the repo and the cwd, in a subshell so the harness-side env is untouched.
    ROWS_JSON="$( cd "$SANDBOX" 2>/dev/null && PIPELINE_REPO="$CALIB_REPO" \
      bash "$clr" --emit-rows-json --capture-log "$CAPTURE_LOG" 2>/dev/null )"
    [ -n "$ROWS_JSON" ] || ROWS_JSON="[]"
    PRICING_TOTAL="$( cd "$SANDBOX" 2>/dev/null && PIPELINE_REPO="$CALIB_REPO" \
      bash "$clr" --emit-pricing-json --capture-log "$CAPTURE_LOG" 2>/dev/null \
      | jq -r '.priced_cost_usd // empty' 2>/dev/null )"
  fi
  # ONE PR fetch for the whole run. `--state all` because "this run opened no
  # PR at all" is a distinct, load-bearing observation (see the abort detector)
  # that a merged-only query cannot make; the merged subset is taken locally.
  # mergedAt carries both the merged filter and each issue's wall-clock end;
  # comments carry the PR-eval verdict — so no second round trip per PR.
  PRS_JSON="$(dispatch gh pr list --repo "$CALIB_REPO" --state all --limit 50 \
    --json number,body,headRefName,files,mergedAt,comments 2>/dev/null)"
  [ -n "$PRS_JSON" ] || PRS_JSON="[]"
  MERGED_JSON="$(printf '%s' "$PRS_JSON" | jq -c '[.[] | select(.mergedAt != null)]' 2>/dev/null)"
  [ -n "$MERGED_JSON" ] || MERGED_JSON="[]"
}

# load_issue_json <issue> — ONE `gh issue view` per issue, cached and fetched
# WITHOUT --jq so all three readers below (path, wall, verdicts) share it.
# emit_calib_block calls this from its loop body, not the readers alone: each
# reader runs inside a command substitution, so a cache filled there would die
# with the subshell and take the one-fetch-per-issue property with it.
load_issue_json() {
  local issue="$1"
  [ "$ISSUE_JSON_FOR" = "$issue" ] && return 0
  ISSUE_JSON="$(dispatch gh issue view "$issue" --repo "$CALIB_REPO" \
    --json comments,createdAt 2>/dev/null)"
  [ -n "$ISSUE_JSON" ] || ISSUE_JSON="{}"
  ISSUE_JSON_FOR="$issue"
}

# merged_pr_field <issue> <field> — <field> of the FIRST merged PR whose body
# references #<issue>, else empty.
merged_pr_field() {
  printf '%s' "$MERGED_JSON" | jq -r --arg n "$1" --arg f "$2" \
    '[.[] | select((.body // "") | test("#" + $n + "\\b"))] | first // {} | .[$f] // empty' 2>/dev/null
}

# detect_abort — did the run FAIL TO START (or fail to finish) rather than do
# the work badly? Sets ABORT_REASON, empty when the run really ran.
#
# Both observed failures graded as regressions instead of aborts: run #1's
# session ended on a question nobody answered and pushed nothing (`0/5`), run
# #2 merged wave 1 and then stopped to ask about the rest (`3/5`). A slate
# score is only meaningful for work the harness actually attempted.
#
# Precedence, most specific first:
#   timeout  the launch hit the cap (rc 124) — it was still working
#   held     the session's last non-blank line ends on `?`; a `-p` session that
#            stops to ask ends its final message on the question, and nobody is
#            there to answer. A heuristic: a run that stops on a statement
#            falls through to no-pr or grades normally.
#   no-pr    the run opened no PR AT ALL (any state) — nothing to grade
detect_abort() {
  local last n
  ABORT_REASON=""
  if [ "${RUN_RC:-0}" -eq 124 ]; then ABORT_REASON="timeout"; return 0; fi
  last="$(sed -e 's/[[:space:]]*$//' "$RUN_LOG" 2>/dev/null | grep -v '^$' | tail -1)"
  case "$last" in
    *\?) ABORT_REASON="held"; return 0 ;;
  esac
  n="$(printf '%s' "$PRS_JSON" | jq -r 'length' 2>/dev/null)"
  case "$n" in
    ''|0) ABORT_REASON="no-pr" ;;
  esac
}

# row_field <issue> <jq field> — echoes the rows-JSON field or empty.
row_field() {
  printf '%s' "$ROWS_JSON" | jq -r --argjson i "$1" \
    "[.[] | select(.issue == \$i) | .$2] | first // empty" 2>/dev/null
}

# issue_cost <issue> — per-issue $ is APPORTIONED: the rows JSON carries no
# per-issue cost (see run-retro.sh's `no per-issue cost in rows JSON`), so the
# priced total is split by each issue's token share. Echoes empty when the
# capture log is absent.
issue_cost() {
  local issue="$1" tok sum
  [ -n "$PRICING_TOTAL" ] || return 0
  tok="$(row_field "$issue" tokens_total)"
  sum="$(printf '%s' "$ROWS_JSON" | jq -r '[.[].tokens_total | select(. != null)] | add // 0' 2>/dev/null)"
  case "$tok" in ''|null) return 0 ;; esac
  [ "${sum:-0}" != "0" ] || return 0
  awk -v t="$tok" -v s="$sum" -v p="$PRICING_TOTAL" 'BEGIN{ printf "%.2f", p * t / s }'
}

# issue_wall <issue> — the issue's WALL-CLOCK span: from its own createdAt to
# the mergedAt of the first merged PR that references it. Not the rows JSON's
# duration_ms, which is the capture log's agent time (one run #2 issue read
# `wall=60` for half an hour of clock). Degrades to empty -> `n/a` when the
# issue never merged, or when `date -d` is not GNU coreutils; never errors.
issue_wall() {
  local issue="$1" created merged t0 t1
  load_issue_json "$issue"
  created="$(printf '%s' "$ISSUE_JSON" | jq -r '.createdAt // empty' 2>/dev/null)"
  merged="$(merged_pr_field "$issue" mergedAt)"
  [ -n "$created" ] && [ -n "$merged" ] || return 0
  t0="$(date -u -d "$created" +%s 2>/dev/null)" || return 0
  t1="$(date -u -d "$merged" +%s 2>/dev/null)" || return 0
  case "$t0" in ''|*[!0-9]*) return 0 ;; esac
  case "$t1" in ''|*[!0-9]*) return 0 ;; esac
  awk -v a="$t0" -v b="$t1" 'BEGIN{ printf "%d", b - a }'
}

# issue_verdicts <issue> — `<plan-eval>/<pr-eval>`, each `n/a` when absent.
# Both halves are reduced locally: the plan half from the cached issue blob,
# the PR half from the merging PR's own comments inside the single PR fetch.
issue_verdicts() {
  local issue="$1" plan pr
  load_issue_json "$issue"
  plan="$(printf '%s' "$ISSUE_JSON" | jq -r \
    '[(.comments // [])[] | .body // "" | capture("Verdict:\\*\\*\\s*(?<v>[A-Za-z-]+)"; "g").v] | last // empty' 2>/dev/null)"
  pr="$(printf '%s' "$MERGED_JSON" | jq -r --arg n "$issue" \
    '[.[] | select((.body // "") | test("#" + $n + "\\b"))] | first // {}
     | [(.comments // [])[] | .body // "" | capture("Verdict:\\*\\*\\s*(?<v>[A-Za-z-]+)"; "g").v] | last // empty' 2>/dev/null)"
  printf '%s/%s' "${plan:-n/a}" "${pr:-n/a}"
}

# issue_path <issue> — the path the harness ACTUALLY routed the issue down,
# read from the `## Classification` comment the classifier posts on the issue
# (`recommended_path:`, last comment wins), else `?`.
#
# NOT the rows JSON and NOT the issue's labels — both are the same source, and
# it lies: post-merge an issue's labels are just `merged`, so the label mapping
# defaults everything to `B` (run #2 graded a docs-only issue `path=B` that
# way). NOT a slate-declared expectation either: `path=` is an OBSERVATION of
# the run under test, and a slate `path.txt` would report the routing we hoped
# for even when the harness misrouted — exactly the regression the calibration
# slate exists to catch. `?` therefore means "this run never classified the
# issue" and is a real signal.
issue_path() {
  local issue="$1" p
  load_issue_json "$issue"
  p="$(printf '%s' "$ISSUE_JSON" | jq -r \
    '[(.comments // [])[] | .body // "" | capture("recommended_path:\\*\\*\\s*(?<p>[ABCD])"; "g").p] | last // empty' 2>/dev/null)"
  case "$p" in
    A|B|C|D) printf '%s' "$p" ;;
    *)       printf '?' ;;
  esac
}

# issue_reftest <slate dir> — runs the slate's reference test IN THE SANDBOX.
issue_reftest() {
  local d="$1"
  [ -f "$d/reference-test.sh" ] || { printf 'n/a'; return 0; }
  if ( cd "$SANDBOX" && bash "$d/reference-test.sh" >/dev/null 2>&1 ); then
    printf 'pass'
  else
    printf 'fail'
  fi
}

# issue_unexpected <issue> <slate dir> — merged-PR files MINUS expected-files.txt.
issue_unexpected() {
  local issue="$1" d="$2" expected="$2/expected-files.txt" files f n=0
  files="$(printf '%s' "$MERGED_JSON" | jq -r --arg n "$issue" \
    '[.[] | select((.body // "") | test("#" + $n + "\\b")) | .files[]?.path] | .[]' 2>/dev/null)"
  [ -n "$files" ] || { printf '0'; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$expected" ] && grep -qxF -- "$f" "$expected"; then continue; fi
    n=$((n + 1))
  done <<< "$files"
  printf '%s' "$n"
}

emit_calib_block() {
  local wall_total="$1"
  local i=0 issue d path cost wall verdicts reftest unexpected
  local total_cost=0 pass=0 count=0
  load_run_substrate
  detect_abort
  if [ -n "$ABORT_REASON" ]; then
    printf 'CALIB-ABORT reason=%s\n' "$ABORT_REASON"
  fi
  for issue in $ISSUE_IDS; do
    d="${SLATE_DIRS[$i]:-}"
    i=$((i + 1)); count=$((count + 1))
    load_issue_json "$issue"   # once per issue, in THIS shell (see the cache note)
    path="$(issue_path "$issue")"
    [ -n "$path" ] || path="?"
    cost="$(issue_cost "$issue")"
    wall="$(issue_wall "$issue")"
    verdicts="$(issue_verdicts "$issue")"
    # On an aborted run the reference test is only meaningful for an issue the
    # harness actually merged. For the rest it would grade the untouched
    # sandbox and report `fail` — a regression the run never got near.
    if [ -n "$ABORT_REASON" ] && [ -z "$(merged_pr_field "$issue" mergedAt)" ]; then
      reftest="n/a"
    else
      reftest="$(issue_reftest "$d")"
    fi
    unexpected="$(issue_unexpected "$issue" "$d")"
    [ "$reftest" = "pass" ] && pass=$((pass + 1))
    if [ -n "$cost" ]; then
      total_cost="$(awk -v a="$total_cost" -v b="$cost" 'BEGIN{ printf "%.2f", a + b }')"
    fi
    printf 'CALIB issue=%s path=%s cost=$%s wall=%s verdicts=%s reftest=%s unexpected-files=%s\n' \
      "$issue" "$path" "${cost:-n/a}" "${wall:-n/a}" "$verdicts" "$reftest" "$unexpected"
  done
  if [ -z "$ABORT_REASON" ]; then
    printf 'CALIB-TOTAL cost=$%s wall=%s issues=%s reftest-pass=%s/%s\n' \
      "$total_cost" "$wall_total" "$count" "$pass" "$count"
  else
    # No k/n for an aborted run, in either direction: `0/5` reads as a total
    # regression and `3/5` as a partial one, when the denominator was never
    # attempted. run-retro.sh renders this as the abort reason.
    printf 'CALIB-TOTAL cost=$%s wall=%s issues=%s reftest-pass=%s\n' \
      "$total_cost" "$wall_total" "$count" "n/a"
  fi
}

# sync_sandbox_after_run — the pipeline merges its PRs on the REMOTE, while
# --reset left THIS clone hard-reset to $BASE_TAG. Without pulling the merged
# tree back, every reference test below grades the unfixed sandbox and --run
# reports `reftest-pass=0/<n>` no matter how well the run went. Routed through
# dispatch() like every other network call so the seam stays honest.
sync_sandbox_after_run() {
  dispatch git -C "$SANDBOX" fetch --quiet origin main \
    || { warn "post-run fetch failed — reference tests will grade the pre-run tree"; return 0; }
  dispatch git -C "$SANDBOX" reset --hard --quiet origin/main \
    || warn "post-run reset failed — reference tests will grade the pre-run tree"
}

cmd_run() {
  cmd_reset || return 1
  stage_harness
  build_launch
  local t0 t1
  # Harness-rooted ABSOLUTE output paths: --run executes with the SANDBOX as
  # cwd. The dir is created BEFORE the launch because the session log is tee'd
  # as the run happens — it is the only evidence of what a run that stopped to
  # ask a question actually said, and detect_abort reads its last line.
  # TRUNCATING, not appending: one artifact per UTC day, last run wins.
  # run-retro.sh's compute_calib() sums the `reftest=` atoms of EVERY CALIB
  # line in the newest artifact, so two same-day runs appended to one file
  # double-count (5/5 -> 10/10). run-retro.sh picks the newest artifact by
  # FILENAME, which this <date>.txt name keeps stable across the rewrite; the
  # <date>.log beside it follows the same day-keyed rule.
  mkdir -p "$CALIB_OUT_DIR" 2>/dev/null
  RUN_LOG="$CALIB_OUT_DIR/$(date -u +%Y-%m-%d).log"
  t0="$(date +%s)"
  ( cd "$SANDBOX" && dispatch "${LAUNCH[@]}" ) 2>&1 | tee "$RUN_LOG"
  RUN_RC=${PIPESTATUS[0]}
  t1="$(date +%s)"
  [ "$RUN_RC" -eq 0 ] || warn "headless run exited $RUN_RC (124 = hit the ${CALIB_TIMEOUT}s cap) — summarizing anyway"
  sync_sandbox_after_run
  emit_calib_block "$((t1 - t0))" | tee "$CALIB_OUT_DIR/$(date -u +%Y-%m-%d).txt"
}

# ---------------------------------------------------------------------------
# Mode dispatch
# ---------------------------------------------------------------------------

case "$MODE" in
  dry-run)
    build_launch
    dispatch "${LAUNCH[@]}"   # DRY=1 -> exactly one CALIB-LAUNCH preview line
    exit 0
    ;;
  bootstrap) cmd_bootstrap ;;
  reset)     cmd_reset ;;
  run)       cmd_run ;;
esac
