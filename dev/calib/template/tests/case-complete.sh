#!/usr/bin/env bash
# case-complete.sh — `calibctl complete`.
. "$(dirname "$0")/helper.sh"
t_setup

id="$(calib add "ship the thing" --priority high)"

out="$(calib complete "$id")"; rc=$?
assert_rc 0 "$rc" "completing an open task succeeds"
assert_contains "$out" "completed #$id" "complete confirms the id"

out="$(calib list --status done)"
assert_contains "$out" "ship the thing" "completed task appears under --status done"
assert_contains "$out" "done" "completed task carries the done status"

out="$(calib complete "$id")"; rc=$?
assert_rc 0 "$rc" "completing an already-done task is idempotent"

out="$(calib complete 99 2>&1)"; rc=$?
assert_rc 4 "$rc" "completing an unknown id returns rc 4"
assert_contains "$out" "no such task" "unknown id explains itself"

out="$(calib complete abc 2>&1)"; rc=$?
assert_rc 2 "$rc" "a non-numeric id is a usage error"
assert_contains "$out" "invalid id" "non-numeric id explains itself"

out="$(calib complete 2>&1)"; rc=$?
assert_rc 2 "$rc" "complete with no argument is a usage error"

t_report
