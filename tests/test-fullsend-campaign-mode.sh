#!/usr/bin/env bash
set -euo pipefail

# Regression guard for issue #835: skills/fullsend/SKILL.md must document the
# `--campaign` mode — an OUTER coordinated-leg loop ABOVE the existing
# wave-by-wave Steps 5-7. The mode classifies/plans/eval-plans the ENTIRE set
# batched-under-caps, approves all up front, partitions into legs via
# scripts/plan-campaign.sh, then runs each leg through the existing
# execute -> 6b -> eval-pr -> greenlight -> base-advance machinery, end-of-leg
# bug filing, and a scoped halt (dependency closure dropped from later legs).
#
# Pure model-facing prose, so this is a phrase-presence guard (mirrors
# tests/test-fullsend-spawn-flag.sh and tests/test-full-send-wave-step.sh):
# `grep -qiF` phrase assertions with a `fail` accumulator, awk-block-scoped to
# the new `## Campaign mode` section where leg-loop ordering matters.

FILE="$(dirname "$0")/../skills/fullsend/SKILL.md"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found" >&2
  exit 1
fi

fail=0
assert_has() { grep -qiF "$1" "$FILE" || { echo "MISSING: $1"; fail=1; }; }

# (1) argv shape gains --campaign (composes with --manual-merge / --spawn).
assert_has "[issue_numbers...] [--manual-merge] [--spawn] [--campaign]"

# (2) the new section heading exists.
assert_has "## Campaign mode"

# Block-scope the rest to the Campaign mode section: starts at the
# "## Campaign mode" heading, ends at the next H2 heading.
camp="$(awk '/^## Campaign mode/{f=1; print; next} /^## /{f=0} f' "$FILE")"
if [ -z "$camp" ]; then
  echo "VIOLATION: could not locate '## Campaign mode' section"; fail=1
fi
assert_camp() {
  printf '%s' "$camp" | grep -qiF "$1" || { echo "MISSING (Campaign mode): $1"; fail=1; }
}

# (3) OUTER loop above the existing wave-by-wave steps; does NOT replace them.
assert_camp "outer"
assert_camp "does not replace"

# (4) the partitioner + its cap env vars.
assert_camp "plan-campaign.sh"
assert_camp "PIPELINE_CAMPAIGN_MAX_BC"
assert_camp "PIPELINE_CAMPAIGN_MAX_AD"

# (5) classify + plan are batched-under-caps (no flat parallel blast of the
#     whole read-only set — the rate-limit budget is GLOBAL).
assert_camp "batched"
printf '%s' "$camp" | grep -qiE 'classify' || { echo "MISSING (Campaign mode): classify"; fail=1; }
printf '%s' "$camp" | grep -qiE 'plan'     || { echo "MISSING (Campaign mode): plan"; fail=1; }

# (6) leg-loop ORDER tokens, in order: execute -> eval-pr -> greenlight ->
#     base advance -> bug filing. Assert each token is present AND the ordinal
#     positions are monotonically non-decreasing.
camp_lc="$(printf '%s' "$camp" | tr '[:upper:]' '[:lower:]')"
ord_execute=$(printf '%s' "$camp_lc" | grep -n "execute" | head -1 | cut -d: -f1)
ord_evalpr=$(printf '%s'  "$camp_lc" | grep -n "eval-pr" | head -1 | cut -d: -f1)
ord_green=$(printf '%s'   "$camp_lc" | grep -n "greenlight" | head -1 | cut -d: -f1)
ord_base=$(printf '%s'    "$camp_lc" | grep -n "base advance" | head -1 | cut -d: -f1)
ord_bug=$(printf '%s'     "$camp_lc" | grep -n "bug filing" | head -1 | cut -d: -f1)
for tok in execute:ord_execute eval-pr:ord_evalpr greenlight:ord_green \
           "base advance:ord_base" "bug filing:ord_bug"; do
  name="${tok%%:*}"; var="${tok##*:}"
  if [ -z "${!var:-}" ]; then echo "MISSING (Campaign mode leg-loop): $name"; fail=1; fi
done
if [ -n "${ord_execute:-}" ] && [ -n "${ord_evalpr:-}" ] && [ -n "${ord_green:-}" ] \
   && [ -n "${ord_base:-}" ] && [ -n "${ord_bug:-}" ]; then
  if ! { [ "$ord_execute" -le "$ord_evalpr" ] && [ "$ord_evalpr" -le "$ord_green" ] \
         && [ "$ord_green" -le "$ord_base" ] && [ "$ord_base" -le "$ord_bug" ]; }; then
    echo "VIOLATION: leg-loop order not execute -> eval-pr -> greenlight -> base advance -> bug filing"
    fail=1
  fi
fi

# (7) end-of-leg bug filing dedups against open issues + the campaign-filed set.
printf '%s' "$camp" | grep -qiE 'dedups?' || { echo "MISSING (Campaign mode): dedup/dedups"; fail=1; }

# (8) scoped halt computes a dependency closure (via plan-campaign.sh closure).
assert_camp "closure"

if [ "$fail" -eq 0 ]; then
  echo "PASS: fullsend --campaign mode phrases present"
else
  exit 1
fi
