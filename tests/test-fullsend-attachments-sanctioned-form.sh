#!/bin/bash
set -euo pipefail

# Guard (#1357): skill text must not drift back to a bare direct
# `fetch-issue-attachments.sh` call inside a fenced bash block — the
# enforce-comment-trust.py PreToolUse hook hard-denies that form (#1340).
# The sanctioned entry point is `scripts/filter-trusted-comments.sh
# fetch-attachments <N>`.
#
# (a) fenced-bash scanner over skills/**/*.md with positive/negative fixture
#     controls proving the scanner logic;
# (b) prose-drift assertions: the fullsend Step 1a / plan-issue 3b /
#     CLAUDE.md `.claude/scratch/` prose lines must NAME the sanctioned form
#     so the description cannot contradict the fence beneath it.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
nope() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# scan_fences <file>
# Prints `file:NR: line` for every line inside a ```bash / ```sh / ```shell
# fence that mentions the bare fetch-issue-attachments.sh token. Untagged /
# other-language fences (hook-output samples, pseudo-flow diagrams) are not
# commands and are deliberately out of scope.
scan_fences() {
  local f="$1"
  awk -v file="$f" '
    /^[[:space:]]*```/ {
      if (infence) {
        infence = 0; isbash = 0
      } else {
        infence = 1
        info = $0
        sub(/^[[:space:]]*```/, "", info)
        isbash = (info ~ /^(bash|sh|shell)([[:space:]]|$)/) ? 1 : 0
      }
      next
    }
    infence && isbash && /fetch-issue-attachments\.sh/ { print file ":" NR ": " $0 }
  ' "$f"
}

# --- Fixture controls -------------------------------------------------------
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

cat >"$FIX/pos.md" <<'EOF'
Prose mentioning fetch-issue-attachments.sh in a sentence is fine.
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/fetch-issue-attachments.sh" "$N"
```
EOF

cat >"$FIX/neg.md" <<'EOF'
Prose mentioning fetch-issue-attachments.sh in a sentence is fine.
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" fetch-attachments "$N"
```
EOF

pos_out=$(scan_fences "$FIX/pos.md" || true)
pos_n=$(printf '%s' "$pos_out" | grep -c . || true)
if [ "$pos_n" -eq 1 ] && printf '%s' "$pos_out" | grep -q "^$FIX/pos.md:3: "; then
  ok "positive control: scanner flags the bare call inside a bash fence (line 3 only)"
else
  nope "positive control: expected exactly 1 hit at pos.md:3, got $pos_n: $pos_out"
fi

neg_out=$(scan_fences "$FIX/neg.md" || true)
if [ -z "$neg_out" ]; then
  ok "negative control: sanctioned fetch-attachments fence yields no hits"
else
  nope "negative control: expected 0 hits, got: $neg_out"
fi

# --- Repo sweep: skills/**/*.md --------------------------------------------
hits=""
while IFS= read -r f; do
  out=$(scan_fences "$f" || true)
  [ -n "$out" ] && hits="${hits}${out}"$'\n'
done < <(find "$ROOT/skills" -name '*.md' | sort)

if [ -z "$hits" ]; then
  ok "no bare fetch-issue-attachments.sh inside any fenced bash block under skills/"
else
  nope "bare fetch-issue-attachments.sh inside a fenced bash block: $hits"
fi

# --- Prose drift ------------------------------------------------------------
SANCTIONED='filter-trusted-comments.sh fetch-attachments'

if grep -E '^\s*\*\*1a\.' "$ROOT/skills/fullsend/SKILL.md" | grep -q "$SANCTIONED"; then
  ok "fullsend Step 1a prose names $SANCTIONED"
else
  nope "fullsend Step 1a prose does not name $SANCTIONED"
fi

if grep -E '^3b\.' "$ROOT/skills/plan-issue/SKILL.md" | grep -q "$SANCTIONED"; then
  ok "plan-issue step 3b prose names $SANCTIONED"
else
  nope "plan-issue step 3b prose does not name $SANCTIONED"
fi

if grep -F '`.claude/scratch/`' "$ROOT/CLAUDE.md" | grep -q "$SANCTIONED"; then
  ok "CLAUDE.md .claude/scratch/ bullet names $SANCTIONED"
else
  nope "CLAUDE.md .claude/scratch/ bullet does not name $SANCTIONED"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
