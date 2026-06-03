#!/usr/bin/env bash
set -euo pipefail

# Regression guard for issue #904: a standalone /pipeline:campaign skill must
# exist as a THIN entry point that runs the coordinated-leg OUTER loop by
# DEFERRING to fullsend's canonical `## Campaign mode` machinery — there must be
# exactly ONE copy of the leg-loop prose (single source of truth), so the two
# entry points (`/pipeline:campaign` and `/pipeline:fullsend --campaign`) can
# never drift. This guard asserts:
#   (1) skills/campaign/SKILL.md exists with `name: campaign` frontmatter;
#   (2) the campaign skill routes into the SAME machinery (references
#       skills/fullsend/SKILL.md AND `## Campaign mode` AND plan-campaign.sh);
#   (3) single-source-of-truth: the campaign skill does NOT re-embed the
#       verbatim leg-ordering sentence — that sentence appears in fullsend but
#       NOT in the campaign skill;
#   (4) fullsend still advertises `--campaign` (NOT deprecated) in its argv
#       shape line AND now names `/pipeline:campaign` as an equivalent entry.
#
# Phrase-presence guard (mirrors tests/test-fullsend-campaign-mode.sh /
# tests/test-fullsend-skill-extraction.sh): `grep -qiF` assertions with a `fail`
# accumulator.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAMP="$ROOT/skills/campaign/SKILL.md"
FS="$ROOT/skills/fullsend/SKILL.md"

fail=0

# (1) campaign skill file exists with `name: campaign` frontmatter.
if [ -f "$CAMP" ]; then
  echo "  PASS: skills/campaign/SKILL.md exists"
else
  echo "  FAIL: skills/campaign/SKILL.md not found"; fail=1
fi
if [ -f "$CAMP" ] && grep -qE '^name:[[:space:]]*campaign$' "$CAMP"; then
  echo "  PASS: campaign skill frontmatter declares name: campaign"
else
  echo "  FAIL: campaign skill frontmatter missing 'name: campaign'"; fail=1
fi

assert_camp() {
  if [ -f "$CAMP" ] && grep -qiF "$1" "$CAMP"; then
    echo "  PASS: campaign skill references '$1'"
  else
    echo "  FAIL: campaign skill missing reference '$1'"; fail=1
  fi
}

# (2) routes into the SAME machinery (canonical source, not a copy).
assert_camp "skills/fullsend/SKILL.md"
assert_camp "## Campaign mode"
assert_camp "plan-campaign.sh"
# Carries the cap contracts BY REFERENCE.
assert_camp "PIPELINE_CAMPAIGN_MAX_BC"
assert_camp "PIPELINE_CAMPAIGN_MAX_AD"

# (3) single-source-of-truth: the verbatim leg-ordering sentence appears in
#     fullsend but NOT in the campaign skill (no forked leg-loop prose).
LEG_SENTENCE='execute → 6b → eval-pr → greenlight-merge'
if grep -qF "$LEG_SENTENCE" "$FS"; then
  echo "  PASS: leg-ordering sentence present in fullsend (canonical home)"
else
  echo "  FAIL: leg-ordering sentence absent from fullsend: $LEG_SENTENCE"; fail=1
fi
if [ -f "$CAMP" ] && grep -qF "$LEG_SENTENCE" "$CAMP"; then
  echo "  FAIL: campaign skill RE-EMBEDS the leg-ordering sentence (forked prose)"; fail=1
else
  echo "  PASS: campaign skill does NOT re-embed the leg-ordering sentence (SSoT)"
fi

# (4) fullsend still advertises --campaign (not deprecated) AND names
#     /pipeline:campaign as an equivalent entry.
if grep -qF "[issue_numbers...] [--manual-merge] [--spawn] [--campaign]" "$FS"; then
  echo "  PASS: fullsend still advertises --campaign in argv shape (not deprecated)"
else
  echo "  FAIL: fullsend argv shape no longer advertises --campaign"; fail=1
fi
if grep -qiF "/pipeline:campaign" "$FS"; then
  echo "  PASS: fullsend names /pipeline:campaign as equivalent entry"
else
  echo "  FAIL: fullsend does not mention /pipeline:campaign equivalent entry"; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: /pipeline:campaign and fullsend --campaign share one machinery"
else
  echo "FAILED: campaign-skill entry-points contract not met"
  exit 1
fi
