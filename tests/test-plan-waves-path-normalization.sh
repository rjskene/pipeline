#!/bin/bash
set -euo pipefail

# Regression guard for issue #1230 — `scripts/plan-waves.sh --stage=execute`
# body-substring path extraction must (a) normalize extracted paths to
# repo-root-relative form before conflict comparison, and (b) reject tokens that
# are not plausible file paths (bolded prose, cross-repo `<owner>/<repo>` and
# `<owner>/<repo>#<n>` references).
#
# Observed defect (nightly meta-campaign, 2026-08-20, slate #1224/#1225):
#   EDGE #1224 ... files=**RED/GREEN,RED/GREEN,...,skills/plan-issue/SKILL.md,...
#   EDGE #1225 ... files=agents/tdd-implementer.md,plan-issue/SKILL.md,
#                        rjskene/work-orchestrator,rjskene/work-orchestrator#1537
# Both issues edit the SAME file, but the deep form (`skills/plan-issue/SKILL.md`)
# and the shallow form (`plan-issue/SKILL.md`) never string-match, so the real
# conflict was silently dropped and both issues were grouped into ONE parallel
# wave. Conversely the junk `rjskene/work-orchestrator` token is shared by any
# two issues filed from that repo, producing SPURIOUS conflicts.
#
# Also guarded here (same run, cosmetic): the `Wave N:` line hardcodes the verb
# `classify` regardless of `--stage`, so an execute-stage wave plan reads as a
# classify-stage one.
#
# Harness: `gh` is replaced by a PATH-resident shim reading canned JSON from
# $GH_ISSUE_DIR/<N>.json, mirroring tests/test-plan-waves-emit-edges.sh.
# Additionally a HERMETIC fixture git repo is built under $TMP/repo and the
# helper is invoked from inside it, so normalization resolves against a known
# `git ls-files` index rather than the real working tree.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/plan-waves.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$HELPER" ]; then
  echo "  (helper does not exist yet at $HELPER — every case will FAIL by design until implementation)"
fi

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
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

# Run the helper from INSIDE the fixture repo so `git rev-parse --show-toplevel`
# resolves to $R and normalization is independent of the real working tree.
run_helper() { ( cd "$R" && bash "$HELPER" "$@" ); }

# Exact-entry helpers. Substring checks would FALSE-PASS here, because
# `skills/plan-issue/SKILL.md` CONTAINS `plan-issue/SKILL.md`.
edge_files() { echo "$1" | grep -E "^EDGE #$2 " | sed -E 's/.* files=//' | head -1 || true; }
has_entry()  { echo "$1" | tr ',' '\n' | grep -Fxq -- "$2"; }

# ---- Fixture slate (lifted from the real #1224 / #1225 repro) --------------
S="$TMP/slate"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"

BODY1='Deep form. Edits `skills/plan-issue/SKILL.md` and `docs/split-role-tdd.md`. Adds `tests/test-brand-new-1230.sh`.'

# The `## Affected areas` block is REQUIRED for A2 to be non-vacuous:
# FROM_BACKTICKS does NOT whitespace-split, so a bolded prose token only reaches
# the extractor through the Affected-areas path.
BODY2='Shallow form: `plan-issue/SKILL.md` emits a canonical closing task. Filed from `rjskene/work-orchestrator#1537` in `rjskene/work-orchestrator`. Also `agents/tdd-implementer.md`.

## Affected areas

- **RED/GREEN** ledger prose in the plan template
- `plan-issue/SKILL.md` (shallow form, same file as #1)
'

BODY3='Unrelated A. Filed from `rjskene/work-orchestrator`. Touches `scripts/alpha-1230.sh`.'
BODY4='Unrelated B. Filed from `rjskene/work-orchestrator`. Touches `scripts/beta-1230.sh`.'

write_issue "$S" 1 "priority/P2" "$BODY1"
write_issue "$S" 2 "priority/P2" "$BODY2"
write_issue "$S" 3 "priority/P2" "$BODY3"
write_issue "$S" 4 "priority/P2" "$BODY4"

EDGE12=$(run_helper --stage=execute --emit-edges 1 2 2>"$S/stderr-edges" || true)
F1=$(edge_files "$EDGE12" 1)
F2=$(edge_files "$EDGE12" 2)

# ---- A1: shallow path form normalizes onto the repo-root-relative path ------
echo "A1: shallow \`plan-issue/SKILL.md\` normalizes to \`skills/plan-issue/SKILL.md\`"
inc
if has_entry "$F2" "skills/plan-issue/SKILL.md" \
   && ! has_entry "$F2" "plan-issue/SKILL.md"; then
  pass_msg "A1: #2 files carry the normalized deep path and NOT the shallow form"
else
  fail_msg "A1: expected normalized 'skills/plan-issue/SKILL.md' and no bare 'plan-issue/SKILL.md'"
  echo "    F2: [$F2]"
  echo "    edges:"; echo "$EDGE12" | sed 's/^/      /'
fi

# ---- A2: junk tokens are rejected ------------------------------------------
echo "A2: bolded prose and cross-repo references are not harvested as paths"
inc
if ! echo "$F2" | grep -q 'RED/GREEN' \
   && ! echo "$F2" | grep -q 'work-orchestrator'; then
  pass_msg "A2: no RED/GREEN prose token and no rjskene/work-orchestrator ref in #2 files"
else
  fail_msg "A2: junk tokens leaked into #2 files"
  echo "    F2: [$F2]"
  echo "    edges:"; echo "$EDGE12" | sed 's/^/      /'
fi

# ---- A3: existence is used to RESOLVE, never to DROP (control) -------------
echo "A3: paths absent from the tree survive extraction (new files still conflict-checked)"
inc
if has_entry "$F1" "tests/test-brand-new-1230.sh" \
   && has_entry "$F1" "docs/split-role-tdd.md"; then
  pass_msg "A3: untracked planned paths preserved verbatim in #1 files"
else
  fail_msg "A3: an untracked planned path was dropped from #1 files"
  echo "    F1: [$F1]"
  echo "    edges:"; echo "$EDGE12" | sed 's/^/      /'
fi

# ---- A4: the REAL shared-file conflict is detected --------------------------
# Verb-agnostic on purpose — A6/A8 own the verb contract.
echo "A4: two issues naming the same file at different prefix depths serialize"
inc
OUT12=$(run_helper --stage=execute 1 2 2>"$S/stderr-12" || true)
if echo "$OUT12" | grep -qE '^Wave 2: .*#2.*shares.*skills/plan-issue/SKILL\.md.*#1'; then
  pass_msg "A4: #2 deferred to Wave 2 — shares skills/plan-issue/SKILL.md with #1"
else
  fail_msg "A4: expected a Wave 2 serialization citing skills/plan-issue/SKILL.md"
  echo "    stdout:"; echo "$OUT12" | sed 's/^/      /'
fi

# ---- A5: no SPURIOUS conflict from a shared cross-repo reference (control) --
echo "A5: two unrelated issues filed from the same repo stay in one wave"
inc
OUT34=$(run_helper --stage=execute 3 4 2>"$S/stderr-34" || true)
if echo "$OUT34" | grep -qE '^Wave 1: [a-z]+ #3, #4 in parallel$' \
   && ! echo "$OUT34" | grep -qE '^Wave 2:'; then
  pass_msg "A5: #3 and #4 share Wave 1; rjskene/work-orchestrator is not a conflict"
else
  fail_msg "A5: spurious serialization from a non-path token"
  echo "    stdout:"; echo "$OUT34" | sed 's/^/      /'
fi

# ---- A6: the Wave verb reflects --stage=execute -----------------------------
echo "A6: --stage=execute prints 'Wave 1: execute ...'"
inc
if echo "$OUT34" | grep -qE '^Wave 1: execute #3, #4 in parallel$'; then
  pass_msg "A6: execute-stage wave line carries the 'execute' verb"
else
  fail_msg "A6: expected '^Wave 1: execute #3, #4 in parallel$'"
  echo "    stdout:"; echo "$OUT34" | sed 's/^/      /'
fi

# ---- A7: --stage=classify still prints 'classify' (control) -----------------
echo "A7: --stage=classify still prints 'Wave 1: classify ...'"
inc
OUT34C=$(run_helper --stage=classify 3 4 2>"$S/stderr-34c" || true)
if echo "$OUT34C" | grep -qE '^Wave 1: classify #3, #4 in parallel$'; then
  pass_msg "A7: classify-stage wave line unchanged"
else
  fail_msg "A7: expected '^Wave 1: classify #3, #4 in parallel$'"
  echo "    stdout:"; echo "$OUT34C" | sed 's/^/      /'
fi

# ---- A8: --stage=plan prints 'plan' -----------------------------------------
echo "A8: --stage=plan prints 'Wave 1: plan ...'"
inc
OUT34P=$(run_helper --stage=plan 3 4 2>"$S/stderr-34p" || true)
if echo "$OUT34P" | grep -qE '^Wave 1: plan #3, #4 in parallel$'; then
  pass_msg "A8: plan-stage wave line carries the 'plan' verb"
else
  fail_msg "A8: expected '^Wave 1: plan #3, #4 in parallel$'"
  echo "    stdout:"; echo "$OUT34P" | sed 's/^/      /'
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
