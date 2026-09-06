#!/bin/bash
set -uo pipefail
#
# Tests for scripts/calibration-run.sh — the §8 calibration-slate driver
# (issue #1280, spec docs/superpowers/specs/2026-09-05-harness-evolve-loop-design.md §8).
#
# HERMETIC BY CONSTRUCTION. Nothing here touches the network, the real
# rjskene/pipeline-calib sandbox, or ~/.claude/calib:
#   * `gh` and `claude` are STUBS on PATH that append to a call log; the
#     `claude` stub additionally fails loudly, so any accidental launch is a
#     hard test failure rather than a silent 90-minute headless run.
#   * the "remote" is a local BARE git repo created in mktemp -d, injected via
#     $PIPELINE_CALIB_REMOTE, so clone/push/tag are exercised for real.
#   * the harness under --harness is a synthetic tree carrying
#     dev/calib/template/, dev/calib/slate/*/ and a scripts/doctor.sh stub.
#
# BEHAVIOUR TESTS ONLY — nothing greps SKILL.md / CLAUDE.md prose.
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/calibration-run.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Synthetic harness (the "pipeline repo under test")
# ---------------------------------------------------------------------------
HARNESS="$TMP/harness"
mkdir -p "$HARNESS/scripts" "$HARNESS/dev/calib/template/docs"

echo "# calib sandbox" > "$HARNESS/dev/calib/template/README.md"
echo "PIPELINE_REPO=owner/pipeline-calib" > "$HARNESS/dev/calib/template/pipeline.config"
echo "stale line" > "$HARNESS/dev/calib/template/docs/guide.md"
printf '{"permissions":{"allow":["Bash"]}}\n' \
  > "$HARNESS/dev/calib/template/claude-settings.local.json"

i=1
for name in 01-stale-doc 02-script-bug 03-small-feature 04-race-vocab 05-two-dir; do
  d="$HARNESS/dev/calib/slate/$name"
  mkdir -p "$d"
  echo "calib: $name" > "$d/title.txt"
  printf 'Body for %s.\n' "$name" > "$d/body.md"
  printf '#!/bin/bash\nexit 0\n' > "$d/reference-test.sh"
  echo "docs/guide.md" > "$d/expected-files.txt"
  case "$i" in 1) echo A ;; 2) echo D ;; 3) echo B ;; 4) echo B ;; 5) echo C ;; esac > "$d/path.txt"
  i=$((i + 1))
done

cat > "$HARNESS/scripts/doctor.sh" <<'DOC'
#!/bin/bash
echo "doctor stub: $* (project root=${PIPELINE_PROJECT_ROOT:-unset})"
DOC
chmod +x "$HARNESS/scripts/doctor.sh"

# ---------------------------------------------------------------------------
# Local bare "remote" + PATH stubs
# ---------------------------------------------------------------------------
REMOTE="$TMP/remote/pipeline-calib.git"
mkdir -p "$TMP/remote"
git init --quiet --bare "$REMOTE"

SANDBOX="$TMP/sandbox/pipeline-calib"
CALLS="$TMP/calls.log"
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$CALIB_TEST_CALLS"
case "$*" in
  "repo view"*)   exit 1 ;;                      # sandbox repo absent -> create
  "repo create"*) echo "created"; exit 0 ;;
  "issue list"*)  printf '%s\n' 4001 4002 ;;     # two stale issues to reap
  "issue close"*|"issue delete"*) exit 0 ;;
  "issue create"*)
    n="$(cat "$CALIB_TEST_COUNTER" 2>/dev/null || echo 4100)"
    n=$((n + 1)); echo "$n" > "$CALIB_TEST_COUNTER"
    echo "https://github.com/owner/pipeline-calib/issues/$n"
    ;;
  *) exit 0 ;;
esac
GH
chmod +x "$STUB_BIN/gh"

cat > "$STUB_BIN/claude" <<'CL'
#!/bin/bash
echo "claude $*" >> "$CALIB_TEST_CALLS"
echo "FATAL: calibration test launched a real claude session" >&2
exit 97
CL
chmod +x "$STUB_BIN/claude"

# run_helper <args...> — runs the helper IN THE CURRENT SHELL (never a command
# substitution, so $RC / $OUT actually propagate) and sets $OUT + $RC.
RC=0
OUT=""
run_helper() {
  OUT="$(PATH="$STUB_BIN:$PATH" \
        CALIB_TEST_CALLS="$CALLS" \
        CALIB_TEST_COUNTER="$TMP/issue-counter" \
        PIPELINE_CALIB_REPO="owner/pipeline-calib" \
        PIPELINE_CALIB_DIR="$SANDBOX" \
        PIPELINE_CALIB_REMOTE="$REMOTE" \
        PIPELINE_CALIB_ISSUE_IDS="8001 8002 8003 8004 8005" \
        GIT_AUTHOR_NAME="calib test" GIT_AUTHOR_EMAIL="calib@example.invalid" \
        GIT_COMMITTER_NAME="calib test" GIT_COMMITTER_EMAIL="calib@example.invalid" \
        bash "$HELPER" "$@" 2>&1)"
  RC=$?
}

expect_sub() { # <label> <text> <substring>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass_msg "$1"; else fail_msg "$1 (missing: $3)"; fi
}
expect_rc() { # <label> <want>
  if [ "$RC" -eq "$2" ]; then pass_msg "$1"; else fail_msg "$1 (want rc=$2, got rc=$RC)"; fi
}

# ---------------------------------------------------------------------------
scenario "Scenario 1: --help prints a usage banner and exits 0"
# ---------------------------------------------------------------------------
run_helper --help
expect_rc "--help exits 0" 0
expect_sub "--help prints a usage banner" "$OUT" "Usage: scripts/calibration-run.sh"
expect_sub "--help documents the four modes" "$OUT" "--bootstrap"

# ---------------------------------------------------------------------------
scenario "Scenario 2: argument validation exits 2"
# ---------------------------------------------------------------------------
run_helper --bogus
expect_rc "unknown flag exits 2" 2
expect_sub "unknown flag names itself on stderr" "$OUT" "--bogus"

run_helper --dry-run --run
expect_rc "--dry-run + --run is rejected" 2
expect_sub "mutual-exclusion error is named" "$OUT" "mutually exclusive"

run_helper --bootstrap --reset
expect_rc "--bootstrap + --reset is rejected" 2

run_helper --dry-run --profile turbo
expect_rc "--profile turbo is rejected" 2
expect_sub "--profile error names the allowed values" "$OUT" "strict|lean"

run_helper --dry-run --model gpt
expect_rc "--model gpt is rejected" 2
expect_sub "--model error names the allowed values" "$OUT" "sonnet|opus"

run_helper --dry-run --profile lean --model opus
expect_rc "--profile lean --model opus is accepted" 0

# ---------------------------------------------------------------------------
scenario "Scenario 3: --dry-run previews the launch and touches nothing"
# ---------------------------------------------------------------------------
rm -f "$CALLS"
run_helper --dry-run --harness "$HARNESS"
expect_rc "--dry-run exits 0" 0

N_LAUNCH="$(printf '%s\n' "$OUT" | grep -c '^CALIB-LAUNCH ')"
if [ "$N_LAUNCH" -eq 1 ]; then
  pass_msg "--dry-run prints exactly one CALIB-LAUNCH line"
else
  fail_msg "--dry-run must print exactly one CALIB-LAUNCH line (got $N_LAUNCH)"
fi
LAUNCH="$(printf '%s\n' "$OUT" | grep '^CALIB-LAUNCH ' | head -1)"

expect_sub "launch line runs claude headless" "$LAUNCH" "claude -p"
expect_sub "launch line drives /pipeline:fullsend" "$LAUNCH" "/pipeline:fullsend"
for id in 8001 8002 8003 8004 8005; do
  expect_sub "launch line carries issue id $id" "$LAUNCH" "$id"
done
expect_sub "launch line passes --plugin-dir <harness>" "$LAUNCH" "--plugin-dir $HARNESS"
expect_sub "launch line exports CLAUDE_PLUGIN_ROOT=<harness>" "$LAUNCH" "CLAUDE_PLUGIN_ROOT=$HARNESS"
expect_sub "launch line passes --dangerously-skip-permissions" "$LAUNCH" "--dangerously-skip-permissions"
expect_sub "launch line names the resolved sandbox dir" "$LAUNCH" "$SANDBOX"

if [ -s "$CALLS" ]; then
  fail_msg "--dry-run made a network / launch call: $(tr '\n' ';' < "$CALLS")"
else
  pass_msg "--dry-run performs no gh call and no claude launch"
fi
if [ -e "$SANDBOX" ]; then
  fail_msg "--dry-run created the sandbox dir"
else
  pass_msg "--dry-run does not materialize the sandbox"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 4: --bootstrap is idempotent"
# ---------------------------------------------------------------------------
rm -f "$CALLS"
run_helper --bootstrap --harness "$HARNESS"
OUT1="$OUT"
RC1=$RC
if [ "$RC1" -eq 0 ]; then
  pass_msg "first --bootstrap exits 0"
else
  fail_msg "first --bootstrap exits 0 (got rc=$RC1): $OUT1"
fi

if [ -d "$SANDBOX/.git" ]; then
  pass_msg "--bootstrap clones the sandbox"
else
  fail_msg "--bootstrap clones the sandbox (no .git at sandbox)"
fi
if [ -f "$SANDBOX/README.md" ]; then
  pass_msg "--bootstrap syncs the template into the sandbox"
else
  fail_msg "--bootstrap syncs the template into the sandbox"
fi
if [ -f "$SANDBOX/.claude/settings.local.json" ]; then
  pass_msg "--bootstrap materializes the flat claude local-settings file"
else
  fail_msg "--bootstrap materializes the flat claude local-settings file"
fi
if [ -e "$SANDBOX/claude-settings.local.json" ]; then
  fail_msg "flat template settings file left behind in the sandbox root"
else
  pass_msg "flat template settings file is consumed, not left in the sandbox root"
fi
expect_sub "--bootstrap seeds labels through doctor --fix labels" "$OUT1" "doctor stub: --fix labels"

TAGS1="$(git -C "$SANDBOX" tag -l 'calib-base' | wc -l | tr -d ' ')"
RTAGS1="$(git -C "$REMOTE" tag -l 'calib-base' | wc -l | tr -d ' ')"
if [ "$TAGS1" = "1" ] && [ "$RTAGS1" = "1" ]; then
  pass_msg "--bootstrap tags calib-base locally and on the remote"
else
  fail_msg "--bootstrap tags calib-base (local=$TAGS1 remote=$RTAGS1)"
fi

HEAD1="$(git -C "$SANDBOX" rev-parse HEAD)"
run_helper --bootstrap --harness "$HARNESS"
OUT2="$OUT"
RC2=$RC
if [ "$RC2" -eq 0 ]; then
  pass_msg "second --bootstrap exits 0 (idempotent)"
else
  fail_msg "second --bootstrap exits 0 (got rc=$RC2): $OUT2"
fi
HEAD2="$(git -C "$SANDBOX" rev-parse HEAD)"
if [ "$HEAD1" = "$HEAD2" ]; then
  pass_msg "second --bootstrap creates no new commit"
else
  fail_msg "second --bootstrap moved HEAD ($HEAD1 -> $HEAD2)"
fi
TAGS2="$(git -C "$SANDBOX" tag -l 'calib-base' | wc -l | tr -d ' ')"
RTAGS2="$(git -C "$REMOTE" tag -l 'calib-base' | wc -l | tr -d ' ')"
if [ "$TAGS2" = "1" ] && [ "$RTAGS2" = "1" ]; then
  pass_msg "second --bootstrap does not duplicate the calib-base tag"
else
  fail_msg "second --bootstrap duplicated calib-base (local=$TAGS2 remote=$RTAGS2)"
fi
if grep -q '^claude ' "$CALLS" 2>/dev/null; then
  fail_msg "--bootstrap launched claude"
else
  pass_msg "--bootstrap never launches claude"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 5: --reset recreates the five slate issues"
# ---------------------------------------------------------------------------
rm -f "$CALLS" "$TMP/issue-counter"
echo "drift" >> "$SANDBOX/README.md"
git -C "$SANDBOX" commit --quiet -a -m "drift commit" 2>/dev/null

run_helper --reset --harness "$HARNESS"
expect_rc "--reset exits 0" 0
ISSUE_LINE="$(printf '%s\n' "$OUT" | grep '^CALIB-ISSUES ' | head -1)"
N_IDS="$(printf '%s\n' "$ISSUE_LINE" | tr ' ' '\n' | grep -c '^[0-9][0-9]*$')"
if [ "$N_IDS" -eq 5 ]; then
  pass_msg "--reset prints CALIB-ISSUES with five issue numbers"
else
  fail_msg "--reset must print CALIB-ISSUES with five numbers (got: $ISSUE_LINE)"
fi
if grep -q '^gh issue close ' "$CALLS" 2>/dev/null; then
  pass_msg "--reset closes stale calib issues"
else
  fail_msg "--reset closes stale calib issues"
fi
if [ "$(git -C "$SANDBOX" rev-parse HEAD)" = "$(git -C "$SANDBOX" rev-parse calib-base)" ]; then
  pass_msg "--reset returns the sandbox worktree to calib-base"
else
  fail_msg "--reset returns the sandbox worktree to calib-base"
fi
if grep -q '^claude ' "$CALLS" 2>/dev/null; then
  fail_msg "--reset launched claude"
else
  pass_msg "--reset never launches claude"
fi

# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "PASS: $PASS  FAIL: $FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
