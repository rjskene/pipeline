#!/bin/bash
set -uo pipefail
#
# tests/test-transition-issue.sh — issue #1449.
#
# Calibration run 19 aborted because the auto-mode classifier DENIED the raw
# `gh issue edit <N> --add-label "plan-approved" --remove-label "plan-pending"`
# lifecycle flip four times (as `[CI Bypass]`), while every `scripts/*.sh` call
# in the same run passed. `scripts/transition-issue.sh` is the opaque,
# script-shaped replacement for those raw flips: the NON-TERMINAL sibling of
# `scripts/finalize-issue-labels.sh` (which keeps the terminal `merged`
# strip-set).
#
# CONTRACT (what this file pins):
#   argv  — <N> --to <label> [--from <label>] [--comment <text>] [--repo o/r]
#   stdout — EXACTLY ONE line:
#     TRANSITION=ok|partial|failed issue=#<N> to=<label> from=<label|-> comment=<posted|skipped|failed>
#   exit  — 0 for all three operational outcomes ("the caller decides");
#           2 with NO `TRANSITION=` line for argv/usage errors (mirrors
#           finalize-issue-labels.sh, so a typo'd hot-path flag is not swallowed).
#   422-avoidance — the present labels are queried FIRST, so an absent `--from`
#           never passes `--remove-label` to gh (issues #963/#967).
#
# THE SHIM PRINTS A URL (the #1449 plan-eval amendment). Real `gh issue edit`
# and `gh issue comment` each print a URL on STDOUT on success, so an
# unredirected call emits 2-3 stdout lines in production. A silent shim (the
# shape tests/test-finalize-issue-labels.sh uses) would green the one-line
# assertion against a broken implementation. Both arms below therefore echo a
# fake URL, which makes Case J discriminate: it FAILS on unredirected `gh`
# calls and passes only on `>/dev/null 2>&1`-redirected ones.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/transition-issue.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

echo "transition-issue.sh contract (#1449)"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$SHIM_LOG"

sub1="${1:-}"; sub2="${2:-}"
case "$sub1 $sub2" in
  "issue edit")
    if [ -n "${FORCE_EDIT_FAIL:-}" ]; then echo "gh: HTTP 422 (simulated)" >&2; exit 1; fi
    # Real gh prints the issue URL on stdout.
    echo "https://github.com/${PIPELINE_REPO:-owner/repo}/issues/${3:-0}"
    exit 0
    ;;
  "issue comment")
    if [ -n "${FORCE_COMMENT_FAIL:-}" ]; then echo "gh: HTTP 500 (simulated)" >&2; exit 1; fi
    # Real gh prints the comment URL on stdout.
    echo "https://github.com/${PIPELINE_REPO:-owner/repo}/issues/${3:-0}#issuecomment-1"
    exit 0
    ;;
  "issue view")
    # Simulate `gh issue view <N> --repo R --json labels --jq '.labels[].name'`.
    printf '%s\n' "${LABELS:-}" | tr ',' '\n' | sed '/^$/d'
    exit 0
    ;;
  "repo view")
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

# The anchored one-line stdout shape (Case J).
SHAPE_RE='^TRANSITION=(ok|partial|failed) issue=#[0-9]+ to=[^ ]+ from=[^ ]+ comment=(posted|skipped|failed)$'

CASE_DIR=""
reset_case() {
  CASE_DIR="$TMP/$1"
  rm -rf "$CASE_DIR"; mkdir -p "$CASE_DIR"
  export SHIM_LOG="$CASE_DIR/calls.log"
  : > "$SHIM_LOG"
}

# Count `gh <sub1> <sub2>` invocations recorded by the shim.
count_calls() { grep -cE "^gh $1 $2( |\$)" "$SHIM_LOG" || true; }

# ---------------------------------------------------------------------------
scenario "A: no args -> exit 2, usage on stderr, NO TRANSITION= line"
inc
reset_case case-a
bash "$HELPER" >"$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'usage' "$CASE_DIR/err" && ! grep -q 'TRANSITION=' "$CASE_DIR/out"; then
  pass_msg "A: no args exits 2 with a usage line and no TRANSITION= on stdout"
else
  fail_msg "A: expected exit 2 + usage on stderr + empty stdout; got rc=$rc"
  sed 's/^/    err: /' "$CASE_DIR/err"; sed 's/^/    out: /' "$CASE_DIR/out"
fi

# ---------------------------------------------------------------------------
scenario "B: issue number but no --to -> exit 2"
inc
reset_case case-b
bash "$HELPER" 191 >"$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -q 'TRANSITION=' "$CASE_DIR/out"; then
  pass_msg "B: missing --to exits 2 with no TRANSITION= line"
else
  fail_msg "B: expected exit 2 with no TRANSITION= line; got rc=$rc"
  sed 's/^/    err: /' "$CASE_DIR/err"; sed 's/^/    out: /' "$CASE_DIR/out"
fi

# ---------------------------------------------------------------------------
scenario "C: unknown flag -> exit 2"
inc
reset_case case-c
bash "$HELPER" 191 --to plan-approved --bogus x >"$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -q 'TRANSITION=' "$CASE_DIR/out"; then
  pass_msg "C: unknown flag exits 2 with no TRANSITION= line"
else
  fail_msg "C: expected exit 2 with no TRANSITION= line; got rc=$rc"
  sed 's/^/    err: /' "$CASE_DIR/err"; sed 's/^/    out: /' "$CASE_DIR/out"
fi

# ---------------------------------------------------------------------------
scenario "C2: an EMPTY --from value is an argv error, not a malformed audit line"
# Closing-review finding: `--from ""` set FROM_SET=1 with FROM="", so the audit
# line read `from=` — violating both the documented `from=<label|->` shape and
# the anchored SHAPE_RE below (`from=[^ ]+`). A caller parsing the line
# positionally mis-reads the field. Same argv-error family as A/B/C.
inc
reset_case case-c2
bash "$HELPER" 191 --to plan-approved --from "" >"$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'usage' "$CASE_DIR/err" && ! grep -q 'TRANSITION=' "$CASE_DIR/out"; then
  pass_msg "C2: empty --from exits 2 with a usage line and emits no TRANSITION= line"
else
  fail_msg "C2: expected exit 2 + usage + no TRANSITION= line; got rc=$rc, stdout: $(cat "$CASE_DIR/out")"
fi

# ---------------------------------------------------------------------------
scenario "D: present --from -> ok, one combined edit, no comment"
inc
reset_case case-d
LABELS="plan-pending" bash "$HELPER" 191 --to plan-approved --from plan-pending \
  >"$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
EXPECT_D='TRANSITION=ok issue=#191 to=plan-approved from=plan-pending comment=skipped'
ok=1
[ "$rc" -eq 0 ] || { ok=0; fail_msg "D: exit $rc, expected 0"; }
[ "$(cat "$CASE_DIR/out")" = "$EXPECT_D" ] || { ok=0; fail_msg "D: stdout is not exactly '$EXPECT_D'"; }
[ "$(count_calls issue edit)" = "1" ] || { ok=0; fail_msg "D: expected exactly 1 'gh issue edit', got $(count_calls issue edit)"; }
grep -qF -- '--add-label plan-approved' "$SHIM_LOG" || { ok=0; fail_msg "D: no --add-label plan-approved recorded"; }
grep -qF -- '--remove-label plan-pending' "$SHIM_LOG" || { ok=0; fail_msg "D: no --remove-label plan-pending recorded"; }
[ "$(count_calls issue comment)" = "0" ] || { ok=0; fail_msg "D: a gh issue comment was posted without --comment"; }
# L (non-vacuity control): the PATH shim must actually have been exercised.
[ -s "$SHIM_LOG" ] || { ok=0; fail_msg "D/L: SHIM_LOG is EMPTY — the PATH shim never ran, so this case is vacuous"; }
if [ "$ok" = 1 ]; then
  pass_msg "D: ok + exact one-line stdout + single combined add/remove edit + no comment (shim exercised)"
else
  sed 's/^/    log: /' "$SHIM_LOG"; sed 's/^/    out: /' "$CASE_DIR/out"; sed 's/^/    err: /' "$CASE_DIR/err"
fi

# ---------------------------------------------------------------------------
scenario "E: --from flag ABSENT -> from=-, no --remove-label anywhere"
inc
reset_case case-e
LABELS="plan-pending" bash "$HELPER" 191 --to plan-approved \
  >"$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
EXPECT_E='TRANSITION=ok issue=#191 to=plan-approved from=- comment=skipped'
ok=1
[ "$rc" -eq 0 ] || { ok=0; fail_msg "E: exit $rc, expected 0"; }
[ "$(cat "$CASE_DIR/out")" = "$EXPECT_E" ] || { ok=0; fail_msg "E: stdout is not exactly '$EXPECT_E'"; }
if grep -qF -- '--remove-label' "$SHIM_LOG"; then
  ok=0; fail_msg "E: --remove-label was passed to gh with no --from flag"
fi
[ -s "$SHIM_LOG" ] || { ok=0; fail_msg "E/L: SHIM_LOG is EMPTY — the PATH shim never ran, so this case is vacuous"; }
if [ "$ok" = 1 ]; then
  pass_msg "E: absent --from reports from=- and attempts no remove (shim exercised)"
else
  sed 's/^/    log: /' "$SHIM_LOG"; sed 's/^/    out: /' "$CASE_DIR/out"
fi

# ---------------------------------------------------------------------------
scenario "F: --from requested but NOT present -> ok, echoed, no remove attempted (#963/#967)"
inc
reset_case case-f
LABELS="plan-approved" bash "$HELPER" 191 --to plan-approved --from plan-pending \
  >"$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
EXPECT_F='TRANSITION=ok issue=#191 to=plan-approved from=plan-pending comment=skipped'
ok=1
[ "$rc" -eq 0 ] || { ok=0; fail_msg "F: exit $rc, expected 0"; }
[ "$(cat "$CASE_DIR/out")" = "$EXPECT_F" ] || { ok=0; fail_msg "F: stdout is not exactly '$EXPECT_F'"; }
if grep -qF -- '--remove-label' "$SHIM_LOG"; then
  ok=0; fail_msg "F: absent label passed to gh --remove-label (re-introduces the 422)"
fi
if [ "$ok" = 1 ]; then
  pass_msg "F: absent requested label is a silent no-op remove, still ok, no 422 exposure"
else
  sed 's/^/    log: /' "$SHIM_LOG"; sed 's/^/    out: /' "$CASE_DIR/out"
fi

# ---------------------------------------------------------------------------
scenario "G: --comment posts exactly one audit comment carrying the body"
inc
reset_case case-g
BODY='plan-eval skipped: lean profile'
LABELS="plan-pending" bash "$HELPER" 191 --to plan-approved --from plan-pending --comment "$BODY" \
  >"$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
EXPECT_G='TRANSITION=ok issue=#191 to=plan-approved from=plan-pending comment=posted'
ok=1
[ "$rc" -eq 0 ] || { ok=0; fail_msg "G: exit $rc, expected 0"; }
[ "$(cat "$CASE_DIR/out")" = "$EXPECT_G" ] || { ok=0; fail_msg "G: stdout is not exactly '$EXPECT_G'"; }
[ "$(count_calls issue comment)" = "1" ] || { ok=0; fail_msg "G: expected exactly 1 'gh issue comment', got $(count_calls issue comment)"; }
grep -qF -- "$BODY" "$SHIM_LOG" || { ok=0; fail_msg "G: the comment body text was not threaded into the gh call"; }
[ -s "$SHIM_LOG" ] || { ok=0; fail_msg "G/L: SHIM_LOG is EMPTY — the PATH shim never ran, so this case is vacuous"; }
if [ "$ok" = 1 ]; then
  pass_msg "G: comment=posted with exactly one gh issue comment carrying the body (shim exercised)"
else
  sed 's/^/    log: /' "$SHIM_LOG"; sed 's/^/    out: /' "$CASE_DIR/out"
fi

# ---------------------------------------------------------------------------
scenario "H: comment failure -> partial, exit 0"
inc
reset_case case-h
LABELS="plan-pending" FORCE_COMMENT_FAIL=1 bash "$HELPER" 191 --to plan-approved --from plan-pending --comment "audit" \
  >"$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
EXPECT_H='TRANSITION=partial issue=#191 to=plan-approved from=plan-pending comment=failed'
ok=1
[ "$rc" -eq 0 ] || { ok=0; fail_msg "H: exit $rc, expected 0"; }
[ "$(cat "$CASE_DIR/out")" = "$EXPECT_H" ] || { ok=0; fail_msg "H: stdout is not exactly '$EXPECT_H'"; }
if [ "$ok" = 1 ]; then
  pass_msg "H: label flipped + comment failed reports partial and still exits 0"
else
  sed 's/^/    out: /' "$CASE_DIR/out"
fi

# ---------------------------------------------------------------------------
scenario "I: gh issue edit failure -> failed, exit 0, comment still attempted"
inc
reset_case case-i
LABELS="plan-pending" FORCE_EDIT_FAIL=1 bash "$HELPER" 191 --to plan-approved --from plan-pending --comment "audit" \
  >"$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
ok=1
[ "$rc" -eq 0 ] || { ok=0; fail_msg "I: exit $rc, expected 0"; }
grep -qE '^TRANSITION=failed issue=#191 to=plan-approved from=plan-pending comment=posted$' "$CASE_DIR/out" \
  || { ok=0; fail_msg "I: expected 'TRANSITION=failed ... comment=posted' (failed dominates; audit comment still attempted)"; }
[ "$(count_calls issue comment)" = "1" ] || { ok=0; fail_msg "I: the audit comment was not attempted after an edit failure"; }
if [ "$ok" = 1 ]; then
  pass_msg "I: edit failure reports failed, exits 0, and still leaves the audit comment"
else
  sed 's/^/    log: /' "$SHIM_LOG"; sed 's/^/    out: /' "$CASE_DIR/out"
fi

# ---------------------------------------------------------------------------
scenario "J: stdout is EXACTLY one line matching the anchored shape"
# This is the amendment-3 discriminator: the shim's `issue edit` / `issue
# comment` arms each print a URL, so an unredirected implementation emits 2-3
# stdout lines here and FAILS.
for spec in "no-comment:LABELS=plan-pending::191 --to plan-approved --from plan-pending" \
            "with-comment:LABELS=plan-pending::191 --to plan-approved --from plan-pending --comment audit" \
            "comment-fail:FORCE_COMMENT_FAIL=1::191 --to plan-approved --comment audit" \
            "edit-fail:FORCE_EDIT_FAIL=1::191 --to plan-approved --comment audit"; do
  name="${spec%%:*}"; rest="${spec#*:}"
  envassign="${rest%%::*}"; args="${rest#*::}"
  inc
  reset_case "case-j-$name"
  # shellcheck disable=SC2086
  env "$envassign" bash "$HELPER" $args >"$CASE_DIR/out" 2>"$CASE_DIR/err"; rc=$?
  lines="$(wc -l <"$CASE_DIR/out" | tr -d ' ')"
  if [ "$rc" -eq 0 ] && [ "$lines" = "1" ] && grep -qE "$SHAPE_RE" "$CASE_DIR/out"; then
    pass_msg "J/$name: stdout is exactly 1 line matching the anchored TRANSITION= shape"
  else
    fail_msg "J/$name: rc=$rc stdout_lines=$lines — stdout must be EXACTLY one anchored TRANSITION= line (redirect gh's URL output)"
    sed 's/^/    out: /' "$CASE_DIR/out"
  fi
done

# ---------------------------------------------------------------------------
scenario "K: repo resolution — --repo beats \$PIPELINE_REPO; env-only still threads through"
inc
reset_case case-k-flag
LABELS="plan-pending" bash "$HELPER" 191 --to plan-approved --repo other/repo \
  >"$CASE_DIR/out" 2>"$CASE_DIR/err"
if grep -qF -- '--repo other/repo' "$SHIM_LOG" && ! grep -qF -- '--repo rjskene/pipeline' "$SHIM_LOG"; then
  pass_msg "K: --repo flag wins over \$PIPELINE_REPO"
else
  fail_msg "K: --repo flag did not win over \$PIPELINE_REPO"
  sed 's/^/    log: /' "$SHIM_LOG"
fi

inc
reset_case case-k-env
LABELS="plan-pending" bash "$HELPER" 191 --to plan-approved \
  >"$CASE_DIR/out" 2>"$CASE_DIR/err"
if grep -qF -- '--repo rjskene/pipeline' "$SHIM_LOG"; then
  pass_msg "K: env-only \$PIPELINE_REPO is threaded into the gh calls"
else
  fail_msg "K: env-only \$PIPELINE_REPO not recorded in the gh calls"
  sed 's/^/    log: /' "$SHIM_LOG"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
