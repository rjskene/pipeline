#!/usr/bin/env bash
# case-lock.sh — unit tests for lib/lock.sh.
. "$(dirname "$0")/helper.sh"
t_setup

# shellcheck source=../lib/store.sh
. "$PROJECT_ROOT/lib/store.sh"
# shellcheck source=../lib/lock.sh
. "$PROJECT_ROOT/lib/lock.sh"

export CALIB_LOCK_STALE=999

rc=0; lock_acquire ledger 1 || rc=$?
assert_rc 0 "$rc" "an uncontended lock is acquired"

rc=0; lock_held ledger || rc=$?
assert_rc 0 "$rc" "lock_held reports the held lock"

rc=0; lock_acquire ledger 1 || rc=$?
assert_rc 3 "$rc" "a contended lock times out with rc 3"

rc=0; lock_acquire other 1 || rc=$?
assert_rc 0 "$rc" "a differently-named lock is independent"
lock_release other

lock_release ledger
rc=0; lock_held ledger || rc=$?
assert_rc 1 "$rc" "lock_held is false after release"

rc=0; lock_acquire ledger 1 || rc=$?
assert_rc 0 "$rc" "the lock can be re-acquired after release"

CALIB_LOCK_STALE=0
rc=0; lock_acquire ledger 1 || rc=$?
assert_rc 0 "$rc" "a stale lock is reclaimed"
CALIB_LOCK_STALE=999
lock_release ledger

out="$(with_lock ledger echo held)"; rc=$?
assert_rc 0 "$rc" "with_lock propagates success"
assert_eq "held" "$out" "with_lock passes stdout through"

rc=0; lock_held ledger || rc=$?
assert_rc 1 "$rc" "with_lock releases the lock afterwards"

rc=0; with_lock ledger bash -c 'exit 7' || rc=$?
assert_rc 7 "$rc" "with_lock propagates the command exit status"

rc=0; lock_held ledger || rc=$?
assert_rc 1 "$rc" "with_lock releases the lock even when the command fails"

t_report
