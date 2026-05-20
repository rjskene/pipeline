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

Screenshots captured during `/pipeline:evaluate-issue-pr`'s visual-validation step (Step 6) are committed to `<worktree>/mock-web-eval/screenshots/` on the PR branch via `mock-web-eval/scripts/eval-screenshot-attach.sh`. The helper:

1. Writes the PNG to `<worktree>/mock-web-eval/screenshots/<name>.png`.
2. Runs `git add mock-web-eval/screenshots/<name>.png` + `git commit -m "chore(eval): screenshot evidence for PR #<N>"` (idempotent on re-eval — an empty commit is suppressed and the prior SHA is reused).
3. Runs `git push origin HEAD` to publish the screenshot commit to the PR branch. Fail-soft: a push failure prints a stderr warning and continues; the helper still emits the local-SHA URL and exits 0.
4. Captures `SHA=$(git rev-parse HEAD)` after the push.
5. Prints the SHA-pinned URL `https://github.com/<owner>/<repo>/raw/<sha>/mock-web-eval/screenshots/<name>.png` on stdout.

The eval skill embeds the URL in the `## Evaluation` comment as `![screenshot](url)`, which renders inline on the PR for any reader with repo access. The `github.com/.../raw/<sha>/...` form (not `raw.githubusercontent.com/...`) is required so private repos render via GitHub's session redirect.

**Why in-branch, not release-assets.** The prior release-asset approach (per-PR tag `eval-evidence-<PR>` with cleanup after the merge gate fired `green`) was fundamentally incompatible with auto-merge: the cleanup ran immediately after the squash-merge, which made the inline `![](url)` markdown 404 the moment the merge landed. Anyone reviewing the merged PR saw a broken-image icon. In-branch commits avoid this because the squash-merge collapses the screenshot commit into the merge commit on `$PIPELINE_BASE_BRANCH` — the PNG blob is now part of base-branch history, so the SHA-pinned URL resolves indefinitely. See #271 for the full rationale.

**Cleanup.** No cleanup needed. The squash-merge collapses the screenshot commit into the base branch; the PNG blob is now permanent base-branch history. PNGs are ~20KB each at a pipeline rate of ~10/month (~2MB/year of git growth), so a retention/GC policy is deferred until it becomes a real problem.

## Known follow-ups

- **Issue #238 mitigation (b) shipped.** `scripts/spawn-claude.sh` now exits 5 when `PIPELINE_EVAL_CLASSIFIER` would emit `--container-mode=<name>` but the operator did not pass the flag. The orthogonal mitigations from the issue body — (a) stale-consumer-copy detection and (c) tmux-window-kill process-group cleanup — remain open as separate follow-ups; file them as new issues if dogfooding surfaces another silent-bypass instance.
