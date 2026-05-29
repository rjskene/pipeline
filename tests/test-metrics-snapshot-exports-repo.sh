#!/bin/bash
set -uo pipefail
#
# Regression guard for issue #638: scripts/metrics-snapshot.sh must EXPORT
# the variables it sources from pipeline.config so its sibling extractors
# (run as child processes) inherit PIPELINE_REPO.
#
# pipeline.config uses bare assignments (no `export`), so a plain `source`
# sets PIPELINE_REPO as a shell variable that is NOT exported to children.
# over-eval-report.sh / late-error-report.sh / compliance-backfill.sh each
# hard-require ${PIPELINE_REPO:-} from the ENVIRONMENT and abort (empty
# stdout) when it is unset, degrading the snapshot's fields to null.
#
# This test exercises the LIVE sibling-dispatch path (not --fixture, which
# bypasses the env-inheritance requirement). It works because the script
# computes REPO_ROOT from its own location, so copying it into a temp
# scripts/ dir redirects REPO_ROOT, the sourced pipeline.config, and all
# sibling paths into the temp tree. Hermetic: no network, no `gh`.
#

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_SCRIPT="$SELF_DIR/../scripts/metrics-snapshot.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/scripts"
cp "$REAL_SCRIPT" "$T/scripts/metrics-snapshot.sh"

# Bare assignment, mirroring the real pipeline.config (NO export).
cat > "$T/pipeline.config" <<'CFG'
PIPELINE_REPO="probe/repo"
CFG

# Stub siblings: emit valid JSON to stdout ONLY when PIPELINE_REPO is set in
# the environment, else marker to stderr + empty stdout (mirrors the real
# hard-require). All CLI args ignored.
cat > "$T/scripts/over-eval-report.sh" <<'STUB'
#!/bin/bash
if [ -n "${PIPELINE_REPO:-}" ]; then
  echo '[{"path":"C","loc":10,"plan":1,"plan_eval":"1","pr_eval":9,"pr_number":1}]'
else
  echo "over-eval-report: ERROR: PIPELINE_REPO not set" >&2
fi
STUB

cat > "$T/scripts/late-error-report.sh" <<'STUB'
#!/bin/bash
if [ -n "${PIPELINE_REPO:-}" ]; then
  echo '[{"stage":"plan"}]'
else
  echo "late-error-report: ERROR: PIPELINE_REPO not set" >&2
fi
STUB

cat > "$T/scripts/compliance-backfill.sh" <<'STUB'
#!/bin/bash
if [ -n "${PIPELINE_REPO:-}" ]; then
  echo '[{"verdict":"PASS"}]'
else
  echo "compliance-backfill: ERROR: PIPELINE_REPO not set" >&2
fi
STUB

cat > "$T/scripts/review-audits.sh" <<'STUB'
#!/bin/bash
if [ -n "${PIPELINE_REPO:-fake/repo}" ]; then
  echo 'deviation'
fi
STUB

chmod +x "$T"/scripts/*.sh

echo "-- live sibling-dispatch path inherits exported PIPELINE_REPO --"

# CLEAN environment: strip PIPELINE_REPO so the parent shell cannot leak it.
# An un-stripped parent env would mask the bug.
ROW="$(env -u PIPELINE_REPO bash "$T/scripts/metrics-snapshot.sh" --dry-run 2>/dev/null)"

if echo "$ROW" | jq -e . >/dev/null 2>&1; then
  pass_msg "row is valid JSON"
else
  fail_msg "row is not valid JSON: $ROW"
fi

check_field() {
  local expr="$1" want="$2" label="$3"
  local got
  got="$(echo "$ROW" | jq -c "$expr" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    pass_msg "$label == $want"
  else
    fail_msg "$label: got '$got', expected '$want' (sibling saw PIPELINE_REPO unset?)"
  fi
}

check_field '.over_eval_count' '1' 'over_eval_count'
check_field '.late_error_count_by_stage.plan' '1' 'late_error_count_by_stage.plan'
check_field '.compliance_pass_rate' '1' 'compliance_pass_rate'
check_field '.review_deviations_count' '1' 'review_deviations_count'

echo ""
echo "=================================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "=================================="
exit "$FAIL"
