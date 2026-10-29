#!/usr/bin/env bash
# Guard: the fullsend rebase-fix prompt names its worktree and declares it
# carries no stage SKILL.md; stage-executor treats such a prompt as the procedure.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/skills/fullsend/references/auto-merge-gate.md"
AGENT="$ROOT/agents/stage-executor.md"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

line="$(grep -F 'conflict FILES=<csv>' "$GATE" | head -1)"
[ -n "$line" ] || bad "R0: no 'conflict FILES=<csv>' line in auto-merge-gate.md"

if printf '%s\n' "$line" | grep -qF 'cd <worktree-abs-path>'; then
  ok "R1: rebase-fix prompt starts with cd <worktree-abs-path>"
else
  bad "R1: rebase-fix prompt lacks 'cd <worktree-abs-path>'"
fi

if printf '%s\n' "$line" | grep -qF 'No stage SKILL.md — this prompt is the whole procedure.'; then
  ok "R2: rebase-fix prompt declares no stage SKILL.md"
else
  bad "R2: rebase-fix prompt lacks the no-stage-SKILL.md declaration"
fi

if printf '%s\n' "$line" | grep -qF 'FLAKY=<test>'; then
  ok "R5: rebase-fix prompt caps a flake at one re-run (FLAKY=<test>)"
else
  bad "R5: rebase-fix prompt lacks the one re-run cap (FLAKY=<test>)"
fi

SENT='When the prompt says it carries no stage skill, the prompt itself is the procedure.'
ANCHOR='Load the stage by Reading the absolute'
if grep -qF "$SENT" "$AGENT"; then
  ok "R3: stage-executor carries the no-skill sentence"
else
  bad "R3: stage-executor lacks the no-skill sentence"
fi

sent_at="$(awk -v s="$SENT" 'BEGIN{RS="\001"} {print index($0, s); exit}' "$AGENT")"
anchor_at="$(awk -v s="$ANCHOR" 'BEGIN{RS="\001"} {print index($0, s); exit}' "$AGENT")"
if [ "${sent_at:-0}" -gt 0 ] && [ "${anchor_at:-0}" -gt 0 ] && [ "$sent_at" -gt "$anchor_at" ]; then
  ok "R4: no-skill sentence follows the Load-the-stage sentence"
else
  bad "R4: no-skill sentence missing or precedes 'Load the stage' (sent=$sent_at anchor=$anchor_at)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
