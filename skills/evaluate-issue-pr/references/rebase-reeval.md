# Rebase-fix re-evaluation (`REEVAL=rebase-fix`)

Trigger: the dispatch prompt carries `REEVAL=rebase-fix OLD_HEAD=<sha> FILES=<csv>` (the fullsend gate's re-run after a rebase-fix). First evaluations carry no `REEVAL=` and run the full Steps.

1. Run Step 2, then the interdiff of the pre- vs post-rebase net change (pass `OLD_HEAD`'s value as the placeholder):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-issue-pr-interdiff.sh" <OLD_HEAD>
   ```

   Skip Step 3 and the full Phase 1/2 pass. Branch on the first line:

2. **`INTERDIFF=none`** ⇒ skip Step 1 too. Post `## Evaluation` with `**Verdict:** Approved`, `**Plan compliance:** unchanged by rebase — prior evaluation stands`, `**Code quality:** rebase-fix interdiff empty`, and the CI row from the prompt's `PREFLIGHT` line.

3. **`INTERDIFF=files=<csv>`, every path inside `FILES=`** ⇒ run Step 1 (to find the plan items naming those paths), Phase 1 on those items, Phase 2 on the interdiff hunks, and executable verification only for guard claims inside them. Post a normal `## Evaluation`.

4. **Any path outside `FILES=`, or `INTERDIFF=unknown`** ⇒ full evaluation exactly as the Steps say, stated in `**Code quality:**`.

Steps 5, 7, 8, 9 and 10 are unchanged; a push re-arms the CI triple as usual.
