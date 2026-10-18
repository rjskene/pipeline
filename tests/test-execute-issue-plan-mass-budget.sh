#!/bin/bash
set -uo pipefail
#
# tests/test-execute-issue-plan-mass-budget.sh — the executor's mass budget.
#
# execute-issue-plan/SKILL.md is loaded on every execute dispatch, so the body
# carries only RULES: citations, history and rationale live in
# docs/execute-issue-plan-design-notes.md, and multi-command shell lives in
# scripts/execute-issue-plan-*.sh behind one call. Modelled on
# tests/test-fullsend-mass-budget.sh.
#
#   X1  BODY (frontmatter stripped) <= 2000 words and >= 1500 (non-vacuous)
#   X2  references/*.md total <= 800 words and >= 400 (non-vacuous)
#   X3  zero `#NNN`/`#NNNN` issue citations in the body outside `## Boot`'s fence
#   X4  zero `#NNN`/`#NNNN` issue citations in references/*.md
#   X5  every bash fence is ONE command (body Boot excepted; references too);
#       a heredoc body and its `)"` closer belong to the enclosing command
#   X6  the test-run and --base literals survive
#   X7  each scripts/execute-issue-plan-*.sh helper is invoked in the body,
#       exists, and answers --help with rc 0
#   X8  docs/execute-issue-plan-design-notes.md exists and carries the citations

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/execute-issue-plan/SKILL.md"
REFS_DIR="$ROOT/skills/execute-issue-plan/references"
NOTES="$ROOT/docs/execute-issue-plan-design-notes.md"
# shellcheck source=tests/_lib/skill-body.sh
source "$ROOT/tests/_lib/skill-body.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

[ -f "$SKILL" ] || { echo "ERROR: $SKILL missing" >&2; exit 1; }

BODY="$(skill_body "$SKILL")"

# body_minus_boot_fence: the body with the FIRST bash fence under `## Boot` cut.
body_minus_boot_fence() {
  printf '%s\n' "$BODY" | awk '
    /^## Boot/ { inboot=1 }
    inboot && !seen && /^[[:space:]]*```bash/ { infence=1; seen=1; next }
    infence && /^[[:space:]]*```[[:space:]]*$/ { infence=0; next }
    infence { next }
    { print }
  '
}

# multi_cmd_fences <file> <skipboot> : prints `<line>\t<count>` per bash fence
# holding more than one logical command. A heredoc opener (`<<'EOF'`, `<<EOF`,
# `<<-EOF`) swallows every line through its terminator, and a following line
# starting with `)` (the `)"` closer of `"$(cat <<'EOF'`) joins the same command.
multi_cmd_fences() {
  awk -v skipboot="$2" '
    function is_open(l)  { return l ~ /^[[:space:]]*```bash[[:space:]]*$/ }
    function is_close(l) { return l ~ /^[[:space:]]*```[[:space:]]*$/ }
    /^## Boot/ { inboot=1 }
    /^## / && !/^## Boot/ { inboot=0 }
    {
      if (!inb) { if (is_open($0)) { inb=1; start=FNR; n=0; cont=0; hd=""; closer=0; boot=(inboot && skipboot=="1") } next }
      if (is_close($0)) { if (!boot && n > 1) printf "%d\t%d\n", start, n; inb=0; next }
      l=$0; sub(/^[[:space:]]+/, "", l); sub(/[[:space:]]+$/, "", l)
      if (hd != "") { if (l == hd) { hd=""; closer=1 } next }
      if (closer) { closer=0; if (l ~ /^\)/) { cont = (l ~ /(\\|\||&&)$/); next } }
      if (l == "" || l ~ /^#/) next
      if (!cont) n++
      if (match(l, /<<-?[\047"]?[A-Za-z_][A-Za-z0-9_]*/)) {
        t = substr(l, RSTART, RLENGTH); sub(/^<<-?[\047"]?/, "", t); hd = t
      }
      cont = (l ~ /(\\|\||&&)$/)
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
scenario "X1: body word budget"

BW="$(printf '%s\n' "$BODY" | wc -w | tr -d ' ')"
if [ "$BW" -le 2000 ]; then pass_msg "SKILL.md body $BW <= 2000 words"; else fail_msg "SKILL.md body $BW > 2000 words"; fi
if [ "$BW" -ge 1500 ]; then pass_msg "SKILL.md body $BW >= 1500 words (non-vacuous)"; else fail_msg "SKILL.md body $BW < 1500 words — gutted"; fi

# ---------------------------------------------------------------------------
scenario "X2: references word budget"

RW="$(cat "$REFS_DIR"/*.md | wc -w | tr -d ' ')"
if [ "$RW" -le 800 ]; then pass_msg "references total $RW <= 800 words"; else fail_msg "references total $RW > 800 words"; fi
if [ "$RW" -ge 400 ]; then pass_msg "references total $RW >= 400 words (non-vacuous)"; else fail_msg "references total $RW < 400 words — gutted"; fi

# ---------------------------------------------------------------------------
scenario "X3: zero issue citations in the body"

HITS="$(body_minus_boot_fence | grep -noE '#[0-9]{3,4}\b' || true)"
if [ -z "$HITS" ]; then pass_msg "body carries zero #NNN citations outside the Boot fence"; else
  fail_msg "body carries $(printf '%s\n' "$HITS" | grep -c .) citation(s): $(printf '%s ' $HITS | cut -c1-200)"; fi

# ---------------------------------------------------------------------------
scenario "X4: zero issue citations in references"

RHITS="$(grep -noE '#[0-9]{3,4}\b' "$REFS_DIR"/*.md || true)"
if [ -z "$RHITS" ]; then pass_msg "references carry zero #NNN citations"; else
  fail_msg "references carry $(printf '%s\n' "$RHITS" | grep -c .) citation(s): $(printf '%s ' $RHITS | sed "s|$REFS_DIR/||g" | cut -c1-200)"; fi

# ---------------------------------------------------------------------------
scenario "X5: every bash fence is one command"

OFF="$(multi_cmd_fences "$SKILL" 1)"
if [ -z "$OFF" ]; then pass_msg "SKILL.md: no multi-command bash fence"; else fail_msg "SKILL.md multi-command fence(s) at line:count $(printf '%s ' $OFF)"; fi
for ref in "$REFS_DIR"/*.md; do
  ROFF="$(multi_cmd_fences "$ref" 0)"
  if [ -z "$ROFF" ]; then pass_msg "$(basename "$ref"): no multi-command bash fence"; else fail_msg "$(basename "$ref") multi-command fence(s) at line:count $(printf '%s ' $ROFF)"; fi
done

# Grammar self-test: a two-command fence is caught, a continued one is not, a
# heredoc body + `)"` closer joins its command, and a command AFTER a heredoc
# still counts.
SELF="$(mktemp)"; trap 'rm -f "$SELF"' EXIT
printf '%s\n' \
  '```bash' 'A=1' 'echo "$A"' '```' \
  '```bash' 'bash x.sh \' '  --flag | head -1' '```' \
  '```bash' 'if [ -z "$B" ]; then echo no >&2; exit 1; else \' '  gh pr create \' '    --body "$(cat <<'"'"'EOF'"'"'' '## Summary' 'body text' 'EOF' ')"; fi' '```' \
  '```bash' 'cat <<EOF' 'x' 'EOF' 'echo after' '```' > "$SELF"
if [ "$(multi_cmd_fences "$SELF" 0)" = "$(printf '1\t2\n18\t2')" ]; then pass_msg "fence grammar self-test (2-command caught, continuation + heredoc joined, post-heredoc command counted)"; else fail_msg "fence grammar self-test failed: $(multi_cmd_fences "$SELF" 0 | tr '\n' ' ')"; fi

# ---------------------------------------------------------------------------
scenario "X6: contract literals survive"

for lit in \
  'timeout 600 bash -c "$PIPELINE_TEST_CMD" </dev/null' \
  '--base "$PIPELINE_BASE_BRANCH"'; do
  case "$BODY" in
    *"$lit"*) pass_msg "literal present: $lit" ;;
    *) fail_msg "literal missing: $lit" ;;
  esac
done

# ---------------------------------------------------------------------------
scenario "X7: helpers invoked, present, and answer --help"

for h in fetch-plan pre-pr; do
  f="$ROOT/scripts/execute-issue-plan-$h.sh"
  case "$BODY" in
    *"scripts/execute-issue-plan-$h.sh"*) pass_msg "body invokes scripts/execute-issue-plan-$h.sh" ;;
    *) fail_msg "body does not invoke scripts/execute-issue-plan-$h.sh" ;;
  esac
  if [ -f "$f" ] && bash "$f" --help >/dev/null 2>&1; then
    pass_msg "execute-issue-plan-$h.sh exists and --help rc 0"
  else
    fail_msg "execute-issue-plan-$h.sh missing or --help rc != 0"
  fi
done

# ---------------------------------------------------------------------------
scenario "X8: rationale archived"

if [ -f "$NOTES" ] && grep -qE '#[0-9]{3,4}' "$NOTES"; then pass_msg "docs/execute-issue-plan-design-notes.md exists and carries citations"; else fail_msg "docs/execute-issue-plan-design-notes.md missing or citation-free"; fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
