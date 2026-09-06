#!/usr/bin/env bash
# case-auth.sh — `calibctl auth` and lib/auth.sh.
. "$(dirname "$0")/helper.sh"
t_setup

# shellcheck source=../lib/store.sh
. "$PROJECT_ROOT/lib/store.sh"
# shellcheck source=../lib/lock.sh
. "$PROJECT_ROOT/lib/lock.sh"
# shellcheck source=../lib/auth.sh
. "$PROJECT_ROOT/lib/auth.sh"

out="$(calib auth show 2>&1)"; rc=$?
assert_rc 6 "$rc" "showing a token before one is issued returns rc 6"
assert_contains "$out" "no token issued" "missing token explains itself"

token="$(calib auth issue)"; rc=$?
assert_rc 0 "$rc" "issuing a token succeeds"
assert_match "$token" "^[0-9a-f]{32}$" "issued token is 32 hex characters"

shown="$(calib auth show)"
assert_eq "$token" "$shown" "show returns the issued token"

second="$(calib auth issue)"
assert_match "$second" "^[0-9a-f]{32}$" "re-issuing produces a well-formed token"
assert_eq "$second" "$(calib auth show)" "show returns the newest token"

out="$(calib auth revoke)"; rc=$?
assert_rc 0 "$rc" "revoking an issued token succeeds"
assert_contains "$out" "token revoked" "revoke confirms itself"

out="$(calib auth show 2>&1)"; rc=$?
assert_rc 6 "$rc" "show after revoke returns rc 6"

out="$(calib auth bogus 2>&1)"; rc=$?
assert_rc 2 "$rc" "an unknown auth subcommand is a usage error"

rc=0; auth_token_valid "deadbeefdeadbeefdeadbeefdeadbeef" || rc=$?
assert_rc 0 "$rc" "auth_token_valid accepts 32 hex characters"
rc=0; auth_token_valid "nope" || rc=$?
assert_rc 1 "$rc" "auth_token_valid rejects a short token"

t_report
