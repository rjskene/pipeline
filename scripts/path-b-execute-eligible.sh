#!/usr/bin/env bash
# PATH B Sonnet-execute eligibility predicate (issue #955).
#
# Dispatch-time blast-radius ESTIMATE that gates the PATH B Sonnet execute
# downshift (PIPELINE_PATH_B_MODEL_EXECUTE) to the #950 §4 low-blast lane —
# moving that gate from prose (docs/analysis/model-downsampling.md §4) into the
# dispatch path. Emits exactly one machine-readable line on stdout:
#
#   ELIGIBLE=<low-blast|high-blast> ISSUE=<N> REASON=<token>
#
# REASON tokens:
#   low-blast:  single-module
#   high-blast: multi-module | too-many-files | loc-over | high-uncertainty
#               | needs-browser | indeterminate
#
# The token carries the verdict; the script exits 0 in EVERY case (mirrors
# scripts/check-ci-fix-loop.sh / scripts/verify-execute-completion.sh). The
# caller (skills/fullsend) parses ELIGIBLE= and passes model= to the PATH B
# execute Agent ONLY when ELIGIBLE=low-blast.
#
# The #950 §4 four-part low-blast gate (ALL must hold for low-blast):
#   1. ≤1 source MODULE (excl tests/docs)   — single-module=true
#   2. ≤6 source files                       — SRC_COUNT ceiling
#   3. ≤150 added-LOC (a pre-execute ESTIMATE — PROXY, never a measured diff)
#   4. no security/migration/auth/concurrency signal
# ANY failure ⇒ high-blast (fail-closed to Opus — never downshift on
# uncertain blast-radius).
#
# Added-LOC is a PROXY, NOT a real diff: at dispatch time (classify/plan-time)
# there is no diff, mirroring classify-issue's "LOC is a retrospective
# validation signal only, never a classify-time input." The 150-LOC ceiling is
# treated as SATISFIED-BY-PROXY when the file/module bounds hold, with an
# explicit `~N LOC` body token as an override that can force high-blast.
#
# Module count, NOT file count, is the low-blast axis (evaluator rec #1): the
# low-blast criterion is single-module (≤1 source module) AND files ≤6. A
# legitimate single-module 2-6-file change IS low-blast.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <issue-number>" >&2
  exit 2
fi

N="$1"
REPO="${PIPELINE_REPO:-}"

emit() {
  # emit <low-blast|high-blast> <reason>
  echo "ELIGIBLE=$1 ISSUE=$N REASON=$2"
  exit 0
}

# --- Fetch issue (fail-closed on any gh/parse failure) ----------------------
RAW="$(gh issue view "$N" --repo "$REPO" --json title,body,labels 2>/dev/null)" || emit high-blast indeterminate
[ -n "$RAW" ] || emit high-blast indeterminate

TITLE="$(printf '%s' "$RAW" | jq -r '.title // ""' 2>/dev/null)" || emit high-blast indeterminate
BODY="$(printf '%s' "$RAW" | jq -r '.body // ""' 2>/dev/null)" || emit high-blast indeterminate
LABELS="$(printf '%s' "$RAW" | jq -r '[.labels[].name] | join(" ")' 2>/dev/null)" || LABELS=""

# --- Browser/UI carve-out (issue #960) --------------------------------------
# needs-browser / web-eval / playwright signals force high-blast: the #950
# Sonnet-on-execute pilot validated SHELL-helper fixtures only and said "do not
# widen ... without a separate pilot." Browser/UI execute was never measured, so
# a needs-browser issue must stay on Opus for execute.
# Two split signals (issue #1063 — kill the prose-token false positive):
#   1. The `needs-browser` LABEL — the real signal. It is now LABEL-GATED: prose
#      mentions of the literal token `needs-browser` (e.g. a meta-issue body that
#      names the label) no longer match, because `needs-browser` is scanned ONLY
#      in the LABELS stream with a space-anchored regex. LABELS is built via
#      `jq '[.labels[].name] | join(" ")'`, so the space-anchor isolates the real
#      label from a join.
#   2. `web-eval`/`playwright` JARGON — distinctive enough to scan prose too, so
#      these stay matched across TITLE/BODY/LABELS (a `web-eval` LABEL still
#      matches via this jargon scan).
# The bare words `browser`/`visual` remain INTENTIONALLY excluded to avoid false
# positives on common prose (e.g. "visual diff", "browser tab").
# INTENTIONAL DIVERGENCE from classify-issue's high-uncertainty vocabulary:
# classify's carve-out gates B->D DOWN-routing (correctness uncertainty); this is
# a MODEL-TIER gate. Browser is added HERE only — adding it to classify would
# wrongly suppress legitimate B->D down-routing of browser fixes (issue #960).
# REASON stays `needs-browser` either way (downstream resolve-execute-dispatch.sh
# is unchanged).
NB_LABEL_RE='(^|[[:space:]])needs-browser([[:space:]]|$)'
BROWSER_JARGON_RE='web-eval|playwright'
if printf '%s' "$LABELS" | grep -iEq "$NB_LABEL_RE" \
   || printf '%s\n%s\n%s\n' "$TITLE" "$BODY" "$LABELS" | grep -iEq "$BROWSER_JARGON_RE"; then
  emit high-blast needs-browser
fi

# --- High-uncertainty carve-out (the protected axis) ------------------------
# REUSE classify-issue's exact vocabulary via the shared single source of truth
# scripts/_high-uncertainty-match.sh (issue #1039) so the carve-out can never
# drift from classify's protected axis — it is now structurally one pattern,
# word-bound on the three proven-noisy short tokens (auth/lock/race). Any hit ⇒
# high-blast regardless of file count (#950 §4 "no security/migration/auth/
# concurrency signal").
# shellcheck source=scripts/_high-uncertainty-match.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_high-uncertainty-match.sh"
if printf '%s\n%s\n%s\n' "$TITLE" "$BODY" "$LABELS" \
     | grep -iEq "$HIGH_UNCERTAINTY_RE"; then
  emit high-blast high-uncertainty
fi

# --- Source-file extraction (shared with plan-waves.sh, do NOT reinvent) ----
# The `## Affected areas` awk slice + FILE_PATH_RE + path-normalization/
# junk-rejection (#1230) are SOURCED from the shared helper (#1239) — this
# call site no longer carries its own copy, so it inherits normalization
# (`plan-issue/SKILL.md` <-> `skills/plan-issue/SKILL.md`) and junk-token
# rejection (`**RED/GREEN`, `rjskene/work-orchestrator`) for free.
# shellcheck source=scripts/_extract-body-paths.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_extract-body-paths.sh"

ALL_PATHS=$( { bp_body_paths "$BODY"; } || true)

# Empty Affected areas / no parseable paths ⇒ fail-closed (indeterminate).
if [ -z "$ALL_PATHS" ]; then
  emit high-blast indeterminate
fi

# Keep only non-test / non-doc SOURCE paths (the "excl tests/docs" clause):
# drop any path with a tests/, test/, fixtures/, or docs/ segment.
SRC_PATHS=$(printf '%s\n' "$ALL_PATHS" \
  | grep -Ev '(^|/)(tests?|fixtures|docs)/' || true)

if [ -z "$SRC_PATHS" ]; then
  # Only test/doc files in Affected areas — no source blast radius to size.
  emit high-blast indeterminate
fi

SRC_COUNT=$(printf '%s\n' "$SRC_PATHS" | grep -c .)

# MODULE = first path segment of each kept source path. single-module iff all
# kept source paths share one top-level segment.
MODULE_COUNT=$(printf '%s\n' "$SRC_PATHS" \
  | sed 's#/.*##' \
  | sort -u \
  | grep -c .)

# --- Decision (ALL must hold for low-blast) ---------------------------------
# 1. single-module: ≤1 source MODULE (the low-blast axis, evaluator rec #1).
if [ "$MODULE_COUNT" -gt 1 ]; then
  emit high-blast multi-module
fi

# 2. ≤6 source files (the §4 file ceiling — NOT the low-blast axis on its own).
if [ "$SRC_COUNT" -gt 6 ]; then
  emit high-blast too-many-files
fi

# 3. ≤150 added-LOC ESTIMATE: satisfied-by-PROXY from the file/module bounds
#    above, with an explicit `~N LOC` body token as an override that forces
#    high-blast when it says >150 (lower-bound wins on multiple matches).
LOC_TOKENS=$(printf '%s' "$BODY" \
  | grep -oiE '~?[0-9]+[[:space:]]*LOC' \
  | grep -oE '[0-9]+' || true)
if [ -n "$LOC_TOKENS" ]; then
  MIN_LOC=$(printf '%s\n' "$LOC_TOKENS" | sort -n | head -1)
  if [ "$MIN_LOC" -gt 150 ]; then
    emit high-blast loc-over
  fi
fi

# All four §4 criteria hold ⇒ low-blast.
emit low-blast single-module
