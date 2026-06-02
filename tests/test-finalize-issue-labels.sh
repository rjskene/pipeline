#!/bin/bash
set -euo pipefail

# Tests for scripts/finalize-issue-labels.sh — the shared merge-completion
# label-strip helper (issue #866). It is the single source of truth for the
# strip-set applied when a pipeline issue reaches the merged/terminal state:
# add `merged`, remove every pipeline-lifecycle / path / priority label, and
# tolerate gh's absent-label 422 (idempotent re-run). Consumed by
# finish-manual-merge.sh, cleanup-worktree.sh, and evaluate-issue-pr Step 11.
#
# The gh CLI is replaced by a PATH-resident shim (modeled on
# tests/test-finish-manual-merge.sh) that records every invocation to $SHIM_LOG
# and simulates gh's absent-label 422: a `--remove-label X` for an X not in
# $LABELS (comma-separated) makes the whole `issue edit` call exit 1.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/finalize-issue-labels.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# Shim: gh issue edit <N> [--add-label A] [--remove-label B]...
#   -> record full invocation; for each --remove-label X not present in
#      $LABELS (comma-separated), exit 1 (simulate gh's absent-label 422).
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$SHIM_LOG"

sub1="${1:-}"; sub2="${2:-}"
case "$sub1 $sub2" in
  "issue edit")
    have=",${LABELS:-},"
    rc=0
    while [ $# -gt 0 ]; do
      if [ "$1" = "--remove-label" ]; then
        tgt="$2"
        case "$have" in
          *",$tgt,"*) : ;;          # present → ok
          *) rc=1 ;;                # absent → simulate 422
        esac
        shift 2; continue
      fi
      shift
    done
    exit "$rc"
    ;;
  *)
    exit 0
    ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="rjskene/pipeline"

reset_case() {
  local case_dir="$1"
  rm -rf "$case_dir"; mkdir -p "$case_dir"
  export SHIM_LOG="$case_dir/calls.log"
  : > "$SHIM_LOG"
}

# Full strip-set (the contract). Keep in sync with the helper's STRIP_LABELS.
STRIP_SET=(plan-pending plan-reviewed plan-approved in-progress pr-open manual-merge docs-only multi-task quick-fix priority/P0 priority/P1 priority/P2 priority/P3)

# ---- Case A: arg guard — missing issue → non-zero + usage ----
echo "Case A: arg guard"
inc
A="$TMP/case-a"; reset_case "$A"
if bash "$HELPER" >"$A/stdout" 2>"$A/stderr"; then
  fail_msg "arg guard: helper exited 0 with no args; expected non-zero"
else
  rc=$?
  if [ "$rc" -ne 0 ] && grep -qi 'usage' "$A/stderr"; then
    pass_msg "arg guard: missing issue exits $rc with a usage line on stderr"
  else
    fail_msg "arg guard: exit=$rc but stderr lacks a usage line"
    sed 's/^/    /' "$A/stderr"
  fi
fi

# ---- Case B: missing PIPELINE_REPO and no --repo → documented error ----
echo "Case B: missing PIPELINE_REPO → required-error"
inc
B="$TMP/case-b"; reset_case "$B"
if env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$HOME" SHIM_LOG="$B/calls.log" \
     LABELS="pr-open" \
     bash "$HELPER" 866 >"$B/stdout" 2>"$B/stderr"; then
  fail_msg "missing PIPELINE_REPO: helper exited 0 — expected non-zero"
  echo "    stderr:"; sed 's/^/      /' "$B/stderr"
else
  rc=$?
  if [ "$rc" -ne 0 ] && grep -qiF 'PIPELINE_REPO' "$B/stderr"; then
    pass_msg "missing PIPELINE_REPO: helper exited $rc with a documented error"
  else
    fail_msg "missing PIPELINE_REPO: exit=$rc but stderr lacks the documented error"
    echo "    stderr:"; sed 's/^/      /' "$B/stderr"
  fi
fi

# ---- Case C: full strip — add merged + every strip-set label removed ----
echo "Case C: full strip-set recorded"
inc
C="$TMP/case-c"; reset_case "$C"
# All strip labels present so the combined call succeeds (no 422).
export LABELS="$(IFS=,; echo "${STRIP_SET[*]}")"
if bash "$HELPER" 866 >"$C/stdout" 2>"$C/stderr"; then
  ok=1
  grep -qF -- '--add-label merged' "$SHIM_LOG" || { ok=0; fail_msg "full strip: no --add-label merged recorded"; }
  for l in "${STRIP_SET[@]}"; do
    grep -qF -- "--remove-label $l" "$SHIM_LOG" || { ok=0; fail_msg "full strip: no --remove-label $l recorded"; }
  done
  [ "$ok" = "1" ] && pass_msg "full strip: add merged + remove all ${#STRIP_SET[@]} strip-set labels"
  [ "$ok" = "1" ] || sed 's/^/    /' "$SHIM_LOG"
else
  rc=$?
  fail_msg "full strip: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$C/stderr"
fi

# ---- Case D: contract guard — representative labels stripped, type-labels kept ----
echo "Case D: strip-set contract (lifecycle/path/priority in; type-labels out)"
inc
D="$TMP/case-d"; reset_case "$D"
export LABELS="$(IFS=,; echo "${STRIP_SET[*]}"),bug,enhancement,needs-browser,tracker"
if bash "$HELPER" 866 >"$D/stdout" 2>"$D/stderr"; then
  ok=1
  for l in plan-reviewed plan-approved in-progress priority/P2 docs-only quick-fix multi-task; do
    grep -qF -- "--remove-label $l" "$SHIM_LOG" || { ok=0; fail_msg "contract: $l should be stripped but was not"; }
  done
  for l in bug enhancement needs-browser tracker merged; do
    if grep -qF -- "--remove-label $l" "$SHIM_LOG"; then
      ok=0; fail_msg "contract: $l must NOT be in the strip-set but --remove-label $l was recorded"
    fi
  done
  [ "$ok" = "1" ] && pass_msg "contract: lifecycle/path/priority stripped; bug/enhancement/needs-browser/tracker/merged preserved"
  [ "$ok" = "1" ] || sed 's/^/    /' "$SHIM_LOG"
else
  rc=$?
  fail_msg "contract: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$D/stderr"
fi

# ---- Case E: idempotency — all strip targets absent → still exits 0, merged add preserved ----
echo "Case E: idempotent on already-stripped issue"
inc
E="$TMP/case-e"; reset_case "$E"
export LABELS="merged"   # every strip target absent → combined call 422s; fallback re-adds merged
if bash "$HELPER" 866 >"$E/stdout" 2>"$E/stderr"; then
  # The combined call 422s, so the fallback `--add-label merged` (only) must run.
  if grep -qF -- '--add-label merged' "$SHIM_LOG"; then
    pass_msg "idempotent: re-run on merged-only exits 0 and the merged add is preserved via fallback"
  else
    fail_msg "idempotent: exited 0 but no --add-label merged recorded (fallback dropped the add)"
    sed 's/^/    /' "$SHIM_LOG"
  fi
else
  rc=$?
  fail_msg "idempotent: helper exited $rc; expected 0 (|| true must absorb absent-label 422s)"
  echo "    stderr:"; sed 's/^/      /' "$E/stderr"
fi

# ---- Case F: --repo flag overrides env ----
echo "Case F: --repo flag honored"
inc
F="$TMP/case-f"; reset_case "$F"
export LABELS="$(IFS=,; echo "${STRIP_SET[*]}")"
if bash "$HELPER" 866 --repo "other/repo" >"$F/stdout" 2>"$F/stderr"; then
  if grep -qF -- '--repo other/repo' "$SHIM_LOG"; then
    pass_msg "--repo flag: explicit repo recorded in the gh call"
  else
    fail_msg "--repo flag: 'other/repo' not recorded"
    sed 's/^/    /' "$SHIM_LOG"
  fi
else
  rc=$?
  fail_msg "--repo flag: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$F/stderr"
fi

# ---- Grep-guards: the three call sites delegate to the helper ----
echo "Case G: call sites delegate to the shared helper"

inc
if grep -qF 'finalize-issue-labels.sh' "$REPO_ROOT/scripts/finish-manual-merge.sh" \
   && ! grep -qF -- '--remove-label manual-merge' "$REPO_ROOT/scripts/finish-manual-merge.sh"; then
  pass_msg "finish-manual-merge.sh references the helper and dropped its inline flip"
else
  fail_msg "finish-manual-merge.sh should reference finalize-issue-labels.sh and drop the inline --remove-label manual-merge flip"
fi

inc
if grep -qF 'finalize-issue-labels.sh' "$REPO_ROOT/scripts/cleanup-worktree.sh" \
   && ! grep -qF -- '--add-label "merged" --remove-label "pr-open"' "$REPO_ROOT/scripts/cleanup-worktree.sh"; then
  pass_msg "cleanup-worktree.sh references the helper and dropped its inline flip"
else
  fail_msg "cleanup-worktree.sh should reference finalize-issue-labels.sh and drop the inline --add-label merged --remove-label pr-open flip"
fi

inc
if grep -qF 'finalize-issue-labels.sh' "$REPO_ROOT/skills/evaluate-issue-pr/SKILL.md" \
   && ! grep -qF -- '--add-label "merged" --remove-label "pr-open"' "$REPO_ROOT/skills/evaluate-issue-pr/SKILL.md"; then
  pass_msg "evaluate-issue-pr SKILL.md references the helper and dropped its inline flip"
else
  fail_msg "evaluate-issue-pr SKILL.md should reference finalize-issue-labels.sh and drop the inline --add-label merged --remove-label pr-open flip"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
