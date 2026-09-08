#!/bin/bash
set -uo pipefail

# Regression guard for issue #1239 — the issue-body / plan-comment path
# extractor must live in exactly ONE place, `scripts/_extract-body-paths.sh`,
# sourced by BOTH `scripts/plan-waves.sh` and
# `scripts/path-b-execute-eligible.sh`.
#
# Background: #1230 (PR #1236) fixed two defects in `plan-waves.sh`'s extractor
#   (a) unnormalized paths — the shallow form `plan-issue/SKILL.md` and the deep
#       form `skills/plan-issue/SKILL.md` never string-matched;
#   (b) junk-token harvesting — `**RED/GREEN`, `rjskene/work-orchestrator#1537`.
# `path-b-execute-eligible.sh` carries its OWN copy of that extractor and
# inherited NEITHER fix. Its `ELIGIBLE=<low-blast|high-blast>` verdict is derived
# from the path set that extractor produces, so under
# `PIPELINE_PATH_B_ELIGIBLE_SCOPE=low-blast` markdown emphasis in an issue body
# pins Opus. The DUPLICATION is the defect; patching the copy recreates the
# drift on the next fix (precedent: #1039 / `scripts/_high-uncertainty-match.sh`).
#
# Case map (the IDs the split-role GREEN implementer greens):
#   B1-B6  helper unit cases over `bp_body_paths` / `bp_plan_files`
#   P1-P2  `plan-waves.sh` parity + conflict-detection control
#   E1-E3  `path-b-execute-eligible.sh` inherits normalization + junk rejection
#   S1     sweep lock — no third copy of the extractor under scripts/
#
# Harness: `gh` is replaced by a PATH-resident shim reading canned JSON from
# $GH_ISSUE_DIR/<N>.json (lifted from tests/test-plan-waves-path-normalization.sh
# lines 47-70; its arg-token `comments` branch also serves
# path-b-execute-eligible.sh's `--json title,body,labels` call). A HERMETIC
# fixture git repo is built under $TMP/repo and BOTH helpers are invoked from
# inside it, so `git ls-files` normalization resolves against a KNOWN index and
# never against the real working tree — load-bearing for the E-group, which
# today runs against the live tree.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTRACTOR="$REPO_ROOT/scripts/_extract-body-paths.sh"
PLAN_WAVES="$REPO_ROOT/scripts/plan-waves.sh"
PATH_B="$REPO_ROOT/scripts/path-b-execute-eligible.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$EXTRACTOR" ]; then
  echo "  (shared extractor does not exist yet at $EXTRACTOR — the B/E/S groups FAIL by design until implementation)"
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
# Args look like: issue view 42 --repo owner/repo --json number,title,body,labels
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  n="$3"
  for a in "$@"; do
    if [ "$a" = "comments" ]; then
      f="$GH_ISSUE_DIR/$n.comments.json"
      if [ -f "$f" ]; then cat "$f"; exit 0; fi
      echo '{"comments":[]}'; exit 0
    fi
  done
  f="$GH_ISSUE_DIR/$n.json"
  if [ -f "$f" ]; then
    cat "$f"
    exit 0
  fi
  echo "shim: no canned JSON for issue $n" >&2
  exit 1
fi
echo "shim: unrecognized call: $*" >&2
exit 2
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="rjskene/pipeline"

# Helper: write a canned issue JSON. Args: dir, number, priority_label, body
write_issue() {
  local dir="$1" num="$2" prio="$3" body="$4"
  local labels='[]'
  if [ -n "$prio" ]; then
    labels=$(printf '[{"name":"%s"}]' "$prio")
  fi
  jq -n \
    --arg num "$num" \
    --arg body "$body" \
    --argjson labels "$labels" \
    '{number: ($num|tonumber), title: ("issue " + $num), body: $body, labels: $labels}' \
    > "$dir/$num.json"
}

# ---- Hermetic fixture repo -------------------------------------------------
# Only the INDEX matters (`git ls-files` reads it), so no commit is needed —
# which is also why this file needs no git identity stamp.
R="$TMP/repo"
mkdir -p "$R/skills/plan-issue" "$R/agents"
: > "$R/skills/plan-issue/SKILL.md"
: > "$R/agents/tdd-implementer.md"
git -C "$R" init -q
git -C "$R" add skills/plan-issue/SKILL.md agents/tdd-implementer.md

# Both call sites run under `set -euo pipefail`, so the shared helper is
# exercised under strict mode too: a zero-match `grep` inside it must yield
# empty output, never abort the caller.
# shellcheck disable=SC1090  # $EXTRACTOR is the system under test, resolved at runtime
run_bp()         { ( set -euo pipefail; cd "$R" && . "$EXTRACTOR" && "$@" ) 2>>"$TMP/bp.err"; }
run_plan_waves() { ( cd "$R" && bash "$PLAN_WAVES" "$@" ); }
run_path_b()     { ( cd "$R" && bash "$PATH_B" "$@" ); }

# Exact-entry helper. Substring checks would FALSE-PASS here, because
# `skills/plan-issue/SKILL.md` CONTAINS `plan-issue/SKILL.md`.
has_entry()  { printf '%s\n' "$1" | grep -Fxq -- "$2"; }
edge_files() { printf '%s\n' "$1" | grep -E "^EDGE #$2 " | sed -E 's/.* files=//' | head -1 || true; }
line_count() { printf '%s\n' "$1" | grep -c . || true; }
dump()       { printf '%s\n' "$2" | sed "s/^/    $1 /"; }

S="$TMP/slate"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"

# ---- Shared fixture body ---------------------------------------------------
# ONE input drives the B, P and E groups, so the parity claim is about a single
# body rather than three hand-tuned ones. Carries BOTH path-depth variants of
# the same file plus the two junk shapes from the #1230 repro.
#
# The `## Affected areas` block is REQUIRED for the junk cases to be
# non-vacuous: the backtick stream does NOT whitespace-split, so a bolded prose
# token only reaches the extractor through the Affected-areas path.
#
# Expected normalized set after the fix: exactly `skills/plan-issue/SKILL.md`.
BODY_DUP='Deep form `skills/plan-issue/SKILL.md` and shallow `plan-issue/SKILL.md`.
Filed from `rjskene/work-orchestrator#1537` in `rjskene/work-orchestrator`.

## Affected areas

- **RED/GREEN** ledger prose in the plan template
- `skills/plan-issue/SKILL.md`
- `plan-issue/SKILL.md`
'

# Junk-only body: every extractable token is a rejected shape, so a correct
# extractor yields an EMPTY path set.
BODY_JUNK='Filed from `rjskene/work-orchestrator#1537` in `rjskene/work-orchestrator`.

## Affected areas

- **RED/GREEN** ledger prose in the plan template
- `rjskene/work-orchestrator#1537` cross-repo reference
'

# Untracked-path control body: neither path exists in the fixture index.
BODY_NEW='Adds `tests/test-brand-new-1239.sh` plus `docs/split-role-tdd.md`; neither is in the tree yet.'

# Two single-form bodies for the P2 conflict control.
BODY_DEEP='Deep form only. Edits `skills/plan-issue/SKILL.md`.'
BODY_SHALLOW='Shallow form only. Edits `plan-issue/SKILL.md`.'

# Plan-comment body for B6: one backticked path, one BARE path, and one
# backticked reason SYMBOL that must not be harvested.
PLAN_BODY_B6='## Implementation Plan

**Files to change:**
- `plan-issue/SKILL.md` — shallow backticked form, must normalize deep
- agents/tdd-implementer.md — bare path, no backticks
- `data.map` — a reason symbol, not a file

**Tasks (ordered):**
- Task 1: `sort` and `next_due` are symbols too
'

write_issue "$S" 1 "priority/P2" "$BODY_DUP"
write_issue "$S" 2 "priority/P2" "$BODY_JUNK"
write_issue "$S" 3 "priority/P2" "$BODY_DEEP"
write_issue "$S" 4 "priority/P2" "$BODY_SHALLOW"

EXPECTED_DUP_SET="skills/plan-issue/SKILL.md"

# ============================================================================
# B group — shared helper unit cases
# ============================================================================

# ---- B1: the helper is sourceable and exports the documented API ------------
echo "B1: scripts/_extract-body-paths.sh is sourceable and defines the extractor API"
inc
# shellcheck disable=SC1090  # $EXTRACTOR is the system under test, resolved at runtime
B1_OUT=$( ( set -uo pipefail; cd "$R" && . "$EXTRACTOR" && {
    [ -n "${FILE_PATH_RE:-}" ] && echo "var:FILE_PATH_RE"
    [ -n "${FILE_EXT_RE:-}" ]  && echo "var:FILE_EXT_RE"
    for f in bp_normalize_tokens bp_body_paths bp_plan_files; do
      declare -F "$f" >/dev/null 2>&1 && echo "fn:$f"
    done
    true
  } ) 2>"$TMP/b1.err" ) || true
B1_MISSING=""
for tok in var:FILE_PATH_RE var:FILE_EXT_RE fn:bp_normalize_tokens fn:bp_body_paths fn:bp_plan_files; do
  has_entry "$B1_OUT" "$tok" || B1_MISSING="$B1_MISSING $tok"
done
if [ -z "$B1_MISSING" ]; then
  pass_msg "B1: FILE_PATH_RE, FILE_EXT_RE, bp_normalize_tokens, bp_body_paths, bp_plan_files all present"
else
  fail_msg "B1: missing from the sourced helper:$B1_MISSING"
  echo "    expected a sourceable $EXTRACTOR"
  dump "stderr:" "$(cat "$TMP/b1.err" 2>/dev/null)"
fi

# ---- B2: shallow path form normalizes onto the repo-root-relative path ------
echo "B2: bp_body_paths normalizes the shallow form onto skills/plan-issue/SKILL.md"
inc
B2_OUT=$(run_bp bp_body_paths "$BODY_DUP")
if has_entry "$B2_OUT" "skills/plan-issue/SKILL.md" \
   && ! has_entry "$B2_OUT" "plan-issue/SKILL.md"; then
  pass_msg "B2: deep path emitted, bare shallow path absent"
else
  fail_msg "B2: expected exact entry 'skills/plan-issue/SKILL.md' and NO exact 'plan-issue/SKILL.md'"
  dump "got:" "$B2_OUT"
fi

# ---- B3: junk tokens are rejected -------------------------------------------
echo "B3: bp_body_paths rejects bolded prose and cross-repo reference tokens"
inc
B3_OUT=$(run_bp bp_body_paths "$BODY_DUP")
if [ -n "$B3_OUT" ] \
   && ! printf '%s\n' "$B3_OUT" | grep -q 'RED/GREEN' \
   && ! printf '%s\n' "$B3_OUT" | grep -q 'work-orchestrator'; then
  pass_msg "B3: no RED/GREEN prose token and no rjskene/work-orchestrator ref"
else
  fail_msg "B3: junk token leaked (or the extractor produced nothing at all)"
  dump "got:" "$B3_OUT"
fi

# ---- B4: existence RESOLVES, never DROPS (control) --------------------------
echo "B4: paths absent from the tree index survive extraction verbatim"
inc
B4_OUT=$(run_bp bp_body_paths "$BODY_NEW")
if has_entry "$B4_OUT" "tests/test-brand-new-1239.sh" \
   && has_entry "$B4_OUT" "docs/split-role-tdd.md"; then
  pass_msg "B4: untracked planned paths preserved verbatim"
else
  fail_msg "B4: an untracked planned path was dropped — existence must RESOLVE, never DROP"
  dump "got:" "$B4_OUT"
fi

# ---- B5: dedup ---------------------------------------------------------------
echo "B5: the two depth variants of one file collapse to exactly one entry"
inc
B5_OUT=$(run_bp bp_body_paths "$BODY_DUP")
B5_N=$(line_count "$B5_OUT")
if [ "${B5_N:-0}" = "1" ]; then
  pass_msg "B5: bp_body_paths emitted exactly 1 line"
else
  fail_msg "B5: expected exactly 1 emitted line, got ${B5_N:-0}"
  dump "got:" "$B5_OUT"
fi

# ---- B6: bp_plan_files handles the **Files to change:** block ---------------
echo "B6: bp_plan_files reads the **Files to change:** block, backticked and bare"
inc
B6_OUT=$(run_bp bp_plan_files "$PLAN_BODY_B6")
if has_entry "$B6_OUT" "skills/plan-issue/SKILL.md" \
   && has_entry "$B6_OUT" "agents/tdd-implementer.md" \
   && ! printf '%s\n' "$B6_OUT" | grep -q 'data\.map' \
   && ! has_entry "$B6_OUT" "plan-issue/SKILL.md"; then
  pass_msg "B6: both paths normalized; reason symbol data.map rejected"
else
  fail_msg "B6: expected {skills/plan-issue/SKILL.md, agents/tdd-implementer.md} and no data.map"
  dump "got:" "$B6_OUT"
fi

# ============================================================================
# P group — plan-waves.sh call-site parity
# ============================================================================

# ---- P1: plan-waves emits exactly the shared helper's path set --------------
echo "P1: plan-waves.sh --emit-edges files= equals bp_body_paths on the same body"
inc
P1_EDGES=$(run_plan_waves --stage=execute --emit-edges 1 2>"$TMP/p1.err" || true)
P1_ACTUAL=$(edge_files "$P1_EDGES" 1 | tr ',' '\n' | sed '/^[[:space:]]*$/d' | sort)
P1_EXPECT=$(run_bp bp_body_paths "$BODY_DUP" | sed '/^[[:space:]]*$/d' | sort)
if [ -n "$P1_EXPECT" ] && [ "$P1_ACTUAL" = "$P1_EXPECT" ]; then
  pass_msg "P1: call-site path set is line-for-line the helper's output"
else
  fail_msg "P1: plan-waves files= diverges from bp_body_paths (or the helper emitted nothing)"
  dump "plan-waves:" "$P1_ACTUAL"
  dump "helper:" "$P1_EXPECT"
  dump "edges:" "$P1_EDGES"
fi

# ---- P2: the real shared-file conflict is still detected (control) ----------
# Expected GREEN at the RED commit: plan-waves.sh ALREADY normalizes correctly
# post-#1230. This case is the REGRESSION LOCK on the Task 3 refactor — an
# executor seeing it green must NOT conclude Task 3 is unnecessary.
echo "P2: two issues naming the same file at different prefix depths serialize"
inc
P2_OUT=$(run_plan_waves --stage=execute 3 4 2>"$TMP/p2.err" || true)
if printf '%s\n' "$P2_OUT" | grep -E '^Wave 2:' | grep -q 'skills/plan-issue/SKILL\.md'; then
  pass_msg "P2: Wave 2 serialization cites skills/plan-issue/SKILL.md"
else
  fail_msg "P2: expected a 'Wave 2:' line citing skills/plan-issue/SKILL.md"
  dump "stdout:" "$P2_OUT"
fi

# ============================================================================
# E group — path-b-execute-eligible.sh call-site
# ============================================================================

# ---- E1: path-b inherits normalization + junk rejection ---------------------
# Today: `ELIGIBLE=high-blast ISSUE=1 REASON=multi-module` — the shallow/deep
# duplicate plus `**RED/GREEN` and `rjskene/work-orchestrator` present as FOUR
# distinct first-segment "modules".
echo "E1: path-b-execute-eligible.sh scores the deduped single-file body low-blast"
inc
E1_OUT=$(run_path_b 1 2>"$TMP/e1.err" || true)
if printf '%s\n' "$E1_OUT" | grep -qE '^ELIGIBLE=low-blast ISSUE=1 REASON=single-module$'; then
  pass_msg "E1: ELIGIBLE=low-blast ISSUE=1 REASON=single-module"
else
  fail_msg "E1: expected 'ELIGIBLE=low-blast ISSUE=1 REASON=single-module'"
  dump "got:" "$E1_OUT"
fi

# ---- E2: a junk-only body fails closed as indeterminate, not multi-module ---
# Fail-closed posture is preserved AND strengthened: an all-junk body now yields
# an EMPTY path set ⇒ `indeterminate` (the correct fail-closed token) instead of
# `multi-module` (today's right verdict for the wrong reason).
echo "E2: junk-only Affected areas fails closed as indeterminate, not multi-module"
inc
E2_OUT=$(run_path_b 2 2>"$TMP/e2.err" || true)
if printf '%s\n' "$E2_OUT" | grep -qE '^ELIGIBLE=high-blast ISSUE=2 REASON=indeterminate$'; then
  pass_msg "E2: ELIGIBLE=high-blast ISSUE=2 REASON=indeterminate"
else
  fail_msg "E2: expected 'ELIGIBLE=high-blast ISSUE=2 REASON=indeterminate'"
  dump "got:" "$E2_OUT"
fi

# ---- E3: source-path parity behind E1's verdict -----------------------------
# E1 asserts an opaque verdict token; E3 asserts the FACT that verdict rests on,
# so a future divergence between the two call sites fails HERE with a readable
# message rather than as a mystery verdict flip.
echo "E3: the non-test/non-doc subset of the shared path set is one module"
inc
E3_SET=$(run_bp bp_body_paths "$BODY_DUP" \
  | grep -Ev '(^|/)(tests?|fixtures|docs)/' \
  | sed '/^[[:space:]]*$/d' \
  | sort)
E3_MODULES=$(printf '%s\n' "$E3_SET" | sed '/^[[:space:]]*$/d' | sed 's#/.*##' | sort -u | grep -c . || true)
if [ "$E3_SET" = "$EXPECTED_DUP_SET" ] && [ "${E3_MODULES:-0}" = "1" ]; then
  pass_msg "E3: source subset is exactly {$EXPECTED_DUP_SET} — 1 distinct module"
else
  fail_msg "E3: expected source subset '$EXPECTED_DUP_SET' with exactly 1 module, got ${E3_MODULES:-0} module(s)"
  dump "got:" "$E3_SET"
fi

# ============================================================================
# S group — sweep lock
# ============================================================================

# ---- S1: exactly one copy of the extractor under scripts/ -------------------
# Anchored on $REPO_ROOT/scripts, NOT a CWD-relative `scripts/` — a sweep lock
# that silently matches nothing when the suite runs from another directory is
# worse than no lock at all.
echo "S1: the extractor is defined in exactly one file under scripts/"
inc
S1_HITS=$( { grep -rl 'normalize_file_tokens\|FILE_PATH_RE=' "$REPO_ROOT/scripts" 2>/dev/null \
  | sed "s#^$REPO_ROOT/##" \
  | sort; } || true)
if [ "$S1_HITS" = "scripts/_extract-body-paths.sh" ]; then
  pass_msg "S1: only scripts/_extract-body-paths.sh defines the extractor"
else
  fail_msg "S1: expected exactly 'scripts/_extract-body-paths.sh'"
  dump "got:" "$S1_HITS"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
