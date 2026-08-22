#!/usr/bin/env bash
set -euo pipefail

# Locked RED suite for scripts/exact-match-guard-sweep.sh (issue #1200).
#
# WHAT IS BEING LOCKED
# --------------------
# There is no mechanical exact-match assertion sweep in the plugin today
# (`grep -rn "assertEqual" skills/ scripts/` returns zero hits). Plan-time
# detection of exact-match guards was improvised per-evaluator, which produced
# the consumer's keyset-caught / literal-missed asymmetry: an undeclared
# `assertEqual(msgs, [{...}])` contradicted the RED-authored suite mid-leg and
# the GREEN implementer correctly STOPPED with no legal resolution.
#
# The fix (authored by the GREEN implementer, NOT here) adds
# `scripts/exact-match-guard-sweep.sh` — a sibling of `split-role-gate.sh` that
# scans the resolved test roots and emits one token line per exact-match guard —
# and wires it into `skills/evaluate-issue-plan/SKILL.md` Step 3 Phase 1 (the
# README anchor guard of #1059 is the structural precedent) plus
# `skills/plan-issue/SKILL.md` Step 4.
#
# CONTRACT UNDER TEST
# -------------------
#   Usage: exact-match-guard-sweep.sh [<test-path>...]
#   NEVER sources pipeline.config — the caller exports env.
#
#   Scope resolution, three tiers (byte-mirroring split-role-gate.sh:138-153):
#     1. positional <test-path>... args (highest)
#     2. else $PIPELINE_TEST_ROOTS, word-split + glob-EXPANDED
#     3. else default `tests/`
#
#   Per-guard stdout line (one per hit, in scan order):
#     EXACT_MATCH_GUARD=<keyset|literal> FILE=<path> LINE=<n> \
#       SYMBOL=<Class.method|method|-> SUBJECT=<expr>
#   Terminal stdout line (always emitted, always last, exactly one):
#     EXACT_MATCH_SWEEP=<ok|error> ROOTS=<n> FILES=<n> GUARDS=<n> \
#       REASON=<swept|no-test-root|no-test-files>
#
#   Detection (keyset tested FIRST and wins — never a duplicate literal line):
#     keyset  <=> assertEqual\([[:space:]]*set\(  AND  ,[[:space:]]*\{
#     literal <=> NOT keyset AND assertEqual\(.+,[[:space:]]*(\[|\{)
#     assertNotEqual( does not contain the substring assertEqual( — never matched.
#
#   Exit codes (fail loud — the #1182 lesson): 0 swept (GUARDS=0 is a real clean
#   result), 2 usage, 3 vacuous scope (no-test-root / no-test-files). The sweep
#   must NEVER exit 0 on a scope it could not prove anything about. This
#   deliberately DIVERGES from split-role-gate.sh's always-exit-0 contract: that
#   gate's verdict rides a token consumed by an auto-merge parser, whereas this
#   sweep's caller is an LLM evaluator that must be forced to notice a vacuous run.
#
# FIXTURES
# --------
# `mktemp -d` scratch trees only — NO `git init` and NO `git commit`. The sweep
# is a pure filesystem scan, so skipping git sidesteps the
# tests/test-guard-temp-repo-git-identity.sh identity invariant entirely.
#
# Physical line numbers are located by unique trailing markers (`# C01`, `# N01`,
# …) via grep, never hardcoded, so the fixture heredocs can be edited safely.
#
# RED NOTE (expected state at authoring time)
# -------------------------------------------
# `scripts/exact-match-guard-sweep.sh` does not exist, so this suite aborts with
#   ERROR: sweep script missing at <repo>/scripts/exact-match-guard-sweep.sh
# and exits 1 — failing for the RIGHT reason (the helper is missing). Once the
# helper lands (Task 2) cases 1-14 + 18 go green and the caller-wiring cases
# 15-17 remain RED until Tasks 3-4 edit the two SKILL.md files.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWEEP="$REPO_ROOT/scripts/exact-match-guard-sweep.sh"
EVAL_SKILL="$REPO_ROOT/skills/evaluate-issue-plan/SKILL.md"
PLAN_SKILL="$REPO_ROOT/skills/plan-issue/SKILL.md"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$SWEEP" ]; then
  echo "ERROR: sweep script missing at $SWEEP" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

OUT=""
CODE=0

# ---------------------------------------------------------------------------
# Harness helpers
# ---------------------------------------------------------------------------

# run_sweep <cwd> <roots-spec|__UNSET__> [positional <test-path>...]
#   roots-spec "__UNSET__" runs with $PIPELINE_TEST_ROOTS scrubbed from the env;
#   any other value is exported VERBATIM (globs are NOT pre-expanded by the
#   caller — expanding them is the helper's tier-2 job). Captures stdout and the
#   exit status into globals OUT / CODE.
run_sweep() {
  local cwd="$1"; shift
  local roots="$1"; shift
  set +e
  if [ "$roots" = "__UNSET__" ]; then
    OUT=$( cd "$cwd" && env -u PIPELINE_TEST_ROOTS bash "$SWEEP" "$@" 2>/dev/null )
  else
    OUT=$( cd "$cwd" && PIPELINE_TEST_ROOTS="$roots" bash "$SWEEP" "$@" 2>/dev/null )
  fi
  CODE=$?
  set -e
}

# lineno <file> <marker> — physical line number of the unique marker comment.
lineno() {
  grep -n -- "$2" "$1" | head -1 | cut -d: -f1
}

# tok <line> <KEY> — value of the whitespace-delimited KEY=<value> token.
# SUBJECT collapses whitespace runs to `_` per contract, so the line stays
# whitespace-tokenizable.
tok() {
  printf '%s\n' "$1" | tr ' \t' '\n\n' | { grep -m1 -- "^$2=" || true; } | cut -d= -f2-
}

# guard_lines — every EXACT_MATCH_GUARD= line in $OUT.
guard_lines() {
  printf '%s\n' "$OUT" | { grep '^EXACT_MATCH_GUARD=' || true; }
}

# summary_line — the (expected: single) EXACT_MATCH_SWEEP= line in $OUT.
summary_line() {
  printf '%s\n' "$OUT" | { grep '^EXACT_MATCH_SWEEP=' || true; }
}

# guard_for <basename> <lineno> — guard lines whose FILE basename and LINE match.
# Matching on the basename keeps the assertions robust across the several root
# spellings the scope cases exercise, while LINE stays exact.
guard_for() {
  printf '%s\n' "$OUT" | awk -v B="$1" -v L="$2" '
    /^EXACT_MATCH_GUARD=/ {
      file = ""; line = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^FILE=/)      { file = substr($i, 6) }
        else if ($i ~ /^LINE=/) { line = substr($i, 6) }
      }
      base = file; sub(/^.*\//, "", base)
      if (base == B && line == L) { print $0 }
    }'
}

# count_nonempty <text>
count_nonempty() {
  printf '%s' "$1" | { grep -c . || true; }
}

# assert_guard <label> <basename> <lineno> <expected-kind>
# EXACTLY ONE guard line must exist for that FILE+LINE, with the expected kind.
assert_guard() {
  local label="$1" base="$2" ln="$3" kind="$4"
  inc
  local lines n got
  lines=$(guard_for "$base" "$ln")
  n=$(count_nonempty "$lines")
  if [ "$n" -eq 0 ]; then
    fail_msg "$label: no EXACT_MATCH_GUARD line for $base:$ln"
    return
  fi
  if [ "$n" -ne 1 ]; then
    fail_msg "$label: expected exactly 1 guard line for $base:$ln, got $n"
    printf '%s\n' "$lines" | sed 's/^/           /'
    return
  fi
  got=$(tok "$lines" EXACT_MATCH_GUARD)
  if [ "$got" = "$kind" ]; then
    pass_msg "$label: $base:$ln → $kind"
  else
    fail_msg "$label: $base:$ln → expected kind '$kind', got '$got'"
    printf '%s\n' "$lines" | sed 's/^/           /'
  fi
}

# assert_no_guard <label> <basename> <lineno>
assert_no_guard() {
  local label="$1" base="$2" ln="$3"
  inc
  local lines
  lines=$(guard_for "$base" "$ln")
  if [ -z "$lines" ]; then
    pass_msg "$label: no guard emitted at $base:$ln"
  else
    fail_msg "$label: unexpected guard at $base:$ln"
    printf '%s\n' "$lines" | sed 's/^/           /'
  fi
}

# assert_eq <label> <expected> <actual>
assert_eq() {
  inc
  if [ "$2" = "$3" ]; then
    pass_msg "$1 ($2)"
  else
    fail_msg "$1: expected [$2], got [$3]"
  fi
}

# assert_file_contains <label> <file> <needle>
assert_file_contains() {
  local label="$1" file="$2" needle="$3"
  inc
  if [ ! -f "$file" ]; then
    fail_msg "$label: $file missing"
  elif grep -qF -- "$needle" "$file"; then
    pass_msg "$label"
  else
    fail_msg "$label (missing substring: $needle)"
  fi
}

# ---------------------------------------------------------------------------
# Fixture 1 — detection tree (cases 1-8, 14). Default root: tests/.
# ---------------------------------------------------------------------------
MAIN="$WORKDIR/detect"
mkdir -p "$MAIN/tests"

cat > "$MAIN/tests/test_shapes.py" <<'PY'
import unittest


class TestMsgs(unittest.TestCase):
    def test_keyset(self):
        result = {"a": 1, "b": 2}
        self.assertEqual(set(result), {"a", "b"})  # C01

    def test_literal_list(self):
        msgs = [{"a": 1}]
        self.assertEqual(msgs, [{"a": 1}])  # C02

    def test_literal_dict(self):
        msgs = [{"attachments": {"name": "x"}}]
        self.assertEqual(msgs[0]["attachments"], {"name": "x"})  # C03

    def test_multiline_open(self):
        msgs = [{"a": 1}]
        self.assertEqual(msgs, [  # C04
            {"a": 1},
        ])

    def test_split_call(self):
        msgs = [{"a": 1}]
        self.assertEqual(  # C05
            msgs,
            [{"a": 1}],
        )

    def test_negatives(self):
        count = 3
        a = b = x = None
        self.assertEqual(count, 3)  # N01
        self.assertEqual(a, b)  # N02
        self.assertEqual(x, "str")  # N03
        self.assertNotEqual(a, [1])  # N04

    def test_shape(self):
        msgs = [{"a": 1}]
        self.assertEqual(msgs, [{"a": 1}])  # C08
PY

# Module-level hit — deliberately a SEPARATE file so no class/def precedes it
# (symbol tracking resets at FNR==1, so a same-file hit after TestMsgs would
# still carry that symbol).
cat > "$MAIN/tests/test_module_level.py" <<'PY'
from helpers import assertEqual

result = [1]
assertEqual(result, [1])  # M01
PY

SHAPES="$MAIN/tests/test_shapes.py"
MODLVL="$MAIN/tests/test_module_level.py"
L_C01=$(lineno "$SHAPES" '# C01')
L_C02=$(lineno "$SHAPES" '# C02')
L_C03=$(lineno "$SHAPES" '# C03')
L_C04=$(lineno "$SHAPES" '# C04')
L_C05=$(lineno "$SHAPES" '# C05')
L_C08=$(lineno "$SHAPES" '# C08')
L_N01=$(lineno "$SHAPES" '# N01')
L_N02=$(lineno "$SHAPES" '# N02')
L_N03=$(lineno "$SHAPES" '# N03')
L_N04=$(lineno "$SHAPES" '# N04')
L_M01=$(lineno "$MODLVL" '# M01')

run_sweep "$MAIN" "__UNSET__"
DETECT_OUT="$OUT"
DETECT_CODE="$CODE"

echo "Case 1: keyset — assertEqual(set(result), {...}) → EXACT_MATCH_GUARD=keyset"
assert_guard "1 keyset" "test_shapes.py" "$L_C01" "keyset"

echo "Case 2: literal-list — assertEqual(msgs, [{...}]) → literal"
assert_guard "2 literal-list" "test_shapes.py" "$L_C02" "literal"

echo "Case 3: literal-dict — assertEqual(msgs[0][\"attachments\"], {...}) → literal"
assert_guard "3 literal-dict" "test_shapes.py" "$L_C03" "literal"

echo "Case 4: multi-line trailing-open-bracket → literal at the assertEqual( line"
assert_guard "4 multiline-open" "test_shapes.py" "$L_C04" "literal"

echo "Case 5: fully-split call form → literal via logical-line assembly"
assert_guard "5 split-call" "test_shapes.py" "$L_C05" "literal"

echo "Case 6: negatives emit NO guard line"
assert_no_guard "6a scalar-int" "test_shapes.py" "$L_N01"
assert_no_guard "6b bare-name" "test_shapes.py" "$L_N02"
assert_no_guard "6c string" "test_shapes.py" "$L_N03"
assert_no_guard "6d assertNotEqual" "test_shapes.py" "$L_N04"

echo "Case 7: precedence — a keyset hit emits exactly ONE line, never a duplicate literal"
inc
C7_LINES=$(guard_for "test_shapes.py" "$L_C01")
C7_N=$(count_nonempty "$C7_LINES")
C7_LITERALS=$(printf '%s\n' "$C7_LINES" | { grep -c '^EXACT_MATCH_GUARD=literal' || true; })
if [ "$C7_N" -ne 1 ]; then
  fail_msg "7 keyset-precedence: expected exactly 1 line for the keyset hit, got $C7_N"
  printf '%s\n' "$C7_LINES" | sed 's/^/           /'
elif [ "$C7_LITERALS" -ne 0 ]; then
  fail_msg "7 keyset-precedence: keyset hit also reported as literal"
  printf '%s\n' "$C7_LINES" | sed 's/^/           /'
else
  pass_msg "7 keyset-precedence: exactly one keyset line, no duplicate literal"
fi

echo "Case 8: symbol tracking"
inc
C8_LINE=$(guard_for "test_shapes.py" "$L_C08")
if [ -z "$C8_LINE" ]; then
  fail_msg "8a symbol-class-method: no guard line at test_shapes.py:$L_C08"
else
  C8_SYM=$(tok "$C8_LINE" SYMBOL)
  if [ "$C8_SYM" = "TestMsgs.test_shape" ]; then
    pass_msg "8a symbol-class-method: SYMBOL=TestMsgs.test_shape"
  else
    fail_msg "8a symbol-class-method: expected SYMBOL=TestMsgs.test_shape, got SYMBOL=$C8_SYM"
  fi
fi
inc
M1_LINE=$(guard_for "test_module_level.py" "$L_M01")
if [ -z "$M1_LINE" ]; then
  fail_msg "8b symbol-module-level: no guard line at test_module_level.py:$L_M01"
else
  M1_SYM=$(tok "$M1_LINE" SYMBOL)
  if [ "$M1_SYM" = "-" ]; then
    pass_msg "8b symbol-module-level: SYMBOL=-"
  else
    fail_msg "8b symbol-module-level: expected SYMBOL=-, got SYMBOL=$M1_SYM"
  fi
fi

# ---------------------------------------------------------------------------
# Case 9 — scope tier 1: positional <test-path> wins over $PIPELINE_TEST_ROOTS.
# ---------------------------------------------------------------------------
SCOPE1="$WORKDIR/scope1"
mkdir -p "$SCOPE1/alpha" "$SCOPE1/beta"
cat > "$SCOPE1/alpha/test_a.py" <<'PY'
def test_a():
    assertEqual(x, [1])  # A01
PY
cat > "$SCOPE1/beta/test_b.py" <<'PY'
def test_b():
    assertEqual(y, [2])  # B01
PY
L_A01=$(lineno "$SCOPE1/alpha/test_a.py" '# A01')
L_B01=$(lineno "$SCOPE1/beta/test_b.py" '# B01')

echo "Case 9: scope tier 1 — positional arg wins over exported PIPELINE_TEST_ROOTS"
run_sweep "$SCOPE1" "beta/" "alpha/"
assert_guard "9a positional-swept" "test_a.py" "$L_A01" "literal"
assert_no_guard "9b env-root-ignored" "test_b.py" "$L_B01"
assert_eq "9c exit 0" "0" "$CODE"

# ---------------------------------------------------------------------------
# Case 10 — scope tier 2: PIPELINE_TEST_ROOTS is shell-expanded (the #1182 shape).
# ---------------------------------------------------------------------------
SCOPE2="$WORKDIR/scope2"
mkdir -p "$SCOPE2/subagents/contract-manager/testing"
cat > "$SCOPE2/subagents/contract-manager/testing/test_pull_core.py" <<'PY'
class TestMsgsFromMailroom:
    def test_maps_manifest_fields_to_pull_shape(self):
        self.assertEqual(msgs, [{"name": "x"}])  # S01
PY
L_S01=$(lineno "$SCOPE2/subagents/contract-manager/testing/test_pull_core.py" '# S01')

echo "Case 10: scope tier 2 — PIPELINE_TEST_ROOTS='subagents/*/testing/' is glob-expanded"
run_sweep "$SCOPE2" "subagents/*/testing/"
assert_guard "10a env-root-swept" "test_pull_core.py" "$L_S01" "literal"
assert_eq "10b exit 0" "0" "$CODE"

# ---------------------------------------------------------------------------
# Case 11 — scope tier 3: both unset ⇒ default tests/.
# ---------------------------------------------------------------------------
SCOPE3="$WORKDIR/scope3"
mkdir -p "$SCOPE3/tests" "$SCOPE3/other"
cat > "$SCOPE3/tests/test_default.py" <<'PY'
def test_default():
    assertEqual(x, [1])  # D01
PY
cat > "$SCOPE3/other/test_other.py" <<'PY'
def test_other():
    assertEqual(y, [2])  # O01
PY
L_D01=$(lineno "$SCOPE3/tests/test_default.py" '# D01')
L_O01=$(lineno "$SCOPE3/other/test_other.py" '# O01')

echo "Case 11: scope tier 3 — unset env + no positional ⇒ defaults to tests/"
run_sweep "$SCOPE3" "__UNSET__"
assert_guard "11a default-root-swept" "test_default.py" "$L_D01" "literal"
assert_no_guard "11b outside-default-root" "test_other.py" "$L_O01"
assert_eq "11c exit 0" "0" "$CODE"

# ---------------------------------------------------------------------------
# Case 12 — fail loud: no root resolves to an existing path ⇒ no-test-root, exit 3.
# ---------------------------------------------------------------------------
SCOPE4="$WORKDIR/scope4"
mkdir -p "$SCOPE4"

echo "Case 12: fail-loud no-test-root ⇒ EXACT_MATCH_SWEEP=error REASON=no-test-root, exit 3"
run_sweep "$SCOPE4" "nope/*/absent/"
S12=$(summary_line)
assert_eq "12a exit 3" "3" "$CODE"
assert_eq "12b status error" "error" "$(tok "$S12" EXACT_MATCH_SWEEP)"
assert_eq "12c reason no-test-root" "no-test-root" "$(tok "$S12" REASON)"
assert_eq "12d no guard lines" "0" "$(count_nonempty "$(guard_lines)")"

# ---------------------------------------------------------------------------
# Case 13 — fail loud: root exists but holds no scannable file ⇒ no-test-files, exit 3.
# ---------------------------------------------------------------------------
SCOPE5="$WORKDIR/scope5"
mkdir -p "$SCOPE5/tests"

echo "Case 13: fail-loud no-test-files ⇒ REASON=no-test-files, exit 3"
run_sweep "$SCOPE5" "__UNSET__"
S13=$(summary_line)
assert_eq "13a exit 3" "3" "$CODE"
assert_eq "13b status error" "error" "$(tok "$S13" EXACT_MATCH_SWEEP)"
assert_eq "13c reason no-test-files" "no-test-files" "$(tok "$S13" REASON)"
assert_eq "13d roots resolved" "1" "$(tok "$S13" ROOTS)"
assert_eq "13e zero files" "0" "$(tok "$S13" FILES)"

# ---------------------------------------------------------------------------
# Case 14 — summary invariant on the detection run: exactly one EXACT_MATCH_SWEEP=
# line, always LAST, GUARDS=<n> equal to the number of EXACT_MATCH_GUARD= lines.
# ---------------------------------------------------------------------------
OUT="$DETECT_OUT"
CODE="$DETECT_CODE"

echo "Case 14: summary invariant — one trailing EXACT_MATCH_SWEEP= line, GUARDS == hit count"
S14=$(summary_line)
assert_eq "14a exactly one summary line" "1" "$(count_nonempty "$S14")"
assert_eq "14b summary is the last line" "$S14" "$(printf '%s\n' "$OUT" | tail -1)"
assert_eq "14c GUARDS == guard-line count" "$(count_nonempty "$(guard_lines)")" "$(tok "$S14" GUARDS)"
assert_eq "14d reason swept" "swept" "$(tok "$S14" REASON)"
assert_eq "14e exit 0" "0" "$CODE"

# ---------------------------------------------------------------------------
# Case 15 — caller wiring: evaluate-issue-plan invokes the sweep and threads the
# test-root env through (the helper NEVER sources pipeline.config).
# ---------------------------------------------------------------------------
echo "Case 15: evaluate-issue-plan/SKILL.md invokes the sweep + threads PIPELINE_TEST_ROOTS"
assert_file_contains "15a eval-plan invokes sweep" "$EVAL_SKILL" "exact-match-guard-sweep.sh"
assert_file_contains "15b eval-plan threads test roots" "$EVAL_SKILL" "PIPELINE_TEST_ROOTS="

# ---------------------------------------------------------------------------
# Case 16 — fail-loud wiring: the vacuous-scope token is named AND tied to Revise.
# A vacuous sweep must never read as a clean pass.
# ---------------------------------------------------------------------------
echo "Case 16: evaluate-issue-plan/SKILL.md names no-test-root and ties it to a Revise verdict"
assert_file_contains "16a eval-plan names no-test-root" "$EVAL_SKILL" "no-test-root"
inc
if [ ! -f "$EVAL_SKILL" ]; then
  fail_msg "16b no-test-root tied to Revise: $EVAL_SKILL missing"
elif awk '
    /no-test-root/ { hits[NR] = 1 }
    /Revise/       { revs[NR] = 1 }
    END {
      for (h in hits) for (r in revs) if ((r - h) <= 10 && (h - r) <= 10) { exit 0 }
      exit 1
    }' "$EVAL_SKILL"; then
  pass_msg "16b no-test-root tied to a Revise verdict (within 10 lines)"
else
  fail_msg "16b no-test-root is not tied to a Revise verdict in $EVAL_SKILL"
fi

# ---------------------------------------------------------------------------
# Case 17 — planner wiring: plan-issue prompts the sweep at authoring time so the
# declaration is produced in the plan, not only demanded at evaluation.
# ---------------------------------------------------------------------------
echo "Case 17: plan-issue/SKILL.md references the sweep + the Shared tests declaration"
assert_file_contains "17a plan-issue references sweep" "$PLAN_SKILL" "exact-match-guard-sweep.sh"
assert_file_contains "17b plan-issue names the declaration" "$PLAN_SKILL" "**Shared tests (split-role):**"

# ---------------------------------------------------------------------------
# Case 18 — packaging: executable, bash shebang.
# ---------------------------------------------------------------------------
echo "Case 18: packaging — executable bit + #!/usr/bin/env bash shebang"
inc
if [ -x "$SWEEP" ]; then
  pass_msg "18a sweep script is executable"
else
  fail_msg "18a sweep script is not executable: $SWEEP"
fi
inc
if [ "$(head -1 "$SWEEP")" = "#!/usr/bin/env bash" ]; then
  pass_msg "18b shebang is #!/usr/bin/env bash"
else
  fail_msg "18b expected shebang '#!/usr/bin/env bash', got '$(head -1 "$SWEEP")'"
fi

# ===========================================================================
# --- Loose plan-comment match guard (#1251) ---
#
# The plan-comment selector defect (#1240 in scripts/plan-waves.sh, #1247 in
# skills/execute-issue-plan/SKILL.md, #1251 in the two evaluation stages) has
# now been fixed THREE times, and each sweep for "is there another copy?"
# missed the next one because the sweep searched for a matching VERB: the
# third instance hid behind a shell `case` glob while the sweep looked for the
# jq `contains(...)` idiom.
#
# So this guard is VERB-INDEPENDENT. Any loose plan selection must SPELL the
# heading `## Implementation Plan` somewhere; the verb that consumes it
# (`contains`, jq `test`, a `case` glob, `[[ == ]]`, `grep`, `awk`, `sed`,
# Python `in`, `rg`, or whatever is invented next year) is an unbounded set and
# is IGNORED by the detector. Keying on the constant instead of the verb is
# what makes "a fourth spelling cannot hide" an executable property rather
# than prose — see the Case 21 decoy self-test.
#
# Comment lines and non-shell markdown prose are excluded, and that exclusion
# is what makes the constant safe to key on: a `#`-prefixed line is
# documentation, and markdown outside a fenced shell block is prose (the
# evaluate-issue-*/SKILL.md trust paragraphs MUST keep naming the heading —
# tests/test-evaluate-issue-*-comment-trust.sh lint on exactly those lines).
#
# `tests/` is deliberately OUT of scope: it legitimately carries decoy
# fixtures and hand-copied mirror drivers — the same self-referential-fixture
# carve-out scripts/exact-match-guard-sweep.sh documents under KNOWN LIMITS.
# ===========================================================================

HEADING='## Implementation Plan'

# scan_loose_plan_matches <root> -> one "FILE:LINE" per hit on stdout.
# Set A: executable sources (.sh/.py) — every non-comment line naming the heading.
# Set B: markdown skill/agent/doc bodies — non-comment lines INSIDE fenced shell
#        blocks only (```bash / ```sh / ```shell / bare ```), so explanatory PROSE
#        may name the heading freely. A bare ``` fence is treated as shell:
#        deliberately fail-CLOSED, and measured to cost 0 false positives.
scan_loose_plan_matches() {
  local root="$1" f
  find "$root/scripts" "$root/hooks" "$root/agents" -type f \
         \( -name '*.sh' -o -name '*.py' \) 2>/dev/null \
    | LC_ALL=C sort | while IFS= read -r f; do
        awk -v H="$HEADING" -v F="${f#"$root"/}" '
          index($0, H) == 0 { next }
          { l = $0; sub(/^[[:space:]]+/, "", l) }
          l ~ /^#/ { next }
          { printf "%s:%d\n", F, FNR }' "$f"
      done
  find "$root/skills" "$root/agents" "$root/docs" -type f -name '*.md' 2>/dev/null \
    | LC_ALL=C sort | while IFS= read -r f; do
        awk -v H="$HEADING" -v F="${f#"$root"/}" '
          /^[[:space:]]*```/ {
            t = $0; sub(/^[[:space:]]*```[[:space:]]*/, "", t); sub(/[[:space:]]+$/, "", t)
            if (inb) { inb = 0; next }
            if (t == "bash" || t == "sh" || t == "shell" || t == "") inb = 1; else inb = 2
            next
          }
          inb != 1 { next }
          index($0, H) == 0 { next }
          { l = $0; sub(/^[[:space:]]+/, "", l) }
          l ~ /^#/ { next }
          { printf "%s:%d\n", F, FNR }' "$f"
      done
}

# Default-deny, COUNT-PINNED allowlist: "<repo-relative path> <exact hit count>".
# A file absent from the table must have ZERO hits; a listed file must have
# EXACTLY N. Equality (not a floor) makes the guard fail-closed in BOTH
# directions — a smuggled-in extra selection trips it, AND a silently-empty
# scan (wrong cwd, renamed directory) trips it too, with no separate "did we
# scan anything?" assertion. The pin is the COUNT, not line numbers, so
# unrelated line drift never breaks it.
#
#   scripts/post-plan.sh        4  lines 11-12 grep + report on a local DRAFT
#                                  FILE (not a comment set); lines 34/38 are a
#                                  post-verify COUNT (| length) + its error text
#   scripts/combine-hint-impact.sh 1  replan COUNT (| length), not a selection
#   skills/fullsend/SKILL.md    1  plan-presence COUNT (| length), not a selection
#
# The table is inline rather than a tests/*.allow sibling because it is three
# rows and belongs next to the assertion; revisit only past ~10 rows.
LOOSE_ALLOWLIST=$(cat <<'ALLOW'
scripts/post-plan.sh 4
scripts/combine-hint-impact.sh 1
skills/fullsend/SKILL.md 1
ALLOW
)

LOOSE_REMEDY='a plan-comment SELECTION must reuse scripts/select-plan-comment.sh; a COUNT/PRESENCE check must be added to the allowlist table with a justification.'

LOOSE_TREE_HITS=$(scan_loose_plan_matches "$REPO_ROOT" || true)

echo "Case 19 (#1251): tree verdict — zero unallowlisted loose plan-comment matches"
inc
LOOSE_UNALLOWED=$(printf '%s\n' "$LOOSE_TREE_HITS" | awk -v list="$LOOSE_ALLOWLIST" '
  BEGIN {
    n = split(list, rows, "\n")
    for (i = 1; i <= n; i++) { split(rows[i], p, " "); if (p[1] != "") allow[p[1]] = 1 }
  }
  NF == 0 { next }
  { f = $0; sub(/:[0-9]+$/, "", f); if (!(f in allow)) print $0 }')
if [ -z "$LOOSE_UNALLOWED" ]; then
  pass_msg "19 loose-plan-match: zero unallowlisted hits"
else
  fail_msg "19 loose-plan-match: $(count_nonempty "$LOOSE_UNALLOWED") unallowlisted loose plan-comment matches: $(printf '%s' "$LOOSE_UNALLOWED" | tr '\n' ' ')"
  printf '%s\n' "$LOOSE_UNALLOWED" | sed 's/^/           /'
  echo "           remedy: $LOOSE_REMEDY"
fi

echo "Case 20 (#1251): count-pinned allowlist — each listed file has EXACTLY N hits"
while read -r LOOSE_AF LOOSE_AN; do
  [ -n "$LOOSE_AF" ] || continue
  assert_eq "20 $LOOSE_AF hit count" "$LOOSE_AN" \
    "$(printf '%s\n' "$LOOSE_TREE_HITS" | awk -F: -v f="$LOOSE_AF" '$1 == f { n++ } END { print n + 0 }')"
done <<ALLOWROWS
$LOOSE_ALLOWLIST
ALLOWROWS

# ---------------------------------------------------------------------------
# Case 21 — decoy self-test. The subject here is the DETECTOR, not the repo
# tree: four decoys spelled with FOUR DIFFERENT verbs must all be CAUGHT, and
# three near-miss negatives must all be MISSED — asserted as EQUALITY, so a
# scanner that over-matches the negatives fails as loudly as one that
# under-matches the positives.
# ---------------------------------------------------------------------------
DECOY="$WORKDIR/loose-decoy"
# Create EVERY directory the scanner is pointed at. `find` exits 1 on a missing
# operand; under this file's `set -euo pipefail` that status propagates out of
# the pipeline and kills the suite with NO diagnostic (and $PIPELINE_TEST_CMD's
# `|| true` then swallows it entirely).
mkdir -p "$DECOY/scripts" "$DECOY/hooks" "$DECOY/agents" "$DECOY/docs" "$DECOY/skills/decoy"

cat > "$DECOY/scripts/decoy-awk.sh" <<'DECOYSH'
#!/bin/bash
BODY=$(cat body.txt)
awk '/## Implementation Plan/ { found = 1 } END { print found }' body.txt
DECOYSH

cat > "$DECOY/scripts/decoy-sed.sh" <<'DECOYSH'
#!/bin/bash
sed -n '/## Implementation Plan/,$p' body.txt
DECOYSH

cat > "$DECOY/hooks/decoy.py" <<'DECOYPY'
body = open("body.txt").read()
if "## Implementation Plan" in body:
    print(body)
DECOYPY

cat > "$DECOY/skills/decoy/SKILL.md" <<'DECOYMD'
# Decoy skill

Prose naming ## Implementation Plan outside any fence must be MISSED.

```bash
# a comment naming ## Implementation Plan inside the fence must be MISSED
[[ "$BODY" == *"## Implementation Plan"* ]] && echo plan
```

```markdown
## Implementation Plan
```
DECOYMD

DECOY_EXPECTED=$(cat <<'DECOYEXP'
hooks/decoy.py:2
scripts/decoy-awk.sh:3
scripts/decoy-sed.sh:2
skills/decoy/SKILL.md:7
DECOYEXP
)

echo "Case 21 (#1251): decoy self-test — no fourth spelling can hide"
inc
DECOY_HITS=$(scan_loose_plan_matches "$DECOY" || true)
if [ "$DECOY_HITS" = "$DECOY_EXPECTED" ]; then
  pass_msg '21 decoy self-test: awk / sed / python-in / glob decoys all CAUGHT; prose-outside-fence, #-comment-inside-fence and markdown-fence negatives all MISSED'
else
  fail_msg "21 decoy self-test: scan output is not exactly the 4 expected positives"
  echo "           expected:"; printf '%s\n' "$DECOY_EXPECTED" | sed 's/^/             /'
  echo "           got:";      printf '%s\n' "$DECOY_HITS"     | sed 's/^/             /'
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
