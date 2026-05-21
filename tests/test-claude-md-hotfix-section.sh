#!/usr/bin/env bash
set -euo pipefail
# Guard: CLAUDE.md must document the /pipeline:hotfix emergency lane —
# distinguished from PATH D, with the locked invariants (in-session, no
# pipeline labels) called out and a pointer to skills/hotfix/SKILL.md.
F="CLAUDE.md"

grep -q "Hotfix" "$F" || { echo "FAIL: $F missing 'Hotfix' subsection heading"; exit 1; }
grep -q "emergency lane" "$F" || { echo "FAIL: $F missing 'emergency lane' phrasing"; exit 1; }
grep -q "no pipeline labels" "$F" || { echo "FAIL: $F missing 'no pipeline labels' invariant"; exit 1; }
grep -q "in-session" "$F" || { echo "FAIL: $F missing 'in-session' invariant"; exit 1; }
grep -q "PATH D" "$F" || { echo "FAIL: $F hotfix subsection does not reference PATH D boundary"; exit 1; }
grep -q "skills/hotfix/SKILL.md" "$F" || { echo "FAIL: $F missing pointer to skills/hotfix/SKILL.md"; exit 1; }

echo "PASS: CLAUDE.md hotfix subsection"
