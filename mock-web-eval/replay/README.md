# mock-web-eval — end-to-end dogfood demonstrator

## What this is

Demonstrator that exercises the full web-eval chain end-to-end (classifier match → container dispatch → in-container Playwright capture → screenshot attachment to the `## Evaluation` comment). Resolves issue #232; rolls up under tracker #233. Linked PR: `<PR>` (placeholder until merge).

## Operator setup (one-time)

**CRITICAL.** `pipeline.config` is gitignored (`.gitignore:7`), so the wiring this demo depends on cannot ship through this PR — it is per-host operator state. Before merging this PR (or any time after, but the demo will not dispatch into a container until this is done) the operator must append the following six lines to the live `pipeline.config` at the repo root:

```
PIPELINE_EVAL_CLASSIFIER="mock-web-eval/scripts/mock-web-eval-classifier.sh"
PIPELINE_EVAL_CONTAINERS="mock-web-eval"
PIPELINE_EVAL_CONTAINER_mock_web_eval_COMPOSE_FILE="mock-web-eval/docker/compose.yml"
PIPELINE_EVAL_CONTAINER_mock_web_eval_SERVICE="mock-web-eval"
PIPELINE_EVAL_CONTAINER_mock_web_eval_ENV_FILE="mock-web-eval/target/.env.mock-web-eval"
PIPELINE_EVAL_CONTAINER_mock_web_eval_PREFLIGHT_CMD="bash mock-web-eval/scripts/mock-web-eval-probe-port.sh"
```

These mirror the commented `mock-web-eval` block in `pipeline.config.example`. Verify after editing:

```bash
grep -q '^PIPELINE_EVAL_CLASSIFIER=' pipeline.config \
  && grep -q '^PIPELINE_EVAL_CONTAINERS=.*mock-web-eval' pipeline.config \
  && echo OK
```

## Host pre-flight checklist

Before invoking the demo, the host must satisfy:

- Docker group membership: `groups | grep -q docker`
- Claude credentials present: `[ -f ~/.claude/.credentials.json ]`
- GitHub CLI authenticated: `gh auth status`
- Plugin installed: `ls ~/.claude/plugins/cache/claude-pipeline/`
- Free host TCP port in the 8080–8089 range (seeded by `mock-web-eval/scripts/mock-web-eval-probe-port.sh`)

`mock-web-eval/replay/replay.sh` runs these checks automatically and prints actionable remediation for any failure.

## Plugin discoverability inside the container

The container's `working_dir` MUST match a `projectPath` entry in `~/.claude/plugins/installed_plugins.json` — otherwise `claude` boots in "no project" mode and every `/pipeline:*` slash command resolves to `Unknown command`. The compose file therefore binds the host project root at the same absolute path inside the container (`${PIPELINE_PROJECT_ROOT}:${PIPELINE_PROJECT_ROOT}`) and pins `working_dir` to the worktree (which lives under `${PIPELINE_PROJECT_ROOT}/.claude/worktrees/`).

Both env vars are seeded automatically:

- by `mock-web-eval/scripts/mock-web-eval-probe-port.sh` (writes `PIPELINE_PROJECT_ROOT` + `PIPELINE_WORKTREE_PATH` into `mock-web-eval/target/.env.mock-web-eval`), and
- by `scripts/spawn-claude.sh` when `--container-mode=mock-web-eval` is passed (forwards both via `-e ...` into `docker compose run`).

If you see `Unknown command: /pipeline:...` inside the container, verify the registration:

```bash
grep -E 'projectPath|installPath' ~/.claude/plugins/installed_plugins.json
```

The `projectPath` value for `pipeline@claude-pipeline` (or, for legacy installs that still have it registered, `pipeline@claude-pipeline-dev`) must equal the absolute path your host knows the repo as. If it doesn't, re-run `/plugin install pipeline@claude-pipeline` from the project root in Claude Code so the registration picks up the right path.

See #241 for the root-cause walkthrough.

## Reproducing the demo

Use `mock-web-eval/replay/replay.sh`. Two modes:

- `--dry-run` (default) — runs every pre-flight check and prints `dry-run: would …` markers for each downstream step without invoking compose or the classifier. Safe to run anywhere; used by the smoke test.
- `--full --pr <N>` — re-runs the classifier + spawn-claude.sh end-to-end against an existing PR. Requires the operator setup above plus a real PR number. Not idempotent — it actually fires the dispatch chain.

```bash
bash mock-web-eval/replay/replay.sh             # dry-run, verification
bash mock-web-eval/replay/replay.sh --full --pr 232 # re-trigger against PR #232
```

## Attachment mechanism — in-branch git commits

Screenshots captured during `/pipeline:evaluate-issue-pr`'s visual-validation step (Step 6) are committed to `<worktree>/.eval-screenshots/` on the PR branch via `mock-web-eval/scripts/eval-screenshot-attach.sh`. The helper:

1. Writes the PNG to `<worktree>/.eval-screenshots/<name>.png`.
2. Runs `git add .eval-screenshots/<name>.png` + `git commit -m "chore(eval): screenshot evidence for PR #<N>"` (idempotent on re-eval — an empty commit is suppressed).
3. Runs `git push origin HEAD` to publish the screenshot commit to the PR branch. Fail-soft: a push failure prints a stderr warning and continues; the helper still emits the URL and exits 0.
4. Captures `BRANCH=$(git rev-parse --abbrev-ref HEAD)`.
5. Prints the branch-pinned URL `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/.eval-screenshots/<name>.png` on stdout.

The eval skill verifies each PNG actually landed on `origin/<branch>` (via `git ls-remote` + `gh api repos/.../contents/.eval-screenshots/<name>?ref=<branch>`) BEFORE embedding it in the `## Evaluation` comment as `![screenshot](url)`. On verification failure it emits a `⚠️ screenshot attach failed` row instead of a broken-link image (issue #337). Relative-path image syntax does NOT render in GitHub comments — a fully-qualified raw URL on a still-existing branch is required.

**Ephemeral by design (Option A, issue #337 / tracker #383).** The branch-pinned `raw.githubusercontent.com/<owner>/<repo>/<branch>/.eval-screenshots/...` URL resolves during the PR review window and intentionally **404s once the feature branch is deleted post-merge** (`--delete-branch`). The squash-merge collapses the screenshot commit into the base branch, but the branch-pinned URL no longer resolves because the branch path component is gone. This is the accepted tradeoff: screenshots are visible during review and become invalid evidence post-merge. Reviewers who need long-lived audit artifacts should screenshot the PR comment before auto-merge fires. (Durable alternatives — a long-lived branch, S3, or `gh` user-attachment upload — are deliberately out of scope.)

**Cleanup.** No cleanup needed. The `.eval-screenshots/` commit collapses into the squash-merge and the feature branch is deleted afterwards; the review-window URLs lapse on their own. `.eval-screenshots/` is intentionally **not** gitignored so the PNG is trackable on the feature branch (the prior `mock-web-eval/screenshots/` path was gitignored, which silently dropped the `git add` and was a root cause of the broken-link bug — see #337).

## Known follow-ups

- **Issue #238 mitigation (b) shipped.** `scripts/spawn-claude.sh` now exits 5 when `PIPELINE_EVAL_CLASSIFIER` would emit `--container-mode=<name>` but the operator did not pass the flag. The orthogonal mitigations from the issue body — (a) stale-consumer-copy detection and (c) tmux-window-kill process-group cleanup — remain open as separate follow-ups; file them as new issues if dogfooding surfaces another silent-bypass instance.
