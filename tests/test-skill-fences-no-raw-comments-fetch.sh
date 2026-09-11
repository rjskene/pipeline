#!/bin/bash
set -euo pipefail

# Regression guard (#1315): no ```bash fence in skills/*/SKILL.md may spell the
# raw comment-fetch form that hooks/enforce-comment-trust.py (#549) hard-denies
# — `gh issue|pr view ... --json <fields>` with `comments` among the fields.
# Every comment read in a skill fence must route through #545's
# scripts/filter-trusted-comments.sh (`--json <N>` for a JSON document,
# default `<N>` for plaintext) so the hook's allow-by-helper exemption fires
# and the trust boundary stays in ONE place.
#
# The sweep mirrors the hook's own two regexes, FENCE-SCOPED:
#   (a) the line is inside a fence opened by /^[[:space:]]*```bash/ and closed
#       by the next /^[[:space:]]*```/ line — bare ``` prose tables (e.g. the
#       fullsend greenlight matrix, which NAMES `gh pr view --json comments` as
#       auto-merge-gate.sh's source) are not commands and must not trip it;
#   (b) the line matches gh[[:space:]]+(issue|pr)[[:space:]]+view; and
#   (c) the line's FIRST `--json[=[:space:]]+<fields>` list, split on `,`,
#       contains the exact field `comments` (both `--json x,comments` and
#       `--json=x,comments`).
#
# Sibling of tests/test-cage-invariant-enforce-comment-trust.sh (which pins
# the HOOK's deny contract and is untouched); this file pins the SKILLS side.
# S1 is the teeth control: it runs the sweep helper on a fixture holding one
# raw fence, one helper-routed fence and one bare-``` table, so S2's green on
# the live skills is provably non-vacuous.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# sweep <file>... — prints FILE:LINE for every offending line (see header).
# ONE helper shared by the teeth control and the live sweep, never two.
sweep() {
  awk '
    FNR == 1 { in_b = 0 }
    !in_b && /^[[:space:]]*```bash/ { in_b = 1; next }
    in_b && /^[[:space:]]*```/ { in_b = 0; next }
    in_b && /gh[[:space:]]+(issue|pr)[[:space:]]+view/ {
      if (match($0, /--json[=[:space:]]+[A-Za-z0-9_,]+/)) {
        fields = substr($0, RSTART, RLENGTH)
        sub(/^--json[=[:space:]]+/, "", fields)
        n = split(fields, parts, ",")
        for (i = 1; i <= n; i++) {
          if (parts[i] == "comments") { print FILENAME ":" FNR; break }
        }
      }
    }
  ' "$@"
}

# ---------------------------------------------------------------------------
# S1 — teeth control. Three fences; exactly ONE must be reported.
# ---------------------------------------------------------------------------
echo '=== S1: sweep helper flags the raw ```bash fence and nothing else ==='
inc
FIXTURE="$TMP/fixture.md"
cat > "$FIXTURE" <<'MD'
# fixture

```bash
X=$(gh issue view 1 --repo o/r --json comments \
  | jq '.comments | length')
```

Helper-routed (allowed):

```bash
Y=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" --json 1)
```

Prose table, bare fence (not a command):

```
| # | Condition | Source                     |
|---|-----------|----------------------------|
| 1 | Approved  | gh pr view --json comments |
```

Outside any fence: gh pr view --json comments is only mentioned here.
MD
# Line of the raw fence body, located mechanically so the fixture can be
# edited without hand-counting.
RAW_LINE=$(grep -nF 'X=$(gh issue view 1' "$FIXTURE" | cut -d: -f1)
EXPECTED="$FIXTURE:$RAW_LINE"
GOT=$(sweep "$FIXTURE" || true)
if [ -n "$RAW_LINE" ] && [ "$GOT" = "$EXPECTED" ]; then
  pass_msg "S1: sweep printed exactly '$EXPECTED' (raw fence flagged; helper fence + bare-\`\`\` table + prose ignored)"
else
  fail_msg "S1: expected exactly '$EXPECTED'; got:"
  printf '%s\n' "$GOT" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
# S2 — the live sweep over every skill.
# ---------------------------------------------------------------------------
echo "=== S2: no \`\`\`bash fence in skills/*/SKILL.md spells the hook-denied comment fetch ==="
inc
HITS=$(sweep "$REPO_ROOT"/skills/*/SKILL.md || true)
if [ -z "$HITS" ]; then
  pass_msg "S2: every skill fence routes comment reads through filter-trusted-comments.sh"
else
  fail_msg "S2: raw \`gh issue|pr view --json ...comments...\` fence lines (hook-denied at runtime):"
  printf '%s\n' "$HITS" | sed "s#^$REPO_ROOT/##; s/^/      /"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Ran $TESTS tests: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
