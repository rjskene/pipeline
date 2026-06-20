#!/bin/bash
# Tests for hooks/restrict_paths.py git-worktree-pointer boundary handling.
#
# Issue #337 (Bug 2b): inside the web-eval flow the evaluator runs git
# operations on the feature worktree. A linked worktree's real git dir lives
# at <main>/.git/worktrees/<slug>/, which resolves OUTSIDE the worktree's
# CLAUDE_PROJECT_DIR. Git proves the linkage with a bidirectional pointer:
# the worktree's .git file names the git dir, and the git dir's `gitdir`
# back-link file names the worktree's .git file. The hook trusts the target
# ONLY via that back-link resolving back into an allowed root — a target an
# out-of-boundary attacker cannot forge (writing the back-link there is itself
# a blocked write).
#
# NOTE ON PATHS: restrict_paths.py unconditionally allows /tmp (it `continue`s
# on any candidate that startswith("/tmp")). A mktemp scaffold under /tmp can
# therefore NEVER be blocked, which would make the boundary checks pass for the
# wrong reason. So the scaffold is anchored under the repo root (a disposable
# worktree on a non-/tmp filesystem path) and cleaned on exit.
#
# Env-isolated subprocess invocation matching tests/test-restrict-paths-hook.sh
# (`env -i PATH=... CLAUDE_PROJECT_DIR=... CLAUDE_PLUGIN_ROOT=...`).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/restrict_paths.py"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

run_hook(){ # <project_dir> <command> -> sets RC/OUT
  set +e
  OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$2" \
    | env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" python3 "$HOOK" 2>&1)"
  RC=$?
  set -e
}

run_hook_filepath(){ # <project_dir> <tool_name> <file_path> -> sets RC/OUT
  # Drives the Write/Edit branch of extract_paths (tool_input.file_path), which
  # — unlike the Bash extractor — has no exists gate, so it surfaces a
  # not-yet-existing target. (#1070)
  set +e
  OUT="$(printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$2" "$3" \
    | env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" python3 "$HOOK" 2>&1)"
  RC=$?
  set -e
}

# Single trap covering the whole scaffold (hygiene: a second trap would clobber
# the first and leak the first temp dir).
BASE="$(mktemp -d "$REPO_ROOT/.rp-worktree-test.XXXXXX")"
trap "rm -rf '$BASE'" EXIT

# --- positive: linked-worktree git-dir resolves as allowed via its back-link ---
# Faithful git layout: PROJECT_DIR is the worktree; its real git dir lives
# OUTSIDE the worktree under the main repo, and that git dir carries a `gitdir`
# back-link file naming the worktree's .git (inside PROJECT_DIR).
WT="$BASE/main/.claude/worktrees/foo"     # PROJECT_DIR (the linked worktree)
GITDIR="$BASE/main/.git/worktrees/foo"    # real git dir, OUTSIDE the worktree
mkdir -p "$WT" "$GITDIR"
echo "gitdir: $GITDIR" > "$WT/.git"       # worktree -> git dir
echo "$WT/.git"        > "$GITDIR/gitdir" # git dir -> worktree (the trust anchor)
touch "$GITDIR/index.lock"
run_hook "$WT" "touch $GITDIR/index.lock"
if [ "$RC" -eq 0 ]; then pass_msg "linked-worktree git-dir path allowed via back-link"
else fail_msg "linked-worktree git-dir path allowed via back-link" "rc=$RC, out=$OUT"; fi

# --- negative-hooks-bash: per-worktree .git/worktrees/<slug>/hooks/ is a
# code-exec surface (git runs pre-commit at git-time, invisible to this hook).
# Even though the back-link resolves into an allowed root, the hooks/ segment
# must be denied so an agent cannot plant/overwrite an executable pre-commit.
# The Bash absolute-path extractor only surfaces EXISTING targets (it `continue`s
# on a path that does not exist on disk), so this case asserts the deny via the
# overwrite-an-existing-hook shape; the not-yet-existing plant is covered by the
# Write/Edit `file_path` case below, whose extractor has no exists gate. (#1070) ---
mkdir -p "$GITDIR/hooks"
touch "$GITDIR/hooks/pre-commit"
run_hook "$WT" "touch $GITDIR/hooks/pre-commit"
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q 'BLOCKED'; then
  pass_msg "per-worktree hooks/ write blocked (Bash touch existing pre-commit)"
else
  fail_msg "per-worktree hooks/ write blocked (Bash touch existing pre-commit)" "rc=$RC, out=$OUT"
fi

# --- negative-hooks-write: a Write/Edit whose file_path targets the
# per-worktree hooks/ dir must block even when the file does not yet exist (the
# plant-a-new-pre-commit shape). The Write/Edit extractor has no exists gate, so
# this exercises the deny on a fresh path. (#1070) ---
run_hook_filepath "$WT" "Write" "$GITDIR/hooks/pre-commit"
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q 'BLOCKED'; then
  pass_msg "per-worktree hooks/ write blocked (Write file_path of pre-commit)"
else
  fail_msg "per-worktree hooks/ write blocked (Write file_path of pre-commit)" "rc=$RC, out=$OUT"
fi

# --- negative-hooks-symlink: a symlink (sneaky -> hooks) cannot launder a write
# past the deny. is_allowed realpath's the target, so .../sneaky/pre-commit
# normalizes to .../hooks/pre-commit before the deny check. The pre-commit file
# already exists (created above) so the Bash extractor surfaces it. (#1070) ---
ln -s hooks "$GITDIR/sneaky"
run_hook "$WT" "touch $GITDIR/sneaky/pre-commit"
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q 'BLOCKED'; then
  pass_msg "symlinked per-worktree hooks/ write still blocked (sneaky -> hooks)"
else
  fail_msg "symlinked per-worktree hooks/ write still blocked (sneaky -> hooks)" "rc=$RC, out=$OUT"
fi

# --- negative-external: .git/worktrees path with no back-link into the project ---
# An unrelated external dir simulating a hostile or stray .git. No `gitdir`
# back-link points into the current project, so it must STILL block.
PROJ="$BASE/proj"; OTHER="$BASE/other"
mkdir -p "$PROJ" "$OTHER/.git/worktrees/baz"
touch "$OTHER/.git/worktrees/baz/HEAD"
run_hook "$PROJ" "touch $OTHER/.git/worktrees/baz/HEAD"
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q 'BLOCKED'; then
  pass_msg "external .git/worktrees dir without back-link still blocked"
else
  fail_msg "external .git/worktrees dir without back-link still blocked" "rc=$RC, out=$OUT"
fi

# --- negative-spoofed-pointer: worktree .git widened to a sensitive ancestor ---
# The C1 attack shape: an agent (which CAN write under PROJECT_DIR) rewrites a
# .git pointer to name an out-of-boundary ancestor as the git dir, then requests
# a regex-matching path under it. With NO valid back-link inside that target
# dir, the request must STILL block. A pointer-content-only trust would let this
# through — this guards exactly that bypass.
SENS="$BASE/sensitive"
mkdir -p "$SENS/.git/worktrees/x"
echo "secret" > "$SENS/.git/worktrees/x/loot"          # target dir, but NO gitdir back-link
echo "gitdir: $SENS/.git/worktrees/x" > "$WT/.git"     # worktree pointer widened to attacker target
run_hook "$WT" "cat $SENS/.git/worktrees/x/loot"
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q 'BLOCKED'; then
  pass_msg "widened pointer with no back-link into project still blocked"
else
  fail_msg "widened pointer with no back-link into project still blocked" "rc=$RC, out=$OUT"
fi
echo "gitdir: $GITDIR" > "$WT/.git"   # restore legit worktree pointer

# --- negative-backlink-points-outside: target carries a back-link, but it
# resolves OUTSIDE any allowed root. Must STILL block (the back-link must point
# back INTO the boundary to be trusted). ---
echo "$SENS/elsewhere/.git" > "$SENS/.git/worktrees/x/gitdir"  # back-link outside allowed roots
run_hook "$WT" "cat $SENS/.git/worktrees/x/loot"
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q 'BLOCKED'; then
  pass_msg "target back-link resolving outside allowed roots still blocked"
else
  fail_msg "target back-link resolving outside allowed roots still blocked" "rc=$RC, out=$OUT"
fi

# --- negative-non-worktree-path: a plain out-of-boundary read (system password
# file) never matches the worktree-git-dir shape and must block. ---
run_hook "$WT" "cat /etc/passwd"
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q 'BLOCKED'; then
  pass_msg "non-worktree out-of-boundary path still blocked"
else
  fail_msg "non-worktree out-of-boundary path still blocked" "rc=$RC, out=$OUT"
fi

echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
