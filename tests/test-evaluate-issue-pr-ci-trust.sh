#!/usr/bin/env bash
# Regression guard for issue #957: evaluate-issue-pr must trust a green CI
# statusCheckRollup and skip the full local PIPELINE_TEST_CMD re-run, while still
# running tests locally (scoped to touched tests) when CI is absent/red/disabled,
# and never overlapping/duplicating the full-suite sweep.
set -euo pipefail
cd "$(dirname "$0")/.."

SKILL="skills/evaluate-issue-pr/SKILL.md"
[ -f "$SKILL" ] || { echo "missing $SKILL"; exit 1; }

# (a) green-CI short-circuit: a green statusCheckRollup ⇒ skip the full PIPELINE_TEST_CMD re-run.
grep -q "statusCheckRollup" "$SKILL" \
  || { echo "FAIL(a): $SKILL missing statusCheckRollup short-circuit reference"; exit 1; }
grep -Eq "green[ -]rollup|green CI rollup|green rollup" "$SKILL" \
  || { echo "FAIL(a): $SKILL missing green-rollup short-circuit phrase"; exit 1; }
grep -Eq "skip(ping)? (the )?full.*PIPELINE_TEST_CMD" "$SKILL" \
  || { echo "FAIL(a): $SKILL missing skip-full-PIPELINE_TEST_CMD-re-run directive"; exit 1; }

# (b) fallback: CI absent/red/PIPELINE_CI_CHECK_ENABLED disabled ⇒ tests still run locally.
grep -q "PIPELINE_CI_CHECK_ENABLED" "$SKILL" \
  || { echo "FAIL(b): $SKILL missing PIPELINE_CI_CHECK_ENABLED gate reference"; exit 1; }
grep -Eq "run tests locally|tests (still )?run locally|run (the )?tests locally" "$SKILL" \
  || { echo "FAIL(b): $SKILL missing non-green/absent-CI run-tests-locally fallback phrase"; exit 1; }

# (c) the fallback is scoped to touched tests, not the whole suite.
grep -Eq "touched test" "$SKILL" \
  || { echo "FAIL(c): $SKILL missing scoped-to-touched-tests fallback phrase"; exit 1; }

# (d) dedup guard: the full-suite sweep runs at most once, never via run_in_background.
grep -Eq "at most once|at-most-once|once per eval" "$SKILL" \
  || { echo "FAIL(d): $SKILL missing at-most-once full-suite directive"; exit 1; }
grep -Eq "overlapping (full-suite )?sweep|duplicate sweep|run_in_background" "$SKILL" \
  || { echo "FAIL(d): $SKILL missing no-overlapping-sweep / never-run_in_background directive"; exit 1; }

# (e) pipeline.config.example (and the gitignored pipeline.config, dual-scan per CLAUDE.md
#     config-convention contract) carry the PIPELINE_CI_CHECK_ENABLED line. The green-CI
#     short-circuit comment is enforced strictly on the canonical tracked example only; the
#     gitignored host pipeline.config needs only the line, since its inline comment is patched
#     by hand on the operator's host and may legitimately lag the example (issue #1002).
for cfg in pipeline.config.example pipeline.config; do
  [ -f "$cfg" ] || continue
  ci_line=$(grep -n "PIPELINE_CI_CHECK_ENABLED" "$cfg" | head -1 | cut -d: -f1 || true)
  [ -n "$ci_line" ] || { echo "FAIL(e): $cfg missing PIPELINE_CI_CHECK_ENABLED line"; exit 1; }
  if [ "$cfg" = "pipeline.config.example" ]; then
    grep -Eq "short-circuit|short circuit|skip.*full.*re-run|trust.*green" "$cfg" \
      || { echo "FAIL(e): $cfg PIPELINE_CI_CHECK_ENABLED comment missing green-CI short-circuit note"; exit 1; }
  fi
done

echo "ok"
