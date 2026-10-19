#!/bin/bash
set -uo pipefail
#
# tests/test-evaluate-issue-plan-mass-budget.sh — the plan evaluator's mass budget.
#
# evaluate-issue-plan/SKILL.md is loaded on every plan-eval dispatch, so the
# body carries only RULES: citations, history and rationale live in
# docs/evaluate-issue-plan-design-notes.md, and multi-command shell lives in
# scripts/evaluate-issue-plan-*.sh behind one call. Modelled on
# tests/test-fullsend-mass-budget.sh.
#
#   E1  BODY (frontmatter stripped) <= 1300 words and >= 1000 (non-vacuous)
#   E2  zero `#NNN`/`#NNNN` issue citations in the body outside `## Boot`'s fence
#   E3  every bash fence is ONE command (Boot excepted); a heredoc body and its
#       `)"` closer belong to the enclosing command
#   E4  the verdict-template, label-flip, dispatch and report literals survive
#   E5  each scripts/evaluate-issue-plan-*.sh helper is invoked in the body,
#       exists, is executable, and answers --help with rc 0
#   E6  docs/evaluate-issue-plan-design-notes.md exists and carries the citations

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/evaluate-issue-plan/SKILL.md"
NOTES="$ROOT/docs/evaluate-issue-plan-design-notes.md"
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
scenario "E1: body word budget"

BW="$(printf '%s\n' "$BODY" | wc -w | tr -d ' ')"
if [ "$BW" -le 1300 ]; then pass_msg "SKILL.md body $BW <= 1300 words"; else fail_msg "SKILL.md body $BW > 1300 words"; fi
if [ "$BW" -ge 1000 ]; then pass_msg "SKILL.md body $BW >= 1000 words (non-vacuous)"; else fail_msg "SKILL.md body $BW < 1000 words — gutted"; fi

# ---------------------------------------------------------------------------
scenario "E2: zero issue citations in the body"

HITS="$(body_minus_boot_fence | grep -noE '#[0-9]{3,4}\b' || true)"
if [ -z "$HITS" ]; then pass_msg "body carries zero #NNN citations outside the Boot fence"; else
  fail_msg "body carries $(printf '%s\n' "$HITS" | grep -c .) citation(s): $(printf '%s ' $HITS | cut -c1-200)"; fi

# ---------------------------------------------------------------------------
scenario "E3: every bash fence is one command"

OFF="$(multi_cmd_fences "$SKILL" 1)"
if [ -z "$OFF" ]; then pass_msg "SKILL.md: no multi-command bash fence"; else fail_msg "SKILL.md multi-command fence(s) at line:count $(printf '%s ' $OFF)"; fi

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
scenario "E4: contract literals survive"

for lit in \
  '## Plan Evaluation' \
  '**Verdict:** Approve / Revise' \
  '**Scope:** patch | structural' \
  '**Recommendations:**' \
  '**Guard claims verified:**' \
  'transition-issue.sh' \
  '--to plan-reviewed --from plan-pending' \
  'resolve-stage-model.sh' \
  'REASON=' \
  'HARNESS-FRICTION:'; do
  case "$BODY" in
    *"$lit"*) pass_msg "literal present: $lit" ;;
    *) fail_msg "literal missing: $lit" ;;
  esac
done

# ---------------------------------------------------------------------------
scenario "E5: helpers invoked, present, executable, and answer --help"

for h in opener-gate fetch-plan; do
  f="$ROOT/scripts/evaluate-issue-plan-$h.sh"
  case "$BODY" in
    *"scripts/evaluate-issue-plan-$h.sh"*) pass_msg "body invokes scripts/evaluate-issue-plan-$h.sh" ;;
    *) fail_msg "body does not invoke scripts/evaluate-issue-plan-$h.sh" ;;
  esac
  if [ -f "$f" ] && [ -x "$f" ] && bash "$f" --help >/dev/null 2>&1; then
    pass_msg "evaluate-issue-plan-$h.sh exists, is executable, and --help rc 0"
  else
    fail_msg "evaluate-issue-plan-$h.sh missing, not executable, or --help rc != 0"
  fi
done

# ---------------------------------------------------------------------------
scenario "E6: rationale archived"

if [ -f "$NOTES" ] && grep -qE '#[0-9]{3,4}' "$NOTES"; then pass_msg "docs/evaluate-issue-plan-design-notes.md exists and carries citations"; else fail_msg "docs/evaluate-issue-plan-design-notes.md missing or citation-free"; fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
