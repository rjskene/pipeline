#!/bin/bash
# Tests for hooks/restrict_paths.py git-worktree-pointer boundary handling.
#
# Issue #337 (Bug 2b): inside the web-eval flow the evaluator runs git
# operations on the feature worktree. A linked worktree's real git dir lives
# at <main>/.git/worktrees/<slug>/, which resolves OUTSIDE the worktree's
# CLAUDE_PROJECT_DIR. The legitimacy proof is the worktree's own .git pointer
# file (a regular file containing `gitdir: <target>`) under an allowed root.
#
# NOTE ON PATHS: restrict_paths.py unconditionally allows /tmp (it `continue`s
# on any candidate that startswith("/tmp")). A mktemp scaffold under /tmp can
# therefore NEVER be blocked, which would make the positive boundary check
# pass for the wrong reason. So the scaffold is anchored under the repo root
# (a disposable worktree on a non-/tmp filesystem path) and cleaned on exit.
#
# Env-isolated subprocess invocation matching tests/test-restrict-paths-hook.sh
# (`env -i PATH=... CLAUDE_PROJECT_DIR=... CLAUDE_PLUGIN_ROOT=...`).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/restrict_paths.py"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Single trap covering the whole scaffold (hygiene: the prior draft's second
# trap clobbered the first, leaking the first temp dir).
BASE="$(mktemp -d "$REPO_ROOT/.rp-worktree-test.XXXXXX")"
trap "rm -rf '$BASE'" EXIT

# --- positive: linked-worktree git-dir resolves as allowed via its pointer ---
# Faithful layout: PROJECT_DIR is the worktree; its real git dir lives OUTSIDE
# the worktree, under the main repo. The worktree's own .git pointer file at
# <PROJECT_DIR>/.git names that target. Without the #337 allowance the hook
# blocks any path under the out-of-boundary git dir.
WT="$BASE/main/.claude/worktrees/foo"     # PROJECT_DIR (the linked worktree)
GITDIR="$BASE/main/.git/worktrees/foo"    # real git dir, OUTSIDE the worktree
mkdir -p "$WT" "$GITDIR"
echo "gitdir: $GITDIR" > "$WT/.git"       # worktree-pointer file under PROJECT_DIR
touch "$GITDIR/index.lock"

PAYLOAD1="$(printf '{"tool_name":"Bash","tool_input":{"command":"touch %s/index.lock"}}' "$GITDIR")"
set +e
OUT1="$(printf '%s' "$PAYLOAD1" | env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$WT" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" python3 "$HOOK" 2>&1)"
RC1=$?
set -e
if [ "$RC1" -eq 0 ]; then pass_msg "worktree-pointer git-dir path allowed under pipeline worktree"
else fail_msg "worktree-pointer git-dir path allowed under pipeline worktree" "rc=$RC1, out=$OUT1"; fi

# --- negative-external: .git/worktrees path with NO matching pointer registered ---
# An unrelated external dir simulating a hostile or stray .git. The current
# project (CLAUDE_PROJECT_DIR=$PROJ) registers no pointer for it, so it must
# STILL block.
PROJ="$BASE/proj"; OTHER="$BASE/other"
mkdir -p "$PROJ" "$OTHER/.git/worktrees/baz"
touch "$OTHER/.git/worktrees/baz/HEAD"
PAYLOAD2="$(printf '{"tool_name":"Bash","tool_input":{"command":"touch %s/.git/worktrees/baz/HEAD"}}' "$OTHER")"
set +e
OUT2="$(printf '%s' "$PAYLOAD2" | env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" python3 "$HOOK" 2>&1)"
RC2=$?
set -e
if [ "$RC2" -eq 2 ] && echo "$OUT2" | grep -q 'BLOCKED'; then
  pass_msg "external .git/worktrees dir without matching pointer still blocked"
else
  fail_msg "external .git/worktrees dir without matching pointer still blocked" "rc=$RC2, out=$OUT2"
fi

# --- negative-spoofed-pointer: pointer exists under allowed root, request is /etc/passwd ---
# Locks in the contract that the worktree allowance is keyed on the REQUESTED
# path matching /\.git/worktrees/<slug>/ (regex on the request path), not just
# on pointer-file existence. A pointer-existence-only bypass would let the
# system password file through — the failure mode this guards.
PAYLOAD3='{"tool_name":"Bash","tool_input":{"command":"cat /etc/passwd"}}'
set +e
OUT3="$(printf '%s' "$PAYLOAD3" | env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$WT" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" python3 "$HOOK" 2>&1)"
RC3=$?
set -e
if [ "$RC3" -eq 2 ] && echo "$OUT3" | grep -q 'BLOCKED'; then
  pass_msg "spoofed pointer present but /etc/passwd request still blocked"
else
  fail_msg "spoofed pointer present but /etc/passwd request still blocked" "rc=$RC3, out=$OUT3"
fi

echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
