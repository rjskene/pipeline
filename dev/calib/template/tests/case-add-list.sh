#!/usr/bin/env bash
# case-add-list.sh — `calibctl add` and `calibctl list`.
. "$(dirname "$0")/helper.sh"
t_setup

id1="$(calib add "write the release notes" --priority high --tag docs)"
assert_eq "1" "$id1" "first add returns id 1"

id2="$(calib add "fix the flaky lock test" --priority med)"
assert_eq "2" "$id2" "second add returns id 2"

id3="$(calib add "prune stale branches" --priority low --tag chore,ops)"
assert_eq "3" "$id3" "third add returns id 3"

out="$(calib list)"; rc=$?
assert_rc 0 "$rc" "list succeeds with open tasks"
assert_contains "$out" "write the release notes" "list shows the first task"
assert_eq "3" "$(printf '%s\n' "$out" | grep -c '^#')" "list shows three open tasks"

out="$(calib list --priority high)"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^#')" "priority filter narrows to one task"
assert_contains "$out" "high" "priority filter output carries the priority column"

calib complete "$id2" >/dev/null
out="$(calib list)"
assert_eq "2" "$(printf '%s\n' "$out" | grep -c '^#')" "completed tasks drop out of the default list"

out="$(calib list --status all)"
assert_eq "3" "$(printf '%s\n' "$out" | grep -c '^#')" "--status all shows completed tasks too"

out="$(calib list --status done)"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^#')" "--status done shows only completed tasks"

out="$(calib list --status bogus 2>&1)"; rc=$?
assert_rc 2 "$rc" "unknown status is a usage error"
assert_contains "$out" "invalid status" "unknown status explains itself"

out="$(calib list --nope 2>&1)"; rc=$?
assert_rc 2 "$rc" "unknown list option is a usage error"

out="$(calib add "" 2>&1)"; rc=$?
assert_rc 2 "$rc" "empty title is rejected"
assert_contains "$out" "invalid title" "empty title explains itself"

out="$(calib add "something" --priority urgent 2>&1)"; rc=$?
assert_rc 2 "$rc" "unknown priority is rejected"

out="$(calib add "something" --tag "a b" 2>&1)"; rc=$?
assert_rc 2 "$rc" "tags containing spaces are rejected"

empty_home="$(mktemp -d)"
out="$(CALIB_HOME="$empty_home" calib list 2>&1)"; rc=$?
rm -rf "$empty_home"
assert_rc 1 "$rc" "listing an empty ledger returns rc 1"
assert_contains "$out" "no matching tasks" "empty ledger says so"

t_report
