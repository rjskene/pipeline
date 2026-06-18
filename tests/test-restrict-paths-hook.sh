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

# Genuine main-repo top — used by the LIVE-protected assertions so they model a
# real consumer/orchestrator project dir whose realpath has NO
# .claude/worktrees/<prefix>-N- ancestor segment. When the suite runs from the
# main repo, git-common-dir is <main>/.git so MAIN_REPO == REPO_ROOT (identical
# to the pre-#1058 behavior). When it runs from INSIDE a worktree (the executor
# session), REPO_ROOT itself sits under .claude/worktrees/<prefix>-N- and would
# be wrongly exempted by the new worktree carve-out — so the LIVE-protected
# cases must root at the real main repo, not the worktree. Falls back to
# REPO_ROOT if git is unavailable. (#1058)
if MAIN_REPO="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"; then
  MAIN_REPO="$(cd "$(dirname "$MAIN_REPO")" 2>/dev/null && pwd)" || MAIN_REPO="$REPO_ROOT"
else
  MAIN_REPO="$REPO_ROOT"
fi

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
# Rooted at MAIN_REPO (not REPO_ROOT) so this LIVE-protected assertion holds
# whether the suite runs from the main repo OR from inside a worktree (#1058).
G_PAYLOAD=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/settings.json"}}' "$MAIN_REPO")
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
H2_PAYLOAD=$(printf '{"tool_name":"Bash","tool_input":{"command":"printf x > %s/.claude/settings.json"}}' "$MAIN_REPO")
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
# Post-#1067 the destination must EXIST (the existence gate applies to siblings
# too), so create a REAL sibling worktree dir as a direct sibling of $REPO_ROOT
# (WORKTREE_PATTERN is dirname(PROJECT_DIR)-anchored, so the worktree must be a
# sibling of CLAUDE_PROJECT_DIR == $REPO_ROOT). The dir is cleaned by the SINGLE
# existing EXIT trap installed in Block 5 (which references $SIBLING_WT_ROOT) —
# do NOT add a second trap (a second EXIT trap clobbers the first and leaks the
# Block-5 nested scaffold).
SIBLING_WT_ROOT="$(dirname "$REPO_ROOT")/wt-42-x"
mkdir -p "$SIBLING_WT_ROOT/.claude/hooks"
H33_PAYLOAD=$(printf '{"tool_name":"Bash","tool_input":{"command":"cp .claude/hooks/restrict_paths.py %s/.claude/hooks/restrict_paths.py"}}' "$SIBLING_WT_ROOT")
run_hook_set \
  "Bash cp to EXISTING sibling worktree-destination hooks file ALLOWED (sync carve-out, #1067)" \
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

# ---------------------------------------------------------------------------
# Block 5 — Nested-worktree .claude/hooks/ edits allowed; live still blocked (#1058).
# setup-worktree.sh creates NESTED worktrees at
# <project>/.claude/worktrees/<prefix>-N-<slug>/. Editing a .claude/hooks/* file
# INSIDE such a worktree is legitimate (effect only after merge+pull) and must be
# allowed. Editing the LIVE main-repo <project>/.claude/hooks/* must STILL block.
# ---------------------------------------------------------------------------
# The nested worktree MUST be a DIRECT child of CLAUDE_PROJECT_DIR (== $REPO_ROOT
# here) — i.e. $REPO_ROOT/.claude/worktrees/<slug>/ — matching production
# (scripts/setup-worktree.sh:67 → $MAIN_REPO/.claude/worktrees/<prefix>-N-<slug>)
# and the PROJECT_DIR-anchored NESTED_WORKTREE_PATTERN that #1067 introduces.
# The prior scaffold interposed a mktemp segment
# (<root>/.rp-nested-wt-test.X/.claude/worktrees/...), which a PROJECT_DIR-anchored
# pattern does NOT match — that would flip 5a/5b/5d/5e (and 6d) ALLOWED→BLOCKED.
# Use a disposable, uniquely-suffixed slug under the REAL project .claude/worktrees/
# dir so it never collides with a live worktree; clean via the SINGLE EXIT trap.
WT_SLUG="wt-516-rptest-$$"
NESTED_WT_ROOT="$REPO_ROOT/.claude/worktrees/$WT_SLUG"
NESTED_WT_DIR="$NESTED_WT_ROOT/.claude/hooks"
NESTED_WT_HOOK="$NESTED_WT_DIR/block_cross_run_reads.py"
mkdir -p "$NESTED_WT_DIR"; echo "x" > "$NESTED_WT_HOOK"
# Exactly ONE EXIT trap for the whole file — removes BOTH the nested worktree
# scaffold (this block) and the Block-4 Task-3.3 sibling worktree ($SIBLING_WT_ROOT,
# defined above). A second `trap ... EXIT` would clobber this one and leak a dir.
trap "rm -rf '$NESTED_WT_ROOT' '$SIBLING_WT_ROOT'" EXIT

# 5a (positive, Write): editing a .claude/hooks/* file inside a nested worktree is ALLOWED.
P5A=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$NESTED_WT_HOOK")
run_hook_set "nested-worktree .claude/hooks/ Write ALLOWED (#1058)" "$P5A" 0 --no-grep

# 5b (positive, Edit): same path via Edit is ALLOWED.
P5B=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$NESTED_WT_HOOK")
run_hook_set "nested-worktree .claude/hooks/ Edit ALLOWED (#1058)" "$P5B" 0 --no-grep

# 5c (SECURITY regression, Write): editing the LIVE main-repo .claude/hooks/* is STILL BLOCKED.
# This is the disarm case the guard exists to prevent — the broadened carve-out must NOT permit it.
# Rooted at MAIN_REPO (a genuine non-worktree project dir) so the assertion is faithful whether
# the suite runs from the main repo OR from inside a worktree (whose own path would otherwise be
# wrongly exempted by the worktree carve-out). (#1058)
P5C=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/hooks/restrict_paths.py"}}' "$MAIN_REPO")
run_hook_set "LIVE main-repo .claude/hooks/ Write STILL BLOCKED (#1058 security regression)" "$P5C" 2 "BLOCKED: cannot modify protected file"

# 5d (positive, Bash absolute token): cp ONTO a nested-worktree hooks file ALLOWED.
P5D=$(printf '{"tool_name":"Bash","tool_input":{"command":"cp src.py %s"}}' "$NESTED_WT_HOOK")
run_hook_set "Bash cp to nested-worktree hooks file ALLOWED (#1058)" "$P5D" 0 --no-grep

# 5e (positive, Bash command-string sync carve-out): cp to nested-worktree dest ALLOWED
# even when a relative .claude/hooks/ source token is present (the sync case, not disarm).
# $NESTED_WT_DIR is the real on-disk PROJECT_DIR-direct hooks dir created in the scaffold above.
P5E=$(printf '{"tool_name":"Bash","tool_input":{"command":"cp .claude/hooks/foo.py %s/foo.py"}}' "$NESTED_WT_DIR")
run_hook_set "Bash cp relative-src to nested-worktree dest ALLOWED (#1058 sync carve-out)" "$P5E" 0 --no-grep

# 5f (SECURITY regression, Bash relative in-place disarm): no worktree dest token → STILL BLOCKED.
run_hook_set "Bash relative in-place disarm of .claude/hooks/ STILL BLOCKED (#1058 security regression)" \
  '{"tool_name":"Bash","tool_input":{"command":"echo \"\" > .claude/hooks/restrict_paths.py"}}' \
  2 "BLOCKED: cannot modify protected file"

# ---------------------------------------------------------------------------
# Block 6 — Worktree-dest carve-out bypass closure (#1067).
# The #1058 carve-out (_command_has_worktree_dest) returned True if ANY absolute
# token anywhere in the command matched the worktree regex — a pure string match
# with no realpath/exists/registration check. So a hardcoded, NON-EXISTENT
# worktree-shaped token appended anywhere disabled the WHOLE protected-command
# scan, letting an in-place relative disarm of a LIVE control file slip through.
# These cases lock the closure: a worktree-shaped token only exempts the scan
# when it is the actual positional copy/move TARGET *and* resolves to an EXISTING,
# registered worktree. All scaffolds are rooted under $REPO_ROOT (NOT /tmp — the
# extractor `continue`s on /tmp candidates, so a /tmp scaffold would pass for the
# wrong reason). NO new EXIT trap here — reuse the single trap from Block 5.
# ---------------------------------------------------------------------------

# 6a: a buried .claude/worktrees/<prefix>-N-/ token with an EMPTY slug must NOT be
# treated as a worktree dest, so an in-place relative disarm in the same command is BLOCKED.
# (Closes the empty-slug `wt-12-/` match that the free-floating `[^/]*` pattern allowed.)
run_hook_set "Bash empty-slug wt-12- token does NOT skip scan (relative disarm STILL BLOCKED)" \
  '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ .claude/settings.json ; : /srv/x/.claude/worktrees/wt-12-/blah"}}' \
  2 "BLOCKED: cannot modify protected file"

# 6b: a hardcoded NON-EXISTENT, project-dir-independent worktree-shaped token appended anywhere
# must NOT disable the protected-command scan — the relative in-place disarm STILL BLOCKS.
# This is the exact issue #1067 repro shape (`: /srv/anything/.claude/worktrees/wt-1-x/blah`).
run_hook_set "Bash hardcoded non-existent worktree token does NOT skip scan (#1067)" \
  '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ .claude/settings.json ; : /srv/anything/.claude/worktrees/wt-1-x/blah"}}' \
  2 "BLOCKED: cannot modify protected file"

# 6c: even a PROJECT_DIR-prefixed worktree-shaped token that does NOT EXIST on disk must not
# skip the scan — existence is required, not just shape. Build the token under $REPO_ROOT so it
# is PROJECT_DIR-prefixed (and thus survives the Task-1 anchor) yet has no on-disk ancestor.
BOGUS_WT="$REPO_ROOT/.claude/worktrees/wt-999-nonexistent/.claude/hooks/x"
P6C=$(printf '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ .claude/settings.json ; : %s"}}' "$BOGUS_WT")
run_hook_set "Bash non-existent PROJECT_DIR worktree token does NOT skip scan (#1067)" "$P6C" \
  2 "BLOCKED: cannot modify protected file"

# 6d: a real cp INTO an EXISTING PROJECT_DIR-anchored nested worktree destination still passes
# (sync carve-out preserved). $NESTED_WT_DIR is created in Block 5 as a real on-disk dir under
# $REPO_ROOT/.claude/worktrees/<slug>/.claude/hooks, so the dest's nearest existing ancestor
# resolves inside a registered worktree → the carve-out still fires.
P6D=$(printf '{"tool_name":"Bash","tool_input":{"command":"cp .claude/hooks/foo.py %s/foo.py"}}' "$NESTED_WT_DIR")
run_hook_set "Bash cp into EXISTING registered worktree still ALLOWED (#1067 sync preserved)" "$P6D" 0 --no-grep

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
