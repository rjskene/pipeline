#!/usr/bin/env bash
# case-report.sh — `calibctl report`.
. "$(dirname "$0")/helper.sh"
t_setup

out="$(calib report)"; rc=$?
assert_rc 0 "$rc" "report on an empty ledger succeeds"
assert_match "$out" "^total +0$" "empty ledger reports zero tasks"

calib add "cut the release" --priority high >/dev/null
calib add "answer the review" --priority med >/dev/null
calib add "tidy the changelog" --priority low >/dev/null
calib add "delete dead code" --priority high >/dev/null
calib complete 2 >/dev/null

out="$(calib report)"
assert_contains "$out" "Task report" "report has a heading"
assert_match "$out" "^open +3$" "report counts open tasks"
assert_match "$out" "^done +1$" "report counts done tasks"
assert_match "$out" "^total +4$" "report counts all tasks"
assert_match "$out" "^ +high +2$" "report counts high-priority tasks"
assert_match "$out" "^ +med +1$" "report counts med-priority tasks"
assert_match "$out" "^ +low +1$" "report counts low-priority tasks"
assert_contains "$out" "oldest open: #1 cut the release" "report names the oldest open task"

t_report
