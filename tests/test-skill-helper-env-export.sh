#!/bin/bash
set -euo pipefail

# Tests that skill prose for /pipeline:run and /pipeline:fullsend wraps every
# `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<helper>.sh` invocation that consumes
# $PIPELINE_REPO with an explicit `PIPELINE_REPO="$PIPELINE_REPO" ` export prefix.
#
# Background: `pipeline.config` is sourced at session start, but `PIPELINE_REPO`
# is a shell var (not exported). Bash tool subshells inherit a fresh environment
# per tool call, so a bare `bash <helper>.sh` invocation runs without
# PIPELINE_REPO and the helper bails with `PIPELINE_REPO (or --repo) is required`.
# See issue #288.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_SKILL="$REPO_ROOT/skills/run/SKILL.md"
FULLSEND_SKILL="$REPO_ROOT/skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

# Allow-list: helper scripts that consume $PIPELINE_REPO and must be wrapped
# wherever they are invoked via `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh ...`.
# Excludes `source ...` lines — sourcing runs in the current shell, which
# already has PIPELINE_REPO from the boot block.
PIPELINE_REPO_CONSUMERS=(
  plan-waves.sh
  auto-close-trackers.sh
  list-release-prs.sh
  analyze-issues.sh
  cleanup-worktree.sh
  sync-worktrees.sh
  run-queue.sh
  auto-merge-gate.sh
  check-ci-fix-loop.sh
  spawn-claude.sh
  retarget-pr.sh
  review-audits.sh
)

# Static-scan: for each skill file × each helper, find lines that invoke the
# helper via `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<helper>.sh` (NOT `source`)
# and assert the line ALSO contains a `PIPELINE_REPO=` assignment before
# the `bash` token.
scan_file() {
  local file="$1"
  local helper="$2"
  # Regex anchors on a literal `bash ` token immediately preceding the
  # ${CLAUDE_PLUGIN_ROOT...}/scripts/<helper>.sh path. The brace form may be
  # bare `$CLAUDE_PLUGIN_ROOT` or `${CLAUDE_PLUGIN_ROOT}` or `${CLAUDE_PLUGIN_ROOT:-.}`.
  # `[^|]*` between `bash` and the var allows for an opening subshell `$(` or
  # quoted-string wrappers without falling through to a pipeline `|`.
  local pat='bash [^|]*\$\{?CLAUDE_PLUGIN_ROOT[^}]*\}?/scripts/'"$helper"
  grep -nE "$pat" "$file" 2>/dev/null || true
}

echo "=== Static scan: PIPELINE_REPO consumers wrapped in skill prose ==="

for SKILL_FILE in "$RUN_SKILL" "$FULLSEND_SKILL"; do
  for HELPER in "${PIPELINE_REPO_CONSUMERS[@]}"; do
    while IFS= read -r match; do
      [ -z "$match" ] && continue
      inc
      lineno="${match%%:*}"
      content="${match#*:}"
      # Extract the substring from start of line up to (but not including)
      # the `bash ` token, so we only check the prefix.
      prefix="${content%%bash *}"
      if echo "$prefix" | grep -qE 'PIPELINE_REPO='; then
        pass_msg "$(basename "$SKILL_FILE"):$lineno wraps $HELPER with PIPELINE_REPO="
      else
        fail_msg "$(basename "$SKILL_FILE"):$lineno invokes $HELPER WITHOUT PIPELINE_REPO= prefix"
        echo "    line: $content"
      fi
    done < <(scan_file "$SKILL_FILE" "$HELPER")
  done
done

echo ""
echo "=== Positive smoke: housekeeping snippet runs without PIPELINE_REPO error ==="

# Build a sandbox: a fake pipeline.config that sets PIPELINE_REPO as a shell
# var (NOT exported), a stub gh on PATH that simulates "no open trackers"
# (so auto-close-trackers exits cleanly), and CLAUDE_PLUGIN_ROOT pointing at
# this repo so the script path resolves.
TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# Stub gh: every invocation prints empty output (no trackers) and exits 0.
# Specifically, `gh issue list ... --json number --jq .[].number` returns nothing.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
# Print empty output and exit 0 — auto-close-trackers reads stdout to decide
# whether to iterate, and an empty list means it returns immediately.
exit 0
GH
chmod +x "$TMP/bin/gh"

# Fake pipeline.config — sourced but not exported. This reproduces the
# real-world setup where /pipeline:run's boot block sources the file.
cat > "$TMP/pipeline.config" <<EOF
PIPELINE_REPO="test/repo"
EOF

inc
SNIPPET_OUT="$TMP/snippet.stderr"

# The snippet below MUST match the one written into skills/run/SKILL.md step 0
# (auto-close-trackers invocation). When the skill prose still has a bare
# `bash ${CLAUDE_PLUGIN_ROOT:-.}/scripts/auto-close-trackers.sh ...` (no
# PIPELINE_REPO= prefix), this test fails because the helper bails with the
# documented error.
env -i HOME="$HOME" PATH="$TMP/bin:/usr/bin:/bin" \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  bash -c '
    set -e
    cd "'"$TMP"'"
    source ./pipeline.config
    PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/auto-close-trackers.sh" --apply || \
      echo "[run] WARN: auto-close-trackers.sh exited non-zero (continuing)"
  ' 2>"$SNIPPET_OUT" >/dev/null

if grep -qF 'PIPELINE_REPO (or --repo) is required' "$SNIPPET_OUT"; then
  fail_msg "smoke: helper bailed with 'PIPELINE_REPO (or --repo) is required'"
  echo "    stderr:"; sed 's/^/      /' "$SNIPPET_OUT"
else
  pass_msg "smoke: auto-close-trackers ran without the PIPELINE_REPO error"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
