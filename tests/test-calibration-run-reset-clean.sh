#!/bin/bash
set -uo pipefail
#
# Unit tests for clean_untracked() in scripts/calibration-run.sh (#1599).
#
# After calibration run 52 the Playwright MCP server's untracked
# `.playwright-mcp/` directory survived `--reset` and `--bootstrap` committed
# it into the seed. clean_untracked() removes untracked, non-ignored files
# outside `.claude/` before the seed is touched: ignored files (`.calib/`)
# and untracked `.claude/` state (settings.local.json) must survive, and the
# `calib: removed <N> untracked file(s)` line prints only when N > 0.
#
# HERMETIC: only dispatch() and clean_untracked() are extracted and evaluated
# against a temporary git repo standing in for the sandbox.
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_lib/git-sandbox.sh
source "$ROOT/tests/_lib/git-sandbox.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Export GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1 and
# XDG_CONFIG_HOME=$TMP/xdg (empty) so neither global config nor the default
# $XDG_CONFIG_HOME/git/ignore (~/.config/git/ignore) can mask
# .claude/settings.local.json — otherwise the .claude/ survival check passes
# whether or not clean_untracked excludes .claude/.
mkdir -p "$TMP/xdg"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$TMP/xdg"

eval "$(sed -n '/^dispatch() {/,/^}/p; /^clean_untracked() {/,/^}/p' "$ROOT/scripts/calibration-run.sh")"
if declare -f clean_untracked >/dev/null 2>&1; then
  pass_msg "clean_untracked extracted from calibration-run.sh"
else
  fail_msg "clean_untracked could not be extracted (empty sed range)"
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

SANDBOX="$TMP/sb"
DRY=0
mkdir -p "$SANDBOX"
git_init_sandbox "$SANDBOX"
printf '.calib/\n' > "$SANDBOX/.gitignore"
printf 'seed\n' > "$SANDBOX/README.md"
git -C "$SANDBOX" add .gitignore README.md
git -C "$SANDBOX" commit -q -m seed

# (a) untracked run artefacts go; ignored and .claude/ state stays.
mkdir -p "$SANDBOX/.playwright-mcp" "$SANDBOX/.calib" "$SANDBOX/.claude"
printf 'snap\n' > "$SANDBOX/.playwright-mcp/page.yml"
printf 'log\n' > "$SANDBOX/.playwright-mcp/console.log"
printf 'state\n' > "$SANDBOX/.calib/state"
printf '{}\n' > "$SANDBOX/.claude/settings.local.json"

if git -C "$SANDBOX" check-ignore -q .claude/settings.local.json; then
  fail_msg "fixture: .claude/settings.local.json is ignored — survival check would be vacuous"
else
  pass_msg "fixture: .claude/settings.local.json is untracked and not ignored"
fi

out="$(clean_untracked 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass_msg "(a) rc 0" || fail_msg "(a) rc=$rc"
[ ! -e "$SANDBOX/.playwright-mcp" ] && pass_msg "(a) .playwright-mcp/ removed" \
  || fail_msg "(a) .playwright-mcp/ survived"
[ -f "$SANDBOX/.calib/state" ] && pass_msg "(a) ignored .calib/state survives" \
  || fail_msg "(a) ignored .calib/state removed"
[ -f "$SANDBOX/.claude/settings.local.json" ] && pass_msg "(a) .claude/settings.local.json survives" \
  || fail_msg "(a) .claude/settings.local.json removed"
[ "$(cat "$SANDBOX/README.md" 2>/dev/null)" = "seed" ] && pass_msg "(a) tracked README.md untouched" \
  || fail_msg "(a) tracked README.md changed"
n="$(printf '%s\n' "$out" | grep -c '^calib: removed 2 untracked file(s)$')"
[ "$n" -eq 1 ] && pass_msg "(a) one 'calib: removed 2 untracked file(s)' line" \
  || fail_msg "(a) want one 'calib: removed 2' line, got $n in: $out"

# (b) clean tree: no message; .claude/settings.local.json must not count.
out="$(clean_untracked 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass_msg "(b) rc 0 on clean tree" || fail_msg "(b) rc=$rc"
if printf '%s\n' "$out" | grep -q 'calib: removed'; then
  fail_msg "(b) unexpected removal message: $out"
else
  pass_msg "(b) no removal message on clean tree"
fi
[ -f "$SANDBOX/.claude/settings.local.json" ] && pass_msg "(b) .claude/settings.local.json still present" \
  || fail_msg "(b) .claude/settings.local.json removed"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
