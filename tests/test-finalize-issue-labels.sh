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
    if [ -n "${FORCE_EDIT_FAIL:-}" ]; then exit 1; fi
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
  "issue view")
    # Simulate `gh issue view <N> --repo R --json labels --jq '.labels[].name'`.
    # Print the present labels (one per line) derived from $LABELS (comma-separated).
    printf '%s\n' "${LABELS:-}" | tr ',' '\n' | sed '/^$/d'
    exit 0
    ;;
  "repo view")
    # Simulate `gh repo view --json nameWithOwner -q .nameWithOwner`.
    # FALLBACK_REPO empty => simulate gh failure (exit 1, no stdout).
    if [ -n "${FALLBACK_REPO:-}" ]; then echo "$FALLBACK_REPO"; exit 0; else exit 1; fi
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
# Run from an isolated cwd (the case dir, under mktemp -d outside any repo) so
# the #1022 self-resolver finds NO pipeline.config up the tree — this case must
# still hit the required-error path when no repo is resolvable from ANY tier.
echo "Case B: missing PIPELINE_REPO → required-error"
inc
B="$TMP/case-b"; reset_case "$B"
if ( cd "$B" && env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$HOME" SHIM_LOG="$B/calls.log" \
     LABELS="pr-open" \
     bash "$HELPER" 866 ) >"$B/stdout" 2>"$B/stderr"; then
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

# ---- Case H: env-only PIPELINE_REPO (Step-11.3 shape) reaches the gh call ----
echo "Case H: env-only PIPELINE_REPO recorded in gh call"
inc
H="$TMP/case-h"; reset_case "$H"
export LABELS="$(IFS=,; echo "${STRIP_SET[*]}")"
# PIPELINE_REPO is exported at top of file (rjskene/pipeline); no --repo flag.
if bash "$HELPER" 888 >"$H/stdout" 2>"$H/stderr"; then
  if grep -qF -- '--repo rjskene/pipeline' "$SHIM_LOG"; then
    pass_msg "env-only PIPELINE_REPO: gh call carries --repo rjskene/pipeline"
  else
    fail_msg "env-only PIPELINE_REPO: --repo rjskene/pipeline not recorded in gh call"
    sed 's/^/    /' "$SHIM_LOG"
  fi
else
  rc=$?
  fail_msg "env-only PIPELINE_REPO: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$H/stderr"
fi

# ---- Case I: REPO unset → gh repo view fallback resolves the repo ----
# Run from an isolated cwd (no ancestor pipeline.config) so the #1022 config tier
# yields nothing and the `gh repo view` fallback remains the resolver of record.
echo "Case I: gh repo view fallback when PIPELINE_REPO unset"
inc
I="$TMP/case-i"; reset_case "$I"
if ( cd "$I" && env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$HOME" SHIM_LOG="$I/calls.log" \
     FALLBACK_REPO="fallback/repo" \
     LABELS="$(IFS=,; echo "${STRIP_SET[*]}")" \
     bash "$HELPER" 888 ) >"$I/stdout" 2>"$I/stderr"; then
  if grep -qF -- '--repo fallback/repo' "$I/calls.log"; then
    pass_msg "gh repo view fallback: resolved repo threaded into gh issue edit"
  else
    fail_msg "gh repo view fallback: --repo fallback/repo not recorded"
    sed 's/^/    /' "$I/calls.log"
  fi
else
  rc=$?
  fail_msg "gh repo view fallback: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$I/stderr"
fi

# ---- Case J: total gh issue edit failure → WARN on stderr, still exit 0 ----
echo "Case J: total edit failure emits WARN (non-blocking)"
inc
J="$TMP/case-j"; reset_case "$J"
export LABELS="$(IFS=,; echo "${STRIP_SET[*]}")"
if FORCE_EDIT_FAIL=1 bash "$HELPER" 888 >"$J/stdout" 2>"$J/stderr"; then
  if grep -qi 'WARN' "$J/stderr"; then
    pass_msg "total edit failure: WARN surfaced on stderr and helper stayed non-blocking (exit 0)"
  else
    fail_msg "total edit failure: exited 0 but no WARN on stderr (silent no-op regression #888)"
    echo "    stderr:"; sed 's/^/      /' "$J/stderr"
  fi
else
  rc=$?
  fail_msg "total edit failure: helper exited $rc; expected 0 (merge path must stay non-blocking)"
  echo "    stderr:"; sed 's/^/      /' "$J/stderr"
fi
unset FORCE_EDIT_FAIL

# ---- Case K: subset strip — only pr-open present → exactly merged, accurate count, no 422 ----
echo "Case K: subset strip — only pr-open present → exactly merged, accurate count, no 422"
inc
K="$TMP/case-k"; reset_case "$K"
export LABELS="pr-open"   # strict subset of the strip-set
if bash "$HELPER" 963 >"$K/stdout" 2>"$K/stderr"; then
  ok=1
  grep -qF -- '--add-label merged' "$SHIM_LOG" || { ok=0; fail_msg "subset: no --add-label merged recorded"; }
  grep -qF -- '--remove-label pr-open' "$SHIM_LOG" || { ok=0; fail_msg "subset: present label pr-open not removed"; }
  # Absent strip-set labels must NOT be passed to gh (that is what 422s the whole call).
  for l in plan-pending plan-reviewed in-progress quick-fix docs-only multi-task priority/P0; do
    if grep -qF -- "--remove-label $l" "$SHIM_LOG"; then
      ok=0; fail_msg "subset: absent label $l was passed to gh (re-introduces the 422)"
    fi
  done
  # stripped= must report the ACTUAL count (1), not the hardcoded array length (13).
  grep -qE 'FINALIZED: issue=963 labels=merged stripped=1$' "$K/stdout" \
    || { ok=0; fail_msg "subset: stripped count is not the actual removal count (expected stripped=1)"; }
  [ "$ok" = "1" ] && pass_msg "subset: only present labels removed, ends with merged, stripped=1, no 422"
  [ "$ok" = "1" ] || { sed 's/^/    /' "$SHIM_LOG"; sed 's/^/    out: /' "$K/stdout"; }
else
  rc=$?
  fail_msg "subset: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$K/stderr"
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
SKILL_MD="$REPO_ROOT/skills/evaluate-issue-pr/SKILL.md"
finalize_line="$(grep -F 'finalize-issue-labels.sh' "$SKILL_MD" | grep -F '"$ISSUE"' | head -1)"
if grep -qF 'finalize-issue-labels.sh' "$SKILL_MD" \
   && ! grep -qF -- '--add-label "merged" --remove-label "pr-open"' "$SKILL_MD" \
   && printf '%s' "$finalize_line" | grep -qF -- '--repo "$PIPELINE_REPO"' \
   && ! printf '%s' "$finalize_line" | grep -qF -- '2>/dev/null || true'; then
  pass_msg "evaluate-issue-pr SKILL.md Step 11.3 passes --repo and dropped the silent 2>/dev/null || true swallow"
else
  fail_msg "evaluate-issue-pr SKILL.md Step 11.3 must pass --repo \"\$PIPELINE_REPO\" to finalize-issue-labels.sh and drop the bare 2>/dev/null || true swallow (#888)"
  echo "    finalize_line: $finalize_line"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
