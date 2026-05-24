#!/bin/bash
set -euo pipefail

# Tests for scripts/check-unbounded-sentinel-polls.sh.
# The lint scans SKILL.md files for the unbounded sentinel-poll shape
#   until grep -q TOKEN file ; do sleep N ; done
#   while ! grep -q TOKEN file ; do sleep N ; done
# which wedges forever if the token never appears. It exits 0 when clean and
# 1 (naming offending file:line) when a violation is found.
#
# Sub-cases:
#   1. live skills/ tree passes (baseline-clean)
#   2. a SKILL.md with the bad single-line shape is flagged (exit 1, file:line)
#   3. good shapes pass: `timeout N bash -c 'until grep...'` and `for i in {1..N}`
#   4. a `scripts/wait-for-sentinel.sh ...` invocation does not trip the check

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../scripts/check-unbounded-sentinel-polls.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$LINT" ]; then
  echo "ERROR: lint not found at $LINT" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Sub-case 1: live skills/ tree is baseline-clean -> exit 0"
inc
set +e
bash "$LINT" >"$WORKDIR/c1.out" 2>"$WORKDIR/c1.err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass_msg "live skills/ passes the check"
else
  fail_msg "expected rc=0 on live tree, got rc=$rc err=$(cat "$WORKDIR/c1.err")"
fi

echo "Sub-case 2: bad single-line shape -> exit 1 + names file:line"
inc
BAD_DIR="$WORKDIR/bad/sub"
mkdir -p "$BAD_DIR"
cat >"$BAD_DIR/SKILL.md" <<'EOF'
# Bad skill

```bash
until grep -q __DONE__ sentinel.log 2>/dev/null; do sleep 5; done
```
EOF
set +e
bash "$LINT" "$WORKDIR/bad" >"$WORKDIR/c2.out" 2>"$WORKDIR/c2.err"
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -qE 'SKILL\.md:[0-9]+' "$WORKDIR/c2.err" "$WORKDIR/c2.out"; then
  pass_msg "flagged with file:line"
else
  fail_msg "expected rc=1 + file:line, got rc=$rc out=$(cat "$WORKDIR/c2.out") err=$(cat "$WORKDIR/c2.err")"
fi

echo "Sub-case 3: good shapes pass (timeout wrapper + for-loop) -> exit 0"
inc
GOOD_DIR="$WORKDIR/good/sub"
mkdir -p "$GOOD_DIR"
cat >"$GOOD_DIR/SKILL.md" <<'EOF'
# Good skill

Bounded with a timeout wrapper:

```bash
timeout 600 bash -c 'until grep -q __DONE__ sentinel.log; do sleep 5; done'
```

Bounded counting loop:

```bash
for i in {1..120}; do grep -q __DONE__ sentinel.log && break; sleep 5; done
```
EOF
set +e
bash "$LINT" "$WORKDIR/good" >"$WORKDIR/c3.out" 2>"$WORKDIR/c3.err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass_msg "bounded shapes pass"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/c3.err")"
fi

echo "Sub-case 4: wait-for-sentinel.sh invocation does not trip the check -> exit 0"
inc
HELPER_DIR="$WORKDIR/helper/sub"
mkdir -p "$HELPER_DIR"
cat >"$HELPER_DIR/SKILL.md" <<'EOF'
# Helper-using skill

```bash
bash scripts/wait-for-sentinel.sh sentinel.log __DONE__ --timeout 600
```
EOF
set +e
bash "$LINT" "$WORKDIR/helper" >"$WORKDIR/c4.out" 2>"$WORKDIR/c4.err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass_msg "helper invocation passes"
else
  fail_msg "expected rc=0, got rc=$rc err=$(cat "$WORKDIR/c4.err")"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
