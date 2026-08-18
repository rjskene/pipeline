#!/bin/bash
set -uo pipefail

# tests/test-check-cross-cutting-guards-consumer-root.sh
#
# Regression test for #1217: scripts/check-cross-cutting-guards.sh sub-guard 6
# (check-branch-cruft.sh) was PERMANENTLY inert in consumer installs. REPO_ROOT
# is computed from the AGGREGATOR's own location (the plugin root); a plugin
# install never ships a local pipeline.config (only pipeline.config.example),
# so PIPELINE_BASE_BRANCH was never resolved and sub-guard 6 unconditionally
# SKIPped from ANY caller cwd -- while the aggregator still printed "ok". Same
# failure class as #1150: a guard answering "pass" while checking nothing.
#
# This test reproduces the CONSUMER GEOMETRY in a temp dir (it does not rely
# on this worktree happening to have its own pipeline.config at the plugin
# root -- it explicitly excludes one from the synthetic plugin root below):
#   - a synthetic "plugin root": symlinks to this repo's scripts/skills/
#     hooks/tests/docs/etc, but EXCLUDING .git and pipeline.config -- matching
#     a real plugin cache-dir install (non-git, ships only .example config).
#   - a synthetic "consumer repo": a real git repo with its OWN
#     pipeline.config, invoking the aggregator by an ABSOLUTE PATH to the
#     synthetic plugin root, from the consumer repo ROOT, PIPELINE_BASE_BRANCH
#     unset in the environment.
#
# Teeth (#1217 acceptance criteria): asserting the ABSENCE of a "SKIP:"
# string is not sufficient evidence the guard ran -- a stub could satisfy
# that trivially. This test instead proves sub-guard 6 (a) catches a REAL
# denylisted committed cruft path (Scenario A, positive/teeth) and (b) reports
# a real OK -- not SKIP -- on a clean branch (Scenario B, negative control),
# so neither a no-op stub nor an always-fail stub could pass both.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Build the synthetic "plugin root": symlink every top-level entry of THIS
# repo except .git and pipeline.config, so the fake root has no config of its
# own and is not itself a git work tree -- the consumer-install geometry.
# ---------------------------------------------------------------------------
FAKE_PLUGIN_ROOT="$WORKDIR/plugin-root"
mkdir -p "$FAKE_PLUGIN_ROOT"
for entry in "$REPO_ROOT"/* "$REPO_ROOT"/.[!.]*; do
  [ -e "$entry" ] || continue
  name="$(basename "$entry")"
  case "$name" in
    .git|pipeline.config) continue ;;
  esac
  ln -s "$entry" "$FAKE_PLUGIN_ROOT/$name"
done

if [ -e "$FAKE_PLUGIN_ROOT/pipeline.config" ]; then
  echo "ERROR: test setup bug -- synthetic plugin root has a pipeline.config" >&2
  exit 1
fi
if git -C "$FAKE_PLUGIN_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: test setup bug -- synthetic plugin root is inside a git work tree" >&2
  exit 1
fi

AGG="$FAKE_PLUGIN_ROOT/scripts/check-cross-cutting-guards.sh"

make_consumer_repo() {
  # $1 = target dir. Builds a 2-commit repo: base "main" commit (with the
  # consumer's OWN pipeline.config), then checks out a feature branch. Caller
  # adds more commits on the feature branch before invoking the aggregator.
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  printf 'PIPELINE_BASE_BRANCH=main\n' > "$dir/pipeline.config"
  printf 'hello\n' > "$dir/README.md"
  git -C "$dir" add pipeline.config README.md
  git -C "$dir" commit -q -m "init"
  git -C "$dir" checkout -q -b feature/test-branch
}

run_agg_in() {
  # $1 = consumer repo dir. Prints combined stdout+stderr. PIPELINE_BASE_BRANCH
  # is explicitly unset so resolution can ONLY come from the consumer's own
  # pipeline.config (never from a leaked outer-shell export).
  ( cd "$1" && env -u PIPELINE_BASE_BRANCH bash "$AGG" 2>&1 )
}

# ---------------------------------------------------------------------------
# Scenario A (teeth / positive control): committed cruft on the feature
# branch. Sub-guard 6 must actually run and catch it.
# ---------------------------------------------------------------------------
echo "Scenario A: consumer repo w/ committed cruft -- sub-guard 6 must catch it"
CRUFTY="$WORKDIR/consumer-crufty"
make_consumer_repo "$CRUFTY"
mkdir -p "$CRUFTY/.claude/logs"
printf 'evidence\n' > "$CRUFTY/.claude/logs/evidence.txt"
git -C "$CRUFTY" add .claude/logs/evidence.txt
git -C "$CRUFTY" commit -q -m "add cruft"

set +e
OUT_A=$(run_agg_in "$CRUFTY")
RC_A=$?
set -e

inc
if printf '%s\n' "$OUT_A" | grep -qF 'SKIP: check-branch-cruft.sh'; then
  fail_msg "sub-guard 6 was SKIPped from consumer geometry (bug #1217 reproduced): $OUT_A"
else
  pass_msg "sub-guard 6 was not skipped from consumer geometry"
fi

inc
if printf '%s\n' "$OUT_A" | grep -qF '.claude/logs/evidence.txt' \
   && printf '%s\n' "$OUT_A" | grep -qF 'FAIL: check-branch-cruft.sh'; then
  pass_msg "sub-guard 6 ran for real and caught the committed cruft path"
else
  fail_msg "sub-guard 6 did not report catching the cruft path; output: $OUT_A"
fi

inc
if [ "$RC_A" -eq 1 ]; then
  pass_msg "aggregator exits 1 with cruft present (not masked as 'ok')"
else
  fail_msg "expected aggregator rc=1 with cruft present, got rc=$RC_A; output: $OUT_A"
fi

# ---------------------------------------------------------------------------
# Scenario B (negative control): identical geometry, NO cruft -- sub-guard 6
# must report a real OK (not SKIP), proving Scenario A isn't satisfied by an
# always-fail stub.
# ---------------------------------------------------------------------------
echo "Scenario B: consumer repo, clean feature branch -- sub-guard 6 reports OK"
CLEAN="$WORKDIR/consumer-clean"
make_consumer_repo "$CLEAN"
printf 'clean\n' > "$CLEAN/notes.txt"
git -C "$CLEAN" add notes.txt
git -C "$CLEAN" commit -q -m "clean change"

set +e
OUT_B=$(run_agg_in "$CLEAN")
set -e

inc
if printf '%s\n' "$OUT_B" | grep -qF 'SKIP: check-branch-cruft.sh'; then
  fail_msg "sub-guard 6 was SKIPped on the clean-branch scenario too: $OUT_B"
else
  pass_msg "sub-guard 6 was not skipped on the clean-branch scenario"
fi

inc
if printf '%s\n' "$OUT_B" | grep -qF 'OK: check-branch-cruft.sh'; then
  pass_msg "sub-guard 6 reports a real OK on a clean branch (ran for real, not an always-fail stub)"
else
  fail_msg "sub-guard 6 did not report OK on a clean branch; output: $OUT_B"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
