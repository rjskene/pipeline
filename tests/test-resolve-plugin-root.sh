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

# Build a fake git repo under $1 with a configurable origin URL ($2) and an
# optional sentinel manifest ($3 = "sentinel" to create .claude-plugin/plugin.json).
# Uses GIT_CONFIG_GLOBAL=/dev/null on every git call so the developer's global
# hooks / signing config can't stall the test.
make_repo() {
  local dir="$1" origin="$2" sentinel="${3:-}"
  mkdir -p "$dir"
  GIT_CONFIG_GLOBAL=/dev/null git -C "$dir" init -q
  GIT_CONFIG_GLOBAL=/dev/null git -C "$dir" remote add origin "$origin"
  if [ "$sentinel" = "sentinel" ]; then
    mkdir -p "$dir/.claude-plugin"
    printf '{}' > "$dir/.claude-plugin/plugin.json"
  fi
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

# ---------------- Case 12: local-override resolves to repo toplevel ----------------
# Opt-in set + cwd is the rjskene/pipeline repo + sentinel present →
# CLAUDE_PLUGIN_ROOT must be the repo toplevel, NOT the cache.
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h12"; make_home "$HOME" 0.4.0
  make_repo "$TMP/repo12" "https://github.com/rjskene/pipeline.git" sentinel
  cd "$TMP/repo12"
  export PIPELINE_USE_LOCAL_PLUGIN=true
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 12: local-override resolves to repo toplevel when opt-in set + origin matches + sentinel present" \
  "$TMP/repo12" "$ACTUAL"

# ---------------- Case 13: opt-in unset → falls through to cache ----------------
# Proves opt-in is REQUIRED — identity + sentinel alone are not enough.
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT PIPELINE_USE_LOCAL_PLUGIN
  HOME="$TMP/h13"; make_home "$HOME" 0.4.0
  make_repo "$TMP/repo13" "https://github.com/rjskene/pipeline.git" sentinel
  cd "$TMP/repo13"
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 13: PIPELINE_USE_LOCAL_PLUGIN unset → resolves to cache, not repo" \
  "$TMP/h13/.claude/plugins/cache/claude-pipeline/pipeline/0.4.0" "$ACTUAL"

# ---------------- Case 14: origin mismatch → falls through to cache ----------------
# Proves identity gate holds — opt-in alone is not enough.
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h14"; make_home "$HOME" 0.4.0
  make_repo "$TMP/repo14" "https://github.com/someone-else/other.git" sentinel
  cd "$TMP/repo14"
  export PIPELINE_USE_LOCAL_PLUGIN=true
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 14: origin mismatch → resolves to cache, not repo (identity gate)" \
  "$TMP/h14/.claude/plugins/cache/claude-pipeline/pipeline/0.4.0" "$ACTUAL"

# ---------------- Case 15: sentinel missing → falls through to cache ----------------
# Proves sentinel gate holds — opt-in + matching origin alone are not enough.
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  HOME="$TMP/h15"; make_home "$HOME" 0.4.0
  make_repo "$TMP/repo15" "https://github.com/rjskene/pipeline.git"
  cd "$TMP/repo15"
  export PIPELINE_USE_LOCAL_PLUGIN=true
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 15: sentinel missing → resolves to cache, not repo (sentinel gate)" \
  "$TMP/h15/.claude/plugins/cache/claude-pipeline/pipeline/0.4.0" "$ACTUAL"

# ---------------- Case 16: local-override beats pre-set env ----------------
# Locks in the ordering: the override block sits ABOVE the pre-set guard so
# a stale CLAUDE_PLUGIN_ROOT inherited from an outer shell is replaced by the
# working tree (the whole point of the issue — see #294).
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT
  export CLAUDE_PLUGIN_ROOT="/already/set"
  HOME="$TMP/h16"; make_home "$HOME" 0.4.0
  make_repo "$TMP/repo16" "https://github.com/rjskene/pipeline.git" sentinel
  cd "$TMP/repo16"
  export PIPELINE_USE_LOCAL_PLUGIN=true
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 16: local-override beats pre-set CLAUDE_PLUGIN_ROOT when opt-in set + identity matches" \
  "$TMP/repo16" "$ACTUAL"

# ---------------- Case 17: pipeline.config.example documents the opt-in ----------------
# Consumer installs copy from pipeline.config.example, so the var must be
# documented there with a default of `false`. Per #857/#762 this knob was
# demoted from a live line to a commented escape-hatch (default `false`
# single-sourced at the _resolve-plugin-root.sh read site), so accept the
# commented form — the documented value must still be `false`.
EXAMPLE="$SCRIPT_DIR/../pipeline.config.example"
if [ -f "$EXAMPLE" ] && grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_USE_LOCAL_PLUGIN=false$' "$EXAMPLE"; then
  pass_msg "Case 17: pipeline.config.example documents PIPELINE_USE_LOCAL_PLUGIN=false"
else
  fail_msg "Case 17: pipeline.config.example must document 'PIPELINE_USE_LOCAL_PLUGIN=false' (live or commented)"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
