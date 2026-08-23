#!/usr/bin/env bash
set -uo pipefail

# Contract test + drift guard for the shared high-uncertainty carve-out regex
# (issue #1039).
#
# scripts/_high-uncertainty-match.sh is the single source of truth that exports
# HIGH_UNCERTAINTY_RE — a surgical word-bound pattern. Word-bound ONLY the three
# proven-noisy short tokens (auth/lock/race) with explicit stems; the distinctive
# tokens (concurrency/deadlock/security/crypto/migration/data-loss) stay
# substrings so cryptography/migrations/etc still match. The carve-out fails
# CLOSED to Opus — substring can only over-match — so tightening is confined to
# the proven-noise tokens.
#
# This file pins BOTH directions of the word-membership contract table (verbatim
# from the issue) AND a structural drift guard: both call sites source the one
# shared helper and carry NO inline copy of the regex.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/_high-uncertainty-match.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$HELPER" ]; then
  echo "ERROR: shared helper not found at $HELPER" >&2
  exit 1
fi

# shellcheck source=scripts/_high-uncertainty-match.sh
. "$HELPER"

if [ -z "${HIGH_UNCERTAINTY_RE:-}" ]; then
  echo "ERROR: sourcing $HELPER did not export HIGH_UNCERTAINTY_RE" >&2
  exit 1
fi

echo "== test-high-uncertainty-match (issue #1039) =="

# A candidate is high-uncertainty iff it matches HIGH_UNCERTAINTY_RE (case-insensitive).
matches() { printf '%s' "$1" | grep -iEq "$HIGH_UNCERTAINTY_RE"; }

assert_match() {
  local candidate="$1"
  inc
  if matches "$candidate"; then
    pass_msg "MUST match: '$candidate'"
  else
    fail_msg "MUST match but did NOT: '$candidate'"
  fi
}

assert_no_match() {
  local candidate="$1"
  inc
  if matches "$candidate"; then
    fail_msg "MUST NOT match but DID: '$candidate'"
  else
    pass_msg "MUST NOT match: '$candidate'"
  fi
}

echo "-- auth token (word-bound stem) --"
# MUST match: auth, authn, authz, authentication, authorization, authenticate(d), authorize(d)
assert_match "auth"
assert_match "authn"
assert_match "authz"
assert_match "authentication"
assert_match "authorization"
assert_match "authenticate"      # FIX 1: verb form MUST match
assert_match "authenticated"
assert_match "authorize"         # FIX 1: verb form MUST match
assert_match "authorized"
# MUST NOT match: authoring, author, authored, authority, authentic
assert_no_match "authoring"
assert_no_match "author"
assert_no_match "authored"
assert_no_match "authority"
assert_no_match "authentic"      # FIX 1: bare adjective MUST NOT match

echo "-- lock token (disambiguated concurrency phrases, issue #1063) --"
# Bare lock/locks/locking/locked are POLYSEMOUS ("locked tests"/"locked suite"/
# "locked down" are benign meta-prose) — dropped per #1063. Only genuine
# concurrency phrasings trip the carve-out now.
# MUST match (genuine concurrency mechanism):
assert_match "lock contention"
assert_match "lock-free"
assert_match "file lock"
assert_match "a file lock guards the cache"
assert_match "mutex"
# MUST NOT match (benign polysemy — the #1057 FPs):
assert_no_match "lock"
assert_no_match "locks"
assert_no_match "locking"
assert_no_match "locked"
assert_no_match "locked tests"
assert_no_match "locked suite"
assert_no_match "locked down"
assert_no_match "file locked"
assert_no_match "locked-test invariant"
# PRESERVE the #1039 boundary cases verbatim: block(s), clock, unlock
assert_no_match "block"
assert_no_match "blocks"
assert_no_match "clock"
assert_no_match "unlock"

echo "-- race token (word-bound stem) --"
# MUST match: race, races, race condition
assert_match "race"
assert_match "races"
assert_match "race condition"
# MUST NOT match: trace, grace, embrace, racetrack
assert_no_match "trace"
assert_no_match "grace"
assert_no_match "embrace"
assert_no_match "racetrack"

echo "-- distinctive tokens (kept substrings) --"
# MUST match: each distinctive token, AND its longer forms (substring kept on purpose).
assert_match "concurrency"
assert_match "deadlock"
assert_match "security"
assert_match "crypto"
assert_match "migration"
assert_match "data-loss"
# substring is intentional for these — cryptography/migrations must still match.
assert_match "cryptography"
assert_match "migrations"

echo "-- mixed-case / in-prose smoke checks --"
assert_match "This fixes a race condition in the concurrency path."
assert_no_match "control-plane files for direct operator authoring; Blocks the sibling"

echo "-- drift guard: single source of truth (both scripts source the helper) --"
PB="$ROOT/scripts/path-b-execute-eligible.sh"
PC="$ROOT/scripts/plan-campaign.sh"

# Each call site must SOURCE the shared helper.
inc
if grep -Eq '_high-uncertainty-match\.sh' "$PB"; then
  pass_msg "path-b-execute-eligible.sh sources _high-uncertainty-match.sh"
else
  fail_msg "path-b-execute-eligible.sh does NOT source _high-uncertainty-match.sh"
fi

inc
if grep -Eq '_high-uncertainty-match\.sh' "$PC"; then
  pass_msg "plan-campaign.sh sources _high-uncertainty-match.sh"
else
  fail_msg "plan-campaign.sh does NOT source _high-uncertainty-match.sh"
fi

# Neither call site may carry an inline assignment of the regex literal.
inc
if grep -Eq '^[[:space:]]*HIGH_UNCERTAINTY_RE=' "$PB"; then
  fail_msg "path-b-execute-eligible.sh still has an inline HIGH_UNCERTAINTY_RE= literal"
else
  pass_msg "path-b-execute-eligible.sh has NO inline HIGH_UNCERTAINTY_RE= literal"
fi

inc
if grep -Eq '^[[:space:]]*(HU_RE|HIGH_UNCERTAINTY_RE)=' "$PC"; then
  fail_msg "plan-campaign.sh still has an inline HU_RE=/HIGH_UNCERTAINTY_RE= literal"
else
  pass_msg "plan-campaign.sh has NO inline HU_RE=/HIGH_UNCERTAINTY_RE= literal"
fi

# Repo-grep guard: no other tracked source carries an inline substring copy of
# this vocabulary list (the broken `...|race|lock|...|auth|...` substring form).
# Scan TRACKED files only (git ls-files) — a bare `grep -r` walks gitignored
# dirs (e.g. /dev/audits/, .gitignore:16) and is green in CI (fresh checkout
# has no gitignored files) but red on any dev host with local artifacts (#1255).
# Exclude this test + the helper + the docs that legitimately quote the list.
scan_tracked_stray() {
  (cd "$ROOT" && git ls-files -z -- '*.sh' \
    | xargs -0 grep -Eln "concurrency\|race\|lock\|deadlock\|security\|auth\|crypto\|migration\|data-loss" 2>/dev/null) \
    | grep -v '^CHANGELOG\.md$' \
    | grep -v '/test-high-uncertainty-match\.sh$' \
    | grep -v '/_high-uncertainty-match\.sh$' \
    || true
}
inc
STRAY=$(scan_tracked_stray)
if [ -z "$STRAY" ]; then
  pass_msg "no other tracked shell source carries an inline substring copy of the regex"
else
  fail_msg "stray inline substring copy of the regex found in: $STRAY"
fi

# Drift-guard scope regression (issue #1255): the STRAY scan above must ignore
# gitignored dirs (e.g. /dev/audits/, .gitignore:16), not just excluded ones.
echo "-- drift guard: guard ignores a gitignored file containing a matching string --"
inc
PLANTED="$ROOT/dev/audits/test-high-uncertainty-match-regression-$$.sh"
mkdir -p "$(dirname "$PLANTED")"
cleanup_planted() { rm -f "$PLANTED"; }
trap cleanup_planted EXIT
echo '# concurrency|race|lock|deadlock|security|auth|crypto|migration|data-loss' > "$PLANTED"
PLANTED_STRAY=$(scan_tracked_stray)
cleanup_planted
trap - EXIT
if printf '%s' "$PLANTED_STRAY" | grep -q "test-high-uncertainty-match-regression"; then
  fail_msg "guard scanned the gitignored planted file (scope leak)"
else
  pass_msg "guard ignored the gitignored planted file"
fi

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
