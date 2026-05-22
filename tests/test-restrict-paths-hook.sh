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
# Block 1 — Fail-open when CLAUDE_PLUGIN_ROOT is unset (Task 1 of #353).
# ---------------------------------------------------------------------------
# Acceptance: hook exits 0 with diagnostic on stderr; diagnostic references
# both CLAUDE_PLUGIN_ROOT and #339 so consumers can self-route to the env-
# propagation root-cause issue.

run_hook_unset \
  "fail-open when CLAUDE_PLUGIN_ROOT unset — exit 0 with #339 diagnostic" \
  '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
  0 \
  "CLAUDE_PLUGIN_ROOT not set" \
  "#339"

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

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
