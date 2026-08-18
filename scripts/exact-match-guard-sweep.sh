#!/usr/bin/env bash
# exact-match-guard-sweep.sh — mechanical exact-match assertion guard sweep (issue #1200).
#
# WHY THIS EXISTS
# ---------------
# On a split-role (RED/GREEN) leg the GREEN implementer may not edit the locked
# `[split-role-red]` suite. If the planned change would break an EXISTING
# exact-match assertion elsewhere in the test tree, that file must be declared
# under `**Shared tests (split-role):**` at plan time — otherwise GREEN reaches a
# contradiction it cannot legally resolve and correctly STOPS mid-leg.
#
# Before #1200 there was no mechanical sweep at all (`grep -rn "assertEqual"
# skills/ scripts/` returned zero hits): each plan evaluator improvised its own
# grep, which produced the consumer's keyset-caught / literal-missed asymmetry.
# This helper replaces the improvisation with one deterministic scan, mirroring
# the mechanical-helper + skill-call-site structure of the #1059 README anchor
# guard. Call sites: `skills/evaluate-issue-plan/SKILL.md` Step 3 Phase 1 and
# `skills/plan-issue/SKILL.md` Step 4.
#
# CONTRACT
# --------
#   Usage: exact-match-guard-sweep.sh [<test-path>...]
#   NEVER sources pipeline.config — the caller exports env (same contract as
#   scripts/split-role-gate.sh).
#
#   Scope resolution, three tiers (mirroring split-role-gate.sh):
#     1. positional <test-path>... args (highest)
#     2. else $PIPELINE_TEST_ROOTS — shell word-split + glob-EXPANDED (globbing
#        ON, NOT `set -f`): a trailing-slash wildcard root such as
#        `subagents/*/testing/` must be pre-expanded into real dirs (#1182/#1183)
#     3. else default `tests/`
#   A root may be a directory (scanned recursively) or a single file.
#
#   Per-guard stdout line (one per hit, in scan order):
#     EXACT_MATCH_GUARD=<keyset|literal> FILE=<path> LINE=<n> \
#       SYMBOL=<Class.method|method|-> SUBJECT=<expr>
#   Terminal stdout line (always emitted, always LAST, exactly one):
#     EXACT_MATCH_SWEEP=<ok|error> ROOTS=<n> FILES=<n> GUARDS=<n> \
#       REASON=<swept|no-test-root|no-test-files>
#
#   Detection (keyset is tested FIRST and wins — never a duplicate literal line
#   for the same FILE+LINE), applied to the assembled logical line:
#     keyset  <=> assertEqual\([[:space:]]*set\(  AND  ,[[:space:]]*\{
#     literal <=> NOT keyset AND assertEqual\(.+,[[:space:]]*(\[|\{)
#     `assertNotEqual(` does not contain the substring `assertEqual(` and is
#     therefore never matched.
#
#   Exit codes (fail loud — the #1182 lesson):
#     0  swept (GUARDS=0 is a real clean result)
#     2  usage
#     3  vacuous scope: no-test-root (zero roots resolved to an existing path)
#        or no-test-files (roots resolved but zero scannable files)
#   The sweep must NEVER exit 0 on a scope it could not prove anything about.
#   This deliberately DIVERGES from split-role-gate.sh's always-exit-0 token
#   contract: that gate rides its verdict on a token consumed by an auto-merge
#   parser, whereas this sweep's caller is an LLM evaluator that must be forced
#   to notice a vacuous run.
#
# KNOWN LIMITS (heuristic, not an AST)
# ------------------------------------
#   - Paren balancing ignores string/comment contents, so `assertEqual("a)b", …)`
#     can mis-assemble. Accepted: this is an evaluator-facing hint generator; a
#     false positive costs one line of attention and the 4-line assembly cap
#     bounds the blast radius.
#   - Reversed-argument keysets (`assertEqual({"a","b"}, set(result))`) are
#     reported as `literal`, not `keyset` — still surfaced, just less precisely.
#   - `assertDictEqual` / `assertListEqual` / `assertCountEqual` are OUT OF SCOPE
#     (#1200 names `assertEqual` only). Widening is a one-line follow-up.
#   - SELF-REFERENTIAL OUTPUT: run from this repo with the default root, the
#     sweep reports hits from the plugin's own fixtures (e.g.
#     `tests/test_block_deletions.py`, `tests/test_restrict_paths.py`, and the
#     heredoc fixtures inside `tests/test-exact-match-guard-sweep.sh`). Those are
#     fixtures, not real guards — do not read them as consumer findings.

set -uo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: exact-match-guard-sweep.sh [<test-path>...]

Scans the resolved test roots for exact-match assertEqual guards and emits one
EXACT_MATCH_GUARD= line per hit plus a trailing EXACT_MATCH_SWEEP= summary.

Scope: positional <test-path>... > $PIPELINE_TEST_ROOTS (glob-expanded) > tests/
Exit:  0 swept | 2 usage | 3 vacuous scope (no-test-root / no-test-files)
EOF
}

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 2
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

# --- Scope resolution (three tiers) -----------------------------------------
if [ "${#ARGS[@]}" -ge 1 ]; then
  TEST_PATHS=("${ARGS[@]}")
elif [ -n "${PIPELINE_TEST_ROOTS:-}" ]; then
  # Intentionally unquoted: word-split AND glob-expand (globbing stays ON).
  # shellcheck disable=SC2206
  TEST_PATHS=( $PIPELINE_TEST_ROOTS )
else
  TEST_PATHS=("tests/")
fi

emit_summary() {
  # emit_summary <ok|error> <roots> <files> <guards> <reason>
  printf 'EXACT_MATCH_SWEEP=%s ROOTS=%s FILES=%s GUARDS=%s REASON=%s\n' \
    "$1" "$2" "$3" "$4" "$5"
}

# --- Enumerate candidate files ----------------------------------------------
ROOTS_RESOLVED=0
CANDIDATES=()
declare -A SEEN=()

for root in "${TEST_PATHS[@]}"; do
  [ -n "$root" ] || continue
  [ -e "$root" ] || continue
  ROOTS_RESOLVED=$((ROOTS_RESOLVED + 1))
  if [ -d "$root" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -z "${SEEN[$f]:-}" ]; then
        SEEN[$f]=1
        CANDIDATES+=("$f")
      fi
    done < <(find "$root" -type f -not -path '*/.git/*' -not -path '*/__pycache__/*' 2>/dev/null | LC_ALL=C sort)
  else
    if [ -z "${SEEN[$root]:-}" ]; then
      SEEN[$root]=1
      CANDIDATES+=("$root")
    fi
  fi
done

if [ "$ROOTS_RESOLVED" -eq 0 ]; then
  emit_summary error 0 0 0 no-test-root
  exit 3
fi

# Keep only non-empty TEXT files (binaries are skipped: `grep -I` treats a binary
# file as containing no matching data, and an empty file matches nothing).
TEXT_FILES=()
if [ "${#CANDIDATES[@]}" -gt 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    TEXT_FILES+=("$f")
  done < <(printf '%s\0' "${CANDIDATES[@]}" | LC_ALL=C xargs -0 grep -lI . -- 2>/dev/null)
fi

if [ "${#TEXT_FILES[@]}" -eq 0 ]; then
  emit_summary error "$ROOTS_RESOLVED" 0 0 no-test-files
  exit 3
fi

# --- Scan --------------------------------------------------------------------
# Logical-line assembly: from the first `assertEqual(` on a physical line, count
# `(` minus `)`; while the balance is > 0 pull in up to 4 further lines. Consumed
# lines are NOT rescanned (a call is never double-reported), but class/def
# markers on them are still recorded for symbol tracking. LINE= is always the
# physical line number of the `assertEqual(`.
AWK_PROG='
function bal_of(s,   i, n, c, b) {
  b = 0; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "(") b++
    else if (c == ")") b--
  }
  return b
}
function norm(t) {
  gsub(/^[ \t\r]+/, "", t)
  gsub(/[ \t\r]+$/, "", t)
  gsub(/[ \t\r]+/, "_", t)
  if (t == "") return "-"
  if (length(t) > 60) t = substr(t, 1, 60)
  return t
}
function subject_of(s,   rest, i, n, ch, d, cut) {
  # s starts at "assertEqual(" (12 chars); walk the arg list for the top-level comma.
  rest = substr(s, 13)
  d = 0; cut = -1; n = length(rest)
  for (i = 1; i <= n; i++) {
    ch = substr(rest, i, 1)
    if (ch == "(" || ch == "[" || ch == "{") d++
    else if (ch == ")" || ch == "]" || ch == "}") { if (d == 0) break; d-- }
    else if (ch == "," && d == 0) { cut = i; break }
  }
  if (cut < 0) return "-"
  return norm(substr(rest, 1, cut - 1))
}
function ident(line, kw,   pre, s) {
  pre = "^[ \t]*" kw "[ \t]+"
  if (match(line, pre "[A-Za-z_][A-Za-z0-9_]*") == 0) return ""
  s = substr(line, RSTART, RLENGTH)
  sub(pre, "", s)
  return s
}
function track(line, ln,   s) {
  s = ident(line, "class")
  if (s != "") { cls = s; clsline = ln }
  s = ident(line, "def")
  if (s != "") { fn = s; fnline = ln }
}
function symbol_now() {
  if (cls != "" && fn != "" && clsline < fnline) return cls "." fn
  if (fn != "") return fn
  if (cls != "") return cls
  return "-"
}
BEGIN { curfile = ""; cls = ""; clsline = 0; fn = ""; fnline = 0 }
{
  if (FILENAME != curfile) {
    curfile = FILENAME; cls = ""; clsline = 0; fn = ""; fnline = 0
  }
  track($0, FNR)
  p = index($0, "assertEqual(")
  if (p == 0) next
  startline = FNR
  buf = substr($0, p)
  bal = bal_of(buf)
  extra = 0
  while (bal > 0 && extra < 4) {
    if ((getline nxt) <= 0) break
    if (FILENAME != curfile) break
    extra++
    track(nxt, FNR)
    buf = buf " " nxt
    bal = bal_of(buf)
  }
  kind = ""
  if (buf ~ /assertEqual\([[:space:]]*set\(/ && buf ~ /,[[:space:]]*\{/) kind = "keyset"
  else if (buf ~ /assertEqual\(.+,[[:space:]]*(\[|\{)/) kind = "literal"
  if (kind != "")
    printf "EXACT_MATCH_GUARD=%s FILE=%s LINE=%d SYMBOL=%s SUBJECT=%s\n", \
      kind, curfile, startline, symbol_now(), subject_of(buf)
}
'

GUARD_OUT=$(printf '%s\0' "${TEXT_FILES[@]}" | xargs -0 awk "$AWK_PROG" 2>/dev/null)

GUARDS=0
if [ -n "$GUARD_OUT" ]; then
  printf '%s\n' "$GUARD_OUT"
  GUARDS=$(printf '%s\n' "$GUARD_OUT" | grep -c '^EXACT_MATCH_GUARD=')
fi

emit_summary ok "$ROOTS_RESOLVED" "${#TEXT_FILES[@]}" "$GUARDS" swept
exit 0
