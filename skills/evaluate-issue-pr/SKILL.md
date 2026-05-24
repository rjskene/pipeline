---
name: evaluate-issue-pr
description: Independently evaluate a PR's implementation against its approved plan. Run from inside the feature worktree. Can make fixes. Auto-merges on green; pass --manual-merge to opt out. Usage: /pipeline:evaluate-issue-pr <issue_number> [--manual-merge]
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Skill, mcp__playwright_*
---

## Boot

Source `pipeline.config` so `PIPELINE_*` variables are available:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

## Invocation mode

Two dispatch shapes; every step below is identical, only CWD setup differs:

1. **Inline `Agent(...)` dispatch (PATH A, docs-only).** Worktree absolute path + issue number in the prompt. You are NOT in the worktree CWD — `cd <worktree-absolute-path>` before any step.
2. **`${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh` / `claude -p` dispatch (PATH B/C and explicit requests).** Already in the feature worktree; no `cd`.

For PATH A the orchestrator threads the manual-merge opt-out by including `MANUAL_MERGE=1` in the prompt (mirroring `spawn-claude.sh --manual-merge`). Inline token and env var are equivalent — both suppress the Step 11 greenlight.

> **Container dispatch (issue #218).** When launched inside a consumer-declared container mode (e.g. `--container-mode=web-eval`), the dispatch is transparent to this skill — the consumer's compose service surfaces any marker env vars (e.g. `BOMON_WEB_EVAL=1`) the skill behavior reads. This skill does not branch on container mode.

## Lifecycle

```
PR → ci check → review → verdict → (if Approved + greenlight) merge
```

# Issue Evaluator

You are a senior engineer reviewing a PR against its approved plan. You have NO context from the implementer — only the plan and the diff.

**Rules:**
- Verify every plan item was implemented — check them off one by one.
- Look for what the implementer DIDN'T do, not just what they did.
- **Fix-vs-flag.** Fix small issues yourself (typos, missing imports, off-by-one). Flag the rest. "Significant rework" = changes touching **more than 3 files** or requiring new design decisions — flag, don't fix.
- Never refactor, add features, or improve code beyond the plan.

## Steps

1. **Fetch the approved plan:**
   ```bash
   gh issue view <N> --repo $PIPELINE_REPO --json comments \
     --jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | last | .body'
   ```
   If empty, STOP: "No implementation plan found for issue #N."

2. **Fetch the PR number and diff:**
   ```bash
   BRANCH=$(git rev-parse --abbrev-ref HEAD)
   PR_NUM=$(gh pr list --repo $PIPELINE_REPO --head "$BRANCH" --json number --jq '.[0].number')
   gh pr diff $PR_NUM --repo $PIPELINE_REPO
   ```
   If no PR found, STOP: "No open PR found for branch $BRANCH."

3. **Read project context:** `CLAUDE.md` in worktree root, plus every file under `.claude/scratch/issue-<N>/` so your review sees the same evidence the planner and executor saw. **For each file printed by `ls -1 .claude/scratch/issue-<N>/`, invoke the `Read` tool exactly once before scoring.** Skip if the directory is empty/absent.

4. **Two-phase review.** The orchestrator's `--append-system-prompt` (injected by `spawn-claude.sh` based on this issue's labels — see `PIPELINE_PATH_<X>_SKILLS_EVALUATE_PR`) requires the path-specific review skills first. If the Skill tool is unavailable, run inline:

   **Phase 1 — Plan compliance.** For each plan item: verify "Files to change" were modified and match descriptions; verify "DB schema / API / Frontend / Test changes" were made or correctly skipped; flag scope creep (implemented but not planned) and missing work (planned but not implemented).

   **Phase 2 — Code quality.** Run checks and review the diff:
   ```bash
   $PIPELINE_TYPECHECK_CMD 2>&1 | head -50
   $PIPELINE_TEST_CMD 2>&1 | tail -30
   ```
   Look for: leftover debug code / console.logs / TODOs; missing error handling at system boundaries; security issues (injection, XSS, unsanitized input); type-safety issues `tsc` missed; test coverage for every implemented feature.

<!-- BEGIN CI_CHECK -->
5. **Check CI workflow status.** A red PR must never receive Approved.

   **5a. Detect CI presence.** Skip if no checks configured:
   ```bash
   CHECK_COUNT=$(gh pr view $PR_NUM --repo $PIPELINE_REPO --json statusCheckRollup --jq '.statusCheckRollup | length')
   ```
   If `CHECK_COUNT` is 0, log `"CI: none configured — skipping status check"` and proceed to Step 6.

   **5b. Wait for in-progress checks to settle.** Single bounded wait via `Bash` with `run_in_background: true` (10-min one-shot, 30-second poll — do NOT wrap in a `while ... sleep ... grep` loop):
   ```bash
   timeout 600 gh pr checks $PR_NUM --repo $PIPELINE_REPO --watch --fail-fast --interval 30
   ```

   **5c. Inspect final check state.**
   ```bash
   gh pr view $PR_NUM --repo $PIPELINE_REPO --json statusCheckRollup \
     --jq '.statusCheckRollup[] | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED") | {name: .name, conclusion: .conclusion, url: .detailsUrl}'
   ```

   For each failed check, fetch the first error line. Parse RUN_ID from `detailsUrl`; if parsing yields empty/non-numeric, use the `gh run list` fallback:
   ```bash
   RUN_ID=$(echo "$DETAILS_URL" | sed 's|.*/runs/\([0-9]*\)/.*|\1|')
   if ! [[ "$RUN_ID" =~ ^[0-9]+$ ]]; then
     BRANCH=$(git rev-parse --abbrev-ref HEAD)
     RUN_ID=$(gh run list --repo $PIPELINE_REPO --branch "$BRANCH" --status failure --limit 1 --json databaseId --jq '.[0].databaseId')
   fi
   gh run view "$RUN_ID" --repo $PIPELINE_REPO --log-failed 2>&1 | head -20
   ```

   **5d. Decide verdict interaction:**
   - Any FAILURE/CANCELLED → you MUST NOT post Approved.
   - Fixable within budget (≤3 files, no new design decisions): fix in-worktree, commit, `git push`, re-run 5b with a fresh 10-minute timeout.
   - Exceeds budget, persists after one fix attempt, or wait timed out: post "Flagged" with failing job names + first error line in the `**CI status:**` row (see Step 9).

   **Hook-enforced.** The `enforce-ci-wait` Stop hook (`hooks/enforce-ci-wait.py`) reads `.claude/logs/tool-use.log` and blocks Stop unless the `gh pr view` → `gh pr checks --watch` → `gh pr view` sequence is recorded; an Approved verdict on a red rollup is also blocked. Prose remains source of truth for HOW; the hook only verifies it happened.
<!-- END CI_CHECK -->

6. **Visual validation** (if UI changes exist in the diff). Two tiers: a baseline screenshot/console pass, then a verdict layer for `needs-browser` issues.

   **6a. Baseline — Playwright MCP probe + screenshot plumbing.** Check Playwright MCP via `cat .mcp.json 2>/dev/null`. If available and on Linux: navigate to affected views, screenshot to `<worktree>/.claude/scratch/*.png`, check console for JS errors, verify UI matches the plan. Otherwise note: "Visual validation skipped — Playwright MCP not available."

   **Attach screenshots to the eval comment.** For each PNG, invoke the attach helper, then verify the file actually reached the remote before embedding its link in Step 9's `**Screenshots:**` row. The helper commits the PNG to `<worktree>/.eval-screenshots/`, pushes to the PR branch, and returns a branch-pinned `raw.githubusercontent.com/<owner>/<repo>/<branch>/.eval-screenshots/<name>.png` URL. These URLs are **ephemeral**: they resolve during the PR review window and intentionally 404 once the feature branch is deleted post-merge (Option A, tracker #383).

   **Failure-loud verification.** A returned URL is not proof the blob landed on origin — `git push` can fail silently inside the sandbox. Before writing any `![](url)` row, confirm the branch exists on the remote (`git ls-remote --exit-code origin "refs/heads/$BRANCH"`) AND the specific file is present at that branch tip (`gh api repos/$PIPELINE_REPO/contents/.eval-screenshots/$name?ref=$BRANCH`). On failure, emit a `⚠️ screenshot attach failed` row instead of a broken-link image so the human reviewer gets a self-debugging trail.
   ```bash
   SCREENSHOT_LINES=()
   BRANCH="$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json headRefName --jq .headRefName)"
   for png in .claude/scratch/*.png; do
     [ -f "$png" ] || continue
     name="$(basename "$png")"
     url="$(bash "${CLAUDE_PLUGIN_ROOT}/mock-web-eval/scripts/eval-screenshot-attach.sh" "$PR_NUM" "$(realpath "$png")" 2>/dev/null || true)"
     if [ -n "$url" ] \
        && git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1 \
        && gh api "repos/$PIPELINE_REPO/contents/.eval-screenshots/$name?ref=$BRANCH" --jq .sha >/dev/null 2>&1; then
       SCREENSHOT_LINES+=("- ![${name%.*}](${url})")
     else
       SCREENSHOT_LINES+=("- ⚠️ screenshot attach failed — see .eval-screenshots/${name} in the worktree")
     fi
   done
   ```

   **6b. Visual proof verdict (needs-browser issues only).** If the issue carries the needs-browser label, invoke `Skill(skill: "pipeline:visual-proof-from-plan")` in this clean-container session and parse its JSON output. For every entry in `unsatisfied`, the verdict MUST be Flagged for user review — record the claim and the failing artifact path/URL in the **Remaining issues** row. This is the load-bearing trust layer; `satisfied` predicates from the executor session do NOT carry over.

7. **If fixable issues found** (≤3 files, no new design decisions): fix in-worktree, then `git commit -m "fix: evaluation fixes for #<N> — <summary>"`, `git push`, and re-run tsc + tests to confirm fixes don't break anything.

8. **Check for branch divergence before merge decision:**
   ```bash
   git fetch origin $PIPELINE_BASE_BRANCH
   git log --oneline HEAD..origin/$PIPELINE_BASE_BRANCH | head -5
   ```
   If `PIPELINE_BASE_BRANCH` has advanced, `git rebase origin/$PIPELINE_BASE_BRANCH`. If conflicts are complex (semantic, not whitespace), flag for user review.

9. **Post evaluation comment on the PR** via `gh pr comment $PR_NUM --repo $PIPELINE_REPO --body "<evaluation>"` using this format:
   ```markdown
   ## Evaluation

   **Verdict:** Approved / Flagged for user review

   **Plan compliance:**
   - [x] <plan item> — implemented correctly
   - [ ] <plan item> — missing or incorrect: <detail>

   **Code quality:** <findings or "No issues found">

   **CI status:** All checks passed / No CI configured / FAILED: <job names> — <first error line> / Timed out

   **Screenshots:** (one row per entry in `$SCREENSHOT_LINES` from Step 6 — already formatted as either an image row or a `⚠️` failure-loud row; `None` if empty)
   - ![screenshot 1](https://raw.githubusercontent.com/owner/repo/<branch>/.eval-screenshots/<filename>.png)

   **Visual proof:** satisfied=N/M; unsatisfied=[<claim>...] (or `N/A — needs-browser not applied`)

   **Fixes applied:** `<commit hash>` — <description> (or "None")

   **Remaining issues:** (if flagged) <what needs human attention and why>
   ```

10. **Report verdict:** Approved → "PR #X approved — ready for merge." / Flagged → "PR #X flagged for review: <summary>". The evaluator auto-merges on the Step 11 greenlight matrix unless `--manual-merge` was passed or the issue carries the `manual-merge` label. Otherwise the orchestrator's step 8 handles merge.

11. **Auto-merge gate.**

    **Authoritative owner of the greenlight check.**

    On `needs-browser` issues, gate (1) requires zero `unsatisfied` entries in the Visual proof row.

    **Greenlight matrix — all 4 must hold** (otherwise the PR is left for manual merge with a `block-*` reason):
    1. Latest `## Evaluation` comment contains `**Verdict:** Approved`.
    2. Every entry in the PR's `statusCheckRollup` has `conclusion == SUCCESS` (or the rollup is empty for repos with no CI configured).
    3. `mergeable == MERGEABLE`.
    4. `mergeStateStatus == CLEAN` (not BLOCKED/BEHIND/DIRTY/UNSTABLE).

    **Dual-defense doctrine (issue #295).** Base-branch enforcement is defense-in-depth across four layers: (i) the eval-time `baseRefName == $PIPELINE_BASE_BRANCH` assertion inside `auto-merge-gate.sh` (Step 11.2 — `block-base-mismatch`); (ii) a TOCTOU re-read immediately before `gh pr merge` in Step 11.3; (iii) the skill-level quoted `--base "$PIPELINE_BASE_BRANCH"` in `execute-issue-plan` Step 9b; (iv) the `enforce-base-branch.py` PreToolUse hook over `gh pr create` / `gh pr edit --base`. The hook alone is **insufficient** — it has bypassed in production (#295) when consumer `.claude/settings.json` shadowed the plugin matcher or stale `spawn-claude.sh` emitted an unnamespaced slash command (see `dev/audits/295-root-cause.md`). The eval-time gate is the load-bearing zero-data-loss layer.

    1. **Flag parsing.** `--manual-merge` may appear anywhere in argv — before or after the issue number; the parser is loop-based, not positional. Also honored via env: `MANUAL_MERGE=1` (exported by `spawn-claude.sh` when the spawn carried `--manual-merge`) is equivalent. If either signal is set, skip Step 11 entirely and return Approved-but-not-merged.

    2. **Source the helper and run the gate.**
       ```bash
       source "${CLAUDE_PLUGIN_ROOT}/scripts/auto-merge-gate.sh"
       REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
       ```
       Checks in order: `MANUAL_MERGE` env, `manual-merge` issue label, the 4 greenlight conditions above, and `baseRefName == $PIPELINE_BASE_BRANCH`. Prints exactly one token: `green`, `block-flag`, `block-label`, `block-verdict`, `block-base-mismatch`, `block-ci`, `block-mergeable`, or `block-mergestate`.

    3. **On `green`:**
       - **TOCTOU re-check (issue #295).** Immediately before the merge, re-read `baseRefName`. A malicious or buggy actor could retarget the PR between Step 11.2's gate and the merge call.
         ```bash
         BASE_RECHECK=$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json baseRefName --jq .baseRefName 2>/dev/null)
         if [ -z "$BASE_RECHECK" ] || [ "$BASE_RECHECK" != "$PIPELINE_BASE_BRANCH" ]; then
           REASON="block-base-mismatch"
           # Fall through to Step 11.4: post the block comment and skip merge.
         fi
         ```
         If `REASON` is now `block-base-mismatch`, jump to Step 11.4 — do not invoke `gh pr merge`.
       - Merge synchronously (NOT `--auto`), then capture the squash SHA (empty `$SHA` from rare API lag → omit from close comment; the merge is authoritative):
         ```bash
         gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --squash --delete-branch
         SHA=$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json mergeCommit --jq .mergeCommit.oid)
         ```
       - Append the auto-merged footer (exact literal prefix — Step 8 of `run/SKILL.md` greps it):
         ```bash
         TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
         FOOTER="Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at ${TS}"
         gh pr comment "$PR_NUM" --repo "$PIPELINE_REPO" --body "$FOOTER"
         ```
       - Flip labels and close the issue (omit `(${SHA})` if `$SHA` is empty):
         ```bash
         gh issue edit "$ISSUE" --repo "$PIPELINE_REPO" --add-label "merged" --remove-label "pr-open"
         CLOSE_SUFFIX=$([ -n "$SHA" ] && echo " (${SHA})" || echo "")
         gh issue close "$ISSUE" --repo "$PIPELINE_REPO" --comment "Merged via #${PR_NUM}${CLOSE_SUFFIX}. ${FOOTER}"
         ```
       - Screenshots: no cleanup needed — the `.eval-screenshots/` commit collapses into the squash-merge and the feature branch is deleted by `--delete-branch`. Branch-pinned `raw.githubusercontent.com/<owner>/<repo>/<branch>/.eval-screenshots/...` URLs in the eval comment will return 404 after merge. This is the explicit accepted tradeoff for Option A (ephemeral review-window artifacts, tracker #383): screenshots are visible during the PR review window and become invalid evidence post-merge by design. Reviewers who need long-lived audit artifacts should screenshot the PR comment before the auto-merge fires.

    4. **On any `block-*` reason:** post a single comment explaining why auto-merge was skipped, then return Approved-but-not-merged. Do not flip labels or close the issue.
       ```bash
       gh pr comment "$PR_NUM" --repo "$PIPELINE_REPO" \
         --body "Auto-merge skipped: ${REASON}. Run \`gh pr merge\` manually."
       ```

       **`block-base-mismatch` extension.** When `REASON == block-base-mismatch` (from Step 11.2's gate or Step 11.3's TOCTOU re-check), the comment body MUST also include a retarget suggestion:
       ```bash
       gh pr comment "$PR_NUM" --repo "$PIPELINE_REPO" \
         --body "Auto-merge skipped: block-base-mismatch — PR baseRefName diverges from \$PIPELINE_BASE_BRANCH ($PIPELINE_BASE_BRANCH).

Run \`\$CLAUDE_PLUGIN_ROOT/scripts/retarget-pr.sh $PR_NUM $PIPELINE_BASE_BRANCH\` to retarget (or \`gh pr edit $PR_NUM --base $PIPELINE_BASE_BRANCH\` if retarget-pr.sh is unavailable)."
       ```

    Release-please PRs are out of scope for this gate — they flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` in Step 7b of `run/SKILL.md`.

## Constraints
- Do NOT read the executor's session logs or conversation history.
- Only inputs: plan comment, PR diff, codebase in worktree.
- Fixes must be minimal: typos, missing imports, small bugs. NOT refactoring.
- If a fix requires touching >3 files or new design decisions, flag instead of fixing.
- Never skip tsc or test validation.
- All PRs target `PIPELINE_BASE_BRANCH`. All commits go to the feature branch.
- Outside the Step 11 auto-merge gate, the evaluator does NOT merge, close issues, or change `pr-open` labels — only reviews, posts verdict, and (optionally) rebases against the base branch.
