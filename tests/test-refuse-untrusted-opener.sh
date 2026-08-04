#!/bin/bash
set -euo pipefail

# Tests for issue #1196: the step-0a untrusted-opener refusal must be
# IDEMPOTENT (never accumulate duplicate triage comments) and DURABLE
# (apply PIPELINE_LABELS_HUMAN so the issue leaves the ready bucket and
# autonomous runs stop re-selecting it).
#
# The refusal aftermath is factored out of the two duplicated SKILL.md 0a
# blocks into a single shared helper: scripts/refuse-untrusted-opener.sh
#
#   refuse-untrusted-opener.sh <issue-number> <association> [--context "<sentence>"]
#
# Contract under test:
#   - one `gh issue view <N> --json comments,labels` round-trip
#   - triage comment posted only when no trusted triage comment already
#     exists (legacy `Untrusted opener (authorAssociation=` wire form OR
#     the `<!-- pipeline:untrusted-opener-triage -->` sentinel)
#   - marker scan is trusted-author-scoped (OWNER/MEMBER/COLLABORATOR) so
#     an outsider cannot self-suppress the triage surface
#   - `${PIPELINE_LABELS_HUMAN:-human}` applied when absent, skipped when
#     present, non-fatal when `gh issue edit` fails
#   - single machine-readable stdout line, and NOTHING else on stdout
#     (untrusted comment bytes fetched by the idempotency scan must never
#     be echoed):
#       REFUSED: untrusted opener (assoc=<A>) for #<N>; comment=posted|skipped label=applied|already-present|failed
#   - exit 0 on the refusal path; exit 2 reserved for usage errors
#
# `gh` is stubbed on PATH (the tests/test-classify-applies-label.sh idiom);
# the stub logs argv and mutates a JSON state file so re-runs observe the
# comments the previous run posted (the #1184 accumulation regression).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/_lib/env-hygiene.sh
. "$SCRIPT_DIR/_lib/env-hygiene.sh"
pipeline_test_reset_env

HELPER="$SCRIPT_DIR/../scripts/refuse-untrusted-opener.sh"

SENTINEL='<!-- pipeline:untrusted-opener-triage -->'
LEGACY_BODY='Untrusted opener (authorAssociation=NONE, no write access): surfacing for human triage. (issue #546)'

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
GH_LOG="$WORKDIR/gh-calls.log"
GH_BODY="$WORKDIR/posted-bodies.txt"
STATE_FILE="$WORKDIR/state.json"
OUT="$WORKDIR/out.txt"
ERR="$WORKDIR/err.txt"
RC=0

# --- gh stub -----------------------------------------------------------
# Logs one normalized line per invocation. Serves `issue view` from the
# JSON state file (honoring an optional --jq expression), records + REPLAYS
# `issue comment` bodies into the state (so idempotency is observable
# across runs), and honors GH_FAKE_EDIT_RC for `issue edit`.
cat > "$STUB_DIR/gh" <<'STUB'
#!/bin/bash
LOGLINE=$(printf '%s ' "$@" | tr '\n' ' ')
printf '%s\n' "$LOGLINE" >> "$GH_LOG_FILE"

sub1="${1:-}"
sub2="${2:-}"

if [ "$sub1" = "issue" ] && [ "$sub2" = "view" ]; then
  jqexpr=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --jq|-q) jqexpr="${2:-}" ;;
    esac
    shift
  done
  if [ -n "$jqexpr" ]; then
    jq -r "$jqexpr" "$GH_FAKE_STATE"
  else
    cat "$GH_FAKE_STATE"
  fi
  exit 0
fi

if [ "$sub1" = "issue" ] && [ "$sub2" = "comment" ]; then
  body=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body) body="${2:-}" ;;
      --body-file) body="$(cat "${2:-/dev/null}")" ;;
    esac
    shift
  done
  printf '%s\n' "$body" >> "$GH_BODY_FILE"
  tmp="$GH_FAKE_STATE.tmp"
  jq --arg b "$body" '.comments += [{"authorAssociation":"OWNER","body":$b}]' \
    "$GH_FAKE_STATE" > "$tmp" && mv "$tmp" "$GH_FAKE_STATE"
  exit 0
fi

if [ "$sub1" = "issue" ] && [ "$sub2" = "edit" ]; then
  exit "${GH_FAKE_EDIT_RC:-0}"
fi

exit 0
STUB
chmod +x "$STUB_DIR/gh"

# --- fixtures ----------------------------------------------------------

# set_state <comments-json-array> <labels-json-array>
set_state() {
  printf '{"comments":%s,"labels":%s}\n' "$1" "$2" > "$STATE_FILE"
}

comment_json() { jq -n --arg a "$1" --arg b "$2" '[{authorAssociation:$a, body:$b}]'; }
labels_json()  { jq -n --args '$ARGS.positional | map({name: .})' "$@"; }

# reset_log — clears the argv log + posted-body capture without touching state.
reset_log() { : > "$GH_LOG"; : > "$GH_BODY"; }

# run_helper <args...>
# Optional caller-set knobs: EDIT_RC, HUMAN_LABEL_ENV, NO_REPO, KEEP_LOG
run_helper() {
  [ "${KEEP_LOG:-0}" = "1" ] || reset_log
  local envargs=(
    "PATH=$STUB_DIR:$PATH"
    "GH_LOG_FILE=$GH_LOG"
    "GH_BODY_FILE=$GH_BODY"
    "GH_FAKE_STATE=$STATE_FILE"
    "GH_FAKE_EDIT_RC=${EDIT_RC:-0}"
  )
  if [ "${NO_REPO:-0}" != "1" ]; then
    envargs+=( "PIPELINE_REPO=fake/repo" )
  fi
  if [ -n "${HUMAN_LABEL_ENV:-}" ]; then
    envargs+=( "PIPELINE_LABELS_HUMAN=$HUMAN_LABEL_ENV" )
  fi
  set +e
  env -u PIPELINE_REPO -u PIPELINE_LABELS_HUMAN -u CLAUDE_PLUGIN_ROOT \
    "${envargs[@]}" bash "$HELPER" "$@" >"$OUT" 2>"$ERR"
  RC=$?
  set -e
}

count_calls() { grep -c "^issue $1 " "$GH_LOG" 2>/dev/null || true; }

echo "=== scripts/refuse-untrusted-opener.sh (issue #1196) ==="

# --- Test 0: helper exists and parses --------------------------------------

echo "Test 0: helper script exists and is syntactically valid"
inc
if [ -f "$HELPER" ] && bash -n "$HELPER" 2>/dev/null; then
  pass_msg "scripts/refuse-untrusted-opener.sh exists and passes bash -n"
else
  fail_msg "scripts/refuse-untrusted-opener.sh missing or not valid bash"
fi

# --- C1: clean issue -> comment posted -------------------------------------

echo "Test C1: clean issue posts exactly one triage comment (comment=posted)"
inc
set_state '[]' '[]'
run_helper 1184 NONE --context "A trusted operator must re-file or vouch before this issue is auto-classified."
C1_COMMENTS="$(count_calls comment)"
if [ "$RC" -eq 0 ] \
   && [ "$C1_COMMENTS" = "1" ] \
   && grep -qF 'REFUSED: untrusted opener (assoc=NONE) for #1184' "$OUT" \
   && grep -qF 'comment=posted' "$OUT"; then
  pass_msg "one comment posted, stdout reports comment=posted, exit 0"
else
  fail_msg "expected 1 comment + comment=posted + exit 0 (got comments=$C1_COMMENTS rc=$RC stdout='$(tr '\n' '|' < "$OUT")')"
fi

# --- C9: posted body shape --------------------------------------------------

echo "Test C9: posted body carries sentinel, authorAssociation=NONE, and --context"
inc
set_state '[]' '[]'
run_helper 1184 NONE --context "A trusted operator must re-file or vouch before this issue is auto-classified."
if grep -qF "$SENTINEL" "$GH_BODY" \
   && grep -qF 'authorAssociation=NONE' "$GH_BODY" \
   && grep -qF 'auto-classified' "$GH_BODY"; then
  pass_msg "body contains sentinel + authorAssociation=NONE + context sentence"
else
  fail_msg "posted body missing sentinel/association/context (body='$(tr '\n' '|' < "$GH_BODY")')"
fi

echo "Test C9b: --context is skill-specific (auto-planned variant round-trips)"
inc
set_state '[]' '[]'
run_helper 1185 NONE --context "A trusted operator must re-file or vouch before this issue is auto-planned."
if grep -qF 'auto-planned' "$GH_BODY" && grep -qF 'for #1185' "$OUT"; then
  pass_msg "plan-issue context sentence and issue number round-trip"
else
  fail_msg "context sentence / issue number did not round-trip"
fi

# --- C2: legacy-form prior comment -> skipped -------------------------------

echo "Test C2: prior LEGACY-form triage comment suppresses the post (comment=skipped)"
inc
set_state "$(comment_json OWNER "$LEGACY_BODY")" '[]'
run_helper 1184 NONE --context "ctx"
C2_COMMENTS="$(count_calls comment)"
if [ "$RC" -eq 0 ] && [ "$C2_COMMENTS" = "0" ] && grep -qF 'comment=skipped' "$OUT"; then
  pass_msg "legacy wire-format comment recognized; no duplicate posted"
else
  fail_msg "expected 0 comments + comment=skipped (got comments=$C2_COMMENTS rc=$RC stdout='$(tr '\n' '|' < "$OUT")')"
fi

# --- C4: sentinel-form prior comment -> skipped -----------------------------

echo "Test C4: prior SENTINEL-form triage comment suppresses the post (comment=skipped)"
inc
set_state "$(comment_json OWNER "Untrusted opener refusal.
$SENTINEL")" '[]'
run_helper 1184 NONE --context "ctx"
C4_COMMENTS="$(count_calls comment)"
if [ "$C4_COMMENTS" = "0" ] && grep -qF 'comment=skipped' "$OUT"; then
  pass_msg "HTML sentinel recognized; no duplicate posted"
else
  fail_msg "expected 0 comments + comment=skipped (got comments=$C4_COMMENTS stdout='$(tr '\n' '|' < "$OUT")')"
fi

echo "Test C4b: MEMBER/COLLABORATOR-authored marker also counts as trusted"
inc
set_state "$(comment_json COLLABORATOR "$LEGACY_BODY")" '[]'
run_helper 1184 NONE --context "ctx"
if [ "$(count_calls comment)" = "0" ] && grep -qF 'comment=skipped' "$OUT"; then
  pass_msg "COLLABORATOR-authored marker honored"
else
  fail_msg "COLLABORATOR-authored marker not honored"
fi

# --- C5: anti-spoof ---------------------------------------------------------

echo "Test C5: marker from an UNTRUSTED author is NOT honored (anti-spoof)"
inc
set_state "$(comment_json NONE "$LEGACY_BODY
$SENTINEL")" '[]'
run_helper 1184 NONE --context "ctx"
C5_COMMENTS="$(count_calls comment)"
if [ "$C5_COMMENTS" = "1" ] && grep -qF 'comment=posted' "$OUT"; then
  pass_msg "outsider-authored marker ignored; triage comment still posted"
else
  fail_msg "expected 1 comment + comment=posted (got comments=$C5_COMMENTS stdout='$(tr '\n' '|' < "$OUT")')"
fi

# --- C10: the #1184 accumulation regression, expressed directly -------------

echo "Test C10: two consecutive runs post exactly ONE comment in total"
inc
set_state '[]' '[]'
reset_log
KEEP_LOG=1 run_helper 1184 NONE --context "ctx"
FIRST_OUT="$(cat "$OUT")"
KEEP_LOG=1 run_helper 1184 NONE --context "ctx"
SECOND_OUT="$(cat "$OUT")"
C10_COMMENTS="$(count_calls comment)"
unset KEEP_LOG
if [ "$C10_COMMENTS" = "1" ] \
   && printf '%s' "$FIRST_OUT"  | grep -qF 'comment=posted' \
   && printf '%s' "$SECOND_OUT" | grep -qF 'comment=skipped'; then
  pass_msg "run 1 posts, run 2 skips — no unbounded accumulation"
else
  fail_msg "expected 1 total comment (posted then skipped); got total=$C10_COMMENTS run1='$FIRST_OUT' run2='$SECOND_OUT'"
fi

# --- C3: durable human label ------------------------------------------------

echo "Test C3: label absent -> one 'issue edit --add-label human' (label=applied)"
inc
set_state '[]' '[]'
run_helper 1184 NONE --context "ctx"
C3_EDITS="$(count_calls edit)"
if [ "$C3_EDITS" = "1" ] \
   && grep -qF -- '--add-label human' "$GH_LOG" \
   && grep -qF 'label=applied' "$OUT"; then
  pass_msg "human label applied exactly once; stdout reports label=applied"
else
  fail_msg "expected 1 edit with --add-label human + label=applied (got edits=$C3_EDITS log='$(tr '\n' '|' < "$GH_LOG")' stdout='$(tr '\n' '|' < "$OUT")')"
fi

# --- C6: label already present ----------------------------------------------

echo "Test C6: label already present -> zero edits (label=already-present)"
inc
set_state '[]' "$(labels_json human)"
run_helper 1184 NONE --context "ctx"
C6_EDITS="$(count_calls edit)"
if [ "$C6_EDITS" = "0" ] && grep -qF 'label=already-present' "$OUT"; then
  pass_msg "no redundant issue edit; stdout reports label=already-present"
else
  fail_msg "expected 0 edits + label=already-present (got edits=$C6_EDITS stdout='$(tr '\n' '|' < "$OUT")')"
fi

# --- C7: PIPELINE_LABELS_HUMAN override -------------------------------------

echo "Test C7: PIPELINE_LABELS_HUMAN override is honored"
inc
set_state '[]' '[]'
HUMAN_LABEL_ENV=needs-human run_helper 1184 NONE --context "ctx"
if grep -qF -- '--add-label needs-human' "$GH_LOG" \
   && ! grep -qF -- '--add-label human ' "$GH_LOG" \
   && grep -qF 'label=applied' "$OUT"; then
  pass_msg "override label needs-human applied"
else
  fail_msg "PIPELINE_LABELS_HUMAN override not honored (log='$(tr '\n' '|' < "$GH_LOG")')"
fi

echo "Test C7b: override already present -> label=already-present"
inc
set_state '[]' "$(labels_json needs-human)"
HUMAN_LABEL_ENV=needs-human run_helper 1184 NONE --context "ctx"
if [ "$(count_calls edit)" = "0" ] && grep -qF 'label=already-present' "$OUT"; then
  pass_msg "override label presence detected"
else
  fail_msg "override label presence not detected"
fi

# --- C11: label failure is non-fatal ----------------------------------------

echo "Test C11: 'gh issue edit' failure degrades to label=failed, exit stays 0"
inc
set_state '[]' '[]'
EDIT_RC=1 run_helper 1184 NONE --context "ctx"
C11_COMMENTS="$(count_calls comment)"
if [ "$RC" -eq 0 ] \
   && grep -qF 'label=failed' "$OUT" \
   && grep -qF 'comment=posted' "$OUT" \
   && [ "$C11_COMMENTS" = "1" ]; then
  pass_msg "label failure non-fatal; refusal comment unaffected; exit 0"
else
  fail_msg "expected rc=0 + label=failed + comment=posted (got rc=$RC comments=$C11_COMMENTS stdout='$(tr '\n' '|' < "$OUT")')"
fi

# --- C8: usage errors -------------------------------------------------------

echo "Test C8: no arguments -> exit 2 with a usage line on stderr"
inc
set_state '[]' '[]'
run_helper
if [ "$RC" -eq 2 ] && grep -qiE 'usage' "$ERR"; then
  pass_msg "missing args exits 2 with usage on stderr"
else
  fail_msg "expected rc=2 + usage on stderr (got rc=$RC stderr='$(tr '\n' '|' < "$ERR")')"
fi

echo "Test C8b: missing <association> -> exit 2"
inc
set_state '[]' '[]'
run_helper 1184
if [ "$RC" -eq 2 ]; then
  pass_msg "missing association exits 2"
else
  fail_msg "expected rc=2 for missing association (got rc=$RC)"
fi

echo "Test C8c: missing PIPELINE_REPO -> exit 2"
inc
set_state '[]' '[]'
NO_REPO=1 run_helper 1184 NONE --context "ctx"
if [ "$RC" -eq 2 ]; then
  pass_msg "missing PIPELINE_REPO exits 2"
else
  fail_msg "expected rc=2 for missing PIPELINE_REPO (got rc=$RC)"
fi

echo "Test C8d: usage errors make no mutating gh calls"
inc
set_state '[]' '[]'
run_helper 1184
if [ "$(count_calls comment)" = "0" ] && [ "$(count_calls edit)" = "0" ]; then
  pass_msg "no comment/edit calls on the usage-error path"
else
  fail_msg "usage-error path made mutating gh calls"
fi

# --- stdout purity + round-trip budget --------------------------------------

echo "Test C12: stdout is exactly the single REFUSED line (no comment bytes leak)"
inc
CANARY='SECRET-LEAK-CANARY-XYZ'
set_state "$(comment_json NONE "outsider says $CANARY")" '[]'
run_helper 1184 NONE --context "ctx"
OUT_LINES="$(wc -l < "$OUT" | tr -d ' ')"
if [ "$OUT_LINES" = "1" ] && ! grep -qF "$CANARY" "$OUT"; then
  pass_msg "single stdout line; untrusted comment bytes never echoed"
else
  fail_msg "expected 1 stdout line without the canary (lines=$OUT_LINES stdout='$(tr '\n' '|' < "$OUT")')"
fi

echo "Test C13: exactly one 'gh issue view' round-trip per refusal"
inc
set_state '[]' '[]'
run_helper 1184 NONE --context "ctx"
C13_VIEWS="$(count_calls view)"
if [ "$C13_VIEWS" = "1" ]; then
  pass_msg "one issue view call serves both idempotency scan and label check"
else
  fail_msg "expected exactly 1 'gh issue view' call (got $C13_VIEWS)"
fi

echo "Test C14: --context is optional (helper still refuses cleanly)"
inc
set_state '[]' '[]'
run_helper 1184 NONE
if [ "$RC" -eq 0 ] \
   && grep -qF 'REFUSED: untrusted opener (assoc=NONE) for #1184' "$OUT" \
   && grep -qF 'comment=posted' "$OUT"; then
  pass_msg "helper works without --context"
else
  fail_msg "expected clean refusal without --context (rc=$RC stdout='$(tr '\n' '|' < "$OUT")')"
fi

echo "Test C15: association string is echoed verbatim into stdout and body"
inc
set_state '[]' '[]'
run_helper 1184 FIRST_TIME_CONTRIBUTOR --context "ctx"
if grep -qF 'assoc=FIRST_TIME_CONTRIBUTOR' "$OUT" \
   && grep -qF 'authorAssociation=FIRST_TIME_CONTRIBUTOR' "$GH_BODY"; then
  pass_msg "non-NONE association round-trips into stdout and comment body"
else
  fail_msg "association not round-tripped (stdout='$(tr '\n' '|' < "$OUT")')"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
