#!/usr/bin/env bash
# test-doctor-golden-seed-set.sh — golden seed-set guard for `doctor.sh --fix config`
# (issue #1052). Pins WHICH keys the reconcile seeds into a minimal host
# (PIPELINE_REPO only) against the REAL repo pipeline.config.example.
#
# Defaults-in-code / config = overrides-only (Claude Code parallel): a PIPELINE_*
# knob with a read-site ${VAR:-default} must be COMMENTED in the example so the
# reconcile does NOT seed it (the read site owns the default; seeding PINS the old
# value and defeats central default evolution). Only no-safe-default required keys
# stay uncommented = seeded. This guard pins the post-change uncommented set: the 5
# defaulted knobs reclassified by #1052 MUST NOT be seeded, and any FUTURE
# uncommented-defaulted knob added to the example turns this test RED, forcing the
# author to comment it (or to consciously extend GOLDEN with a justification).
#
# Hermetic: a temp fixture holding a COPY of the real example + a minimal host;
# doctor.sh runs with cwd=fixture so it reconciles the fixture only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/doctor.sh"
REAL_EXAMPLE="$REPO_ROOT/pipeline.config.example"

PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -f "$DOCTOR" ]       || { echo "ERROR: $DOCTOR not found" >&2; exit 1; }
[ -f "$REAL_EXAMPLE" ] || { echo "ERROR: $REAL_EXAMPLE not found" >&2; exit 1; }

# GOLDEN — the keys the reconcile is EXPECTED to seed into a minimal (PIPELINE_REPO-only)
# host. PIPELINE_REPO is excluded from the comparison because it is already present in
# the host (never re-seeded). Sorted; one key per line. Keep this list and the example
# in lockstep: commenting an example knob removes it here; adding an uncommented knob
# adds it here (and demands a justification that it has NO safe default).
#
# NOTE: several entries below (e.g. PIPELINE_BASE_BRANCH, PIPELINE_CI_CHECK_ENABLED,
# PIPELINE_LOGS_ENABLED, the Opus PIPELINE_PRICE_* block) DO have read-site defaults and
# are legacy-still-seeded. #1052 scope reclassifies only the 5 knobs named below; a
# follow-up audit may comment more, shrinking GOLDEN. The 5 #1052-reclassified knobs are
# asserted ABSENT separately (Case 3) so the intent is unambiguous regardless of GOLDEN's
# legacy tail.
read -r -d '' GOLDEN <<'EOF'
PIPELINE_BASE_BRANCH
PIPELINE_CI_CHECK_ENABLED
PIPELINE_CONTEXT_FILES
PIPELINE_INSTALL_CMD
PIPELINE_LABELS_BRAINSTORM
PIPELINE_LABELS_EXCLUDED
PIPELINE_LABELS_HUMAN
PIPELINE_LABELS_LATER
PIPELINE_LOGS_ENABLED
PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_CREATION
PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_READ
PIPELINE_PRICE_CLAUDE_OPUS_4_8_INPUT
PIPELINE_PRICE_CLAUDE_OPUS_4_8_OUTPUT
PIPELINE_RELEASE_PR_LABEL
PIPELINE_SEED_CMD
PIPELINE_SYNC_DOCS
PIPELINE_SYNC_ENVS
PIPELINE_SYNC_FILES
PIPELINE_SYNC_VENVS
PIPELINE_TEST_CMD
PIPELINE_TMUX_SESSION
PIPELINE_TYPECHECK_CMD
PIPELINE_WIN_TEMP
PIPELINE_WORKTREE_PREFIX
EOF
GOLDEN_SORTED="$(printf '%s\n' "$GOLDEN" | sed '/^$/d' | sort -u)"

# The 5 knobs #1052 reclassifies — MUST NOT be seeded after this issue lands.
RECLASSIFIED="PIPELINE_PATH_B_MODEL_EXECUTE PIPELINE_PATH_D_MODEL_EXECUTE PIPELINE_PATH_B_ELIGIBLE_SCOPE PIPELINE_PATH_B_SPLIT_ROLE PIPELINE_CI_FIX_LOOP_ENABLED"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$REAL_EXAMPLE" "$WORK/pipeline.config.example"
cat > "$WORK/pipeline.config" <<'HEOF'
set -a
PIPELINE_REPO="rjskene/pipeline"
set +a
HEOF

OUT="$(cd "$WORK" && bash "$DOCTOR" --fix config 2>&1)"; RC=$?

# Case 1: exits 0.
[ "$RC" -eq 0 ] && pass_msg "exit 0" || fail_msg "expected exit 0, got $RC ($OUT)"

# Seeded set = uncommented PIPELINE_* keys in post-reconcile host, minus PIPELINE_REPO.
SEEDED="$(grep -oE '^[[:space:]]*PIPELINE_[A-Z0-9_]+=' "$WORK/pipeline.config" \
          | sed -E 's/^[[:space:]]*//; s/=$//' | grep -vx 'PIPELINE_REPO' | sort -u)"

# Case 2: seeded set equals GOLDEN exactly (diff is empty).
if [ "$SEEDED" = "$GOLDEN_SORTED" ]; then
  pass_msg "seeded set matches GOLDEN exactly"
else
  fail_msg "seeded set != GOLDEN. diff (< golden  > seeded):"
  diff <(printf '%s\n' "$GOLDEN_SORTED") <(printf '%s\n' "$SEEDED") | sed 's/^/    /' >&2 || true
fi

# Case 3: none of the 5 #1052-reclassified knobs were seeded.
for k in $RECLASSIFIED; do
  if printf '%s\n' "$SEEDED" | grep -qx "$k"; then
    fail_msg "$k was seeded but must be COMMENTED in the example (#1052)"
  else
    pass_msg "$k not seeded (correctly commented in example)"
  fi
done

echo ""
echo "================================"
echo "  test-doctor-golden-seed-set: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
