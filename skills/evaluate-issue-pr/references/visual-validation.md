# Visual validation

Loaded by `skills/evaluate-issue-pr/SKILL.md` Step 6 when the diff touches UI, or when the issue carries `needs-browser`. Two tiers: a baseline screenshot/console pass, then a verdict layer for `needs-browser` issues.

**6a. Baseline — Playwright MCP probe + screenshot plumbing.** Check Playwright MCP via `cat .mcp.json 2>/dev/null`. If available and on Linux: navigate to affected views, screenshot to `<worktree>/.claude/scratch/*.png`, check console for JS errors, verify UI matches the plan. Otherwise note: "Visual validation skipped — Playwright MCP not available."

**Attach screenshots to the eval comment.** For each PNG, invoke the attach helper, then verify the file actually reached the remote before embedding its link in Step 9's `**Screenshots:**` row. The helper commits the PNG to `<worktree>/.eval-screenshots/`, pushes to the PR branch, and returns a branch-pinned `raw.githubusercontent.com/<owner>/<repo>/<branch>/.eval-screenshots/<name>.png` URL. These URLs initially resolve via the branch-pinned form during the PR review window; after auto-merge fires, `skills/fullsend/references/auto-merge-gate.md` step 3 rewrites them to the merge-SHA-pinned form (`raw.githubusercontent.com/<owner>/<repo>/<merge-sha>/.eval-screenshots/...`), which is durable for the life of the commit (issue #506, superseding the Option A ephemeral behaviour of tracker #383). Operators who prefer the legacy ephemeral behaviour may set `PIPELINE_SCREENSHOT_REWRITE_ENABLED=false`.

**Private repos (issue #551).** On a private repo the attach helper emits a `github.com/<owner>/<repo>/blob/<branch>/.eval-screenshots/...` URL instead, and Step 6 wraps it as a clickable `[name](url)` link (not `![]()`). Reason: GitHub's camo image proxy fetches `![]()` image URLs anonymously, and a private repo's `raw.githubusercontent.com` content 404s anonymously — so the inline embed renders broken. The blob link routes through GitHub's authenticated file viewer, which renders the PNG for repo members. True inline rendering on a private repo is only possible via GitHub's `user-attachments` CDN (browser drag-drop upload, which needs a browser session + CSRF token and is NOT reachable via `gh`/PAT) — blob links are the CLI-feasible answer; drag-drop is the manual inline alternative. Visibility is detected fail-soft (`gh repo view "$PIPELINE_REPO" --json isPrivate`); any `gh` absence/error/non-`true` value falls back to the public raw + `![]()` behaviour.

**Failure-loud verification.** A returned URL is not proof the blob landed on origin — `git push` can fail silently inside the sandbox. Before writing any `![](url)` row, confirm the branch exists on the remote (`git ls-remote --exit-code origin "refs/heads/$BRANCH"`) AND the specific file is present at that branch tip (`gh api repos/$PIPELINE_REPO/contents/.eval-screenshots/$name?ref=$BRANCH`). On failure, emit a `⚠️ screenshot attach failed` row instead of a broken-link image so the human reviewer gets a self-debugging trail.
```bash
# Required env: PR_NUM (bound by `skills/evaluate-issue-pr/SKILL.md` Step 2).
SCREENSHOT_LINES=()
BRANCH="$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json headRefName --jq .headRefName)"
PRIVATE="$(gh repo view "$PIPELINE_REPO" --json isPrivate --jq .isPrivate 2>/dev/null || true)"
for png in .claude/scratch/*.png; do
  [ -f "$png" ] || continue
  name="$(basename "$png")"
  url="$(bash "${CLAUDE_PLUGIN_ROOT}/mock-web-eval/scripts/eval-screenshot-attach.sh" "$PR_NUM" "$(realpath "$png")" 2>/dev/null || true)"
  if [ -n "$url" ] \
     && git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1 \
     && gh api "repos/$PIPELINE_REPO/contents/.eval-screenshots/$name?ref=$BRANCH" --jq .sha >/dev/null 2>&1; then
    if [ "$PRIVATE" = "true" ]; then
      # Private repo: camo proxy can't fetch raw.githubusercontent.com anonymously (404),
      # so use a clickable blob link — GitHub's authenticated viewer renders the PNG for members.
      SCREENSHOT_LINES+=("- [${name%.*}](${url})")
    else
      SCREENSHOT_LINES+=("- ![${name%.*}](${url})")
    fi
  else
    SCREENSHOT_LINES+=("- ⚠️ screenshot attach failed — see .eval-screenshots/${name} in the worktree")
  fi
done
```

**6b. Visual proof verdict (needs-browser issues only).** If the issue carries the needs-browser label, invoke `Skill(skill: "pipeline:visual-proof-from-plan")` in this evaluator session and parse its JSON output. For every entry in `unsatisfied`, the verdict MUST be Flagged for user review — record the claim and the failing artifact path/URL in the **Remaining issues** row. This is the load-bearing trust layer; `satisfied` predicates from the executor session do NOT carry over.

**6c. Inline-mode visual proof setup** (issue #517, #527 — applies when invoked via the inline Agent dispatch for browser-eval, dispatch mode #3 above). Before any `browser_navigate` / `browser_evaluate` call, bootstrap the loopback server via the single-responsibility helper `scripts/visual-proof-server-start.sh` (composes the port broker + starts `python3 -m http.server --directory <target> --bind 127.0.0.1` + readiness probe). The helper allocates the port itself, so this path no longer depends on the orchestrator pre-resolving `$PORT`:
```bash
# Required env: TARGET_DIR (abs path under the worktree, from PIPELINE_VISUAL_PROOF_TARGET_DIR).
SERVER_LINE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/visual-proof-server-start.sh" \
                "${SLATE_INDEX:-0}" "$TARGET_DIR" 2>&1) \
  || { echo "$SERVER_LINE"; exit 1; }   # block-server-start: ... on stderr
PORT=$(printf '%s\n' "$SERVER_LINE" | sed -n 's/^SERVER: .*port=\([0-9]*\) .*/\1/p')
SERVER_PID=$(printf '%s\n' "$SERVER_LINE" | sed -n 's/^SERVER: pid=\([0-9]*\) .*/\1/p')
trap 'kill "$SERVER_PID" 2>/dev/null' EXIT
```
`$TARGET_DIR` is the absolute path under the worktree served by the server (from `PIPELINE_VISUAL_PROOF_TARGET_DIR`). For the **single-issue orchestrator-driven path** (fullsend on a 1-issue inline slate) the orchestrator does NOT pre-resolve `$PORT` — it never reaches `run-queue.sh launch_agent()` — so the helper allocating the port closes the #519 gap. `$SLATE_INDEX` defaults to 0 for a single-issue dispatch.

All subsequent `browser_navigate` / `browser_evaluate` calls target `http://127.0.0.1:$PORT/<path>`. The EXIT trap kills the server on normal exit and most signals; SIGKILL leaks are reaped by `scripts/reap-stale-visual-proof-servers.sh` (tracks by `--directory`, unchanged) invoked from `/pipeline:status` Step 0 housekeeping. `--bind 127.0.0.1` is load-bearing — never bind to `0.0.0.0` (avoids external exposure during concurrent fullsend runs). The queue dispatch-inline path (`run-queue.sh launch_agent()`) emits only the EVENT line and does NOT start a server, so routing the single start through the helper introduces no double-bootstrap.

**Per-tool wall-clock budget.** Wrap each `browser_evaluate` and `browser_navigate` call in a 60s wall-clock budget. On timeout, post Flagged with a timeout note and exit non-zero — this explicitly prevents the `until-grep DONE_MARKER` wedge pattern from issue #511 from migrating into the inline path. The 60s budget applies to inline-mode dispatch (mode #3) unconditionally.

**Selector pitfall (as of 2026-05-26).** When clicking elements, prefer the `ref=` identifier returned by `browser_snapshot` over CSS selectors with embedded quotes (e.g. `#echo-form button[type="submit"]`). The Playwright MCP server rejects the latter on the literal string (escaped-quote selectors fail to parse); the `ref=` from the snapshot works instantly. (Upstream Playwright MCP behavior, #525.)
