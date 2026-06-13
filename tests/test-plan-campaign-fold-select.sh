#!/usr/bin/env bash
set -uo pipefail
# Unit test for plan-campaign.sh fold-select (#838): FIFO ordering, --max ceiling,
# and the mechanical high-uncertainty TITLE-keyword skip. The classify-clean
# (human/brainstorm/excluded) decision is model judgment in SKILL.md, NOT here.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/plan-campaign.sh"
fail=0
chk() { local label="$1" want="$2" got="$3"; if [ "$got" = "$want" ]; then echo "  PASS: $label"; else echo "  FAIL: $label"; echo "    want: $want"; echo "    got:  $got"; fail=1; fi; }

# (1) FIFO + ceiling: 4 clean signals, max=2 -> first 2 FOLD, rest OVERFLOW, in order.
OUT=$(printf '%s\n' \
  'SIGNAL issue=#11 kind=ci title="fix(a): one" detail="x"' \
  'SIGNAL issue=#12 kind=ci title="fix(b): two" detail="x"' \
  'SIGNAL issue=#13 kind=ci title="fix(c): three" detail="x"' \
  'SIGNAL issue=#14 kind=ci title="fix(d): four" detail="x"' \
  | bash "$SCRIPT" fold-select --max=2)
chk "FIFO fold #11 first"   "FOLD issue=#11 title=\"fix(a): one\""     "$(printf '%s\n' "$OUT" | sed -n 1p)"
chk "FIFO fold #12 second"  "FOLD issue=#12 title=\"fix(b): two\""     "$(printf '%s\n' "$OUT" | sed -n 2p)"
chk "overflow #13"          "OVERFLOW issue=#13 title=\"fix(c): three\"" "$(printf '%s\n' "$OUT" | sed -n 3p)"
chk "overflow #14"          "OVERFLOW issue=#14 title=\"fix(d): four\""  "$(printf '%s\n' "$OUT" | sed -n 4p)"

# (2) High-uncertainty title keyword is SKIPped and does NOT consume budget.
OUT=$(printf '%s\n' \
  'SIGNAL issue=#21 kind=ci title="fix(auth): token race in login" detail="x"' \
  'SIGNAL issue=#22 kind=ci title="fix(ui): button label" detail="x"' \
  | bash "$SCRIPT" fold-select --max=1)
chk "skip high-uncertainty #21" "SKIP issue=#21 reason=high-uncertainty title=\"fix(auth): token race in login\"" "$(printf '%s\n' "$OUT" | sed -n 1p)"
chk "fold clean #22 (budget intact)" "FOLD issue=#22 title=\"fix(ui): button label\"" "$(printf '%s\n' "$OUT" | sed -n 2p)"

# (3) Default max=3 when --max omitted (PIPELINE_CAMPAIGN_MAX_FOLD unset).
OUT=$(unset PIPELINE_CAMPAIGN_MAX_FOLD; printf '%s\n' \
  'SIGNAL issue=#31 kind=ci title="fix(a): one" detail="x"' \
  'SIGNAL issue=#32 kind=ci title="fix(b): two" detail="x"' \
  'SIGNAL issue=#33 kind=ci title="fix(c): three" detail="x"' \
  'SIGNAL issue=#34 kind=ci title="fix(d): four" detail="x"' \
  | bash "$SCRIPT" fold-select)
chk "default max=3 -> #34 overflow" "OVERFLOW issue=#34 title=\"fix(d): four\"" "$(printf '%s\n' "$OUT" | sed -n 4p)"

# (4) Env default honored when flag omitted.
OUT=$(PIPELINE_CAMPAIGN_MAX_FOLD=1 bash "$SCRIPT" fold-select <<'EOF'
SIGNAL issue=#41 kind=ci title="fix(a): one" detail="x"
SIGNAL issue=#42 kind=ci title="fix(b): two" detail="x"
EOF
)
chk "env max=1 -> #42 overflow" "OVERFLOW issue=#42 title=\"fix(b): two\"" "$(printf '%s\n' "$OUT" | sed -n 2p)"

# (5) Word-bound high-uncertainty (issue #1039): benign TITLEs whose words merely
#     SUBSTRING-contain auth/lock/race (authoring/block/trace) must FOLD (consume
#     budget), NOT SKIP. Real signals (auth/race condition, migration, deadlock)
#     must still SKIP without consuming budget.
OUT=$(printf '%s\n' \
  'SIGNAL issue=#51 kind=ci title="fix(authoring): control-plane docs" detail="x"' \
  'SIGNAL issue=#52 kind=ci title="fix(block): unblock the sibling render" detail="x"' \
  'SIGNAL issue=#53 kind=ci title="fix(trace): add a trace span" detail="x"' \
  | bash "$SCRIPT" fold-select --max=3)
chk "benign authoring FOLDs (not skipped)" "FOLD issue=#51 title=\"fix(authoring): control-plane docs\"" "$(printf '%s\n' "$OUT" | sed -n 1p)"
chk "benign block FOLDs (not skipped)"     "FOLD issue=#52 title=\"fix(block): unblock the sibling render\"" "$(printf '%s\n' "$OUT" | sed -n 2p)"
chk "benign trace FOLDs (not skipped)"     "FOLD issue=#53 title=\"fix(trace): add a trace span\"" "$(printf '%s\n' "$OUT" | sed -n 3p)"

OUT=$(printf '%s\n' \
  'SIGNAL issue=#61 kind=ci title="fix(auth): authentication race condition" detail="x"' \
  'SIGNAL issue=#62 kind=ci title="fix(db): schema migration" detail="x"' \
  'SIGNAL issue=#63 kind=ci title="fix(lock): deadlock under contention" detail="x"' \
  | bash "$SCRIPT" fold-select --max=3)
chk "real auth/race SKIPs (high-uncertainty)" "SKIP issue=#61 reason=high-uncertainty title=\"fix(auth): authentication race condition\"" "$(printf '%s\n' "$OUT" | sed -n 1p)"
chk "real migration SKIPs (high-uncertainty)" "SKIP issue=#62 reason=high-uncertainty title=\"fix(db): schema migration\"" "$(printf '%s\n' "$OUT" | sed -n 2p)"
chk "real deadlock SKIPs (high-uncertainty)"  "SKIP issue=#63 reason=high-uncertainty title=\"fix(lock): deadlock under contention\"" "$(printf '%s\n' "$OUT" | sed -n 3p)"

[ "$fail" -eq 0 ] && echo "PASS: fold-select" || exit 1
