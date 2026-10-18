#!/bin/bash
set -uo pipefail
#
# tests/test-evaluate-issue-plan-helpers.sh — the scripts/evaluate-issue-plan-*.sh
# helpers that carry evaluate-issue-plan's multi-command shell behind one call.
#
#   G1  every helper answers --help with rc 0
#   G2  opener gate: a write-access opener (OWNER) -> OPENER=trusted, rc 0,
#       no comment posted
#   G3  negative control (only the association differs: NONE) -> REFUSED line,
#       rc 0, exactly one triage comment carrying the legacy wire text
#   G4  opener gate with no <N> -> rc 2
#   F1  fetch-plan: issue JSON first, then the trusted plan body, rc 0
#   F2  negative control (only the plan author differs: NONE) -> the STOP
#       line, rc 1
#
# `gh` is a PATH stub logging argv; fixtures live under one mktemp -d.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# gh stub: every call appends its argv (one line) to $GH_LOG.
#   api repos/<r>/issues/<n> --jq ...   -> $STUB_ASSOC
#   issue view <n> --json body,comments -> one plan comment by $STUB_PLAN_ASSOC
#   issue view <n> --json number,...    -> a minimal issue JSON line
#   issue comment ...                   -> rc 0 (logged only)
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "api repos/"*) printf '%s\n' "${STUB_ASSOC:-}"; exit 0 ;;
  "issue comment") exit 0 ;;
  "issue view")
    case " $* " in
      *" body,comments "*)
        jq -cn --arg a "${STUB_PLAN_ASSOC:-OWNER}" \
          '{body:"issue body", comments:[{authorAssociation:$a, author:{login:"u"}, createdAt:"2026-01-01T00:00:00Z", body:"## Implementation Plan\n\nSTUB-PLAN-BODY\n"}]}'
        exit 0 ;;
      *) echo '{"number":42,"title":"STUB-ISSUE-TITLE","body":"b"}'; exit 0 ;;
    esac ;;
esac
echo "gh stub: unrecognized call: $*" >&2
exit 2
STUB
chmod +x "$TMP/bin/gh"

GATE="$ROOT/scripts/evaluate-issue-plan-opener-gate.sh"
FETCH="$ROOT/scripts/evaluate-issue-plan-fetch-plan.sh"

# run <script> <args...> — env-isolated run; stdout -> $TMP/out, rc -> $RC.
run() {
  : > "$TMP/gh.log"
  RC=0
  env PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" PIPELINE_REPO=test/repo PIPELINE_BASE_BRANCH=main \
    CLAUDE_PLUGIN_ROOT="$ROOT" "${ENVS[@]}" bash "$@" > "$TMP/out" 2> "$TMP/err" || RC=$?
}
comment_calls() { grep -c '^issue comment' "$TMP/gh.log" || true; }

scenario "G1: --help"
for f in "$GATE" "$FETCH"; do
  if [ -f "$f" ] && bash "$f" --help >/dev/null 2>&1; then
    pass_msg "$(basename "$f") --help rc 0"
  else
    fail_msg "$(basename "$f") missing or --help rc != 0"
  fi
done

scenario "G2: trusted opener passes, no comment"
ENVS=(STUB_ASSOC=OWNER); run "$GATE" 42
if [ "$RC" -eq 0 ] && grep -qx 'OPENER=trusted assoc=OWNER' "$TMP/out" && [ "$(comment_calls)" = 0 ]; then
  pass_msg "OWNER -> OPENER=trusted, rc 0, no comment"
else
  fail_msg "OWNER: rc=$RC out=$(tr '\n' ' ' < "$TMP/out") comments=$(comment_calls)"
fi

scenario "G3: negative control — untrusted opener refused with one triage comment"
ENVS=(STUB_ASSOC=NONE); run "$GATE" 42
if [ "$RC" -eq 0 ] && head -1 "$TMP/out" | grep -qF 'REFUSED: untrusted opener (assoc=NONE) for #42' \
   && [ "$(comment_calls)" = 1 ] && grep '^issue comment' "$TMP/gh.log" | grep -qF 'Untrusted opener (authorAssociation=NONE'; then
  pass_msg "NONE -> REFUSED line, rc 0, one triage comment"
else
  fail_msg "NONE: rc=$RC out=$(tr '\n' ' ' < "$TMP/out") log=$(tr '\n' ' ' < "$TMP/gh.log")"
fi

scenario "G4: missing <N> -> rc 2"
ENVS=(STUB_ASSOC=OWNER); run "$GATE"
if [ "$RC" -eq 2 ]; then pass_msg "no <N> -> rc 2"; else fail_msg "no <N> -> rc $RC"; fi

scenario "F1: fetch-plan prints the issue, then the trusted plan"
ENVS=(STUB_PLAN_ASSOC=OWNER); run "$FETCH" 42
ISSUE_LN=$(grep -n 'STUB-ISSUE-TITLE' "$TMP/out" | head -1 | cut -d: -f1)
PLAN_LN=$(grep -n 'STUB-PLAN-BODY' "$TMP/out" | head -1 | cut -d: -f1)
if [ "$RC" -eq 0 ] && [ -n "$ISSUE_LN" ] && [ -n "$PLAN_LN" ] && [ "$ISSUE_LN" -lt "$PLAN_LN" ]; then
  pass_msg "OWNER plan -> issue JSON (line $ISSUE_LN) before plan body (line $PLAN_LN), rc 0"
else
  fail_msg "OWNER plan: rc=$RC out=$(tr '\n' ' ' < "$TMP/out") err=$(tr '\n' ' ' < "$TMP/err")"
fi

scenario "F2: negative control — untrusted plan author -> STOP line, rc 1"
ENVS=(STUB_PLAN_ASSOC=NONE); run "$FETCH" 42
if [ "$RC" -eq 1 ] && grep -qx 'No implementation plan found for issue #42.' "$TMP/out" && ! grep -qF 'STUB-PLAN-BODY' "$TMP/out"; then
  pass_msg "NONE plan -> STOP line, rc 1, plan not printed"
else
  fail_msg "NONE plan: rc=$RC out=$(tr '\n' ' ' < "$TMP/out")"
fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
