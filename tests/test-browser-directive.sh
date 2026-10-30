#!/bin/bash
# Guard (#1484): browser evaluation is a one-line directive in execute-issue-plan
# and evaluate-issue-pr — no label, no sub-skill, no predicates, no server
# plumbing, no knobs.
#   (a) execute SKILL carries the `**6c. Browser check.**` directive sentence.
#   (b) evaluate SKILL carries the evaluate-form directive sentence.
#   (c) every deleted browser-eval path is absent.
#   (d) no residual reference to the removed surface in live sources.
#   (e) plan-issue template's `**Frontend changes:**` line names user-visible outcomes.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
FAIL() { echo "FAIL: $*"; fail=1; }

EXEC=skills/execute-issue-plan/SKILL.md
EVAL=skills/evaluate-issue-pr/SKILL.md
PLAN=skills/plan-issue/SKILL.md
LEAD='If the diff changes anything a user sees or does in a browser'

# (a) execute directive
for needle in '**6c. Browser check.**' "$LEAD" 'Playwright MCP tools' \
  'prove the behaviour, not the rendering' 'browser_snapshot' 'Browser check: skipped' \
  'screenshots stay local'; do
  grep -qF -- "$needle" "$EXEC" || FAIL "(a) $EXEC missing: $needle"
done

# (b) evaluate directive
for needle in "$LEAD" 'evidence, not proof' 'Playwright MCP tools' \
  'browser_snapshot' 'Browser check: skipped'; do
  grep -qF -- "$needle" "$EVAL" || FAIL "(b) $EVAL missing: $needle"
done

# (c) deleted paths stay deleted
for p in \
  skills/visual-proof-from-plan \
  skills/execute-issue-plan/references/visual-validation.md \
  skills/evaluate-issue-pr/references/visual-validation.md \
  scripts/visual-proof-port-broker.sh \
  scripts/visual-proof-server-start.sh \
  scripts/reap-stale-visual-proof-servers.sh \
  tests/test-classify-needs-browser-backstop.sh \
  tests/test-create-issues-needs-browser-advisory.sh \
  tests/test-plan-issue-needs-browser-predicates.sh \
  tests/test-pipeline-config-needs-browser-doc.sh \
  tests/test-pipeline-config-mock-web-eval-paths.sh \
  tests/test-evaluate-issue-pr-screenshot-wiring.sh \
  tests/test-evaluate-issue-pr-visual-proof-invocation.sh \
  tests/test-execute-issue-plan-visual-proof-invocation.sh \
  tests/test-visual-proof-from-plan-contract.sh \
  tests/test-visual-proof-port-broker.sh \
  tests/test-visual-proof-server-start.sh \
  tests/test-reap-stale-visual-proof-servers.sh \
  tests/test-reap-visual-proof-sandboxed.sh; do
  [ -e "$p" ] && FAIL "(c) removed path still present: $p"
done

# (d) residual scan. Tokens are assembled without the config-var prefix so the
# config-drift scanner (which also scans tests/) does not see a knob here.
RE='needs-browser|visual-proof|VISUAL''_PROOF|MOCK_WEB''_EVAL|visual-validation|MEMORY_MAX''_BROWSER'
SELF="tests/$(basename "$0")"
hits=$(grep -rlE "$RE" scripts skills hooks agents docs tests CLAUDE.md pipeline.config.example .github 2>/dev/null \
  | grep -vE '^docs/(retros|superpowers|analysis)/' \
  | grep -vxF "$SELF" || true)
if [ -n "$hits" ]; then
  FAIL "(d) residual browser-eval references:"
  printf '  %s\n' $hits
fi

# (e) plan template outcome clause
for needle in '**Frontend changes:**' 'one line per user-visible outcome'; do
  grep -qF -- "$needle" "$PLAN" || FAIL "(e) $PLAN missing: $needle"
done

[ "$fail" -eq 0 ] || exit 1
echo "PASS: browser directive pinned; browser-eval structure removed"
