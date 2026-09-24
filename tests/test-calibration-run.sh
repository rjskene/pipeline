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
#   * the harness under --harness is a synthetic GIT CHECKOUT (non-bare)
#     carrying dev/calib/template/, dev/calib/slate/*/ and a scripts/doctor.sh
#     stub, plus an untracked pipeline.config — the shape --run's harness
#     staging needs (a commit to detach at, a host-specific config to copy).
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
  # Graded against the sandbox WORKING TREE (issue_reftest runs it with the
  # sandbox as cwd): passes only once the merged fix has been pulled back.
  printf '#!/bin/bash\ngrep -qx fixed docs/guide.md\n' > "$d/reference-test.sh"
  echo "docs/guide.md" > "$d/expected-files.txt"
  # A DECOY. `path=` must report the routing the run actually chose, never a
  # slate-declared expectation, so any driver that reads this file reports `X`
  # and fails the CALIB path assertions below.
  echo X > "$d/path.txt"
  i=$((i + 1))
done

# The harness's cost/latency reporter. Records the environment it is invoked
# with: it joins PRs against issue numbers, so an invocation carrying the
# HARNESS's PIPELINE_REPO would join the WRONG repo's PRs against sandbox issue
# ids (#1280). Emits whatever rows / pricing JSON the scenario staged.
cat > "$HARNESS/scripts/cost-latency-report.sh" <<'CLR'
#!/bin/bash
echo "clr $* cwd=$PWD PIPELINE_REPO=${PIPELINE_REPO:-unset}" >> "$CALIB_TEST_CALLS"
case "$*" in
  *--emit-rows-json*)    cat "${CALIB_TEST_ROWS_JSON:-/dev/null}" 2>/dev/null ;;
  *--emit-pricing-json*) cat "${CALIB_TEST_PRICING_JSON:-/dev/null}" 2>/dev/null ;;
esac
exit 0
CLR
chmod +x "$HARNESS/scripts/cost-latency-report.sh"

cat > "$HARNESS/scripts/doctor.sh" <<'DOC'
#!/bin/bash
echo "doctor stub: $* (project root=${PIPELINE_PROJECT_ROOT:-unset})"
# Record the exact environment the label-seed step runs with. The real
# doctor.sh --fix labels reads ./pipeline.config from its CWD and seeds
# $PIPELINE_REPO, so both are load-bearing: seeding the harness repo instead
# of the sandbox is the #1280 defect this recording exists to catch.
if [ -n "${CALIB_TEST_DOCTOR_ENV:-}" ]; then
  {
    echo "cwd=$PWD"
    echo "PIPELINE_REPO=${PIPELINE_REPO:-unset}"
    echo "PIPELINE_PROJECT_ROOT=${PIPELINE_PROJECT_ROOT:-unset}"
  } > "$CALIB_TEST_DOCTOR_ENV"
fi
DOC
chmod +x "$HARNESS/scripts/doctor.sh"

# The harness is a REAL (non-bare) checkout, not a loose tree: --run stages the
# harness HEAD as a detached worktree, which needs a commit to detach at, and
# copies the harness's pipeline.config across. That config is UNTRACKED here on
# purpose — the real one is gitignored and host-specific, so a staging step
# that relied on `git checkout` alone would leave the staged tree without it.
# GIT_* identity is set explicitly for the same reason run_helper sets it: the
# test host may have no git identity configured at all.
printf 'PIPELINE_CALIB_REPO=owner/pipeline-calib\n' > "$HARNESS/pipeline.config"
printf 'pipeline.config\ndocs/retros/\n' > "$HARNESS/.gitignore"
git init --quiet "$HARNESS"
git -C "$HARNESS" add .gitignore scripts dev
GIT_AUTHOR_NAME="calib test" GIT_AUTHOR_EMAIL="calib@example.invalid" \
GIT_COMMITTER_NAME="calib test" GIT_COMMITTER_EMAIL="calib@example.invalid" \
  git -C "$HARNESS" commit --quiet -m "calib: synthetic harness"

# ---------------------------------------------------------------------------
# Local bare "remote" + PATH stubs
# ---------------------------------------------------------------------------
REMOTE="$TMP/remote/pipeline-calib.git"
mkdir -p "$TMP/remote"
git init --quiet --bare "$REMOTE"

SANDBOX="$TMP/sandbox/pipeline-calib"
# Where --run stages the harness: a sibling of the sandbox clone inside the
# calib dir. Derived from PIPELINE_CALIB_DIR, so it needs no knob of its own.
STAGE="$TMP/sandbox/harness"
CALLS="$TMP/calls.log"
DOCTOR_ENV="$TMP/doctor-env.txt"
LAUNCH_ENV="$TMP/launch-env.txt"
# The capture log the sandbox session's own cost hooks write (#1395). --run
# refuses to report a total it never priced, so a stub standing in for a run
# that REALLY happened has to leave one behind — and the stubs standing in for
# a run that never started (Scenario 12, Scenario 13c) must not. Exported
# rather than passed through run_helper so the scripted `claude` stand-ins can
# see it: they inherit this shell's environment through the `claude` stub.
COST_LOG="$SANDBOX/.claude/logs/agent-costs.jsonl"
export CALIB_TEST_COST_LOG="$COST_LOG"
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$CALIB_TEST_CALLS"
case "$*" in
  # `gh repo view --json nameWithOwner` (no repo arg) = "what repo is this
  # checkout?" — the slug the --reset blast-radius guard compares against.
  "repo view --json"*) echo "${CALIB_TEST_OWN_SLUG:-rjskene/pipeline}" ;;
  "repo view"*)   exit 1 ;;                      # sandbox repo absent -> create
  "repo create"*) echo "created"; exit 0 ;;
  # ONE fetch per PR set and ONE per issue, both reduced with jq INSIDE the
  # driver — so this stub stays pure transport: it cats whatever JSON the
  # scenario staged and never interprets --json / --jq itself.
  "pr list"*)     cat "${CALIB_TEST_PRS_JSON:-}" 2>/dev/null || echo '[]' ;;
  # `gh issue view <n> --repo R --json ...` — the number is the third token.
  "issue view"*)  cat "${CALIB_TEST_ISSUES_DIR:-}/$3.json" 2>/dev/null || echo '{}' ;;
  # <number>TAB<title>, the shape the title-scoped reap reads. 4001 carries a
  # slate title (reapable); 4777 is an unrelated issue that must survive.
  "issue list"*)  printf '%s\t%s\n' 4001 "calib: 01-stale-doc" 4777 "unrelated issue" ;;
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

# Default: fail loudly, so an accidental launch is a hard failure rather than a
# silent 90-minute headless run. $CALIB_TEST_CLAUDE_SCRIPT swaps in a scripted
# stand-in for the ONE scenario that needs the launch to "do the work".
cat > "$STUB_BIN/claude" <<'CL'
#!/bin/bash
echo "claude $*" >> "$CALIB_TEST_CALLS"
# Record the environment the launch actually hands the sandbox session. Two
# things must be true of it and neither is visible in the argv: the delegation
# hook has to be LIVE inside the measured run (so the loop session's
# ALLOW_ORCHESTRATOR_EDIT must not be inherited), and the session has to know
# it is headless.
if [ -n "${CALIB_TEST_LAUNCH_ENV:-}" ]; then
  {
    echo "ALLOW_ORCHESTRATOR_EDIT=${ALLOW_ORCHESTRATOR_EDIT:-unset}"
    echo "PIPELINE_HEADLESS=${PIPELINE_HEADLESS:-unset}"
    echo "CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT:-unset}"
    echo "PIPELINE_TRUST_PROFILE=${PIPELINE_TRUST_PROFILE:-unset}"
    # #1390 regression guard: an operator shell that has sourced the clone's
    # pipeline.config exports these too. They must never reach this launch.
    echo "PIPELINE_REPO=${PIPELINE_REPO:-unset}"
    echo "PIPELINE_PROJECT_ROOT=${PIPELINE_PROJECT_ROOT:-unset}"
    echo "PIPELINE_USE_LOCAL_PLUGIN=${PIPELINE_USE_LOCAL_PLUGIN:-unset}"
  } > "$CALIB_TEST_LAUNCH_ENV"
fi
if [ -x "${CALIB_TEST_CLAUDE_SCRIPT:-}" ]; then
  exec "$CALIB_TEST_CLAUDE_SCRIPT" "$@"
fi
echo "FATAL: calibration test launched a real claude session" >&2
exit 97
CL
chmod +x "$STUB_BIN/claude"

# run_helper <args...> — runs the helper IN THE CURRENT SHELL (never a command
# substitution, so $RC / $OUT actually propagate) and sets $OUT + $RC.
#
# `timeout 20` is load-bearing, not belt-and-braces: an arg-parse bug that
# fails to consume its token spins the `while [ $# -gt 0 ]` loop forever with
# no output, which without the cap wedges the whole suite instead of failing
# it (rc=124).
RC=0
OUT=""
run_helper() {
  OUT="$(PATH="$STUB_BIN:$PATH" \
        CALIB_TEST_CALLS="$CALLS" \
        CALIB_TEST_COUNTER="$TMP/issue-counter" \
        CALIB_TEST_DOCTOR_ENV="$DOCTOR_ENV" \
        CALIB_TEST_LAUNCH_ENV="$LAUNCH_ENV" \
        HOME="${CALIB_TEST_HOME:-$HOME}" \
        ALLOW_ORCHESTRATOR_EDIT="true" \
        PIPELINE_REPO="${CALIB_TEST_PIPELINE_REPO_OVERRIDE:-rjskene/pipeline}" \
        PIPELINE_CALIB_REPO="${CALIB_TEST_REPO_OVERRIDE:-owner/pipeline-calib}" \
        PIPELINE_CALIB_DIR="$SANDBOX" \
        PIPELINE_CALIB_REMOTE="$REMOTE" \
        PIPELINE_CALIB_ISSUE_IDS="8001 8002 8003 8004 8005" \
        GIT_AUTHOR_NAME="calib test" GIT_AUTHOR_EMAIL="calib@example.invalid" \
        GIT_COMMITTER_NAME="calib test" GIT_COMMITTER_EMAIL="calib@example.invalid" \
        timeout 20 bash "$HELPER" "$@" 2>&1)"
  RC=$?
}

expect_sub() { # <label> <text> <substring>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass_msg "$1"; else fail_msg "$1 (missing: $3)"; fi
}
expect_rc() { # <label> <want>
  if [ "$RC" -eq "$2" ]; then pass_msg "$1"; else fail_msg "$1 (want rc=$2, got rc=$RC)"; fi
}
refute_sub() { # <label> <text> <substring>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then
    fail_msg "$1 (unexpectedly present: $3)"
  else
    pass_msg "$1"
  fi
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

# A value-taking flag in LAST position has no value to shift: `shift 2` with
# $#=1 fails, the token is never consumed, and the parser spins forever with
# no output. Must be a usage error, never a hang (rc=124 from run_helper's cap).
for flag in --profile --model --harness; do
  run_helper --dry-run "$flag"
  expect_rc "trailing $flag exits 2 (never spins)" 2
  expect_sub "trailing $flag reports the missing value" "$OUT" "$flag requires a value"
done

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
# The session loads the STAGED harness, not the checkout under test: its own
# restrict_paths hook allows only the sandbox project dir and ~/.claude, so a
# plugin dir anywhere else is unreadable from inside the run.
expect_sub "launch line passes --plugin-dir <staged harness>" "$LAUNCH" "--plugin-dir $STAGE"
expect_sub "launch line exports CLAUDE_PLUGIN_ROOT=<staged harness>" "$LAUNCH" "CLAUDE_PLUGIN_ROOT=$STAGE"
expect_sub "launch line passes --dangerously-skip-permissions" "$LAUNCH" "--dangerously-skip-permissions"
# The loop session that drives this script exports ALLOW_ORCHESTRATOR_EDIT;
# inheriting it would disable the delegation hook inside the very run being
# measured, so the launch strips it back out.
expect_sub "launch line strips the loop session's ALLOW_ORCHESTRATOR_EDIT" \
  "$LAUNCH" "-u ALLOW_ORCHESTRATOR_EDIT"
expect_sub "launch line starts with env" "$LAUNCH" "cwd=$SANDBOX env "
expect_sub "launch line tells the session it is headless" "$LAUNCH" "PIPELINE_HEADLESS=true"
expect_sub "launch line disables the print-mode background wait ceiling" \
  "$LAUNCH" "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0"
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
if [ -e "$STAGE" ]; then
  fail_msg "--dry-run created the staged harness dir"
else
  pass_msg "--dry-run computes the staged harness path without creating it"
fi

# Control: a harness that ALREADY lives under ~/.claude is readable from inside
# the session, so it is launched IN PLACE — staging is not unconditional.
mkdir -p "$TMP/home/.claude/h"
CALIB_TEST_HOME="$TMP/home" run_helper --dry-run --harness "$TMP/home/.claude/h"
LAUNCH_NS="$(printf '%s\n' "$OUT" | grep '^CALIB-LAUNCH ' | head -1)"
expect_sub "a harness already under ~/.claude is launched in place" \
  "$LAUNCH_NS" "--plugin-dir $TMP/home/.claude/h"
expect_sub "a harness already under ~/.claude keeps its own CLAUDE_PLUGIN_ROOT" \
  "$LAUNCH_NS" "CLAUDE_PLUGIN_ROOT=$TMP/home/.claude/h"

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

# The label seed must target the SANDBOX repo. Regression guard for #1280: the
# harness pipeline.config leaks PIPELINE_REPO=<harness slug> into the
# environment (run_helper exports it, exactly as the real dogfood shell does),
# and doctor.sh --fix labels honours both an already-set PIPELINE_REPO and the
# pipeline.config sitting in its CWD — so an unscoped seed step silently seeds
# the harness repo and leaves the sandbox with only GitHub's default labels.
SEED_ENV="$(cat "$DOCTOR_ENV" 2>/dev/null)"
if printf '%s\n' "$SEED_ENV" | grep -qxF "PIPELINE_REPO=owner/pipeline-calib"; then
  pass_msg "label seed runs with PIPELINE_REPO pinned to the sandbox repo"
else
  fail_msg "label seed must run with PIPELINE_REPO=owner/pipeline-calib (got: $(printf '%s' "$SEED_ENV" | grep '^PIPELINE_REPO=' || echo none))"
fi
if printf '%s\n' "$SEED_ENV" | grep -qxF "PIPELINE_REPO=rjskene/pipeline"; then
  fail_msg "label seed leaked the harness repo slug into PIPELINE_REPO"
else
  pass_msg "label seed never inherits the harness repo slug"
fi
if printf '%s\n' "$SEED_ENV" | grep -qxF "cwd=$SANDBOX"; then
  pass_msg "label seed runs with the sandbox as cwd (doctor reads ./pipeline.config)"
else
  fail_msg "label seed must run with cwd=$SANDBOX (got: $(printf '%s' "$SEED_ENV" | grep '^cwd=' || echo none))"
fi
if printf '%s\n' "$SEED_ENV" | grep -qxF "PIPELINE_PROJECT_ROOT=$SANDBOX"; then
  pass_msg "label seed runs with PIPELINE_PROJECT_ROOT=<sandbox>"
else
  fail_msg "label seed must run with PIPELINE_PROJECT_ROOT=$SANDBOX"
fi
expect_sub "--bootstrap names the repo it actually seeded" "$OUT1" "labels seeded on owner/pipeline-calib"

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
scenario "Scenario 5b: --reset closes stale PRs and deletes remote branches (backlog #51)"
# ---------------------------------------------------------------------------
rm -f "$CALLS" "$TMP/issue-counter"
GIT_AUTHOR_NAME="calib test" GIT_AUTHOR_EMAIL="calib@example.invalid" \
GIT_COMMITTER_NAME="calib test" GIT_COMMITTER_EMAIL="calib@example.invalid" \
  git -C "$SANDBOX" checkout --quiet -b feature/stale calib-base
GIT_AUTHOR_NAME="calib test" GIT_AUTHOR_EMAIL="calib@example.invalid" \
GIT_COMMITTER_NAME="calib test" GIT_COMMITTER_EMAIL="calib@example.invalid" \
  git -C "$SANDBOX" commit --quiet --allow-empty -m "stale PR work"
git -C "$SANDBOX" push --quiet origin feature/stale
git -C "$SANDBOX" checkout --quiet main

PRS_JSON="$TMP/prs-open.json"
printf '[{"number":9001,"headRefName":"feature/stale"}]\n' > "$PRS_JSON"

# Control: a dry-run reset must print CALIB-LAUNCH previews and touch nothing.
CALIB_TEST_PRS_JSON="$PRS_JSON" run_helper --dry-run --reset --harness "$HARNESS"
DRY_BRANCHES="$(git -C "$REMOTE" for-each-ref --format='%(refname:short)' refs/heads)"
if printf '%s\n' "$DRY_BRANCHES" | grep -qxF "feature/stale"; then
  pass_msg "--dry-run --reset leaves feature/stale on the remote"
else
  fail_msg "--dry-run --reset must not delete remote branches (remote heads: $DRY_BRANCHES)"
fi

# Real run: closes the stale PR and deletes every remote branch but main.
CALIB_TEST_PRS_JSON="$PRS_JSON" run_helper --reset --harness "$HARNESS"
expect_rc "--reset (PR sweep) exits 0" 0
if grep -qF "gh pr close 9001 --repo owner/pipeline-calib --delete-branch" "$CALLS" 2>/dev/null; then
  pass_msg "--reset closes the stale open PR"
else
  fail_msg "--reset must close the stale open PR: $(grep '^gh pr ' "$CALLS" 2>/dev/null | tr '\n' ';')"
fi
REMOTE_BRANCHES="$(git -C "$REMOTE" for-each-ref --format='%(refname:short)' refs/heads)"
if [ "$REMOTE_BRANCHES" = "main" ]; then
  pass_msg "--reset deletes every remote branch but main"
else
  fail_msg "--reset must leave only main on the remote (got: $REMOTE_BRANCHES)"
fi
if grep -q '^claude ' "$CALLS" 2>/dev/null; then
  fail_msg "--reset (PR sweep) launched claude"
else
  pass_msg "--reset (PR sweep) never launches claude"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 6: --reset refuses to nuke a non-sandbox repo"
# ---------------------------------------------------------------------------
# --reset force-pushes a branch back to a tag and DELETES issues. Pointed at
# the harness repo (a one-character config slip) that is unrecoverable, so the
# refusal is asserted from both directions: the exported PIPELINE_REPO and the
# slug of the checkout the driver is running in.

rm -f "$CALLS"
CALIB_TEST_REPO_OVERRIDE="rjskene/pipeline" run_helper --reset --harness "$HARNESS"
expect_rc "--reset dies when the sandbox repo is PIPELINE_REPO" 1
expect_sub "the refusal names the repo it refused" "$OUT" "rjskene/pipeline"
if [ -s "$CALLS" ]; then
  fail_msg "--reset dispatched before refusing: $(tr '\n' ';' < "$CALLS")"
else
  pass_msg "--reset refuses before any gh dispatch"
fi

rm -f "$CALLS"
CALIB_TEST_REPO_OVERRIDE="owner/harness-checkout" CALIB_TEST_OWN_SLUG="owner/harness-checkout" \
  run_helper --reset --harness "$HARNESS"
expect_rc "--reset dies when the sandbox repo is this checkout's own repo" 1
if grep -q '^gh issue ' "$CALLS" 2>/dev/null; then
  fail_msg "--reset touched issues on its own repo: $(grep '^gh issue ' "$CALLS" | tr '\n' ';')"
else
  pass_msg "--reset touches no issue on its own repo"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 7: the reap is bounded and scoped to the slate"
# ---------------------------------------------------------------------------
rm -f "$CALLS" "$TMP/issue-counter"
run_helper --reset --harness "$HARNESS"
expect_rc "--reset exits 0 against the sandbox repo" 0

LIST_CALL="$(grep -m1 '^gh issue list ' "$CALLS" 2>/dev/null)"
expect_sub "the reap bounds gh issue list (default 30 silently truncates)" "$LIST_CALL" "--limit 200"

if grep -qE '^gh issue (close|delete) 4001 ' "$CALLS" 2>/dev/null; then
  pass_msg "the reap closes an issue carrying a slate title"
else
  fail_msg "the reap must close issue 4001 (title 'calib: 01-stale-doc')"
fi
if grep -qE '^gh issue (close|delete) 4777 ' "$CALLS" 2>/dev/null; then
  fail_msg "the reap deleted an unrelated issue (4777)"
else
  pass_msg "the reap leaves non-slate issues alone"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 7b: --reset re-materializes the sandbox local-settings file"
# ---------------------------------------------------------------------------
# The #1395 defect. --bootstrap was the ONLY writer of the sandbox's
# .claude/<local settings> file, and on the operator's host that file is
# untracked AND covered by a global ignore rule, so `git reset --hard` never
# touched it either. Every hook added to the harness template since the first
# bootstrap — log_subagent.py and capture_agent_cost.py among them — therefore
# never reached a single measured run, and every CALIB block since reported
# cost=$0. --reset has to refresh it from the harness template, every time.

TEMPLATE_SETTINGS="$HARNESS/dev/calib/template/claude-settings.local.json"
SANDBOX_SETTINGS="$SANDBOX/.claude/settings.local.json"
cat > "$TEMPLATE_SETTINGS" <<'TPL'
{
  "permissions": {"allow": ["Bash"]},
  "hooks": {
    "PostToolUse": [
      {"matcher": "Agent", "hooks": [
        {"type": "command", "command": "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/capture_agent_cost.py"}
      ]}
    ]
  }
}
TPL

# The stale bootstrap-era blob: enabledPlugins + permissions, no `hooks` key at
# all — the shape found in the live sandbox on 2026-09-23, weeks after the
# template grew its hooks.
STALE_SETTINGS='{"enabledPlugins":{},"permissions":{"allow":[]}}'
mkdir -p "$SANDBOX/.claude"
printf '%s\n' "$STALE_SETTINGS" > "$SANDBOX_SETTINGS"

rm -f "$CALLS" "$TMP/issue-counter"
run_helper --reset --harness "$HARNESS"
expect_rc "--reset (settings refresh) exits 0" 0
expect_sub "--reset reports the local-settings refresh" \
  "$OUT" "calib: settings.local.json refreshed from template ("
# Counted off the template, not hardcoded: a driver that prints `(0 hooks)`
# while copying a one-hook file is the same defect wearing a log line.
expect_sub "the refresh line carries the template's real hook count" \
  "$OUT" "refreshed from template (1 hooks)"

SETTINGS_AFTER="$(cat "$SANDBOX_SETTINGS" 2>/dev/null)"
expect_sub "the sandbox settings file carries the template's hook command" \
  "$SETTINGS_AFTER" "capture_agent_cost.py"
refute_sub "the stale bootstrap-era blob is replaced, not merged into" \
  "$SETTINGS_AFTER" '"enabledPlugins":{}'
if [ -f "$TEMPLATE_SETTINGS" ]; then
  pass_msg "the refresh is a COPY — the harness template survives it"
else
  fail_msg "--reset consumed the harness template instead of copying it"
fi

rm -f "$CALLS"
run_helper --reset --harness "$HARNESS"
expect_rc "a second --reset (settings refresh) exits 0" 0
if grep -qF 'capture_agent_cost.py' "$SANDBOX_SETTINGS" 2>/dev/null; then
  pass_msg "a second --reset leaves the refreshed settings in place (idempotent)"
else
  fail_msg "a second --reset must leave the template's hooks in the sandbox settings"
fi
if [ -e "$SANDBOX/claude-settings.local.json" ]; then
  fail_msg "--reset left the flat template settings file in the sandbox root"
else
  pass_msg "--reset leaves no flat template settings file in the sandbox root"
fi

# --reset --dry-run is the FREE preview: it must NAME the copy and mutate
# nothing, so every mutating call in the refresh goes through dispatch().
printf '%s\n' "$STALE_SETTINGS" > "$SANDBOX_SETTINGS"
# sync_template rsyncs the template's flat file into the sandbox root and the
# real refresh consumes it. A dry run must leave it exactly where it found it.
printf '%s\n' '{"flat":true}' > "$SANDBOX/claude-settings.local.json"

rm -f "$CALLS"
run_helper --dry-run --reset --harness "$HARNESS"
expect_rc "--reset --dry-run (settings refresh) exits 0" 0
expect_sub "the dry-run preview names the template -> sandbox copy" \
  "$OUT" "$TEMPLATE_SETTINGS $SANDBOX_SETTINGS"
expect_sub "the dry-run preview still reports the hook count it WOULD install" \
  "$OUT" "refreshed from template (1 hooks)"
DRY_SETTINGS="$(cat "$SANDBOX_SETTINGS" 2>/dev/null)"
expect_sub "--dry-run leaves the stale sandbox settings file untouched" \
  "$DRY_SETTINGS" '"enabledPlugins":{}'
refute_sub "--dry-run installs no hook into the sandbox" \
  "$DRY_SETTINGS" "capture_agent_cost.py"
if [ -f "$SANDBOX/claude-settings.local.json" ]; then
  pass_msg "--dry-run does not consume the flat template settings file"
else
  fail_msg "--dry-run deleted the flat template settings file from the sandbox root"
fi

rm -rf "$SANDBOX/.claude"
rm -f "$CALLS"
run_helper --dry-run --reset --harness "$HARNESS"
expect_rc "--reset --dry-run with no sandbox .claude/ exits 0" 0
if [ -e "$SANDBOX/.claude" ]; then
  fail_msg "--dry-run created $SANDBOX/.claude"
else
  pass_msg "--dry-run creates no .claude/ dir in the sandbox"
fi

# Restore the sandbox for the --run scenarios below: the real reset re-creates
# the tracked settings file; the planted flat copy is untracked, so it has to
# be removed by hand.
rm -f "$SANDBOX/claude-settings.local.json" "$TMP/issue-counter"
run_helper --reset --harness "$HARNESS"
expect_rc "--reset restores the sandbox after the dry-run probes" 0

# ---------------------------------------------------------------------------
scenario "Scenario 7c: --reset rewrites \${CLAUDE_PLUGIN_ROOT} to the staged harness path (#1404)"
# ---------------------------------------------------------------------------
# Claude Code refuses \${CLAUDE_PLUGIN_ROOT} in a settings-level hook -- it is
# only honored inside a plugin's own hooks/hooks.json. Run #7 showed every
# PostToolUse(Agent) hook exiting 1 with exactly that message (38/38 Agent
# dispatches), so the cost log was never written and the run aborted
# no-cost-log. The refresh has to rewrite the literal placeholder to the
# absolute staged-harness path every time, idempotently.
cat > "$TEMPLATE_SETTINGS" <<'TPL'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/log-tool-use.sh"}
      ]},
      {"matcher": "Agent", "hooks": [
        {"type": "command", "command": "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/log_subagent.py"},
        {"type": "command", "command": "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/capture_agent_cost.py"}
      ]}
    ]
  }
}
TPL

rm -f "$CALLS"
run_helper --reset --harness "$HARNESS"
expect_rc "--reset (plugin-root substitution) exits 0" 0
expect_sub "the refresh line reports the substituted staged-harness path" \
  "$OUT" "-> $STAGE"

SUBST_SETTINGS="$(cat "$SANDBOX_SETTINGS" 2>/dev/null)"
refute_sub "the sandbox settings file carries no literal \${CLAUDE_PLUGIN_ROOT}" \
  "$SUBST_SETTINGS" '${CLAUDE_PLUGIN_ROOT}'

hook_cmds="$(grep -o '"command": "[^"]*"' "$SANDBOX_SETTINGS")"
if [ -n "$hook_cmds" ] && ! printf '%s\n' "$hook_cmds" | grep -qvE "\"command\": \"(bash|python3) $STAGE/hooks/"; then
  pass_msg "every hook command starts with the staged harness path"
else
  fail_msg "some hook command was not rewritten to the staged harness path: $hook_cmds"
fi

# A second --reset is idempotent: the placeholder is already gone, so the
# substitution is a no-op re-run, not a double-rewrite.
rm -f "$CALLS"
run_helper --reset --harness "$HARNESS"
expect_rc "a second --reset (plugin-root substitution) exits 0" 0
SUBST_SETTINGS_2="$(cat "$SANDBOX_SETTINGS" 2>/dev/null)"
if [ "$SUBST_SETTINGS_2" = "$SUBST_SETTINGS" ]; then
  pass_msg "a second --reset re-substitution is idempotent (unchanged output)"
else
  fail_msg "a second --reset changed the already-substituted settings file"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 8: --run grades the MERGED sandbox tree, scoped to the sandbox"
# ---------------------------------------------------------------------------
# Still hermetic: `claude` is a scripted stand-in for the headless run and the
# "remote" is the local bare repo. The stand-in does what the real run does —
# it lands the fix ON THE REMOTE (the pipeline merges PRs there; this clone was
# hard-reset to calib-base by --reset moments earlier). So a driver that never
# pulls the merged tree back grades the UNFIXED sandbox and reports 0/5.

PUSHER="$TMP/pusher"
git clone --quiet "$REMOTE" "$PUSHER"

cat > "$TMP/claude-merge.sh" <<'MERGE'
#!/bin/bash
set -e
# A run that really happened leaves a capture log behind — the sandbox's own
# cost hooks write it as the session works (#1395). Without one the driver has
# nothing to price and refuses to report a total at all, so every stub standing
# in for a REAL run has to write one too.
mkdir -p "$(dirname "$CALIB_TEST_COST_LOG")"
printf '%s\n' '{"schema_version":1,"issue":"5001","stage":"execute","tokens":{"total":1000}}' \
  >> "$CALIB_TEST_COST_LOG"
git -C "$CALIB_TEST_PUSHER" fetch --quiet origin
git -C "$CALIB_TEST_PUSHER" checkout --quiet -B main origin/main
printf 'fixed\n' > "$CALIB_TEST_PUSHER/docs/guide.md"
git -C "$CALIB_TEST_PUSHER" add docs/guide.md
git -C "$CALIB_TEST_PUSHER" commit --quiet -m "merge: slate fix"
git -C "$CALIB_TEST_PUSHER" push --quiet origin main
MERGE
chmod +x "$TMP/claude-merge.sh"

# --reset assigns the ids, so pin the stub's counter and stage the substrate
# against the ids it will hand out (5001..5005). The rows JSON's `path` field
# is a DECOY, exactly like each slate dir's path.txt: it is derived from the
# merged PR's labels, which post-merge are just `merged`. 5001 is classified A
# and its row says X, so any driver still reading the rows reports X.
echo 5000 > "$TMP/issue-counter"
cat > "$TMP/rows.json" <<'ROWS'
[
  {"issue":5001,"path":"X","loc":10,"tokens_total":1000,"duration_ms":60000},
  {"issue":5003,"path":"B","loc":90,"tokens_total":2000,"duration_ms":180000}
]
ROWS
printf '{"priced_cost_usd": 30}\n' > "$TMP/pricing.json"

# One blob per issue, byte-for-byte what `gh issue view <n> --json
# comments,createdAt` returns. 5001/5003/5004 carry a `## Classification`
# comment (A / B / D); 5002 and 5005 were never classified, so `path=?` is the
# honest answer. Compact single-line JSON on purpose: a driver that forgets to
# reduce the blob locally still emits one line per row, so the row-count
# assertions below stay meaningful while the path assertions fail.
ISSUES_DIR="$TMP/issues"
mkdir -p "$ISSUES_DIR"
printf '%s\n' '{"createdAt":"2026-09-06T10:00:00Z","comments":[{"body":"## Classification\n- **recommended_path:** A\n- rationale: single doc file"},{"body":"**Verdict:** Approve"}]}' > "$ISSUES_DIR/5001.json"
printf '%s\n' '{"createdAt":"2026-09-06T10:00:00Z","comments":[{"body":"## Classification\n- **recommended_path:** B\n"}]}' > "$ISSUES_DIR/5003.json"
printf '%s\n' '{"createdAt":"2026-09-06T10:00:00Z","comments":[{"body":"## Classification\n- **recommended_path:** D\n"}]}' > "$ISSUES_DIR/5004.json"
printf '%s\n' '{"createdAt":"2026-09-06T10:00:00Z","comments":[]}' > "$ISSUES_DIR/5002.json"
printf '%s\n' '{"createdAt":"2026-09-06T10:00:00Z","comments":[]}' > "$ISSUES_DIR/5005.json"

# The PR set the run produced: one merged PR per issue, each carrying the
# PR-eval verdict comment. 5001 merges 30 minutes after its issue was filed
# (wall=1800); the rest an hour after. The rows JSON's duration_ms for 5001 is
# 60000 -> a driver reading THAT reports wall=60.
cat > "$TMP/prs.json" <<'PRS'
[
  {"number":9001,"body":"Closes #5001","headRefName":"feature/calib-5001","mergedAt":"2026-09-06T10:30:00Z","files":[{"path":"docs/guide.md"}],"comments":[{"body":"**Verdict:** Approved"}]},
  {"number":9002,"body":"Closes #5002","headRefName":"feature/calib-5002","mergedAt":"2026-09-06T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[{"body":"**Verdict:** Approved"}]},
  {"number":9003,"body":"Closes #5003","headRefName":"feature/calib-5003","mergedAt":"2026-09-06T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[{"body":"**Verdict:** Approved"}]},
  {"number":9004,"body":"Closes #5004","headRefName":"feature/calib-5004","mergedAt":"2026-09-06T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[{"body":"**Verdict:** Approved"}]},
  {"number":9005,"body":"Closes #5005","headRefName":"feature/calib-5005","mergedAt":"2026-09-06T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[{"body":"**Verdict:** Approved"}]}
]
PRS

export CALIB_TEST_PUSHER="$PUSHER"
export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-merge.sh"
export CALIB_TEST_ROWS_JSON="$TMP/rows.json"
export CALIB_TEST_PRICING_JSON="$TMP/pricing.json"
export CALIB_TEST_ISSUES_DIR="$ISSUES_DIR"
export CALIB_TEST_PRS_JSON="$TMP/prs.json"

rm -f "$CALLS"
run_helper --run --harness "$HARNESS"
expect_rc "--run exits 0" 0

TOTAL_LINE="$(printf '%s\n' "$OUT" | grep '^CALIB-TOTAL ' | head -1)"
expect_sub "every reference test passes against the merged sandbox tree" \
  "$TOTAL_LINE" "reftest-pass=5/5"
# The planted-defect grade is a per-RUN atom on the total line (#1395): did the
# slate's hidden boundary assertion escape the pr-eval gate? This synthetic
# harness carries no *planted* slate dir, so the honest answer is n/a — but the
# atom itself must be there, or a real run has nowhere to report the escape.
expect_sub "the graded total records the planted-defect verdict" \
  "$TOTAL_LINE" "planted="
expect_sub "a slate with no planted-defect dir grades it n/a" \
  "$TOTAL_LINE" "planted=n/a"

SANDBOX_HEAD="$(git -C "$SANDBOX" rev-parse HEAD)"
REMOTE_HEAD="$(git -C "$REMOTE" rev-parse main)"
if [ "$SANDBOX_HEAD" = "$REMOTE_HEAD" ]; then
  pass_msg "--run syncs the sandbox to the remote before grading"
else
  fail_msg "--run must pull the merged tree back (sandbox=$SANDBOX_HEAD remote=$REMOTE_HEAD)"
fi

CLR_CALL="$(grep -m1 '^clr .*--emit-rows-json' "$CALLS" 2>/dev/null)"
expect_sub "the cost report is scoped to the SANDBOX repo" \
  "$CLR_CALL" "PIPELINE_REPO=owner/pipeline-calib"
expect_sub "the cost report runs with the sandbox as cwd" "$CLR_CALL" "cwd=$SANDBOX"

expect_sub "path= comes from the ## Classification comment (5001)" \
  "$OUT" "CALIB issue=5001 path=A "
expect_sub "path= comes from the ## Classification comment (5003)" \
  "$OUT" "CALIB issue=5003 path=B "
expect_sub "path= comes from the ## Classification comment (5004)" \
  "$OUT" "CALIB issue=5004 path=D "
expect_sub "an unclassified issue reports path=? rather than a label guess" \
  "$OUT" "CALIB issue=5002 path=? "

ROW_5001="$(printf '%s\n' "$OUT" | grep -m1 '^CALIB issue=5001 ')"
expect_sub "wall= spans the issue createdAt -> merging PR mergedAt" \
  "$ROW_5001" "wall=1800 "
expect_sub "verdicts= pair the plan-eval and the merged PR's own comments" \
  "$ROW_5001" "verdicts=Approve/Approved "
refute_sub "a run that produced merged PRs emits no CALIB-ABORT line" \
  "$OUT" "CALIB-ABORT"
if printf '%s\n' "$OUT" | grep -q '^CALIB issue=5001 .*cost=\$n/a'; then
  fail_msg "--run reported no cost for 5001 despite a priced rows substrate"
else
  pass_msg "--run apportions the priced total onto the slate issues"
fi

# #1408: minute-granular <UTC date>T<HHMM>Z.txt, not the legacy day-granular
# <UTC date>.txt — a same-day re-run must get its OWN artifact rather than
# truncating the prior run's. Newest-by-sort, tolerant of whatever minute the
# test itself actually lands on.
CALIB_ARTIFACT="$(ls -1 "$HARNESS"/docs/retros/calib/"$(date -u +%Y-%m-%d)"T*.txt 2>/dev/null | sort | tail -1)"
if [ -n "$CALIB_ARTIFACT" ] && [ -f "$CALIB_ARTIFACT" ]; then
  pass_msg "--run tees the CALIB block to docs/retros/calib/<UTC date>T<HHMM>Z.txt"
else
  fail_msg "--run must tee the CALIB block to docs/retros/calib/<UTC date>T<HHMM>Z.txt"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 9: a same-day re-run never appends to a prior run's rows (#1408)"
# ---------------------------------------------------------------------------
# run-retro.sh's compute_calib() sums the `reftest=` atoms of every CALIB line
# in the artifact it reads. Pre-#1408, two same-day runs shared one
# <date>.txt file and a `tee` (never `tee -a`) truncated it, so a double-count
# was already impossible WITHIN one artifact — but the overwrite silently
# erased the FIRST run's own record (run #9 erased run #8's `reason=timeout`
# abort). #1408 gives each run its own <date>T<HHMM>Z artifact instead: this
# re-run's tee is either a fresh minute-keyed file (the common case) or, on
# the rare same-minute collision, a truncating overwrite of its own file —
# either way the picked (newest-by-sort) artifact holds exactly one run's
# rows, never an accumulation of two.

run_helper --run --harness "$HARNESS"
expect_rc "the same-day re-run exits 0" 0

CALIB_ARTIFACT="$(ls -1 "$HARNESS"/docs/retros/calib/"$(date -u +%Y-%m-%d)"T*.txt 2>/dev/null | sort | tail -1)"
N_TOTAL="$(grep -c '^CALIB-TOTAL ' "$CALIB_ARTIFACT" 2>/dev/null)"
if [ "$N_TOTAL" = "1" ]; then
  pass_msg "the picked artifact holds exactly one CALIB-TOTAL line"
else
  fail_msg "a re-run's artifact must hold one CALIB-TOTAL line (got $N_TOTAL)"
fi
N_ROWS="$(grep -c '^CALIB issue=' "$CALIB_ARTIFACT" 2>/dev/null)"
if [ "$N_ROWS" = "5" ]; then
  pass_msg "the picked artifact holds exactly one row per slate issue"
else
  fail_msg "the picked artifact must hold 5 CALIB rows, not an accumulation (got $N_ROWS)"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 10: --run stages the harness as a detached worktree"
# ---------------------------------------------------------------------------
# Asserted against the --run Scenarios 8/9 just performed. The sandbox
# session's restrict_paths hook allows only its own project dir and ~/.claude,
# so a harness outside ~/.claude has its own scripts blocked from inside the
# run. --run therefore stages the harness HEAD beside the sandbox clone and
# launches THAT, while every other harness role (template, slate, doctor,
# artifacts) keeps pointing at the ORIGINAL checkout.

if [ -e "$STAGE/.git" ]; then
  pass_msg "--run stages the harness at <calib dir>/harness"
else
  fail_msg "--run must stage the harness at $STAGE"
fi
if [ "$(git -C "$STAGE" rev-parse HEAD 2>/dev/null)" = "$(git -C "$HARNESS" rev-parse HEAD)" ]; then
  pass_msg "the staged harness sits at the harness HEAD"
else
  fail_msg "the staged harness must sit at the harness HEAD (uncommitted edits are not under test)"
fi
if git -C "$STAGE" symbolic-ref -q HEAD >/dev/null 2>&1; then
  fail_msg "the staged harness must be DETACHED, never on a branch"
else
  pass_msg "the staged harness is detached"
fi
if [ -f "$STAGE/pipeline.config" ] && cmp -s "$STAGE/pipeline.config" "$HARNESS/pipeline.config"; then
  pass_msg "the harness pipeline.config (untracked, host-specific) is copied in"
else
  fail_msg "the staged harness must carry the harness's pipeline.config"
fi
if [ -f "$STAGE/scripts/doctor.sh" ]; then
  pass_msg "the staged harness carries the harness's tracked content"
else
  fail_msg "the staged harness must carry the harness's tracked content"
fi
if [ -f "$CALIB_ARTIFACT" ] && [ ! -e "$STAGE/docs/retros/calib/$(basename "$CALIB_ARTIFACT")" ]; then
  pass_msg "the run's artifact lands in the ORIGINAL harness, not the staged copy"
else
  fail_msg "the artifact must stay at $CALIB_ARTIFACT and never appear under $STAGE"
fi

# A second run REFRESHES the stage to the new harness HEAD — it must not leave
# a stale copy behind, and must not accumulate a worktree per run.
echo "# refreshed" >> "$HARNESS/scripts/doctor.sh"
GIT_AUTHOR_NAME="calib test" GIT_AUTHOR_EMAIL="calib@example.invalid" \
GIT_COMMITTER_NAME="calib test" GIT_COMMITTER_EMAIL="calib@example.invalid" \
  git -C "$HARNESS" commit --quiet -a -m "harness: move HEAD"
cat > "$TMP/claude-noop.sh" <<'NOOP'
#!/bin/bash
exit 0
NOOP
chmod +x "$TMP/claude-noop.sh"
export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-noop.sh"
run_helper --run --harness "$HARNESS"
expect_rc "the refreshing --run exits 0" 0

if [ "$(git -C "$STAGE" rev-parse HEAD 2>/dev/null)" = "$(git -C "$HARNESS" rev-parse HEAD)" ]; then
  pass_msg "a second --run refreshes the staged harness to the new HEAD"
else
  fail_msg "the staged harness must be refreshed to the harness HEAD on every run"
fi
# The environment the session was actually handed, recorded by the stub during
# the --run above: what the launch line PREVIEWS must be what the launch DOES.
LAUNCH_ENV_TXT="$(cat "$LAUNCH_ENV" 2>/dev/null)"
for want in "ALLOW_ORCHESTRATOR_EDIT=unset" "PIPELINE_HEADLESS=true" "CLAUDE_PLUGIN_ROOT=$STAGE"; do
  if printf '%s\n' "$LAUNCH_ENV_TXT" | grep -qxF -- "$want"; then
    pass_msg "the launched session's environment carries $want"
  else
    fail_msg "the launched session's environment must carry $want (got: $(printf '%s' "$LAUNCH_ENV_TXT" | tr '\n' ' '))"
  fi
done

N_WT="$(git -C "$HARNESS" worktree list --porcelain 2>/dev/null | grep -c '^worktree .*/sandbox/harness$')"
if [ "$N_WT" = "1" ]; then
  pass_msg "the stage is ONE worktree, refreshed in place"
else
  fail_msg "the harness must register exactly one stage worktree (got $N_WT)"
fi

# ---------------------------------------------------------------------------
scenario "Scenario 11: a run that stops to ask a question aborts, never grades 0/n"
# ---------------------------------------------------------------------------
# Run #1's observed shape: the headless session ended its final message on a
# question ("your call on auto-merge?"), nobody answered, and it pushed
# nothing. The driver graded that as reftest-pass=0/5 — indistinguishable in
# the retro from "the harness regressed on all five issues", when in fact the
# harness never started. The run must self-report the abort instead.

# Rewind the "remote" to the unfixed base first: Scenario 8's stand-in landed
# the fix there, and a run that merges nothing must grade against a sandbox
# that carries no fix — otherwise the n/a assertions below could pass for the
# wrong reason (a tree that happens to be green).
git -C "$REMOTE" update-ref refs/heads/main "$(git -C "$REMOTE" rev-parse calib-base)"

cat > "$TMP/claude-held.sh" <<'HELD'
#!/bin/bash
# A held run DID start — it merged wave 1 and then stopped to ask — so it left
# a capture log behind. `held` outranks `no-cost-log` either way (#1395), and
# this stub is the control that says so for the right reason.
mkdir -p "$(dirname "$CALIB_TEST_COST_LOG")"
printf '%s\n' '{"schema_version":1,"issue":"5001","stage":"execute","tokens":{"total":1000}}' \
  >> "$CALIB_TEST_COST_LOG"
echo "Wave 1 merged. Your call on auto-merge for the rest?"
HELD
chmod +x "$TMP/claude-held.sh"
printf '[]\n' > "$TMP/prs-empty.json"

# --reset hands out fresh issue ids on every run, so re-pin the counter: the
# staged issue substrate is keyed on 5001..5005.
echo 5000 > "$TMP/issue-counter"
export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-held.sh"
export CALIB_TEST_PRS_JSON="$TMP/prs-empty.json"
rm -f "$CALLS"
run_helper --run --harness "$HARNESS"
expect_rc "a run that merged nothing still exits 0" 0
expect_sub "a session that ends on a question reports CALIB-ABORT reason=held" \
  "$OUT" "CALIB-ABORT reason=held"

ABORT_LN="$(printf '%s\n' "$OUT" | grep -n '^CALIB-ABORT ' | head -1 | cut -d: -f1)"
ROW_LN="$(printf '%s\n' "$OUT" | grep -n '^CALIB issue=' | head -1 | cut -d: -f1)"
if [ -n "$ABORT_LN" ] && [ -n "$ROW_LN" ] && [ "$ABORT_LN" -lt "$ROW_LN" ]; then
  pass_msg "the CALIB-ABORT line comes before the first CALIB row"
else
  fail_msg "CALIB-ABORT must lead the block (abort line=${ABORT_LN:-none} first row=${ROW_LN:-none})"
fi

N_NA="$(printf '%s\n' "$OUT" | grep -c '^CALIB issue=.* reftest=n/a ')"
if [ "$N_NA" = "5" ]; then
  pass_msg "every row of a run that reached no issue reports reftest=n/a"
else
  fail_msg "an aborted run must report reftest=n/a for all 5 rows (got $N_NA)"
fi
TOTAL_HELD="$(printf '%s\n' "$OUT" | grep '^CALIB-TOTAL ' | head -1)"
expect_sub "the total refuses to score an aborted run" "$TOTAL_HELD" "reftest-pass=n/a"
refute_sub "an aborted run never reports a failed slate" "$OUT" "reftest-pass=0/5"
# BOTH total printfs carry the atom, or the aborted branch silently drops a
# field and every cross-artifact grammar pin only sees the graded one.
expect_sub "the aborted total carries the planted-defect atom too" \
  "$TOTAL_HELD" "planted="

RUN_LOG_FILE="$(ls -1 "$HARNESS"/docs/retros/calib/"$(date -u +%Y-%m-%d)"T*.log 2>/dev/null | sort | tail -1)"
if [ -n "$RUN_LOG_FILE" ] && grep -qF 'auto-merge for the rest?' "$RUN_LOG_FILE"; then
  pass_msg "--run tees the session output to docs/retros/calib/<UTC date>T<HHMM>Z.log"
else
  fail_msg "--run must tee the question it stopped on to docs/retros/calib/<UTC date>T<HHMM>Z.log"
fi

# That tee lands INSIDE docs/retros/calib/, which is tracked (the <date>.txt
# artifact lives there and is committed). The session log is a per-run runtime
# transcript, never a tracked artifact, so the repo must ignore it by name —
# without an ignore rule every --run leaves the harness checkout dirty and the
# next commit sweeps a raw session transcript into the repo.
if git -C "$ROOT" check-ignore -q docs/retros/calib/x.log 2>/dev/null; then
  pass_msg "the repo ignores docs/retros/calib/*.log"
else
  fail_msg "docs/retros/calib/*.log must be gitignored (the per-run session log)"
fi
if git -C "$ROOT" check-ignore -q docs/retros/calib/x.txt 2>/dev/null; then
  fail_msg "the CALIB artifact docs/retros/calib/*.txt must stay TRACKED"
else
  pass_msg "the ignore rule spares the tracked <date>.txt artifact"
fi

# A `-p` session writes to BOTH streams and --run tees them merged (2>&1), so
# the question it stopped on is routinely not the very last line: one stderr
# line after it (a limit notice, a stray warning) defeated a detector that
# read the last line alone and the held run silently regraded. Scan the tail.
cat > "$TMP/claude-held-stderr.sh" <<'HELD2'
#!/bin/bash
mkdir -p "$(dirname "$CALIB_TEST_COST_LOG")"
printf '%s\n' '{"schema_version":1,"issue":"5001","stage":"execute","tokens":{"total":1000}}' \
  >> "$CALIB_TEST_COST_LOG"
echo "Wave 1 merged. Your call on auto-merge for the rest?"
echo "note: session limit approaching" >&2
HELD2
chmod +x "$TMP/claude-held-stderr.sh"
echo 5000 > "$TMP/issue-counter"
export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-held-stderr.sh"
rm -f "$CALLS"
run_helper --run --harness "$HARNESS"
expect_sub "a trailing stderr line after the question still reports reason=held" \
  "$OUT" "CALIB-ABORT reason=held"

# ---------------------------------------------------------------------------
scenario "Scenario 12: the abort reason separates a timeout from a silent finish"
# ---------------------------------------------------------------------------
cat > "$TMP/claude-timeout.sh" <<'TO'
#!/bin/bash
echo "working on it"
exit 124
TO
chmod +x "$TMP/claude-timeout.sh"
echo 5000 > "$TMP/issue-counter"
export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-timeout.sh"
run_helper --run --harness "$HARNESS"
expect_rc "a timed-out run still exits 0" 0
expect_sub "hitting the timeout cap reports CALIB-ABORT reason=timeout" \
  "$OUT" "CALIB-ABORT reason=timeout"

# DELIBERATELY writes no capture log, and must stay that way: this stub and the
# stale-PR variant below are the `no-pr` controls. `no-pr` outranks
# `no-cost-log` (#1395), and Scenario 13c pins that order against exactly this
# stub — "helpfully" giving it a cost log would make the precedence untestable.
cat > "$TMP/claude-quiet.sh" <<'QUIET'
#!/bin/bash
echo "done."
QUIET
chmod +x "$TMP/claude-quiet.sh"
echo 5000 > "$TMP/issue-counter"
export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-quiet.sh"
run_helper --run --harness "$HARNESS"
expect_sub "a clean finish that opened no PR reports CALIB-ABORT reason=no-pr" \
  "$OUT" "CALIB-ABORT reason=no-pr"

# The sandbox is never wiped clean: --reset reaps the slate ISSUES and rewinds
# the base tag, but the PRs of every earlier run survive forever, so
# `gh pr list --state all` is non-empty from the second real run onward. A
# detector that counts the WHOLE PR set can therefore never fire `no-pr` again
# — a silent finish that opened nothing falls through to a normal `0/5` grade,
# exactly the "harness regressed on all five" misreading the abort exists to
# prevent. The count has to be scoped to THIS run's slate ids, the same
# scoping merged_pr_field() already applies.
cat > "$TMP/prs-stale.json" <<'STALE'
[
  {"number":8001,"body":"Closes #4001","headRefName":"feature/calib-4001","mergedAt":"2026-09-01T10:30:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":8002,"body":"Closes #4002","headRefName":"feature/calib-4002","mergedAt":"2026-09-01T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":8003,"body":"Closes #4003","headRefName":"feature/calib-4003","mergedAt":"2026-09-01T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":8004,"body":"Closes #4004","headRefName":"feature/calib-4004","mergedAt":"2026-09-01T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":8005,"body":"Closes #4005","headRefName":"feature/calib-4005","mergedAt":"2026-09-01T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]}
]
STALE
echo 5000 > "$TMP/issue-counter"
export CALIB_TEST_PRS_JSON="$TMP/prs-stale.json"
run_helper --run --harness "$HARNESS"
expect_sub "PRs from an EARLIER slate never mask this run's no-pr abort" \
  "$OUT" "CALIB-ABORT reason=no-pr"
refute_sub "a run masked by stale PRs is never graded as a failed slate" \
  "$OUT" "reftest-pass=0/5"

# ---------------------------------------------------------------------------
scenario "Scenario 13: a run held AFTER a partial merge grades only what merged"
# ---------------------------------------------------------------------------
# Run #2's observed shape: wave 1 merged, then the orchestrator stopped to ask
# about the rest. The merged issues carry real evidence and must be graded for
# real; the ones the run never reached must not be graded at all.

cat > "$TMP/claude-partial.sh" <<'PART'
#!/bin/bash
"$CALIB_TEST_MERGE_SCRIPT"
echo "Wave 1 merged. Want me to auto-merge the rest?"
PART
chmod +x "$TMP/claude-partial.sh"

# 5001/5003/5004 merged; 5002/5005 have an OPEN PR (mergedAt null), so the set
# is non-empty — the reason must be `held`, not `no-pr`.
cat > "$TMP/prs-partial.json" <<'PARTPRS'
[
  {"number":9001,"body":"Closes #5001","headRefName":"feature/calib-5001","mergedAt":"2026-09-06T10:30:00Z","files":[{"path":"docs/guide.md"}],"comments":[{"body":"**Verdict:** Approved"}]},
  {"number":9003,"body":"Closes #5003","headRefName":"feature/calib-5003","mergedAt":"2026-09-06T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[{"body":"**Verdict:** Approved"}]},
  {"number":9004,"body":"Closes #5004","headRefName":"feature/calib-5004","mergedAt":"2026-09-06T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[{"body":"**Verdict:** Approved"}]},
  {"number":9002,"body":"Closes #5002","headRefName":"feature/calib-5002","mergedAt":null,"files":[],"comments":[]},
  {"number":9005,"body":"Closes #5005","headRefName":"feature/calib-5005","mergedAt":null,"files":[],"comments":[]}
]
PARTPRS

echo 5000 > "$TMP/issue-counter"
export CALIB_TEST_MERGE_SCRIPT="$TMP/claude-merge.sh"
export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-partial.sh"
export CALIB_TEST_PRS_JSON="$TMP/prs-partial.json"
run_helper --run --harness "$HARNESS"
expect_rc "a partially-merged held run still exits 0" 0
expect_sub "a held run with open PRs is held, not no-pr" "$OUT" "CALIB-ABORT reason=held"
for n in 5001 5003 5004; do
  expect_sub "issue $n merged, so its reference test is graded for real" \
    "$OUT" "CALIB issue=$n path=" 
  ROW="$(printf '%s\n' "$OUT" | grep -m1 "^CALIB issue=$n ")"
  expect_sub "issue $n reports a real reftest verdict" "$ROW" "reftest=pass "
done
for n in 5002 5005; do
  ROW="$(printf '%s\n' "$OUT" | grep -m1 "^CALIB issue=$n ")"
  expect_sub "issue $n never merged, so its reference test is n/a" "$ROW" "reftest=n/a "
done
TOTAL_PARTIAL="$(printf '%s\n' "$OUT" | grep '^CALIB-TOTAL ' | head -1)"
expect_sub "a partially-graded run still refuses a k/n total" "$TOTAL_PARTIAL" "reftest-pass=n/a"
refute_sub "a partially-graded run never reports 3/5" "$OUT" "reftest-pass=3/5"

unset CALIB_TEST_CLAUDE_SCRIPT

# ---------------------------------------------------------------------------
scenario "Scenario 13b: a run that priced nothing aborts, it never reports \$0"
# ---------------------------------------------------------------------------
# Every calibration run since #2 printed `CALIB-TOTAL cost=$0` and `cost=$n/a`
# per issue, so the loop's two headline metrics were never once measured — and
# nothing in the block said so. `$0` is not a cheap run, it is an unpriced one:
# the sandbox session registered no cost-capture hooks, so no
# agent-costs.jsonl was ever written and issue_cost() had nothing to apportion.
# The run has to say `no-cost-log` out loud instead.

cat > "$TMP/claude-nocost.sh" <<'NOCOST'
#!/bin/bash
echo "all five merged."
NOCOST
chmod +x "$TMP/claude-nocost.sh"

# The PRODUCTION shape of a pricing probe over a missing capture log:
# `cost-latency-report.sh --emit-pricing-json` answers "0.00", never an empty
# string. Staging it is load-bearing — leaving CALIB_TEST_PRICING_JSON unset
# makes the stub emit nothing, PRICING_TOTAL empty, and an emptiness-only guard
# would look correct here while `cost=$0` still printed in production.
printf '%s\n' '{"priced_cost_usd":"0.00","unpriced_count":0}' > "$TMP/pricing-zero.json"

# The log is untracked, so neither --reset's hard reset nor the post-run sync
# removes one an earlier scenario's stub left behind.
rm -f "$COST_LOG"
echo 5000 > "$TMP/issue-counter"
export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-nocost.sh"
export CALIB_TEST_PRS_JSON="$TMP/prs.json"
export CALIB_TEST_PRICING_JSON="$TMP/pricing-zero.json"
rm -f "$CALLS"
run_helper --run --harness "$HARNESS"
expect_rc "a run that wrote no cost log still exits 0" 0

if [ -s "$COST_LOG" ]; then
  fail_msg "the no-cost-log stub left a capture log behind (the premise is broken)"
else
  pass_msg "the no-cost-log stub leaves no capture log (the condition under test)"
fi
# The PR set is this run's own slate (5001..5005, all merged), so `no-pr`
# cannot fire and the reason under test is the only one available.
refute_sub "the no-cost-log run opened PRs, so no-pr is not what fired" \
  "$OUT" "CALIB-ABORT reason=no-pr"
expect_sub "a session that priced nothing reports CALIB-ABORT reason=no-cost-log" \
  "$OUT" "CALIB-ABORT reason=no-cost-log"
TOTAL_NOCOST="$(printf '%s\n' "$OUT" | grep '^CALIB-TOTAL ' | head -1)"
expect_sub "an unpriced run reports cost=\$n/a" "$TOTAL_NOCOST" "cost=\$n/a"
refute_sub "an unpriced run never reports a \$0 total" "$TOTAL_NOCOST" "cost=\$0"
expect_sub "an unpriced run refuses to score the slate" \
  "$TOTAL_NOCOST" "reftest-pass=n/a"

# Mirror control: the same run, with the stub writing ONE capture record. The
# guard is on the missing log, not on runs in general — it must not fire here,
# and a priced total must still render a real dollar figure.
cat > "$TMP/claude-cost.sh" <<'WITHCOST'
#!/bin/bash
mkdir -p "$(dirname "$CALIB_TEST_COST_LOG")"
printf '%s\n' '{"schema_version":1,"issue":"5001","stage":"execute","tokens":{"total":1000}}' \
  >> "$CALIB_TEST_COST_LOG"
echo "all five merged."
WITHCOST
chmod +x "$TMP/claude-cost.sh"

rm -f "$COST_LOG" "$CALLS"
echo 5000 > "$TMP/issue-counter"
export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-cost.sh"
export CALIB_TEST_PRICING_JSON="$TMP/pricing.json"
run_helper --run --harness "$HARNESS"
expect_rc "a run whose session wrote a cost log exits 0" 0
if [ -s "$COST_LOG" ]; then
  pass_msg "the mirror stub wrote a capture log"
else
  fail_msg "the mirror stub must write a capture log (the premise is broken)"
fi
refute_sub "a run that priced something never aborts" "$OUT" "CALIB-ABORT"
TOTAL_PRICED="$(printf '%s\n' "$OUT" | grep '^CALIB-TOTAL ' | head -1)"
refute_sub "a priced run still reports a real total" "$TOTAL_PRICED" "cost=\$n/a"

# ---------------------------------------------------------------------------
scenario "Scenario 13c: no-pr outranks no-cost-log"
# ---------------------------------------------------------------------------
# Documented precedence, most specific first: timeout > held > no-pr >
# no-cost-log. A run that opened no PR is better described by `no-pr` than by
# the cost log it also never wrote. The `no-pr` arm of detect_abort() assigns
# WITHOUT returning, so a no-cost-log check appended after it overwrites the
# more specific reason unless it is guarded on an empty ABORT_REASON. Nothing
# else in this suite orders the reasons — this scenario is the whole pin.

rm -f "$COST_LOG" "$CALLS"
echo 5000 > "$TMP/issue-counter"
export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-quiet.sh"
export CALIB_TEST_PRS_JSON="$TMP/prs-empty.json"
export CALIB_TEST_PRICING_JSON="$TMP/pricing-zero.json"
run_helper --run --harness "$HARNESS"
expect_rc "a run with neither a PR nor a cost log still exits 0" 0
if [ -s "$COST_LOG" ]; then
  fail_msg "the precedence stub left a capture log behind (the premise is broken)"
else
  pass_msg "the precedence stub leaves no capture log either"
fi
expect_sub "a run that opened no PR keeps the more specific reason=no-pr" \
  "$OUT" "CALIB-ABORT reason=no-pr"
refute_sub "no-cost-log never overwrites the no-pr reason" "$OUT" "reason=no-cost-log"
N_ABORT="$(printf '%s\n' "$OUT" | grep -c '^CALIB-ABORT ')"
if [ "$N_ABORT" -eq 1 ]; then
  pass_msg "an aborted run prints exactly one CALIB-ABORT line"
else
  fail_msg "an aborted run must print exactly one CALIB-ABORT line (got $N_ABORT)"
fi

unset CALIB_TEST_CLAUDE_SCRIPT
export CALIB_TEST_PRICING_JSON="$TMP/pricing.json"

# ---------------------------------------------------------------------------
scenario "Scenario 14: the launch scrubs the operator's inherited PIPELINE_* env (#1390)"
# ---------------------------------------------------------------------------
# Regression guard for #1390: calibration run #6 was launched from an operator
# shell that had sourced the clone's pipeline.config (`set -a`), which exports
# PIPELINE_REPO / PIPELINE_PROJECT_ROOT / PIPELINE_USE_LOCAL_PLUGIN (and ~25
# more). The launch unset exactly one var (ALLOW_ORCHESTRATOR_EDIT) and passed
# everything else through, so the sandbox session's slate lookup ran against
# the inherited PIPELINE_REPO instead of the sandbox — CALIB-ABORT reason=no-pr
# after 61s. The launch must scrub every exported PIPELINE_* name instead.

rm -f "$CALLS" "$LAUNCH_ENV" "$TMP/issue-counter"
export PIPELINE_PROJECT_ROOT="/poison"
export PIPELINE_USE_LOCAL_PLUGIN="true"
CALIB_TEST_PIPELINE_REPO_OVERRIDE="poison/harness" \
CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-noop.sh" \
  run_helper --run --harness "$HARNESS"
expect_rc "a poisoned-env --run still exits 0" 0

LAUNCH_ENV_POISON="$(cat "$LAUNCH_ENV" 2>/dev/null)"
for poison in "PIPELINE_REPO=poison/harness" "PIPELINE_PROJECT_ROOT=/poison" "PIPELINE_USE_LOCAL_PLUGIN=true"; do
  if printf '%s\n' "$LAUNCH_ENV_POISON" | grep -qxF -- "$poison"; then
    fail_msg "the launched session's environment must NOT carry $poison"
  else
    pass_msg "the launched session's environment does not carry $poison"
  fi
done
for want in "CLAUDE_PLUGIN_ROOT=" "PIPELINE_TRUST_PROFILE=strict" "PIPELINE_HEADLESS=true"; do
  if printf '%s\n' "$LAUNCH_ENV_POISON" | grep -qF -- "$want"; then
    pass_msg "the launched session's environment still carries $want"
  else
    fail_msg "the launched session's environment must still carry $want (got: $(printf '%s' "$LAUNCH_ENV_POISON" | tr '\n' ' '))"
  fi
done
unset PIPELINE_PROJECT_ROOT PIPELINE_USE_LOCAL_PLUGIN

# --dry-run control: the scrub is visible in the CALIB-LAUNCH preview so the
# operator can see the -u list.
rm -f "$CALLS"
export PIPELINE_PROJECT_ROOT="/poison"
run_helper --dry-run --harness "$HARNESS"
expect_rc "a poisoned-env --dry-run still exits 0" 0
LAUNCH_DRY="$(printf '%s\n' "$OUT" | grep '^CALIB-LAUNCH ' | head -1)"
expect_sub "the dry-run preview names the scrubbed PIPELINE_REPO" "$LAUNCH_DRY" "-u PIPELINE_REPO"
expect_sub "the dry-run preview names the scrubbed PIPELINE_PROJECT_ROOT" "$LAUNCH_DRY" "-u PIPELINE_PROJECT_ROOT"
unset PIPELINE_PROJECT_ROOT

# ---------------------------------------------------------------------------
scenario "Scenario 15: --run backfills retroactive costs before grading and dedups by agent_id (#1406)"
# ---------------------------------------------------------------------------
# Run #8 (2026-09-24) showed the forward-only capture log under-attributes
# almost every issue (async Agent dispatches carry no usage at PostToolUse)
# and that a forward/retroactive duplicate pair for the SAME agent_id double-
# counts unless collapsed. This is the ONE scenario using the REAL
# capture-agent-costs.sh (not a scripted stand-in) so the backfill call is
# exercised end to end; cost-latency-report.sh stays the shared fake stub.

mkdir -p "$HARNESS/scripts"
cp "$ROOT/scripts/capture-agent-costs.sh" "$HARNESS/scripts/capture-agent-costs.sh"
cp "$ROOT/scripts/_logging.sh" "$HARNESS/scripts/_logging.sh"
cp "$ROOT/scripts/_token-usage-lib.sh" "$HARNESS/scripts/_token-usage-lib.sh"
chmod +x "$HARNESS/scripts/capture-agent-costs.sh"

echo 9000 > "$TMP/issue-counter"

cat > "$TMP/prs-1406.json" <<'PRS1406'
[
  {"number":9101,"body":"Closes #9001","headRefName":"feature/calib-9001","mergedAt":"2026-09-24T10:30:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":9102,"body":"Closes #9002","headRefName":"feature/calib-9002","mergedAt":"2026-09-24T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":9103,"body":"Closes #9003","headRefName":"feature/calib-9003","mergedAt":"2026-09-24T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":9104,"body":"Closes #9004","headRefName":"feature/calib-9004","mergedAt":"2026-09-24T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":9105,"body":"Closes #9005","headRefName":"feature/calib-9005","mergedAt":"2026-09-24T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]}
]
PRS1406

cat > "$TMP/rows-1406.json" <<'ROWS1406'
[ {"issue":9001,"path":"D","loc":10,"tokens_total":5000,"duration_ms":60000} ]
ROWS1406
printf '{"priced_cost_usd": "42.00"}\n' > "$TMP/pricing-1406.json"

# Transcript hint the retroactive INLINE pass backfills against: it EXCEEDS
# the sidecar's own lower-bound usage, so the real script adopts it as the
# reconciled (usage_complete=true) cumulative. 3500 + 4500 = 8000 total.
mkdir -p "$TMP/home1406/.claude/projects/proj-slug/sess-fwd/subagents"
cat > "$TMP/home1406/.claude/projects/proj-slug/sess-fwd/subagents/agent-shared1.jsonl" <<'TX'
{"timestamp":"2099-01-01T10:00:00Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":2000,"cache_creation_input_tokens":300}}}
{"timestamp":"2099-01-01T10:00:30Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1500,"output_tokens":300,"cache_read_input_tokens":2500,"cache_creation_input_tokens":200}}}
TX

cat > "$TMP/claude-backfill.sh" <<'BACKFILL'
#!/bin/bash
set -e
logs_dir="$(dirname "$CALIB_TEST_COST_LOG")"
mkdir -p "$logs_dir/subagents"
# FORWARD row: a synchronous pr-eval dispatch, captured live at PostToolUse
# with a LOWER partial total (300), tagged with the SAME agent_id the
# retroactive sidecar below resolves to a larger cumulative for -- the
# forward/retroactive duplicate pair #1406's dedup step must collapse.
printf '%s\n' '{"schema_version":1,"issue":"9001","stage":"pr-eval","agent_kind":"main","agent_type":"single","session_id":"sess-fwd","model":"claude-sonnet-4-6","agent_id":"shared1","role":"single","tokens":{"input":150,"output":150,"cache_read":0,"cache_creation":0,"total":300},"duration_ms":1000,"ts_start":"2099-01-01T10:00:00Z","ts_end":"2099-01-01T10:00:01Z","source":"forward","usage_complete":true}' \
  >> "$CALIB_TEST_COST_LOG"
# RETROACTIVE substrate: subagents.log + sidecar for the backfill pass to
# discover (SAME agent_id; sidecar lower-bound 5000, transcript-upgraded 8000).
printf '2099-01-01T10:00:00Z\tsess-fwd\tevaluate-issue-pr #9001\t0\t0\t0\tagent-preval-9001.json\n' \
  >> "$logs_dir/subagents.log"
cat > "$logs_dir/subagents/agent-preval-9001.json" <<'SIDECAR'
{
  "ts": "2099-01-01T10:00:00Z",
  "session": "sess-fwd",
  "description": "evaluate-issue-pr #9001",
  "subagent_type": "pipeline:pr-evaluator",
  "agent_id": "shared1",
  "usage": {
    "input_tokens": 4000,
    "output_tokens": 900,
    "cache_read_input_tokens": 100,
    "cache_creation_input_tokens": 0
  }
}
SIDECAR
echo "all five merged."
BACKFILL
chmod +x "$TMP/claude-backfill.sh"

export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-backfill.sh"
export CALIB_TEST_PRS_JSON="$TMP/prs-1406.json"
export CALIB_TEST_ROWS_JSON="$TMP/rows-1406.json"
export CALIB_TEST_PRICING_JSON="$TMP/pricing-1406.json"
export CALIB_TEST_HOME="$TMP/home1406"
rm -f "$COST_LOG" "$CALLS"
run_helper --run --harness "$HARNESS"
expect_rc "a run whose session wrote a forward + retroactive substrate exits 0" 0

expect_sub "the run backfills the sidecar's retroactive cost record" \
  "$OUT" "calib: cost backfill appended 1 record(s)"

CAP_LOG_ARG="$(grep -m1 '^clr .*--emit-pricing-json' "$CALLS" 2>/dev/null \
  | sed -n 's/.*--capture-log \([^ ]*\).*/\1/p')"
if [ -n "$CAP_LOG_ARG" ] && [ -f "$CAP_LOG_ARG" ]; then
  pass_msg "the grader hands cost-latency-report.sh a resolvable --capture-log"
else
  fail_msg "the grader's --capture-log argument did not resolve to a file (got: $CAP_LOG_ARG)"
fi
if [ "$CAP_LOG_ARG" = "$COST_LOG" ]; then
  fail_msg "the grader must dedup BEFORE pricing, not hand cost-latency-report.sh the raw capture log"
else
  pass_msg "the grader prices a deduped copy, not the raw forward+retroactive capture log"
fi

DEDUPED_COUNT="$(jq -s '[.[] | select(.agent_id=="shared1")] | length' "$CAP_LOG_ARG" 2>/dev/null)"
if [ "$DEDUPED_COUNT" = "1" ]; then
  pass_msg "duplicate agent_id rows (forward + retroactive) count once"
else
  fail_msg "expected exactly 1 deduped row for agent_id=shared1, got $DEDUPED_COUNT"
fi

DEDUPED_TOTAL="$(jq -s '[.[] | select(.agent_id=="shared1")][0].tokens.total' "$CAP_LOG_ARG" 2>/dev/null)"
if [ "$DEDUPED_TOTAL" = "8000" ]; then
  pass_msg "dedup keeps the MAX tokens.total (8000, transcript-upgraded), not the sum (8300)"
else
  fail_msg "expected the deduped row's tokens.total to be the max (8000), got $DEDUPED_TOTAL"
fi

if printf '%s\n' "$OUT" | grep -q '^CALIB issue=9001 .*cost=\$n/a'; then
  fail_msg "issue=9001 still reports cost=\$n/a despite the backfilled + priced substrate"
else
  pass_msg "issue=9001 reports a real cost=\$ once the backfill substrate is wired in"
fi

# A second --run: cmd_reset's #1408 archive step moves the FIRST run's
# agent-costs.jsonl/subagents.log out of the way before this run's launch, so
# the backfill pass starts from a genuinely clean substrate and re-derives its
# own retroactive record — "1 record(s)" again, not "0". (record_key dedup
# WITHIN one capture log's own lifetime is covered at the unit level by
# tests/test-capture-agent-costs.sh; archiving is what makes that lifetime
# per-run instead of forever.)
rm -f "$CALLS"
run_helper --run --harness "$HARNESS"
expect_rc "a second run against a freshly-archived sandbox still exits 0" 0
expect_sub "a second run's backfill re-derives its own record from the archived-clean log" \
  "$OUT" "calib: cost backfill appended 1 record(s)"

unset CALIB_TEST_CLAUDE_SCRIPT CALIB_TEST_PRS_JSON CALIB_TEST_ROWS_JSON \
      CALIB_TEST_PRICING_JSON CALIB_TEST_HOME

# ---------------------------------------------------------------------------
scenario "Scenario 16: --reset archives the sandbox's previous-run logs before creating the slate (#1408)"
# ---------------------------------------------------------------------------
# The sandbox's .claude/logs/ dir is gitignored, so --reset's hard git reset
# never touches it: agent-costs.jsonl accumulated EVERY prior run's rows
# forever, so run #9's pricing was diluted by run #8's tokens too (#1408).
# --reset must move the previous run's logs out of the way before
# create_slate_issues() seeds the fresh slate. usage-gate.jsonl is cross-run
# by design and must stay in place.

rm -f "$CALLS" "$TMP/issue-counter"
LOGS_DIR="$SANDBOX/.claude/logs"
mkdir -p "$LOGS_DIR/subagents"
echo '{"issue":"8888"}' > "$LOGS_DIR/agent-costs.jsonl"
echo "prior subagent line" > "$LOGS_DIR/subagents.log"
echo '{"sidecar":true}' > "$LOGS_DIR/subagents/agent-old.json"
echo "prior tool use" > "$LOGS_DIR/tool-use.log"
echo "prior run" > "$LOGS_DIR/runs.log"
echo '{"state":true}' > "$LOGS_DIR/agent-cost-orchestrator-state.json"
echo "keep me" > "$LOGS_DIR/usage-gate.jsonl"

run_helper --reset --harness "$HARNESS"
expect_rc "--reset (archive) exits 0" 0
expect_sub "--reset logs the archive destination" "$OUT" "calib: archived previous run logs -> "

ARCHIVE_DIR="$(printf '%s\n' "$OUT" | sed -n 's/^calib: archived previous run logs -> //p' | head -1)"
if [ -n "$ARCHIVE_DIR" ] && [ -d "$ARCHIVE_DIR" ]; then
  pass_msg "the archive destination directory exists"
else
  fail_msg "the archive destination directory must exist (got: $ARCHIVE_DIR)"
fi
if [ -f "$ARCHIVE_DIR/agent-costs.jsonl" ] && [ ! -e "$LOGS_DIR/agent-costs.jsonl" ]; then
  pass_msg "agent-costs.jsonl is archived and removed from the sandbox"
else
  fail_msg "agent-costs.jsonl must be archived to $ARCHIVE_DIR and removed from $LOGS_DIR"
fi
for f in subagents.log tool-use.log runs.log agent-cost-orchestrator-state.json; do
  if [ -f "$ARCHIVE_DIR/$f" ] && [ ! -e "$LOGS_DIR/$f" ]; then
    pass_msg "$f is archived and removed from the sandbox"
  else
    fail_msg "$f must be archived to $ARCHIVE_DIR and removed from $LOGS_DIR"
  fi
done
if [ -f "$ARCHIVE_DIR/subagents/agent-old.json" ]; then
  pass_msg "the subagents/ directory is archived wholesale"
else
  fail_msg "the subagents/ directory must be archived to $ARCHIVE_DIR"
fi
if [ -f "$LOGS_DIR/usage-gate.jsonl" ]; then
  pass_msg "usage-gate.jsonl stays in the sandbox (cross-run by design)"
else
  fail_msg "usage-gate.jsonl must NOT be archived"
fi

# A --reset with nothing to archive (a fresh sandbox, no prior logs) is a
# no-op: no archive dir, no log line.
rm -f "$CALLS" "$TMP/issue-counter"
rm -rf "$LOGS_DIR"
run_helper --reset --harness "$HARNESS"
expect_rc "--reset (nothing to archive) exits 0" 0
refute_sub "--reset with no prior logs never prints an archive line" \
  "$OUT" "calib: archived previous run logs"

# ---------------------------------------------------------------------------
scenario "Scenario 17: --run scopes pricing to its own window, filtering stale capture rows by ts_end (#1408)"
# ---------------------------------------------------------------------------
# Run #9 priced run #8's leftover rows too because issue_cost() apportions
# PRICING_TOTAL by each issue's SHARE of ROWS_JSON's token sum, and that sum
# included every row ever captured. This is the belt-and-braces control for a
# row that somehow survives the Scenario 16 archive (e.g. a session that
# writes AFTER the archive step with a backdated ts_end): --run must record
# RUN_START_TS before the launch and exclude any row whose ts_end predates it
# from the sum, so a stale issue's tokens can never dilute a fresh issue's
# apportioned $.

echo 5000 > "$TMP/issue-counter"
cat > "$TMP/prs-1408.json" <<'PRS1408'
[
  {"number":9201,"body":"Closes #5001","headRefName":"feature/calib-5001","mergedAt":"2026-09-24T10:30:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":9202,"body":"Closes #5002","headRefName":"feature/calib-5002","mergedAt":"2026-09-24T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":9203,"body":"Closes #5003","headRefName":"feature/calib-5003","mergedAt":"2026-09-24T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":9204,"body":"Closes #5004","headRefName":"feature/calib-5004","mergedAt":"2026-09-24T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]},
  {"number":9205,"body":"Closes #5005","headRefName":"feature/calib-5005","mergedAt":"2026-09-24T11:00:00Z","files":[{"path":"docs/guide.md"}],"comments":[]}
]
PRS1408

# Both rows present unfiltered: sum=1000+9000=10000, so issue 5001's
# apportioned share of the fixed $100 total is $10.00. Filtered (the stale
# 5099 row dropped), the sum is 1000 alone and 5001's share is the full
# $100.00 — a deterministic tell for whether the ts_end filter ran.
cat > "$TMP/rows-1408.json" <<'ROWS1408'
[
  {"issue":5001,"path":"D","loc":10,"tokens_total":1000,"duration_ms":1000},
  {"issue":5099,"path":"B","loc":10,"tokens_total":9000,"duration_ms":1000}
]
ROWS1408
printf '{"priced_cost_usd": "100.00"}\n' > "$TMP/pricing-1408.json"

cat > "$TMP/claude-stale-mix.sh" <<'STALEMIX'
#!/bin/bash
mkdir -p "$(dirname "$CALIB_TEST_COST_LOG")"
# A STALE row for a FOREIGN issue (5099 is not in this run's slate) dated
# WAY in the past: models a record the Scenario 16 archive somehow missed.
printf '%s\n' '{"schema_version":1,"issue":"5099","stage":"execute","agent_id":"stale1","tokens":{"total":9000},"ts_start":"2000-01-01T00:00:00Z","ts_end":"2000-01-01T00:00:01Z"}' \
  >> "$CALIB_TEST_COST_LOG"
# A FRESH row for this run's own issue, dated WAY in the future so it is
# >= RUN_START_TS regardless of when this test actually executes.
printf '%s\n' '{"schema_version":1,"issue":"5001","stage":"execute","agent_id":"fresh1","tokens":{"total":1000},"ts_start":"2099-01-01T00:00:00Z","ts_end":"2099-01-01T00:00:01Z"}' \
  >> "$CALIB_TEST_COST_LOG"
echo "all five merged."
STALEMIX
chmod +x "$TMP/claude-stale-mix.sh"

export CALIB_TEST_CLAUDE_SCRIPT="$TMP/claude-stale-mix.sh"
export CALIB_TEST_PRS_JSON="$TMP/prs-1408.json"
export CALIB_TEST_ROWS_JSON="$TMP/rows-1408.json"
export CALIB_TEST_PRICING_JSON="$TMP/pricing-1408.json"
rm -f "$COST_LOG" "$CALLS"
run_helper --run --harness "$HARNESS"
expect_rc "a run with a stale foreign-issue row still exits 0" 0

PRICING_CALL="$(grep -m1 '^clr .*--emit-pricing-json' "$CALLS" 2>/dev/null)"
expect_sub "the pricing call is scoped by --since to this run's window" \
  "$PRICING_CALL" "--since "

ROW_5001_1408="$(printf '%s\n' "$OUT" | grep -m1 '^CALIB issue=5001 ')"
expect_sub "the stale foreign row never dilutes this run's own issue cost" \
  "$ROW_5001_1408" "cost=\$100.00"
refute_sub "the pre-fix apportionment (diluted by the stale row) is gone" \
  "$OUT" "CALIB issue=5001 path=D cost=\$10.00 "

unset CALIB_TEST_CLAUDE_SCRIPT CALIB_TEST_PRS_JSON CALIB_TEST_ROWS_JSON \
      CALIB_TEST_PRICING_JSON

# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "PASS: $PASS  FAIL: $FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
