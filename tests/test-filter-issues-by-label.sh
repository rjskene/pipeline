#!/bin/bash
set -uo pipefail
#
# Unit tests for scripts/filter-issues-by-label.sh (#1269) — the hermetic
# label filter that scopes the /pipeline:status issue set BEFORE render.
#
# Contract under test:
#   --issues <file>          required; readable (-r, so /dev/fd/N works)
#   --label <l>              repeatable; repeats are a UNION (OR), which
#                            deliberately DIFFERS from `gh issue list --label`
#                            (AND)
#   --emit issues|trackers   default `issues`
#
# Semantics:
#   * zero --label            → identity passthrough, exit 0
#   * non-tracker issues      → survive iff they carry one of the labels
#   * tracker issues          → CHILD-DRIVEN: a tracker survives iff >= 1 of
#                               its `## Rollout sequence` children survives.
#                               The tracker's OWN labels do not keep it.
#   * zero matches            → stdout `[]`, exit 0, stderr WARN
#
# Tracker detection MUST use the label predicate
# `[.labels[].name] | any(. == "tracker")` on the RAW `gh issue list` payload.
# `.is_tracker` is synthesised INSIDE the renderer (render-status-table.sh:233)
# and is absent here — scenario 9a pins that input fact.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILTER="$REPO_ROOT/scripts/filter-issues-by-label.sh"
PARSE_CHILDREN="$REPO_ROOT/scripts/parse-tracker-children.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); echo "    $2"; }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------------------
# Payloads
# ----------------------------------------------------------------------
#
# FLAT_PAYLOAD — no trackers; exercises argv + label-OR semantics (1–8).
cat > "$TMP/flat.json" <<'JSON'
[
  {"number": 1, "title": "feat(redline): one", "labels": [{"name": "redline"}],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"},
  {"number": 2, "title": "feat(mailroom): two", "labels": [{"name": "mailroom"}],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"},
  {"number": 3, "title": "chore(core): three", "labels": [],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"},
  {"number": 4, "title": "chore(release): four", "labels": [{"name": "autorelease: pending"}],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"}
]
JSON

# TRACKER_PAYLOAD — trackers + children + orphans (9–16).
#
# CHECKLIST SYNTAX IS LOAD-BEARING. parse-tracker-children.sh:75 matches ONLY
#   ^- \[[ x]\] \*\*#[0-9]+[[:space:]]*[-—]
# The `**` and the trailing ASCII-hyphen/em-dash are MANDATORY. A loose bullet
# (`- [ ] #901 child one`) parses to ZERO children, which drops EVERY tracker
# and makes scenarios 10/11/12 pass for the WRONG reason. Scenario 0 below is
# the tripwire that catches exactly that.
cat > "$TMP/trackers-payload.json" <<'JSON'
[
  {"number": 900, "title": "tracker: redline rollout", "labels": [{"name": "tracker"}],
   "body": "Tracker A.\n\n## Rollout sequence\n\n- [ ] **#901 — child one**\n- [ ] **#902 — child two**\n",
   "updatedAt": "2026-05-20T12:00:00Z"},
  {"number": 901, "title": "feat(redline): child one", "labels": [{"name": "redline"}],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"},
  {"number": 902, "title": "feat(mailroom): child two", "labels": [],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"},

  {"number": 910, "title": "tracker: mailroom rollout", "labels": [{"name": "tracker"}],
   "body": "Tracker B.\n\n## Rollout sequence\n\n- [ ] **#911 — child three**\n- [ ] **#912 — child four**\n",
   "updatedAt": "2026-05-20T12:00:00Z"},
  {"number": 911, "title": "feat(mailroom): child three", "labels": [],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"},
  {"number": 912, "title": "chore(mailroom): child four", "labels": [],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"},

  {"number": 930, "title": "tracker: self-labelled rollout", "labels": [{"name": "tracker"}, {"name": "redline"}],
   "body": "Tracker C — carries the filter label itself.\n\n## Rollout sequence\n\n- [ ] **#931 — child five**\n- [ ] **#932 — child six**\n",
   "updatedAt": "2026-05-20T12:00:00Z"},
  {"number": 931, "title": "feat(other): child five", "labels": [],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"},
  {"number": 932, "title": "feat(other): child six", "labels": [],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"},

  {"number": 940, "title": "tracker: sectionless rollout", "labels": [{"name": "tracker"}, {"name": "redline"}],
   "body": "Tracker D has no rollout section at all.\n\n## Notes\n\n- nothing to see here\n",
   "updatedAt": "2026-05-20T12:00:00Z"},

  {"number": 950, "title": "fix(redline): orphan on redline", "labels": [{"name": "redline"}],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"},
  {"number": 951, "title": "fix(mailroom): orphan off redline", "labels": [],
   "body": "", "updatedAt": "2026-05-20T12:00:00Z"}
]
JSON

# ----------------------------------------------------------------------
# Scenario 0 — FIXTURE PRE-CHECK (blocking; runs BEFORE scenarios 9–16)
# ----------------------------------------------------------------------
#
# Tripwire, not a deliverable: it asserts a property of the PAYLOAD (that the
# strict-form bullets parse), never of the code under test. If it goes red,
# someone loosened the checklist syntax and scenarios 10/11/12 have silently
# become vacuous. Hard-fail the WHOLE file so no tracker-rule assertion runs
# against a mis-parsed payload.
#
# parse-tracker-children.sh emits one number per LINE; normalise with
# `tr '\n' ' '` before comparing against the space-separated expectation.
precheck_children() {
  local num="$1"
  jq -r --argjson n "$num" '.[] | select(.number == $n) | .body' "$TMP/trackers-payload.json" \
    | bash "$PARSE_CHILDREN" - \
    | tr '\n' ' ' \
    | sed -e 's/[[:space:]]*$//'
}

PRECHECK_OK=1
PRECHECK_DETAIL=""
for pair in "900:901 902" "910:911 912" "930:931 932"; do
  t="${pair%%:*}"
  want="${pair#*:}"
  got=$(precheck_children "$t")
  if [ "$got" != "$want" ]; then
    PRECHECK_OK=0
    PRECHECK_DETAIL="${PRECHECK_DETAIL}tracker #$t: want '$want', got '$got'; "
  fi
  # Non-zero child count is part of the tripwire — an empty parse drops every
  # tracker and makes the tracker-rule scenarios vacuous.
  if [ -z "$got" ]; then
    PRECHECK_OK=0
    PRECHECK_DETAIL="${PRECHECK_DETAIL}tracker #$t parsed ZERO children; "
  fi
done

inc
if [ "$PRECHECK_OK" -eq 1 ]; then
  pass_msg "0. fixture pre-check: strict-form bullets parse to the expected children"
else
  fail_msg "0. fixture pre-check: strict-form bullets parse to the expected children" \
    "$PRECHECK_DETAIL -- parse-tracker-children.sh:75 matches ONLY '- [ ] **#N — ' (the ** and the trailing hyphen/em-dash are mandatory). Fix the payload bullets; do NOT relax this check."
  echo ""
  echo "=========================================================="
  echo "ABORT: fixture pre-check failed — the tracker-rule scenarios"
  echo "would pass VACUOUSLY against a mis-parsed payload."
  echo "TOTAL: $TESTS  PASS: $PASS  FAIL: $FAIL"
  echo "=========================================================="
  exit 1
fi

# ----------------------------------------------------------------------
# Task 1 — argv + label-OR filter over non-tracker issues (1–8)
# ----------------------------------------------------------------------

# 1. no args → exit 2 + usage on stderr
inc
bash "$FILTER" >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'usage' "$TMP/err"; then
  pass_msg "1. no args → exit 2 + usage on stderr"
else
  fail_msg "1. no args → exit 2 + usage on stderr" "rc=$rc, stderr=$(cat "$TMP/err")"
fi

# 2. --issues pointing at a nonexistent file → exit 2 + stderr names the path
inc
bash "$FILTER" --issues "$TMP/does-not-exist.json" >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'does-not-exist.json' "$TMP/err"; then
  pass_msg "2. missing --issues file → exit 2 + stderr names the path"
else
  fail_msg "2. missing --issues file → exit 2 + stderr names the path" "rc=$rc, stderr=$(cat "$TMP/err")"
fi

# 3. unknown flag → exit 2
inc
bash "$FILTER" --issues "$TMP/flat.json" --bogus-flag >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 2 ]; then
  pass_msg "3. unknown flag → exit 2"
else
  fail_msg "3. unknown flag → exit 2" "rc=$rc, stderr=$(cat "$TMP/err")"
fi

# 4. no --label → identity passthrough (stdout array == input array, exit 0)
inc
out=$(bash "$FILTER" --issues "$TMP/flat.json" 2>"$TMP/err"); rc=$?
want=$(jq -S -c '.' "$TMP/flat.json")
got=$(printf '%s' "$out" | jq -S -c '.' 2>/dev/null)
if [ "$rc" -eq 0 ] && [ -n "$got" ] && [ "$got" = "$want" ]; then
  pass_msg "4. no --label → identity passthrough, exit 0"
else
  fail_msg "4. no --label → identity passthrough, exit 0" "rc=$rc, got='$got', stderr=$(cat "$TMP/err")"
fi

# 5. single --label redline → only issues carrying `redline` survive
inc
out=$(bash "$FILTER" --issues "$TMP/flat.json" --label redline 2>"$TMP/err"); rc=$?
got=$(printf '%s' "$out" | jq -c 'map(.number)' 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$got" = "[1]" ]; then
  pass_msg "5. single --label redline → only the redline issue survives"
else
  fail_msg "5. single --label redline → only the redline issue survives" "rc=$rc, numbers='$got', stderr=$(cat "$TMP/err")"
fi

# 6. two --label flags → UNION (an issue carrying EITHER label survives).
#    Deliberately different from `gh issue list --label a --label b` (AND).
inc
out=$(bash "$FILTER" --issues "$TMP/flat.json" --label redline --label mailroom 2>"$TMP/err"); rc=$?
got=$(printf '%s' "$out" | jq -c 'map(.number) | sort' 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$got" = "[1,2]" ]; then
  pass_msg "6. repeated --label is a UNION (OR), not an intersection"
else
  fail_msg "6. repeated --label is a UNION (OR), not an intersection" "rc=$rc, numbers='$got', stderr=$(cat "$TMP/err")"
fi

# 7. a label name containing `:` and a space matches EXACTLY and is not a
#    regex/substring — `autorelease` alone must NOT match `autorelease: pending`.
inc
out=$(bash "$FILTER" --issues "$TMP/flat.json" --label 'autorelease: pending' 2>"$TMP/err"); rc=$?
got=$(printf '%s' "$out" | jq -c 'map(.number)' 2>/dev/null)
out2=$(bash "$FILTER" --issues "$TMP/flat.json" --label 'autorelease' 2>/dev/null); rc2=$?
got2=$(printf '%s' "$out2" | jq -c 'map(.number)' 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$got" = "[4]" ] && [ "$rc2" -eq 0 ] && [ "$got2" = "[]" ]; then
  pass_msg "7. label names with ':' and spaces match by exact string equality (no regex/substring)"
else
  fail_msg "7. label names with ':' and spaces match by exact string equality (no regex/substring)" \
    "exact: rc=$rc numbers='$got' (want [4]); prefix: rc=$rc2 numbers='$got2' (want []); stderr=$(cat "$TMP/err")"
fi

# 8. zero matches → stdout `[]`, exit 0, stderr WARN naming the labels
inc
out=$(bash "$FILTER" --issues "$TMP/flat.json" --label nosuchlabel 2>"$TMP/err"); rc=$?
got=$(printf '%s' "$out" | jq -c '.' 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$got" = "[]" ] \
   && grep -q 'WARN' "$TMP/err" && grep -qF 'nosuchlabel' "$TMP/err"; then
  pass_msg "8. zero matches → [] on stdout, exit 0, WARN naming the labels on stderr"
else
  fail_msg "8. zero matches → [] on stdout, exit 0, WARN naming the labels on stderr" \
    "rc=$rc, stdout='$got', stderr=$(cat "$TMP/err")"
fi

# ----------------------------------------------------------------------
# Task 2 — tracker survival rule + --emit trackers (9–16)
# ----------------------------------------------------------------------

# Single filtered run reused by 9/10/11/12/16. Non-vacuity guard: every
# "issue N is ABSENT" assertion below is conjoined with TRACKER_RUN_OK, so a
# missing script (empty stdout) can never satisfy an absence assertion.
TRACKER_OUT=$(bash "$FILTER" --issues "$TMP/trackers-payload.json" --label redline 2>"$TMP/terr"); TRACKER_RC=$?
TRACKER_RUN_OK=0
if [ "$TRACKER_RC" -eq 0 ] && printf '%s' "$TRACKER_OUT" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
  TRACKER_RUN_OK=1
fi
TRACKER_NUMS=$(printf '%s' "$TRACKER_OUT" | jq -c 'map(.number) | sort' 2>/dev/null)

has_num() {
  printf '%s' "$TRACKER_OUT" | jq -e --argjson n "$1" 'map(.number) | index($n) != null' >/dev/null 2>&1
}

# 9. a tracker with >= 1 SURVIVING child is KEPT
inc
if [ "$TRACKER_RUN_OK" -eq 1 ] && has_num 900; then
  pass_msg "9. tracker #900 (child #901 carries redline) is KEPT"
else
  fail_msg "9. tracker #900 (child #901 carries redline) is KEPT" \
    "rc=$TRACKER_RC, numbers='$TRACKER_NUMS', stderr=$(cat "$TMP/terr")"
fi

# 9a. INPUT-SHAPE GUARD (tripwire, not a deliverable). `.is_tracker` does NOT
#     exist on a raw `gh issue list --json number,title,labels,body,updatedAt`
#     payload — it is synthesised inside render-status-table.sh:233. A filter
#     written as `select(.is_tracker)` therefore emits NOTHING. Red only if
#     someone rewrites the payload to pre-synthesise the field, which would
#     mask the real spec gap.
inc
is_tracker_count=$(jq '[.[] | select(.is_tracker)] | length' "$TMP/trackers-payload.json" 2>/dev/null)
label_tracker_count=$(jq '[.[] | select([.labels[].name] | any(. == "tracker"))] | length' "$TMP/trackers-payload.json" 2>/dev/null)
if [ "$is_tracker_count" = "0" ] && [ "$label_tracker_count" = "4" ]; then
  pass_msg "9a. input-shape guard: .is_tracker absent on the raw payload; the label predicate finds all 4 trackers"
else
  fail_msg "9a. input-shape guard: .is_tracker absent on the raw payload; the label predicate finds all 4 trackers" \
    "select(.is_tracker) → '$is_tracker_count' (want 0); label predicate → '$label_tracker_count' (want 4)"
fi

# 10. a tracker whose children ALL fall outside the filter is DROPPED
inc
if [ "$TRACKER_RUN_OK" -eq 1 ] && ! has_num 910; then
  pass_msg "10. tracker #910 (no child carries redline) is DROPPED"
else
  fail_msg "10. tracker #910 (no child carries redline) is DROPPED" \
    "rc=$TRACKER_RC, numbers='$TRACKER_NUMS', stderr=$(cat "$TMP/terr")"
fi

# 11. a tracker that itself carries the filter label but has NO surviving
#     child is DROPPED — the rule is CHILD-driven, not self-labelled
inc
if [ "$TRACKER_RUN_OK" -eq 1 ] && ! has_num 930; then
  pass_msg "11. tracker #930 carries redline itself but has no surviving child → DROPPED (child-driven rule)"
else
  fail_msg "11. tracker #930 carries redline itself but has no surviving child → DROPPED (child-driven rule)" \
    "rc=$TRACKER_RC, numbers='$TRACKER_NUMS', stderr=$(cat "$TMP/terr")"
fi

# 12. a tracker with NO `## Rollout sequence` section is DROPPED under any
#     --label (it has no children, so nothing can keep it)
inc
if [ "$TRACKER_RUN_OK" -eq 1 ] && ! has_num 940; then
  pass_msg "12. tracker #940 (no ## Rollout sequence section) is DROPPED"
else
  fail_msg "12. tracker #940 (no ## Rollout sequence section) is DROPPED" \
    "rc=$TRACKER_RC, numbers='$TRACKER_NUMS', stderr=$(cat "$TMP/terr")"
fi

# 13. --emit trackers prints exactly the SURVIVING tracker numbers,
#     space-separated, with no stray CR (CRLF-jq seam, #1158)
inc
out=$(bash "$FILTER" --issues "$TMP/trackers-payload.json" --label redline --emit trackers 2>"$TMP/err"); rc=$?
has_cr=0
case "$out" in *$'\r'*) has_cr=1 ;; esac
if [ "$rc" -eq 0 ] && [ "$out" = "900" ] && [ "$has_cr" -eq 0 ]; then
  pass_msg "13. --emit trackers → surviving tracker numbers only, space-separated, no CR"
else
  fail_msg "13. --emit trackers → surviving tracker numbers only, space-separated, no CR" \
    "rc=$rc, stdout='$out' (want '900'), has_cr=$has_cr, stderr=$(cat "$TMP/err")"
fi

# 14. --emit trackers with NO --label prints EVERY tracker number
inc
out=$(bash "$FILTER" --issues "$TMP/trackers-payload.json" --emit trackers 2>"$TMP/err"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "900 910 930 940" ]; then
  pass_msg "14. --emit trackers with no --label → every tracker number"
else
  fail_msg "14. --emit trackers with no --label → every tracker number" \
    "rc=$rc, stdout='$out' (want '900 910 930 940'), stderr=$(cat "$TMP/err")"
fi

# 15. --emit with an unrecognised value → exit 2
inc
bash "$FILTER" --issues "$TMP/trackers-payload.json" --emit bogus >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 2 ]; then
  pass_msg "15. --emit bogus → exit 2"
else
  fail_msg "15. --emit bogus → exit 2" "rc=$rc, stderr=$(cat "$TMP/err")"
fi

# 16. non-tracker CHILDREN filter on their OWN labels — a non-matching child
#     of a SURVIVING tracker does not get rescued by its parent
inc
if [ "$TRACKER_RUN_OK" -eq 1 ] && has_num 901 && ! has_num 902; then
  pass_msg "16. child #902 (no redline) does not survive via its surviving parent #900"
else
  fail_msg "16. child #902 (no redline) does not survive via its surviving parent #900" \
    "rc=$TRACKER_RC, numbers='$TRACKER_NUMS' (want #901 present, #902 absent), stderr=$(cat "$TMP/terr")"
fi

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "TOTAL: $TESTS  PASS: $PASS  FAIL: $FAIL"
echo "=========================================================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
