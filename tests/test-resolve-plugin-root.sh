#!/bin/bash
set -uo pipefail

# Tests for scripts/_resolve-plugin-root.sh — sourceable helper that self-resolves
# CLAUDE_PLUGIN_ROOT from ~/.claude/plugins/cache/claude-pipeline/pipeline/<latest>/
# when the env var is empty/unset.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/_resolve-plugin-root.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_msg "$label"
  else
    fail_msg "$label (expected='$expected' actual='$actual')"
  fi
}

# Each case runs in a subshell with a hermetic HOME so we never touch the
# developer's real ~/.claude/plugins cache.
make_home() {
  local home="$1"; shift
  mkdir -p "$home/.claude/plugins/cache/claude-pipeline/pipeline"
  for v in "$@"; do
    mkdir -p "$home/.claude/plugins/cache/claude-pipeline/pipeline/$v"
  done
}

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# ---------------- Case 1: env already set → no-op ----------------
(
  unset CLAUDE_PLUGIN_ROOT
  export CLAUDE_PLUGIN_ROOT="/already/set"
  HOME="$TMP/h1"; make_home "$HOME" 0.4.0
  # shellcheck disable=SC1090
  source "$HELPER"
  [ "$CLAUDE_PLUGIN_ROOT" = "/already/set" ]
) && pass_msg "Case 1: pre-set env is not overwritten" || fail_msg "Case 1: pre-set env is not overwritten"

# ---------------- Case 2: env empty + no cache → no-op ----------------
(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h2"; mkdir -p "$HOME"
  # shellcheck disable=SC1090
  source "$HELPER"
  [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]
) && pass_msg "Case 2: empty env + no cache → stays empty" || fail_msg "Case 2: empty env + no cache → stays empty"

# ---------------- Case 3: env empty + single version ----------------
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h3"; make_home "$HOME" 0.4.0
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 3: single version → resolves to it" \
  "$TMP/h3/.claude/plugins/cache/claude-pipeline/pipeline/0.4.0" "$ACTUAL"

# ---------------- Case 4: stable beats prerelease ----------------
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h4"; make_home "$HOME" 0.3.1 0.4.0 0.4.0-rc.1 0.4.0-rc.2
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 4: stable 0.4.0 beats 0.4.0-rc.N and 0.3.1" \
  "$TMP/h4/.claude/plugins/cache/claude-pipeline/pipeline/0.4.0" "$ACTUAL"

# ---------------- Case 5: only prereleases → pick highest ----------------
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h5"; make_home "$HOME" 0.4.0-rc.1 0.4.0-rc.2
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 5: only RCs → picks 0.4.0-rc.2" \
  "$TMP/h5/.claude/plugins/cache/claude-pipeline/pipeline/0.4.0-rc.2" "$ACTUAL"

# ---------------- Case 6: idempotent sourcing ----------------
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h6"; make_home "$HOME" 0.4.0
  # shellcheck disable=SC1090
  source "$HELPER"
  FIRST="$CLAUDE_PLUGIN_ROOT"
  # shellcheck disable=SC1090
  source "$HELPER"
  [ "$FIRST" = "$CLAUDE_PLUGIN_ROOT" ] && echo OK
)
assert_eq "Case 6: sourcing twice is idempotent" "OK" "$ACTUAL"

# ---------------- Case 7: silent on success ----------------
STDOUT=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h7"; make_home "$HOME" 0.4.0
  # shellcheck disable=SC1090
  source "$HELPER"
)
assert_eq "Case 7: helper produces no stdout on success" "" "$STDOUT"

# ---------------- Case 8: cross-MMP — newer prerelease beats older stable ----------------
# Regression: previously the resolver globally partitioned stable vs prerelease, so 0.7.2
# (stable) beat 0.8.0-rc.5 (prerelease) even though 0.8.0-rc.5 is the newer version.
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h8"; make_home "$HOME" 0.7.2 0.8.0-rc.5
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 8: 0.8.0-rc.5 beats 0.7.2 (newer M.m.p wins across stable/pre)" \
  "$TMP/h8/.claude/plugins/cache/claude-pipeline/pipeline/0.8.0-rc.5" "$ACTUAL"

# ---------------- Case 9: full dogfood-machine reproducer ----------------
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h9"
  make_home "$HOME" 0.2.0 0.3.1 0.4.0 0.4.0-rc.1 0.4.0-rc.2 0.5.0 0.5.0-rc.1 \
                    0.7.2 0.8.0-rc.2 0.8.0-rc.3 0.8.0-rc.4 0.8.0-rc.5
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 9: full reproducer set → picks 0.8.0-rc.5" \
  "$TMP/h9/.claude/plugins/cache/claude-pipeline/pipeline/0.8.0-rc.5" "$ACTUAL"

# ---------------- Case 10: stable still wins within same M.m.p ----------------
# Case 4 already covers 0.4.0 vs 0.4.0-rc.1/rc.2 alongside 0.3.1; this tightens to the
# pure same-M.m.p invariant so a regression that flipped the stable-beats-pre tie-break
# inside a single M.m.p line is caught in isolation.
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h10"; make_home "$HOME" 0.4.0 0.4.0-rc.2
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 10: same-M.m.p — stable 0.4.0 beats 0.4.0-rc.2" \
  "$TMP/h10/.claude/plugins/cache/claude-pipeline/pipeline/0.4.0" "$ACTUAL"

# ---------------- Case 11: rc number ordering is numeric, not lexical ----------------
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h11"; make_home "$HOME" 0.8.0-rc.2 0.8.0-rc.10
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 11: 0.8.0-rc.10 beats 0.8.0-rc.2 (numeric rc ordering)" \
  "$TMP/h11/.claude/plugins/cache/claude-pipeline/pipeline/0.8.0-rc.10" "$ACTUAL"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
