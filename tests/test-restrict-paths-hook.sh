#!/bin/bash
# Tests for hooks/restrict_paths.py — fail-open guard and false-positive
# avoidance in Bash command path extraction. See issue #353 for the full
# rationale (#339 is the env-propagation root cause).
#
# Pattern modeled on tests/test-derive-pr-title-escaping.sh:
# env-isolated subprocess invocation, PASS/FAIL counters, set -euo pipefail.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/restrict_paths.py"

PASS=0
FAIL=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# run_hook_unset <desc> <payload_json> <expected_rc> <stderr_grep_1> [<stderr_grep_2>...]
# Runs the hook with CLAUDE_PLUGIN_ROOT deliberately NOT set in the env.
run_hook_unset() {
  local desc="$1"; shift
  local payload="$1"; shift
  local expected_rc="$1"; shift
  local tmp_err rc
  tmp_err=$(mktemp)
  set +e
  printf '%s' "$payload" | env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$REPO_ROOT" python3 "$HOOK" >/dev/null 2>"$tmp_err"
  rc=$?
  set -e
  local stderr; stderr=$(cat "$tmp_err"); rm -f "$tmp_err"
  if [ "$rc" -ne "$expected_rc" ]; then
    fail_msg "$desc" "expected exit $expected_rc, got $rc; stderr='$stderr'"
    return
  fi
  while [ "$#" -gt 0 ]; do
    if ! printf '%s' "$stderr" | grep -q -- "$1"; then
      fail_msg "$desc" "stderr missing '$1': '$stderr'"
      return
    fi
    shift
  done
  pass_msg "$desc"
}

# run_hook_set <desc> <payload_json> <expected_rc> [stderr_grep|--no-grep]
# Runs the hook with CLAUDE_PLUGIN_ROOT set correctly to REPO_ROOT.
run_hook_set() {
  local desc="$1"; shift
  local payload="$1"; shift
  local expected_rc="$1"; shift
  local stderr_grep="${1:-}"
  local tmp_err rc
  tmp_err=$(mktemp)
  set +e
  printf '%s' "$payload" | env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" python3 "$HOOK" >/dev/null 2>"$tmp_err"
  rc=$?
  set -e
  local stderr; stderr=$(cat "$tmp_err"); rm -f "$tmp_err"
  if [ "$rc" -ne "$expected_rc" ]; then
    fail_msg "$desc" "expected exit $expected_rc, got $rc; stderr='$stderr'"
    return
  fi
  if [ -n "$stderr_grep" ] && [ "$stderr_grep" != "--no-grep" ]; then
    if ! printf '%s' "$stderr" | grep -q -- "$stderr_grep"; then
      fail_msg "$desc" "stderr missing '$stderr_grep': '$stderr'"
      return
    fi
  fi
  pass_msg "$desc"
}

# ---------------------------------------------------------------------------
# Block 1 — CLAUDE_PLUGIN_ROOT absent must enforce normally (#966).
# ---------------------------------------------------------------------------
# The old fail-open block (lines 10-21 of restrict_paths.py) has been
# deleted. An unset CLAUDE_PLUGIN_ROOT now changes nothing — enforcement
# runs as normal.

# 1a: out-of-boundary Write path with CLAUDE_PLUGIN_ROOT unset → exit 2 + BLOCKED
run_hook_unset \
  "unset CLAUDE_PLUGIN_ROOT + out-of-boundary Write — must block (exit 2, BLOCKED)" \
  '{"tool_name":"Write","tool_input":{"file_path":"/etc/shadow"}}' \
  2 \
  "BLOCKED"

# 1b: in-boundary path with CLAUDE_PLUGIN_ROOT unset → exit 0, no spurious warning
IB_PAYLOAD=$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s/CLAUDE.md"}}' "$REPO_ROOT")
run_hook_unset \
  "unset CLAUDE_PLUGIN_ROOT + in-boundary Read — must allow (exit 0, no warning)" \
  "$IB_PAYLOAD" \
  0

# ---------------------------------------------------------------------------
# Block 2 — Skip env-var literals and // substrings in Bash command text
# (Task 2 of #353).
# ---------------------------------------------------------------------------

# Payload A: literal ${CLAUDE_PLUGIN_ROOT} in command text, env IS set.
# Today this hard-blocks because the regex finds /hooks/restrict_paths.py
# (or similar) as a substring; the env-var literal scrub must drop it.
run_hook_set \
  "skip literal \${CLAUDE_PLUGIN_ROOT} in command text" \
  '{"tool_name":"Bash","tool_input":{"command":"python3 ${CLAUDE_PLUGIN_ROOT}/hooks/restrict_paths.py"}}' \
  0 \
  --no-grep

# Payload B: bare $HOME literal in command text, env IS set.
run_hook_set \
  "skip bare \$HOME literal in command text" \
  '{"tool_name":"Bash","tool_input":{"command":"echo $HOME/anything"}}' \
  0 \
  --no-grep

# Payload C (regression guard): a real out-of-boundary path must STILL block.
# /etc/passwd exists, is not a worktree, is not under ~/.claude, so the hook
# must exit 2 with the BLOCKED diagnostic. This pins the env-var scrub against
# over-reach.
run_hook_set \
  "baseline still blocks real out-of-boundary /etc/passwd reference" \
  '{"tool_name":"Bash","tool_input":{"command":"cat /etc/passwd"}}' \
  2 \
  "BLOCKED: path outside project boundary: /etc/passwd"

# Payload D: jq alternative-operator // substring must not be treated as a
# path. This is the today-this-bit-us regression from the issue Context.
run_hook_set \
  "skip jq // alternative-operator substring in command text" \
  '{"tool_name":"Bash","tool_input":{"command":"jq '"'"'.foo | .bar // empty'"'"'"}}' \
  0 \
  --no-grep

# Payload D2 (regression guard for the // skip): real out-of-boundary path
# with a leading double-slash MUST still block. POSIX collapses // to /, so
# //etc/passwd is equivalent to /etc/passwd and must not be allowed through
# by a too-broad startswith("//") shortcut. Pins against the bypass that
# review caught.
SS="$(printf '/%s' /)"
D2_PAYLOAD=$(printf '{"tool_name":"Bash","tool_input":{"command":"cat %setc/passwd"}}' "$SS")
run_hook_set \
  "regression: cat <double-slash>etc/passwd blocked (no // bypass)" \
  "$D2_PAYLOAD" \
  2 \
  "BLOCKED: path outside project boundary"

# ---------------------------------------------------------------------------
# Block 3 — Baseline behavior unchanged when env is healthy and no
# false-positive substrings appear (Task 3 of #353).
# ---------------------------------------------------------------------------

# Payload E: Read /etc/shadow — out-of-boundary, must block.
run_hook_set \
  "baseline: Read /etc/shadow blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"/etc/shadow"}}' \
  2 \
  "BLOCKED: path outside project boundary"

# Payload F: Read inside the repo (CLAUDE.md) — allowed.
F_PAYLOAD=$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s/CLAUDE.md"}}' "$REPO_ROOT")
run_hook_set \
  "baseline: Read repo-local CLAUDE.md allowed" \
  "$F_PAYLOAD" \
  0 \
  --no-grep

# Payload G: Write to .claude/settings.json — must block as protected.
G_PAYLOAD=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/settings.json"}}' "$REPO_ROOT")
run_hook_set \
  "baseline: Write to .claude/settings.json blocked (protected)" \
  "$G_PAYLOAD" \
  2 \
  "BLOCKED: cannot modify protected file"

# ---------------------------------------------------------------------------
# Block 4 — Bash-branch protected-file coverage (issue #964).
# The protected-file check used to be gated to Write/Edit only, so an inline
# Bash command (sed -i, >, cp-onto) could disarm a guard in place. These pin
# the three layered fixes: ungate the protected check for all extracted paths,
# scan the raw command string for relative protected targets, and add a 4th
# PROTECTED_PATTERN for the plugin's own cache hooks dir. Plus regression pins
# that worktree-destination copies and benign refs are NOT over-blocked.
# ---------------------------------------------------------------------------

# Task 1 — plugin's own cache hooks dir IS protected. Build a path under $HOME
# (real allowed root) so is_allowed passes and only is_protected decides.
H1_PAYLOAD=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/plugins/cache/x/pipeline/0.0.0/hooks/restrict_paths.py"}}' "$HOME")
run_hook_set \
  "plugin-cache hooks dir is protected (Write blocked)" \
  "$H1_PAYLOAD" \
  2 \
  "BLOCKED: cannot modify protected file"

# Task 2 — Bash command with an ABSOLUTE in-project protected path is blocked.
# Write a real file first so the absolute+exists extractor sees it, then the
# (now-ungated) protected loop must block it. Use printf-into-settings.json.
H2_PAYLOAD=$(printf '{"tool_name":"Bash","tool_input":{"command":"printf x > %s/.claude/settings.json"}}' "$REPO_ROOT")
run_hook_set \
  "Bash absolute in-project protected path blocked (.claude/settings.json)" \
  "$H2_PAYLOAD" \
  2 \
  "BLOCKED: cannot modify protected file"

# Task 3.1 — in-place RELATIVE disarm of settings.json is blocked by the
# command-string scan (the absolute+exists extractor never sees relative
# targets).
run_hook_set \
  "Bash relative in-place disarm of .claude/settings.json blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ .claude/settings.json"}}' \
  2 \
  "BLOCKED: cannot modify protected file"

# Task 3.2 — in-place RELATIVE disarm of a hooks file is blocked.
run_hook_set \
  "Bash relative in-place disarm of .claude/hooks/ blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"echo \"\" > .claude/hooks/restrict_paths.py"}}' \
  2 \
  "BLOCKED: cannot modify protected file"

# Task 3.3 — worktree-DESTINATION copy is ALLOWED (the sync carve-out).
# Build <parent>/<prefix>-<N>-... where <parent> is dirname of REPO_ROOT and
# <prefix> is the default PIPELINE_WORKTREE_PREFIX (wt).
WT_PARENT="$(dirname "$REPO_ROOT")"
H33_PAYLOAD=$(printf '{"tool_name":"Bash","tool_input":{"command":"cp .claude/hooks/restrict_paths.py %s/wt-42-x/.claude/hooks/restrict_paths.py"}}' "$WT_PARENT")
run_hook_set \
  "Bash cp to worktree-destination hooks file ALLOWED (sync carve-out)" \
  "$H33_PAYLOAD" \
  0 \
  --no-grep

# Task 4.1 — worktree-sync wrapper invocation is NOT over-blocked (hook only
# sees the wrapper, never the inner cp).
run_hook_set \
  "Bash bash scripts/sync-worktrees.sh not over-blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"bash scripts/sync-worktrees.sh"}}' \
  0 \
  --no-grep

# Task 4.2 — benign protected-adjacent read of .claude/logs/ is allowed
# (.claude/logs/ is not protected).
run_hook_set \
  "Bash cat .claude/logs/run.json not over-blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .claude/logs/run.json"}}' \
  0 \
  --no-grep

# Task 4.3 — benign grep mentioning 'settings' under .claude/scratch/ allowed.
run_hook_set \
  "Bash grep settings .claude/scratch/x not over-blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"grep settings .claude/scratch/x"}}' \
  0 \
  --no-grep

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
