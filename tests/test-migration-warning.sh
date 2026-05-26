#!/bin/bash
set -uo pipefail
#
# test-migration-warning.sh — verifies the one-shot migration warning emitted
# by scripts/run-queue.sh launch_agent() when PIPELINE_VISUAL_PROOF_TARGET_DIR
# is unset/empty at the moment of an inline browser-eval dispatch (issue #517).
#
# Contract:
#  - WARNING substring on stderr: "PIPELINE_VISUAL_PROOF_TARGET_DIR unset"
#    (one-shot per slate).
#  - The EVENT line carries notes=no-target-dir.
#  - RESULTS[$issue] is set to dispatched-inline-no-visual-proof.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_QUEUE_SRC="$ROOT/scripts/run-queue.sh"
HELPER_SRC="$ROOT/scripts/eval-classifier-invoke.sh"
PORT_BROKER_SRC="$ROOT/scripts/visual-proof-port-broker.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$RUN_QUEUE_SRC" "$HELPER_SRC" "$PORT_BROKER_SRC"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR" /tmp/wt-610-a /tmp/wt-611-b 2>/dev/null' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/scripts" "$PROJ/.claude/logs" \
         "$PROJ/plugin-root/scripts"
cp "$RUN_QUEUE_SRC"     "$PROJ/plugin-root/scripts/run-queue.sh"
cp "$ROOT/scripts/_logging.sh" "$PROJ/plugin-root/scripts/_logging.sh"
cp "$ROOT/scripts/_resolve-container-var.sh" "$PROJ/plugin-root/scripts/_resolve-container-var.sh"
cp "$HELPER_SRC"        "$PROJ/plugin-root/scripts/eval-classifier-invoke.sh"
cp "$PORT_BROKER_SRC"   "$PROJ/plugin-root/scripts/visual-proof-port-broker.sh"
chmod +x "$PROJ/plugin-root/scripts/run-queue.sh" \
         "$PROJ/plugin-root/scripts/eval-classifier-invoke.sh" \
         "$PROJ/plugin-root/scripts/visual-proof-port-broker.sh"

# Stub spawn-claude.sh: log argv and exit 0.
cat > "$PROJ/plugin-root/scripts/spawn-claude.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SPAWN_LOG"
exit 0
EOF
chmod +x "$PROJ/plugin-root/scripts/spawn-claude.sh"

# Classifier emits container-mode for two issues so we can confirm one-shot warning.
cat > "$PROJ/.claude/scripts/classifier.sh" <<'EOF'
#!/bin/bash
ISSUE="$1"
for wi in ${CLASSIFIER_WEB_ISSUES:-}; do
  if [ "$ISSUE" = "$wi" ]; then
    echo "--container-mode=mock-web-eval"
    exit 0
  fi
done
exit 0
EOF
chmod +x "$PROJ/.claude/scripts/classifier.sh"

# Note: PIPELINE_VISUAL_PROOF_TARGET_DIR intentionally NOT set.
cat > "$PROJ/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="fake"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/classifier.sh"
PIPELINE_EVAL_CONTAINERS="mock-web-eval"
EOF

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/tmux" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
issue=""
for tok in "$@"; do
  case "$tok" in
    linked:*) issue="${tok#linked:}" ;;
  esac
done
varname="STUB_PR_FOR_${issue}"
val="${!varname:-}"
[ -n "$val" ] && echo "$val" || echo ""
EOF
cat > "$STUB_DIR/git" <<'EOF'
#!/bin/bash
if [ "$1" = "worktree" ] && [ "$2" = "list" ]; then
  for entry in ${STUB_WORKTREES:-}; do
    issue="${entry%%:*}"
    slug="${entry##*:}"
    echo "worktree /tmp/wt-${issue}-${slug}"
    echo "HEAD abc"
    echo "branch refs/heads/feature/${slug}"
    echo ""
  done
fi
EOF
chmod +x "$STUB_DIR/tmux" "$STUB_DIR/gh" "$STUB_DIR/git"

SPAWN_LOG="$PROJ/spawn-invocations.log"
: > "$SPAWN_LOG"
mkdir -p /tmp/wt-610-a /tmp/wt-611-b

# ---- Test: warning + notes=no-target-dir on inline dispatch with TARGET_DIR unset ----
echo "Test: TARGET_DIR unset + classifier match -> warning + notes=no-target-dir"
inc
OUT=$(cd "$PROJ" && \
  PATH="$STUB_DIR:$PATH" \
  TMUX="fake" \
  SPAWN_LOG="$SPAWN_LOG" \
  PIPELINE_QUEUE_DRY_RUN=1 \
  PIPELINE_LOGS_ENABLED=false \
  STUB_WORKTREES="610:a 611:b" \
  CLASSIFIER_WEB_ISSUES="610 611" \
  STUB_PR_FOR_610="7001" \
  STUB_PR_FOR_611="7002" \
  CLAUDE_PLUGIN_ROOT="$PROJ/plugin-root" \
  bash plugin-root/scripts/run-queue.sh 610 611 2>"$WORKDIR/stderr.log")
STDERR=$(cat "$WORKDIR/stderr.log")

ok=1
if ! echo "$STDERR" | grep -q "PIPELINE_VISUAL_PROOF_TARGET_DIR unset"; then
  fail_msg "missing stderr warning substring 'PIPELINE_VISUAL_PROOF_TARGET_DIR unset'"
  echo "    stderr:"; echo "$STDERR" | sed 's/^/    /'
  ok=0
fi
# Migration doc reference required.
if [ "$ok" = "1" ] && ! echo "$STDERR" | grep -q "migration"; then
  fail_msg "stderr warning missing migration doc reference (e.g. docs/migration-0.18.md)"
  echo "    $STDERR" | head -5 | sed 's/^/    /'
  ok=0
fi
# One-shot: only one warning regardless of two inline dispatches.
if [ "$ok" = "1" ]; then
  warn_count=$(echo "$STDERR" | grep -c "PIPELINE_VISUAL_PROOF_TARGET_DIR unset" || true)
  if [ "$warn_count" -ne 1 ]; then
    fail_msg "expected exactly one warning emission across slate (got $warn_count)"
    ok=0
  fi
fi
# EVENT line carries notes=no-target-dir.
if [ "$ok" = "1" ]; then
  EVENT_LINE=$(echo "$OUT" | grep '^EVENT: dispatch-inline' | head -1)
  if [ -z "$EVENT_LINE" ]; then
    fail_msg "no EVENT: dispatch-inline line emitted"
    echo "$OUT" | sed 's/^/    /'
    ok=0
  elif ! echo "$EVENT_LINE" | grep -q "notes=no-target-dir"; then
    fail_msg "EVENT line missing notes=no-target-dir field"
    echo "    $EVENT_LINE"
    ok=0
  fi
fi
[ "$ok" = "1" ] && pass_msg "warning emitted once + EVENT carries notes=no-target-dir"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
