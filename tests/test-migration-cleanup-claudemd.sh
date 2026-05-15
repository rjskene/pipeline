#!/bin/bash
set -uo pipefail

# Tests for scripts/migration-cleanup-claudemd.sh — the advisory CLAUDE.md
# scanner that flags pipeline-legacy content and emits a unified-diff patch
# without ever mutating source files.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCANNER_SH="$SCRIPT_DIR/../scripts/migration-cleanup-claudemd.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Task 1: detect pure pipeline section headers (gated by corroborating sig).
# ---------------------------------------------------------------------------
echo "Test 'detect: pure pipeline section headers'"

PROJ_HDR="$WORKDIR/proj-hdr"
mkdir -p "$PROJ_HDR"
cat > "$PROJ_HDR/CLAUDE.md" <<'EOF'
## Pipeline

Run `bash .claude-pipeline/scripts/spawn-claude.sh` to launch.
EOF

(cd "$PROJ_HDR" && bash "$SCANNER_SH") >/dev/null 2>&1
EXIT=$?

REPORT="$PROJ_HDR/.claude/migration-cleanup-report-claudemd.txt"

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "hdr: exit 0"; else fail_msg "hdr: exit $EXIT"; fi

inc
if [ -f "$REPORT" ]; then pass_msg "hdr: report file created"; else fail_msg "hdr: report file missing"; fi

inc
if [ -f "$REPORT" ] && grep -qF 'CLAUDE.md:1:' "$REPORT"; then
  pass_msg "hdr: report mentions line 1"
else
  fail_msg "hdr: report missing CLAUDE.md:1:"
  [ -f "$REPORT" ] && sed 's/^/    /' "$REPORT"
fi

inc
if [ -f "$REPORT" ] && grep -qF '## Pipeline' "$REPORT"; then
  pass_msg "hdr: report mentions ## Pipeline"
else
  fail_msg "hdr: report missing ## Pipeline"
fi

inc
if [ -f "$REPORT" ] && grep -qF '.claude-pipeline/' "$REPORT"; then
  pass_msg "hdr: report mentions corroborating .claude-pipeline/"
else
  fail_msg "hdr: report missing corroborating signature"
fi

# ---------------------------------------------------------------------------
# Task 2: detect legacy paths anywhere in file (outside any flagged section).
# ---------------------------------------------------------------------------
echo ""
echo "Test 'detect: legacy paths anywhere in file'"

assert_paths_finding() {
  local tag="$1" projdir="$2" sig="$3"
  local report="$projdir/.claude/migration-cleanup-report-claudemd.txt"
  inc
  if [ -f "$report" ]; then pass_msg "$tag: report exists"; else fail_msg "$tag: report missing"; fi
  inc
  if [ -f "$report" ] && grep -qF "$sig" "$report"; then
    pass_msg "$tag: report mentions signature ($sig)"
  else
    fail_msg "$tag: report missing signature ($sig)"
  fi
  inc
  if [ -f "$report" ] && grep -qF 'Legacy paths' "$report"; then
    pass_msg "$tag: report has Legacy paths subsection"
  else
    fail_msg "$tag: report missing Legacy paths subsection"
  fi
}

PROJ_PATHS_A="$WORKDIR/proj-paths-a"
mkdir -p "$PROJ_PATHS_A"
printf 'Run `bash .claude-pipeline/scripts/spawn-claude.sh` to begin.\n' > "$PROJ_PATHS_A/CLAUDE.md"
(cd "$PROJ_PATHS_A" && bash "$SCANNER_SH") >/dev/null 2>&1
assert_paths_finding "paths-A" "$PROJ_PATHS_A" ".claude-pipeline/"

PROJ_PATHS_B="$WORKDIR/proj-paths-b"
mkdir -p "$PROJ_PATHS_B"
printf 'Update with `git subtree pull --prefix .claude-pipeline ...` after upstream changes.\n' > "$PROJ_PATHS_B/CLAUDE.md"
(cd "$PROJ_PATHS_B" && bash "$SCANNER_SH") >/dev/null 2>&1
assert_paths_finding "paths-B" "$PROJ_PATHS_B" "subtree pull"

PROJ_PATHS_C="$WORKDIR/proj-paths-c"
mkdir -p "$PROJ_PATHS_C"
printf 'Run `bash install.sh` after cloning.\n' > "$PROJ_PATHS_C/CLAUDE.md"
(cd "$PROJ_PATHS_C" && bash "$SCANNER_SH") >/dev/null 2>&1
assert_paths_finding "paths-C" "$PROJ_PATHS_C" "install.sh"

# ---------------------------------------------------------------------------
# Task 3: detect deprecated unprefixed slash commands.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'detect: deprecated unprefixed slash commands'"

run_cmd_fixture() {
  local projdir="$1" content="$2"
  mkdir -p "$projdir"
  printf '%s\n' "$content" > "$projdir/CLAUDE.md"
  (cd "$projdir" && bash "$SCANNER_SH") >/dev/null 2>&1
}

PROJ_CMD_A="$WORKDIR/proj-cmd-a"
run_cmd_fixture "$PROJ_CMD_A" 'Run `/plan-issue 42` to plan an issue.'
REPORT_A="$PROJ_CMD_A/.claude/migration-cleanup-report-claudemd.txt"
inc
if [ -f "$REPORT_A" ] && grep -qF 'Deprecated slash commands' "$REPORT_A" \
   && grep -qF '/plan-issue' "$REPORT_A"; then
  pass_msg "cmd-A: /plan-issue flagged"
else
  fail_msg "cmd-A: /plan-issue NOT flagged"
fi

PROJ_CMD_B="$WORKDIR/proj-cmd-b"
run_cmd_fixture "$PROJ_CMD_B" 'Run `/pipeline:plan-issue 42` to plan an issue.'
REPORT_B="$PROJ_CMD_B/.claude/migration-cleanup-report-claudemd.txt"
inc
if [ ! -f "$REPORT_B" ]; then
  pass_msg "cmd-B: namespaced form not flagged"
else
  fail_msg "cmd-B: namespaced form WAS flagged"
  sed 's/^/    /' "$REPORT_B"
fi

PROJ_CMD_C="$WORKDIR/proj-cmd-c"
run_cmd_fixture "$PROJ_CMD_C" 'See `/run` and `/doctor` for status checks.'
REPORT_C="$PROJ_CMD_C/.claude/migration-cleanup-report-claudemd.txt"
inc
if [ ! -f "$REPORT_C" ]; then
  pass_msg "cmd-C: /run and /doctor not flagged"
else
  fail_msg "cmd-C: /run or /doctor incorrectly flagged"
  sed 's/^/    /' "$REPORT_C"
fi

PROJ_CMD_D="$WORKDIR/proj-cmd-d"
run_cmd_fixture "$PROJ_CMD_D" 'Use `/evaluate-issue-plan 5`, `/execute-issue-plan 5`, and `/worktree-sync`.'
REPORT_D="$PROJ_CMD_D/.claude/migration-cleanup-report-claudemd.txt"
inc
if [ -f "$REPORT_D" ] && grep -qF '/evaluate-issue-plan' "$REPORT_D" \
   && grep -qF '/execute-issue-plan' "$REPORT_D" \
   && grep -qF '/worktree-sync' "$REPORT_D"; then
  pass_msg "cmd-D: all three hyphenated commands flagged"
else
  fail_msg "cmd-D: missing one or more hyphenated commands"
  [ -f "$REPORT_D" ] && sed 's/^/    /' "$REPORT_D"
fi

# ---------------------------------------------------------------------------
# Task 4: false-positive gate — bare ## Pipeline section preserved byte-for-byte.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'fp-gate: bare ## Pipeline section is not flagged AND not mutated'"

PROJ_FP="$WORKDIR/proj-fp"
mkdir -p "$PROJ_FP"
cat > "$PROJ_FP/CLAUDE.md" <<'EOF'
## Pipeline

This section describes our ETL data pipeline. Records flow from Kafka into BigQuery, then to Snowflake nightly.

## Other section
EOF

BEFORE_SHA=$(sha256sum "$PROJ_FP/CLAUDE.md" | awk '{print $1}')
(cd "$PROJ_FP" && bash "$SCANNER_SH") >/dev/null 2>&1
EXIT=$?
AFTER_SHA=$(sha256sum "$PROJ_FP/CLAUDE.md" | awk '{print $1}')

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "fp: exit 0"; else fail_msg "fp: exit $EXIT"; fi

inc
if [ ! -f "$PROJ_FP/.claude/migration-cleanup-report-claudemd.txt" ]; then
  pass_msg "fp: no report file created"
else
  fail_msg "fp: report file unexpectedly created"
  sed 's/^/    /' "$PROJ_FP/.claude/migration-cleanup-report-claudemd.txt"
fi

inc
if [ "$BEFORE_SHA" = "$AFTER_SHA" ]; then
  pass_msg "fp: CLAUDE.md sha256 byte-identical"
else
  fail_msg "fp: CLAUDE.md sha256 changed"
fi

# ---------------------------------------------------------------------------
# Task 5: scan nested CLAUDE.md files from PIPELINE_CONTEXT_FILES.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'scan: nested CLAUDE.md from PIPELINE_CONTEXT_FILES'"

PROJ_NESTED="$WORKDIR/proj-nested"
mkdir -p "$PROJ_NESTED/docs" "$PROJ_NESTED/src"
cat > "$PROJ_NESTED/pipeline.config" <<'EOF'
PIPELINE_CONTEXT_FILES="CLAUDE.md docs/CLAUDE.md src/CLAUDE.md nonexistent.md"
EOF
echo "# Project root" > "$PROJ_NESTED/CLAUDE.md"
printf 'Run `.claude-pipeline/install.sh` before starting.\n' > "$PROJ_NESTED/docs/CLAUDE.md"
echo "# Source" > "$PROJ_NESTED/src/CLAUDE.md"

(cd "$PROJ_NESTED" && bash "$SCANNER_SH") >/dev/null 2>&1
EXIT=$?

REPORT_N="$PROJ_NESTED/.claude/migration-cleanup-report-claudemd.txt"

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "nested: exit 0"; else fail_msg "nested: exit $EXIT"; fi

inc
if [ -f "$REPORT_N" ] && grep -qE 'docs/CLAUDE\.md:[0-9]+:' "$REPORT_N"; then
  pass_msg "nested: docs/CLAUDE.md flagged with line number"
else
  fail_msg "nested: docs/CLAUDE.md NOT flagged"
  [ -f "$REPORT_N" ] && sed 's/^/    /' "$REPORT_N"
fi

inc
if [ -f "$REPORT_N" ] && ! grep -qF 'src/CLAUDE.md' "$REPORT_N"; then
  pass_msg "nested: src/CLAUDE.md NOT in report"
else
  fail_msg "nested: src/CLAUDE.md unexpectedly in report"
fi

# ---------------------------------------------------------------------------
# Task 6: unified-diff patch (section-scope rule).
# ---------------------------------------------------------------------------
echo ""
echo "Test 'patch: unified diff is git-apply-clean'"

# Fixture S: section-header → delete whole section.
PROJ_PATCH_S="$WORKDIR/proj-patch-s"
mkdir -p "$PROJ_PATCH_S"
cat > "$PROJ_PATCH_S/CLAUDE.md" <<'EOF'
# Top

## Pipeline

Run `bash .claude-pipeline/install.sh` first.
Then run /plan-issue 1.

## Keep me

I survive.
EOF
(
  cd "$PROJ_PATCH_S"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  git add CLAUDE.md
  git commit -q -m "init"
)
(cd "$PROJ_PATCH_S" && bash "$SCANNER_SH") >/dev/null 2>&1
PATCH_S="$PROJ_PATCH_S/.claude/migration-cleanup-claudemd.patch"

inc
if [ -f "$PATCH_S" ]; then pass_msg "patch-S: patch file exists"; else fail_msg "patch-S: patch file missing"; fi

inc
if [ -f "$PATCH_S" ] && (cd "$PROJ_PATCH_S" && git apply --check .claude/migration-cleanup-claudemd.patch) >/dev/null 2>&1; then
  pass_msg "patch-S: git apply --check clean"
else
  fail_msg "patch-S: git apply --check failed"
  [ -f "$PATCH_S" ] && sed 's/^/    /' "$PATCH_S"
fi

if [ -f "$PATCH_S" ]; then
  (cd "$PROJ_PATCH_S" && git apply .claude/migration-cleanup-claudemd.patch) >/dev/null 2>&1 || true
fi

inc
if ! grep -qF '## Pipeline' "$PROJ_PATCH_S/CLAUDE.md" \
   && ! grep -qF '.claude-pipeline/install.sh' "$PROJ_PATCH_S/CLAUDE.md" \
   && ! grep -qF '/plan-issue' "$PROJ_PATCH_S/CLAUDE.md"; then
  pass_msg "patch-S: entire section removed"
else
  fail_msg "patch-S: section content still present"
  sed 's/^/    /' "$PROJ_PATCH_S/CLAUDE.md"
fi

inc
if grep -qF '## Keep me' "$PROJ_PATCH_S/CLAUDE.md" \
   && grep -qF 'I survive.' "$PROJ_PATCH_S/CLAUDE.md"; then
  pass_msg "patch-S: ## Keep me section preserved"
else
  fail_msg "patch-S: ## Keep me section damaged"
fi

# Fixture O: outside-section → delete only the matched line.
PROJ_PATCH_O="$WORKDIR/proj-patch-o"
mkdir -p "$PROJ_PATCH_O"
cat > "$PROJ_PATCH_O/CLAUDE.md" <<'EOF'
# Top

Run `bash .claude-pipeline/install.sh` once.

Then continue with `/pipeline:run`.
EOF
(
  cd "$PROJ_PATCH_O"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  git add CLAUDE.md
  git commit -q -m "init"
)
(cd "$PROJ_PATCH_O" && bash "$SCANNER_SH") >/dev/null 2>&1
PATCH_O="$PROJ_PATCH_O/.claude/migration-cleanup-claudemd.patch"

inc
if [ -f "$PATCH_O" ]; then pass_msg "patch-O: patch file exists"; else fail_msg "patch-O: patch file missing"; fi

inc
if [ -f "$PATCH_O" ] && (cd "$PROJ_PATCH_O" && git apply --check .claude/migration-cleanup-claudemd.patch) >/dev/null 2>&1; then
  pass_msg "patch-O: git apply --check clean"
else
  fail_msg "patch-O: git apply --check failed"
  [ -f "$PATCH_O" ] && sed 's/^/    /' "$PATCH_O"
fi

if [ -f "$PATCH_O" ]; then
  (cd "$PROJ_PATCH_O" && git apply .claude/migration-cleanup-claudemd.patch) >/dev/null 2>&1 || true
fi

inc
if ! grep -qF '.claude-pipeline/install.sh' "$PROJ_PATCH_O/CLAUDE.md"; then
  pass_msg "patch-O: legacy-path line removed"
else
  fail_msg "patch-O: legacy-path line still present"
fi

inc
if grep -qF '# Top' "$PROJ_PATCH_O/CLAUDE.md" \
   && grep -qF '/pipeline:run' "$PROJ_PATCH_O/CLAUDE.md"; then
  pass_msg "patch-O: surrounding context preserved"
else
  fail_msg "patch-O: surrounding context damaged"
  sed 's/^/    /' "$PROJ_PATCH_O/CLAUDE.md"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
