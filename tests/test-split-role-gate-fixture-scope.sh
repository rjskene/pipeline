#!/bin/bash
set -euo pipefail

# Regression suite for scripts/split-role-gate.sh lock SCOPE within a resolved
# test root (issue #1201). The W7 gate compares the `[split-role-red]` anchor to
# HEAD over EVERY path under the resolved test roots, so a GREEN commit whose
# only testing-root delta is a plan-sanctioned DATA FIXTURE regen (observed live:
# `subagents/contract-manager/testing/fixtures/redline_config_schema.json`, 1+/1-)
# trips `SPLIT_ROLE=block REASON=locked-test-modified` even though every
# RED-locked `test_*.py` is byte-identical. That false positive forced a
# manual-merge override on a PR with green CI and a green auto-merge gate.
#
# The fix (authored by the GREEN implementer, NOT here) narrows the locked set to
# discoverable TEST FILES: a basename classifier over a default glob set
# (`test_*.py *_test.py conftest.py test*.sh ...`), replaceable wholesale via the
# new `$PIPELINE_TEST_FILE_GLOBS` knob. `skills/evaluate-issue-pr/SKILL.md`
# threads the knob into the gate invocation env (same shape as
# `PIPELINE_TEST_ROOTS`), and `pipeline.config.example` declares it.
#
# This suite pins BOTH directions deliberately. A fix that simply exempted
# everything under a test root would satisfy the positive cases while gutting the
# gate — cases C/D/E/F/H/J exist to make that implementation fail.
#
# This is the split-role RED artifact ([split-role-red]). Expected state at
# authoring time (against the UNFIXED gate + unwired caller/config):
#   A fixture modified          FAIL — gate blocks locked-test-modified (THE bug).
#   B fixture deleted           FAIL — gate blocks locked-test-deleted (same bug, D side).
#   C real test modified        PASS — must KEEP blocking after the fix (anti-gut guard).
#   D real test deleted         PASS — must KEEP blocking after the fix (anti-gut guard).
#   E fixture + test tampered   PASS — precedence guard: fixture noise never masks a tamper.
#   F conftest.py modified      PASS — fixture MODULE stays locked by default.
#   G override replaces default FAIL — override semantics are REPLACE, not append.
#   H override re-locks golden  PASS — a named golden is locked again under the override.
#   I incident replay (py)      FAIL — the exact rjskene/work-orchestrator #1237 shape.
#   J no-CWD-globbing guard     PASS — pattern set must be split with globbing OFF.
#   K caller wiring             FAIL — SKILL.md does not yet thread the knob.
#   L config declaration        FAIL — pipeline.config.example does not yet declare it.
# A/B/G/I/K/L go GREEN once the fix lands; C/D/E/F/H/J stay GREEN throughout.
#
# The gate always emits EXACTLY ONE stdout line and ALWAYS exits 0 (the verdict
# rides the token): SPLIT_ROLE=<pass|block> ISSUE=<N> REASON=<token>.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_ROOT/scripts/split-role-gate.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$GATE" ]; then
  echo "ERROR: gate script missing at $GATE" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

ISSUE=1201
BASE=base-anchor

# Incident-shape test root: tests live OUTSIDE tests/, reached via
# $PIPELINE_TEST_ROOTS (#1182) — the work-orchestrator layout.
PY_ROOT="subagents/contract-manager/testing"

# Suite-green stub so the SECONDARY suite check is a no-op pass; every case here
# exercises the PRIMARY locked-test invariant.
TEST_CMD="true"

# ---------------------------------------------------------------------------
# Repo builders
# ---------------------------------------------------------------------------

# build_repo <name> — shell-shape repo (scope `tests`, passed positionally).
# The $BASE branch holds ONE base commit seeding, under tests/:
#   test-locked.sh          a real, discoverable test file (base-origin, locked)
#   conftest.py             a pytest fixture MODULE (locked by default — it can
#                           neuter assertions, so it is NOT inert data)
#   fixtures/schema.json    inert DATA fixture (must fall OUT of lock scope)
#   fixtures/out.golden.json  inert golden (out of scope by default; re-lockable)
# plus base.txt outside the test root. A feature branch is then checked out off
# the base tip so every later commit lands inside the gate's $BASE..HEAD window.
# Echoes the repo path.
build_repo() {
  local repo="$WORKDIR/$1"
  mkdir -p "$repo/tests/fixtures"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  git -C "$repo" checkout -q -b "$BASE"
  echo base > "$repo/base.txt"
  printf 'echo locked-v1\n' > "$repo/tests/test-locked.sh"
  printf '# fixtures\n' > "$repo/tests/conftest.py"
  printf '{"v":1}\n' > "$repo/tests/fixtures/schema.json"
  printf '{"g":1}\n' > "$repo/tests/fixtures/out.golden.json"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "base"
  git -C "$repo" checkout -q -b "feature/issue-$ISSUE"
  echo "$repo"
}

# commit_red <repo> — the single [split-role-red] anchor commit. It only ADDS a
# new red-authored test file; it never touches a base-origin path.
commit_red() {
  local repo="$1"
  printf 'echo red-suite\n' > "$repo/tests/test-red.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "test(x): add failing suite [split-role-red] (#$ISSUE)"
}

# build_pyrepo <name> [<decoy-basename>] — incident-shape repo reproducing the
# rjskene/work-orchestrator PR #1237 layout: tests under $PY_ROOT (reached via
# $PIPELINE_TEST_ROOTS, no positional arg) with a generated JSON schema fixture
# living in a fixtures/ subdir of that same root.
# <decoy-basename> (case J only) seeds a file at the REPO ROOT whose name matches
# the default `test_*.py` pattern, so an implementation that word-splits the glob
# set with globbing ON would expand the pattern to the decoy and stop matching
# real basenames. Echoes the repo path.
build_pyrepo() {
  local repo="$WORKDIR/$1"
  local decoy="${2:-}"
  mkdir -p "$repo/$PY_ROOT/fixtures"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  git -C "$repo" checkout -q -b "$BASE"
  echo base > "$repo/base.txt"
  printf 'def test_redline():\n    assert render() == 1\n' > "$repo/$PY_ROOT/test_redline.py"
  printf '{"title":"redline","version":1}\n' > "$repo/$PY_ROOT/fixtures/redline_config_schema.json"
  if [ -n "$decoy" ]; then
    printf 'def test_decoy():\n    assert True\n' > "$repo/$decoy"
  fi
  git -C "$repo" add -A
  git -C "$repo" commit -qm "base"
  git -C "$repo" checkout -q -b "feature/issue-$ISSUE"
  echo "$repo"
}

# commit_red_py <repo> — [split-role-red] anchor for the incident shape; ADDS a
# new red-authored test module only.
commit_red_py() {
  local repo="$1"
  printf 'def test_new():\n    assert schema_version() == 2\n' > "$repo/$PY_ROOT/test_new.py"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "test(x): add failing suite [split-role-red] (#$ISSUE)"
}

# green_commit <repo> <subject> — stage everything (including deletions) and
# commit as a NON-marker green implementer commit.
green_commit() {
  local repo="$1" subject="$2"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$subject"
}

# ---------------------------------------------------------------------------
# run_gate <repo> [--globs <spec>] [--roots <spec>] [positional-test-path...]
# Invokes the gate from INSIDE the repo (its natural eval-time CWD is the feature
# worktree). --globs / --roots export $PIPELINE_TEST_FILE_GLOBS /
# $PIPELINE_TEST_ROOTS respectively; omitted ⇒ the var stays UNSET so the gate's
# built-in default applies. Captures stdout + exit into globals OUT and CODE.
# ---------------------------------------------------------------------------
run_gate() {
  local repo="$1"; shift
  local globs="" roots="" have_globs=0 have_roots=0
  while [ $# -ge 1 ]; do
    case "$1" in
      --globs) globs="$2"; have_globs=1; shift 2 ;;
      --roots) roots="$2"; have_roots=1; shift 2 ;;
      *) break ;;
    esac
  done
  set +e
  if [ "$have_globs" -eq 1 ] && [ "$have_roots" -eq 1 ]; then
    OUT=$( cd "$repo" && PIPELINE_TEST_CMD="$TEST_CMD" \
           PIPELINE_TEST_FILE_GLOBS="$globs" PIPELINE_TEST_ROOTS="$roots" \
           bash "$GATE" "$ISSUE" "$BASE" "$@" 2>/dev/null )
  elif [ "$have_globs" -eq 1 ]; then
    OUT=$( cd "$repo" && PIPELINE_TEST_CMD="$TEST_CMD" \
           PIPELINE_TEST_FILE_GLOBS="$globs" \
           bash "$GATE" "$ISSUE" "$BASE" "$@" 2>/dev/null )
  elif [ "$have_roots" -eq 1 ]; then
    OUT=$( cd "$repo" && PIPELINE_TEST_CMD="$TEST_CMD" \
           PIPELINE_TEST_ROOTS="$roots" \
           bash "$GATE" "$ISSUE" "$BASE" "$@" 2>/dev/null )
  else
    OUT=$( cd "$repo" && PIPELINE_TEST_CMD="$TEST_CMD" \
           bash "$GATE" "$ISSUE" "$BASE" "$@" 2>/dev/null )
  fi
  CODE=$?
  set -e
}

# assert_case <label> <expected-stdout-line>
assert_case() {
  local label="$1" expected="$2"
  inc
  if [ "$CODE" -ne 0 ]; then
    fail_msg "$label: expected exit 0 (verdict rides the token), got exit $CODE"
  elif [ "$OUT" != "$expected" ]; then
    fail_msg "$label: stdout mismatch"
    echo "         expected: [$expected]"
    echo "         actual:   [$OUT]"
  else
    pass_msg "$label: exit 0 + '$expected'"
  fi
}

BLOCK_MOD="SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-modified"
BLOCK_DEL="SPLIT_ROLE=block ISSUE=$ISSUE REASON=locked-test-deleted"
PASS_OK="SPLIT_ROLE=pass ISSUE=$ISSUE REASON=additive-ok"

# ---------------------------------------------------------------------------
# Case A — data-fixture MODIFY must not block (THE core case; RED until the fix).
# The green commit rewrites an inert JSON fixture under the test root (removed > 0)
# and adds impl source. NO discoverable test file is touched. Against the unfixed
# gate the whole-root sweep sees tests/fixtures/schema.json in the M set and emits
# locked-test-modified — the #1201 false positive ⇒ this FAILS now.
echo "Case A: data-fixture modified → pass/additive-ok (RED until fix)"
REPO=$(build_repo cA)
commit_red "$REPO"
printf '{"v":2}\n' > "$REPO/tests/fixtures/schema.json"
printf 'impl\n' > "$REPO/src.txt"
green_commit "$REPO" "feat(x): regenerate schema fixture from impl (#$ISSUE)"
run_gate "$REPO" tests
assert_case "A fixture-modified" "$PASS_OK"

# ---------------------------------------------------------------------------
# Case B — data-fixture DELETE must not block (RED until the fix).
# Deletion is the D-side of the same defect: a retired fixture is not a retired
# test. Unfixed gate ⇒ locked-test-deleted.
echo "Case B: data-fixture deleted → pass/additive-ok (RED until fix)"
REPO=$(build_repo cB)
commit_red "$REPO"
git -C "$REPO" rm -q tests/fixtures/schema.json
green_commit "$REPO" "feat(x): drop obsolete schema fixture (#$ISSUE)"
run_gate "$REPO" tests
assert_case "B fixture-deleted" "$PASS_OK"

# ---------------------------------------------------------------------------
# Case C — real locked test MODIFIED still blocks (anti-gut guard; PASS throughout).
# The whole point of W7. A fix that exempts everything under a test root breaks
# HERE, not in case A.
echo "Case C: locked test-file modified → block/locked-test-modified (guard)"
REPO=$(build_repo cC)
commit_red "$REPO"
printf 'echo locked-v2-tampered\n' > "$REPO/tests/test-locked.sh"
green_commit "$REPO" "feat(x): green impl, alter locked line (#$ISSUE)"
run_gate "$REPO" tests
assert_case "C test-modified" "$BLOCK_MOD"

# ---------------------------------------------------------------------------
# Case D — real locked test DELETED still blocks (anti-gut guard; PASS throughout).
# Deletion of a discoverable test is NEVER additive — no exemption channel applies.
echo "Case D: locked test-file deleted → block/locked-test-deleted (guard)"
REPO=$(build_repo cD)
commit_red "$REPO"
git -C "$REPO" rm -q tests/test-locked.sh
green_commit "$REPO" "feat(x): delete locked test (#$ISSUE)"
run_gate "$REPO" tests
assert_case "D test-deleted" "$BLOCK_DEL"

# ---------------------------------------------------------------------------
# Case E — precedence guard (PASS throughout). A single green commit tampers BOTH
# an inert fixture AND a real locked test. Dropping the fixture from the M set must
# NOT drop the real tamper with it: locked-test-modified still wins, and still
# precedes locked-test-deleted.
echo "Case E: fixture + real test both tampered → block/locked-test-modified (guard)"
REPO=$(build_repo cE)
commit_red "$REPO"
printf '{"v":2}\n' > "$REPO/tests/fixtures/schema.json"
printf 'echo locked-v2-tampered\n' > "$REPO/tests/test-locked.sh"
green_commit "$REPO" "feat(x): regen fixture and weaken locked test (#$ISSUE)"
run_gate "$REPO" tests
assert_case "E fixture-plus-test" "$BLOCK_MOD"

# ---------------------------------------------------------------------------
# Case F — conftest.py stays locked by DEFAULT (guard; PASS throughout).
# conftest.py is a fixture MODULE (executable pytest code that can neuter
# assertions), not inert data. It must be in the default discoverable-test glob
# set. A classifier keyed only on `test_*`/`*_test*` would regress here.
echo "Case F: conftest.py modified → block/locked-test-modified (guard)"
REPO=$(build_repo cF)
commit_red "$REPO"
printf '# neutered\n' > "$REPO/tests/conftest.py"
green_commit "$REPO" "feat(x): rewrite conftest (#$ISSUE)"
run_gate "$REPO" tests
assert_case "F conftest-modified" "$BLOCK_MOD"

# ---------------------------------------------------------------------------
# Case G — override REPLACES the default set (RED until the fix).
# With PIPELINE_TEST_FILE_GLOBS="*.golden.json" the consumer has declared that
# ONLY goldens are locked. Modifying tests/test-locked.sh must therefore NOT block.
# This case is what discriminates replace-vs-append semantics: an append-only
# implementation keeps `test*.sh` in the set and still blocks. Unfixed gate blocks.
echo "Case G: override replaces default set → pass/additive-ok (RED until fix)"
REPO=$(build_repo cG)
commit_red "$REPO"
printf 'echo locked-v2-tampered\n' > "$REPO/tests/test-locked.sh"
green_commit "$REPO" "feat(x): edit shell test under golden-only lock (#$ISSUE)"
run_gate "$REPO" --globs "*.golden.json" tests
assert_case "G override-replaces" "$PASS_OK"

# ---------------------------------------------------------------------------
# Case H — override RE-LOCKS a golden (guard; PASS throughout). The safety valve
# for repos whose goldens ARE their assertions: naming *.golden.json in the knob
# puts it back under lock, so regenerating it blocks.
echo "Case H: override re-locks golden fixture → block/locked-test-modified (guard)"
REPO=$(build_repo cH)
commit_red "$REPO"
printf '{"g":2}\n' > "$REPO/tests/fixtures/out.golden.json"
green_commit "$REPO" "feat(x): regenerate golden (#$ISSUE)"
run_gate "$REPO" --globs "*.golden.json" tests
assert_case "H override-relocks-golden" "$BLOCK_MOD"

# ---------------------------------------------------------------------------
# Case I — incident replay (RED until the fix). The literal rjskene/work-orchestrator
# PR #1237 shape: tests under subagents/*/testing/ reached via $PIPELINE_TEST_ROOTS
# (no positional arg), green regenerates the JSON schema fixture in that root's
# fixtures/ subdir (1+/1-) plus impl source, while every test_*.py is byte-identical.
# Unfixed gate ⇒ block locked-test-modified, the observed false positive.
echo "Case I: incident replay — testing-root fixture regen → pass/additive-ok (RED until fix)"
REPO=$(build_pyrepo cI)
commit_red_py "$REPO"
printf '{"title":"redline","version":2}\n' > "$REPO/$PY_ROOT/fixtures/redline_config_schema.json"
printf 'def schema_version():\n    return 2\n' > "$REPO/src.py"
green_commit "$REPO" "feat(x): bump schema + regen fixture (#$ISSUE)"
run_gate "$REPO" --roots "subagents/*/testing/"
# Sanity: both red-locked test modules are untouched by the green commit.
inc
if [ -n "$(git -C "$REPO" diff HEAD~1 HEAD --name-only -- "$PY_ROOT/test_redline.py" "$PY_ROOT/test_new.py")" ]; then
  fail_msg "I precondition: green commit unexpectedly touched a test_*.py module"
else
  pass_msg "I precondition: green commit left both test_*.py modules byte-identical"
fi
assert_case "I incident-replay" "$PASS_OK"

# ---------------------------------------------------------------------------
# Case J — no-CWD-globbing guard (PASS throughout). Same incident shape, plus a
# base-committed decoy `test_decoy.py` at the REPO ROOT (the gate's CWD). The green
# commit tampers a REAL locked test module, so the gate MUST block. An
# implementation that word-splits $PIPELINE_TEST_FILE_GLOBS with globbing ON would
# expand `test_*.py` to `test_decoy.py`, stop matching `test_redline.py`, and
# vacuously pass — this case fails against exactly that bug. (Patterns are matched
# against BASENAMES via `case`, never against the filesystem.)
echo "Case J: glob patterns not expanded against CWD → block/locked-test-modified (guard)"
REPO=$(build_pyrepo cJ "test_decoy.py")
commit_red_py "$REPO"
printf 'def test_redline():\n    assert True  # weakened\n' > "$REPO/$PY_ROOT/test_redline.py"
green_commit "$REPO" "feat(x): weaken locked test module (#$ISSUE)"
inc
if [ ! -f "$REPO/test_decoy.py" ]; then
  fail_msg "J precondition: decoy test_decoy.py missing from gate CWD"
else
  pass_msg "J precondition: decoy test_decoy.py present at repo root (gate CWD)"
fi
run_gate "$REPO" --roots "subagents/*/testing/"
assert_case "J no-cwd-globbing" "$BLOCK_MOD"

# ---------------------------------------------------------------------------
# Case K — caller wiring guard (RED until the fix). The eval-time transport is
# prose in skills/evaluate-issue-pr/SKILL.md, not gate code: the gate never sources
# pipeline.config, so the caller must thread PIPELINE_TEST_FILE_GLOBS into the gate
# invocation env (same shape as PIPELINE_TEST_ROOTS, #1182).
echo "Case K: evaluate-issue-pr/SKILL.md threads PIPELINE_TEST_FILE_GLOBS (RED until fix)"
EVAL_SKILL="$REPO_ROOT/skills/evaluate-issue-pr/SKILL.md"
inc
if [ ! -f "$EVAL_SKILL" ]; then
  fail_msg "K caller-wiring: $EVAL_SKILL missing"
elif ! grep -qF 'PIPELINE_TEST_FILE_GLOBS=' "$EVAL_SKILL"; then
  fail_msg "K caller-wiring: evaluate-issue-pr/SKILL.md does not thread PIPELINE_TEST_FILE_GLOBS="
else
  pass_msg "K caller-wiring: evaluate-issue-pr/SKILL.md threads PIPELINE_TEST_FILE_GLOBS="
fi

# ---------------------------------------------------------------------------
# Case L — config-declaration guard (RED until the fix). pipeline.config.example
# must declare the optional PIPELINE_TEST_FILE_GLOBS knob (COMMENTED, so
# `doctor --fix config` does not seed it and pin the default) adjacent to
# PIPELINE_TEST_ROOTS, so consumers whose goldens ARE assertions can re-lock them.
echo "Case L: pipeline.config.example declares PIPELINE_TEST_FILE_GLOBS (RED until fix)"
CONFIG_EXAMPLE="$REPO_ROOT/pipeline.config.example"
inc
if [ ! -f "$CONFIG_EXAMPLE" ]; then
  fail_msg "L config-doc: $CONFIG_EXAMPLE missing"
elif ! grep -qF 'PIPELINE_TEST_FILE_GLOBS' "$CONFIG_EXAMPLE"; then
  fail_msg "L config-doc: pipeline.config.example does not declare PIPELINE_TEST_FILE_GLOBS"
else
  pass_msg "L config-doc: pipeline.config.example declares PIPELINE_TEST_FILE_GLOBS"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
