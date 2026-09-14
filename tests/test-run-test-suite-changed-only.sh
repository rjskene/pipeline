#!/bin/bash
set -uo pipefail

# Locked suite for issue #1334 — `scripts/run-test-suite.sh --changed-only`
# (diff-scoped selection) + the Step 6b prose contract that makes it the
# PRIMARY pre-PR verification form.
#
# #1208 gave the executor a FOREGROUND 4-chunk run of the full ~590-file corpus
# because the whole suite does not fit in one Bash-call timeout. #1322/#1329
# then made CI the oracle for UNTOUCHED failures: only the diff's touched tests
# and their SUBJECT tests (a test that reads/greps/sources/execs a touched path
# by path, basename, or containing glob such as `hooks/*.py`) must be green
# locally. Running four chunks to learn what one selected subset already proves
# is pure cost. `--changed-only [--base <ref>]` computes exactly that subset —
# touched tests ∪ subject tests — from the diff against the merge-base and runs
# only those, printing ONE `CHANGED-ONLY: touched=<n> selected=<k>/<total>
# RESULT=pass|fail` summary. When base CI is green, Step 6b runs that single
# call; the 4-chunk run survives only as the fallback.
#
# Contracts pinned here (scenarios 1–10):
#   1. touched `scripts/a.sh` ⇒ only the test that names `scripts/a.sh` runs;
#      summary `touched=1 selected=1/3 RESULT=pass`, exit 0.
#   2. touched `hooks/b.py` ⇒ the test that globs `hooks/*.py` runs (containing
#      glob is a subject needle); the `a.sh` test does not.
#   3. an UNTRACKED `tests/test-new.sh` counts as touched and is selected.
#   4. clean tree ⇒ `touched=0 selected=0/<total> RESULT=pass`, exit 0, nothing runs.
#   5. unresolvable `--base` ⇒ fail-open: ONE stderr line
#      `CHANGED-ONLY: base <ref> unresolved — running the full suite`, the full
#      suite runs, and NO `CHANGED-ONLY: touched=` summary is printed.
#   6. `--changed-only` + `--chunk` ⇒ exit 2, `mutually exclusive` + `usage:`,
#      no `CHANGED-ONLY: touched=` and no `CHUNK=` line.
#   7. a touched test that fails ⇒ `RESULT=fail`, exit 1 (STRICT fail survives).
#   8. no `--base` ⇒ `origin/${PIPELINE_BASE_BRANCH}` is the base;
#      `PIPELINE_TEST_VERBOSE=1` adds a `CHANGED-ONLY: selected <rel>` line per
#      selected file on stdout.
#   9. DEFAULT mode is byte-compatible: no `--changed-only` ⇒ no `CHANGED-ONLY:`
#      token at all (negative control — green before and after the impl).
#  10. Step 6b of skills/execute-issue-plan/SKILL.md names `--changed-only` as
#      the primary form (`When base CI is green …`), reads the `CHANGED-ONLY:`
#      summary, and keeps `--chunk 1/4` as the fallback.
#
# The runner exercises use a THROWAWAY git repo (with a bare `origin` so
# `origin/main` resolves) under `mktemp -d` — NEVER the real tests/ dir. The
# leak guard (#1316) is switched off for these runs
# (PIPELINE_TEST_LEAK_GUARD_REPO=""). Every scenario passes `--base origin/main`
# explicitly (or an explicit env pair in scenario 8) because the dogfood
# `pipeline.config` is `set -a`-exported and would otherwise leak
# `PIPELINE_BASE_BRANCH=evolve` into the fixture, where `origin/evolve` does not
# exist. Needle checks grep the CAPTURED FILE (never `<pipe> | grep -q`, the
# #897 SIGPIPE flake shape).
#
# Mirrors the ROOT / pass_msg / fail_msg / inc / `exit 1` shape of
# tests/test-run-test-suite-chunked.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/run-test-suite.sh"
SKILL="$ROOT/skills/execute-issue-plan/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$RUNNER" ]; then
  echo "FAIL: scripts/run-test-suite.sh not found under $ROOT" >&2
  exit 1
fi
if [ ! -f "$SKILL" ]; then
  echo "FAIL: skills/execute-issue-plan/SKILL.md not found under $ROOT" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Fixture — a throwaway repo with a bare `origin` so `origin/main` resolves.
#
#   scripts/a.sh            #!/bin/bash / echo a
#   hooks/b.py              print("b")
#   tests/test-a.sh         subject of scripts/a.sh by path + basename
#   tests/test-hooks.sh     subject of hooks/b.py via the containing glob hooks/*
#   tests/test-unrelated.sh names NO touched path (no scripts/, hooks/, tests/*,
#                           a.sh or b.py substring anywhere in the file)
#
# Every stub echoes `RANFILE:<name>` and exits 0 so the captured output tells
# exactly which files the runner selected.
# ---------------------------------------------------------------------------

R="$WORK/repo"

# stub <name> <body> — write tests/<name> in the fixture repo.
stub() {
  local name="$1" body="$2"
  printf '#!/bin/bash\n%s\necho "RANFILE:%s"\nexit 0\n' "$body" "$name" > "$R/tests/$name"
  chmod +x "$R/tests/$name"
}

# Commit as a fixed identity (#1117: CI has no global git identity).
gitc() { git -C "$R" -c user.name=t -c user.email=t@t "$@"; }

build_fixture() {
  git -c init.defaultBranch=main init -q "$R" || return 1
  # Belt-and-braces for a git too old to honour init.defaultBranch.
  git -C "$R" symbolic-ref HEAD refs/heads/main || return 1
  mkdir -p "$R/scripts" "$R/hooks" "$R/tests" || return 1
  printf '#!/bin/bash\necho a\n' > "$R/scripts/a.sh"
  printf 'print("b")\n' > "$R/hooks/b.py"
  stub test-a.sh         'grep -q a "$(dirname "$0")/../scripts/a.sh"'
  stub test-hooks.sh     'for f in "$(dirname "$0")"/../hooks/*.py; do [ -f "$f" ] || exit 1; done'
  stub test-unrelated.sh ':'
  gitc add -A || return 1
  gitc commit -qm base || return 1
  git clone -q --bare "$R" "$WORK/origin.git" || return 1
  git -C "$R" remote add origin "$WORK/origin.git" || return 1
  git -C "$R" fetch -q origin || return 1
  git -C "$R" rev-parse --verify -q origin/main >/dev/null || return 1
}

if ! build_fixture; then
  echo "FAIL: could not build the throwaway fixture repo under $WORK" >&2
  exit 1
fi

# Sanity: the "unrelated" stub really carries no needle-able substring.
for needle in 'scripts/' 'hooks/' 'tests/*' 'a.sh' 'b.py'; do
  if grep -Fq -- "$needle" "$R/tests/test-unrelated.sh"; then
    echo "FAIL: fixture bug — tests/test-unrelated.sh contains the needle '$needle'" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Driver + assertion helpers.
# ---------------------------------------------------------------------------

N=0
RC=0
OUT=""
WHY=""

# run <runner-args...> — run the runner in the FOREGROUND against the fixture
# tests dir, leak guard OFF, combined stdout+stderr captured to a file (the
# fail-open fallback line and the usage diagnostic go to stderr).
run() {
  N=$((N + 1))
  OUT="$WORK/out.$N"
  TESTS_DIR="$R/tests" PIPELINE_TEST_LEAK_GUARD_REPO="" bash "$RUNNER" "$@" > "$OUT" 2>&1
  RC=$?
}

# Put the fixture back to a clean tree (tracked edits reverted, untracked
# files under tests/ removed).
revert() {
  git -C "$R" checkout -q -- . && git -C "$R" clean -qfd tests
}

want_rc() { [ "$RC" -eq "$1" ] || WHY="$WHY rc=$RC(want $1);"; }
has()     { grep -Fq -- "$1" "$OUT" || WHY="$WHY missing:[$1];"; }
lacks()   { if grep -Fq -- "$1" "$OUT"; then WHY="$WHY present:[$1];"; fi; }
verdict() {
  inc
  if [ -z "$WHY" ]; then
    pass_msg "$1"
  else
    fail_msg "$1 —$WHY"
  fi
  WHY=""
}

# ---------------------------------------------------------------------------
# 1. Touched scripts/a.sh ⇒ only its subject test (path + basename) runs.
# ---------------------------------------------------------------------------

echo '# t' >> "$R/scripts/a.sh"
run --changed-only --base origin/main
want_rc 0
has   'RANFILE:test-a.sh'
lacks 'RANFILE:test-unrelated.sh'
lacks 'RANFILE:test-hooks.sh'
has   'CHANGED-ONLY: touched=1 selected=1/3 scanners=0 RESULT=pass'
verdict "changed-only/path-subject: touched scripts/a.sh selects only test-a.sh (touched=1 selected=1/3 scanners=0 RESULT=pass, exit 0)"
revert

# ---------------------------------------------------------------------------
# 2. Touched hooks/b.py ⇒ the containing-glob subject (hooks/*.py) runs.
# ---------------------------------------------------------------------------

echo '# t' >> "$R/hooks/b.py"
run --changed-only --base origin/main
want_rc 0
has   'RANFILE:test-hooks.sh'
lacks 'RANFILE:test-a.sh'
has   'selected=1/3'
verdict "changed-only/glob-subject: touched hooks/b.py selects only test-hooks.sh via the hooks/* containing glob (selected=1/3)"
revert

# ---------------------------------------------------------------------------
# 3. An UNTRACKED tests/test-new.sh counts as touched and is selected.
#    Then land it on origin/main so scenarios 4+ see a 4-file corpus.
# ---------------------------------------------------------------------------

stub test-new.sh ':'
run --changed-only --base origin/main
want_rc 0
has 'RANFILE:test-new.sh'
has 'touched=1 selected=1/4'
verdict "changed-only/untracked: an untracked tests/test-new.sh is touched and selected (touched=1 selected=1/4)"

if ! { gitc add -A && gitc commit -qm new && git -C "$R" push -q origin main && git -C "$R" fetch -q origin; }; then
  echo "FAIL: could not land tests/test-new.sh on the fixture's origin/main" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Clean tree ⇒ touched=0 selected=0/4 RESULT=pass, nothing runs, exit 0.
# ---------------------------------------------------------------------------

run --changed-only --base origin/main
want_rc 0
has   'CHANGED-ONLY: touched=0 selected=0/4 scanners=0 RESULT=pass'
lacks 'RANFILE:'
verdict "changed-only/clean: a clean tree reports touched=0 selected=0/4 scanners=0 RESULT=pass and runs nothing"

# ---------------------------------------------------------------------------
# 5. Unresolvable base ⇒ fail-open to the full suite with ONE stderr line and
#    NO CHANGED-ONLY summary (default output stays byte-compatible).
# ---------------------------------------------------------------------------

run --changed-only --base origin/nope
want_rc 0
has   'CHANGED-ONLY: base origin/nope unresolved — running the full suite'
has   'RANFILE:test-a.sh'
has   'RANFILE:test-hooks.sh'
has   'RANFILE:test-unrelated.sh'
has   'RANFILE:test-new.sh'
lacks 'CHANGED-ONLY: touched='
verdict "changed-only/fail-open: an unresolvable --base prints the 'unresolved — running the full suite' line, runs all four, and emits no touched= summary"

# ---------------------------------------------------------------------------
# 6. --changed-only + --chunk ⇒ exit 2 with the usage diagnostic.
# ---------------------------------------------------------------------------

run --changed-only --chunk 1/2
want_rc 2
has   'mutually exclusive'
has   'usage:'
lacks 'CHANGED-ONLY: touched='
lacks 'CHUNK='
verdict "changed-only/argcheck: --changed-only with --chunk exits 2 with 'mutually exclusive' + 'usage:' and no summary line"

# ---------------------------------------------------------------------------
# 7. A touched test that FAILS reds the run (STRICT fail survives selection).
# ---------------------------------------------------------------------------

printf '#!/bin/bash\necho "RANFILE:test-a.sh"\nexit 1\n' > "$R/tests/test-a.sh"
run --changed-only --base origin/main
want_rc 1
has 'touched=1 selected=1/4 scanners=0 RESULT=fail'
verdict "changed-only/strict-fail: a touched, failing test reports touched=1 selected=1/4 scanners=0 RESULT=fail and exits 1"
revert

# ---------------------------------------------------------------------------
# 8. No --base ⇒ origin/${PIPELINE_BASE_BRANCH}; verbose lists each selection.
# ---------------------------------------------------------------------------

echo '# t' >> "$R/scripts/a.sh"
PIPELINE_BASE_BRANCH=main PIPELINE_REPO=x/y PIPELINE_TEST_VERBOSE=1 run --changed-only
want_rc 0
has 'RANFILE:test-a.sh'
has 'selected=1/4 scanners=0 RESULT=pass'
has 'CHANGED-ONLY: selected tests/test-a.sh'
verdict "changed-only/env-base+verbose: no --base resolves origin/\$PIPELINE_BASE_BRANCH and PIPELINE_TEST_VERBOSE=1 lists 'CHANGED-ONLY: selected tests/test-a.sh'"
revert

# ---------------------------------------------------------------------------
# 9. DEFAULT mode is byte-compatible — no CHANGED-ONLY: token at all.
# ---------------------------------------------------------------------------

run
want_rc 0
has   'RANFILE:test-a.sh'
has   'RANFILE:test-hooks.sh'
has   'RANFILE:test-unrelated.sh'
has   'RANFILE:test-new.sh'
lacks 'CHANGED-ONLY:'
verdict "default-mode: no --changed-only ⇒ all four run, exit 0, and NO CHANGED-ONLY: line"

# ---------------------------------------------------------------------------
# 10. Step 6b prose pin — the region between `**6b. Run tests` and `**6c.`
#     names --changed-only as the primary form and keeps the 4-chunk fallback.
#     Same extractor as tests/test-dispatch-no-background-test-run.sh.
# ---------------------------------------------------------------------------

STEP6B="$(awk '/^\s*\*\*6b\. Run tests/{c=1} /^\s*\*\*6c\./{c=0} c' "$SKILL")"
if [ -z "$STEP6B" ]; then
  echo "FAIL: could not extract the Step 6b region from $SKILL (markers '**6b. Run tests' / '**6c.' moved?)" >&2
  exit 1
fi

has6b() { case "$STEP6B" in *"$1"*) ;; *) WHY="$WHY 6b-missing:[$1];" ;; esac; }

has6b '--changed-only'
has6b 'When base CI is green'
has6b 'CHANGED-ONLY:'
has6b '--chunk 1/4'
verdict "step-6b-prose: Step 6b names --changed-only as the primary form ('When base CI is green'), reads the CHANGED-ONLY: summary, and keeps --chunk 1/4 as the fallback"

# ---------------------------------------------------------------------------
# Fixture extension (#1339, backlog #65) — add a SCANNER-shaped test that
# globs `"$TESTS_DIR"/test*.sh` (the exact idiom used by the real
# tests/test-guard-temp-repo-git-identity.sh) and fails if ANY corpus test
# file contains the marker string SCANNERMARK. It names no single touched
# path, so pre-#1339 --changed-only would never select it even when a diff
# adds a file that trips it. Land it on origin/main so scenarios 11+ see a
# 5-file corpus baseline (was 4 after scenario 3).
# ---------------------------------------------------------------------------

cat > "$R/tests/test-scanner.sh" <<'SCANEOF'
#!/bin/bash
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "RANFILE:test-scanner.sh"
for f in "$TESTS_DIR"/test*.sh "$TESTS_DIR"/test_*.sh; do
  [ -f "$f" ] || continue
  grep -q SCANNERMARK "$f" && { echo "SCANNER-FAIL: $f"; exit 1; }
done
exit 0
SCANEOF
chmod +x "$R/tests/test-scanner.sh"

if ! { gitc add -A && gitc commit -qm scanner && git -C "$R" push -q origin main && git -C "$R" fetch -q origin; }; then
  echo "FAIL: could not land tests/test-scanner.sh on the fixture's origin/main" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 11. Touched tests/test-marked.sh (new, carries SCANNERMARK) ⇒ the scanner
#     test — which globs the tests dir but names no touched path — is
#     selected too (scanners=1), and its marker-detection reds the run: the
#     exact CI-red-head blind spot #1339 closes.
# ---------------------------------------------------------------------------

printf '#!/bin/bash\necho SCANNERMARK\nexit 0\n' > "$R/tests/test-marked.sh"
chmod +x "$R/tests/test-marked.sh"
run --changed-only --base origin/main
want_rc 1
has 'RANFILE:test-scanner.sh'
has 'touched=1 selected=2/6 scanners=1 RESULT=fail'
verdict "changed-only/scanner-selected: a touched new test carrying the SCANNERMARK marker also selects the scanner test (scanners=1) and reds the run (touched=1 selected=2/6 scanners=1 RESULT=fail)"
revert

# ---------------------------------------------------------------------------
# 12. Control: a diff touching only scripts/a.sh (no tests/ path) does NOT
#     select the scanner — scanners=0.
# ---------------------------------------------------------------------------

echo '# t' >> "$R/scripts/a.sh"
run --changed-only --base origin/main
want_rc 0
has   'RANFILE:test-a.sh'
lacks 'RANFILE:test-scanner.sh'
has   'touched=1 selected=1/5 scanners=0 RESULT=pass'
verdict "changed-only/scanner-control: a diff touching only scripts/a.sh (no tests/ path) does not select the scanner (touched=1 selected=1/5 scanners=0 RESULT=pass)"
revert

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
