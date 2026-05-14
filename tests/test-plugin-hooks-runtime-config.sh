#!/bin/bash
set -euo pipefail

# Asserts the renamed plugin-rooted hooks (enforce-base-branch.py,
# restrict_paths.py, enforce-path-c-delegation.py) resolve their
# PIPELINE_* values from $CLAUDE_PROJECT_DIR/pipeline.config at fire time
# rather than via install-time envsubst substitution.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
FAIL_LINES=()

note_fail() { FAIL=$((FAIL + 1)); FAIL_LINES+=("FAIL: $1"); }
note_pass() { PASS=$((PASS + 1)); }

# --- Sandbox 1: enforce-base-branch.py reads PIPELINE_BASE_BRANCH ---
SANDBOX1=$(mktemp -d)
trap 'rm -rf "$SANDBOX1" "$SANDBOX2" "$SANDBOX3"' EXIT
cat > "$SANDBOX1/pipeline.config" <<'EOF'
PIPELINE_BASE_BRANCH="custom-base"
PIPELINE_WORKTREE_PREFIX="alt"
PIPELINE_REPO="acme/widget"
EOF

input_good='{"tool_name":"Bash","tool_input":{"command":"gh pr create --base custom-base --title x"}}'
input_bad='{"tool_name":"Bash","tool_input":{"command":"gh pr create --base wrong --title x"}}'

export CLAUDE_PROJECT_DIR="$SANDBOX1"
if printf '%s' "$input_good" | python3 "$REPO_ROOT/hooks/enforce-base-branch.py" >/dev/null 2>&1; then
  note_pass
else
  note_fail "enforce-base-branch.py rejected --base custom-base when pipeline.config said custom-base"
fi

if printf '%s' "$input_bad" | python3 "$REPO_ROOT/hooks/enforce-base-branch.py" >/dev/null 2>err.$$; then
  note_fail "enforce-base-branch.py accepted --base wrong but pipeline.config said custom-base"
  rm -f err.$$
else
  note_pass
  err=$(cat err.$$ || true); rm -f err.$$
  if printf '%s' "$err" | grep -q 'custom-base'; then
    note_pass
  else
    note_fail "enforce-base-branch stderr missing 'custom-base' (got: $err)"
  fi
fi
unset CLAUDE_PROJECT_DIR

# Assert no literal ${PIPELINE_BASE_BRANCH} remains in the source.
if grep -q '${PIPELINE_BASE_BRANCH}' "$REPO_ROOT/hooks/enforce-base-branch.py"; then
  note_fail "enforce-base-branch.py still contains literal \${PIPELINE_BASE_BRANCH}"
else
  note_pass
fi

# --- Sandbox 2: restrict_paths.py reads PIPELINE_WORKTREE_PREFIX ---
SANDBOX2=$(mktemp -d)
cat > "$SANDBOX2/pipeline.config" <<'EOF'
PIPELINE_WORKTREE_PREFIX="alt"
EOF

# A sibling worktree under the configured prefix should be allowed.
PARENT="$(dirname "$SANDBOX2")"
WORKTREE_DIR="$PARENT/alt-99-foo"
mkdir -p "$WORKTREE_DIR"
TARGET_FILE="$WORKTREE_DIR/file.py"
touch "$TARGET_FILE"

restrict_input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1]}}))' "$TARGET_FILE")
export CLAUDE_PROJECT_DIR="$SANDBOX2"
if printf '%s' "$restrict_input" | python3 "$REPO_ROOT/hooks/restrict_paths.py" >/dev/null 2>&1; then
  note_pass
else
  err=$(printf '%s' "$restrict_input" | python3 "$REPO_ROOT/hooks/restrict_paths.py" 2>&1 >/dev/null || true)
  note_fail "restrict_paths.py blocked an 'alt-99-foo' worktree path despite PIPELINE_WORKTREE_PREFIX=alt (err: $err)"
fi
unset CLAUDE_PROJECT_DIR

rm -rf "$WORKTREE_DIR"

if grep -q '${PIPELINE_WORKTREE_PREFIX}' "$REPO_ROOT/hooks/restrict_paths.py"; then
  note_fail "restrict_paths.py still contains literal \${PIPELINE_WORKTREE_PREFIX}"
else
  note_pass
fi

# --- Sandbox 3: enforce-path-c-delegation.py reads PIPELINE_REPO ---
SANDBOX3=$(mktemp -d)
cat > "$SANDBOX3/pipeline.config" <<'EOF'
PIPELINE_REPO="acme/widget"
EOF
mkdir -p "$SANDBOX3/.claude/logs/subagents"

# Drive an allowlisted-path Edit through the hook — this exits 0 before
# any gh call, so it confirms the module loads cleanly (i.e. PIPELINE_REPO
# resolved without raising) regardless of whether gh is on PATH.
delegation_input='{"tool_name":"Edit","tool_input":{"file_path":"README.md"},"session_id":"sess-xyz"}'
if CLAUDE_PROJECT_DIR="$SANDBOX3" CLAUDE_PIPELINE_ISSUE_NUMBER=999 \
    python3 "$REPO_ROOT/hooks/enforce-path-c-delegation.py" <<< "$delegation_input" >/dev/null 2>&1; then
  note_pass
else
  note_fail "enforce-path-c-delegation.py did not exit 0 on allowlisted path (module-load failure suspected)"
fi

# Also assert PIPELINE_REPO actually resolves to the sandbox value via
# the import-and-call path.
resolved=$(CLAUDE_PROJECT_DIR="$SANDBOX3" python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/hooks')
from _pipeline_config import read
print(read('PIPELINE_REPO', 'MISS'))
")
if [ "$resolved" = "acme/widget" ]; then
  note_pass
else
  note_fail "_pipeline_config.read('PIPELINE_REPO') returned '$resolved', expected 'acme/widget'"
fi

if grep -q '${PIPELINE_REPO}' "$REPO_ROOT/hooks/enforce-path-c-delegation.py"; then
  note_fail "enforce-path-c-delegation.py still contains literal \${PIPELINE_REPO}"
else
  note_pass
fi

# --- Invariant: renamed plain .py files exist, old .template files do not ---
for f in enforce-base-branch.py restrict_paths.py enforce-path-c-delegation.py; do
  if [ -f "$REPO_ROOT/hooks/$f" ]; then note_pass; else note_fail "hooks/$f missing"; fi
  if [ -f "$REPO_ROOT/hooks/$f.template" ]; then note_fail "hooks/$f.template should be removed"; else note_pass; fi
done

if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "${FAIL_LINES[@]}"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi
echo "RESULT: $PASS passed, $FAIL failed"
