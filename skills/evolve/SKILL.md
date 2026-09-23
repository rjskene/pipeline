---
name: evolve
description: Harness-evolve loop driver — runs observe→diagnose→file→fullsend→measure→decide→log cycles on the evolve integration branch from the loop clone. Subcommands: start [--cycles N] | stop | pause | resume | status. Usage: /pipeline:evolve start [--cycles N] | stop | pause | resume | status [--tracker N]
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Skill, Agent
---

## Boot

Capture `HARNESS_ROOT` on the FIRST line — the harness rewrites that braced token when it loads this skill, so it must be read before the resolver overwrites the Bash variable. Then source the clone's `pipeline.config` and self-resolve the plugin root:

```bash
HARNESS_ROOT="${CLAUDE_PLUGIN_ROOT}"
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$([ "${PIPELINE_USE_LOCAL_PLUGIN:-}" = true ] && git rev-parse --show-toplevel 2>/dev/null | sed 's|$|/|')}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
ARGV="<the raw subcommand + flags this skill was invoked with, e.g. start --cycles 2>"
TRACKER=$(sed -nE 's/.*--tracker[= ]([0-9]+).*/\1/p' <<<"$ARGV"); TRACKER=${TRACKER:-1271}
CYCLES=$(sed -nE 's/.*--cycles[= ]([0-9]+).*/\1/p' <<<"$ARGV"); CYCLES=${CYCLES:-0}   # 0 = unbounded
MAIN_REPO="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
TMP="$MAIN_REPO/.claude/scratch/evolve-tracker-body.md"; mkdir -p "$(dirname "$TMP")"
```

If `CLAUDE_PLUGIN_ROOT` fails to resolve, **STOP** — every step below calls a script under it.

Bash-tool shell state does NOT persist between calls, so re-run fences 1+2 (which capture `HARNESS_ROOT`) at the head of every later fence's Bash call, or Step 0 emits a spurious `--plugin-dir` STOP.

The harness rewrites positional-argument tokens in this body with the invocation args, so no bash fence may contain one (`tests/test-skill-fence-positional-args.sh`).

## Subcommands

- `start [--cycles N]` — run cycles from Step 0 until `CYCLES` is reached (when non-zero), the `paused` label appears, or diminishing returns fires.
- `stop` — pause the tracker and report; never touches an in-flight fullsend (detail: `## pause / resume / stop`).
- `pause` — finish/abort the in-flight cycle, forward-sync, merge back, then pause (detail below).
- `resume` — clear the kill switch first, then Step 0, then continue at the recorded step (detail below).
- `status` — print the `## Mode` line, then (behind an `[ -x ]` guard) `bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-retro.sh" --cycle "$N" --tracker "$TRACKER" | grep -E '^(cycle-issues|pending-verdicts):'`, then the current `usage-gate.sh` line.

## Durable state (tracker body)

The `## Mode` section of the tracker body is the ONLY step record. Canonical line:

`` `<active|paused>` — cycle <N> · step <0..7|done> · issues <#a #b …|none> · updated <ISO8601> ``

A hand-written line without `step K` parses as `N=0 STEP=done`, so the next `start`/`resume` begins cycle 1; write `step K` by hand to resume mid-cycle.

Read — run at every entry:

```bash
gh issue view "$TRACKER" --repo "$PIPELINE_REPO" --json body --jq .body > "$TMP"
MODE_LINE=$(awk '/^## Mode/{f=1;next} f&&/^`/{print;exit}' "$TMP")
MODE=$(sed -nE 's/^`([a-z]+)`.*/\1/p' <<<"$MODE_LINE")
N=$(sed -nE 's/.*cycle ([0-9]+).*/\1/p' <<<"$MODE_LINE"); N=${N:-0}
STEP=$(sed -nE 's/.*step ([0-9]+|done).*/\1/p' <<<"$MODE_LINE"); STEP=${STEP:-done}
case "$MODE_LINE" in *"· issues "*) ISSUES=$(grep -oE '#[0-9]+' <<<"${MODE_LINE#*· issues }" | tr '\n' ' '); ISSUES="${ISSUES% }" ;; *) ISSUES="" ;; esac
```

Write — called at every step transition with `STEP_NEW=<0..7|done>` and, for stop/pause/halt, `MODE_NEW=paused`; `ISSUES` is updated by Step 3:

```bash
NEW_MODE_LINE="\`${MODE_NEW:-active}\` — cycle $N · step ${STEP_NEW:-done} · issues ${ISSUES:-none} · updated $(date -u +%FT%TZ)"
awk -v l="$NEW_MODE_LINE" '/^## Mode/{print;f=1;next} f&&/^`/{print l;f=0;next} {print}' "$TMP" > "$TMP.new"
gh issue edit "$TRACKER" --repo "$PIPELINE_REPO" --body-file "$TMP.new"
```

Comments are read ONLY via `bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" "$TRACKER"` — the trust filter of record, hard-dropping untrusted-author comment bytes before they reach context; `--json body` and `gh issue edit --body-file` are unaffected.

## Step 0 — gate

Run after fence 2. Each check is a one-line STOP carrying its reason and sets `STOP=1`; the forward-sync runs ONLY when every check passed, so a failed gate never mutates the working tree:

```bash
STOP=""
HEAD_BRANCH=$(git -C "$MAIN_REPO" symbolic-ref --short HEAD)
[ "$HEAD_BRANCH" = "$PIPELINE_BASE_BRANCH" ] && [ "$PIPELINE_BASE_BRANCH" = evolve ] || { echo "STOP: branch=$HEAD_BRANCH base=$PIPELINE_BASE_BRANCH (need evolve/evolve)"; STOP=1; }
[ "${PIPELINE_USE_LOCAL_PLUGIN:-}" = true ] || { echo "STOP: PIPELINE_USE_LOCAL_PLUGIN=true missing from the clone pipeline.config (Bash-side resolver would run the published cache)"; STOP=1; }
[ "$HARNESS_ROOT" = "$(git -C "$MAIN_REPO" rev-parse --show-toplevel)" ] || { echo "STOP: session not started with --plugin-dir <clone> (harness root=$HARNESS_ROOT)"; STOP=1; }
gh issue view "$TRACKER" --repo "$PIPELINE_REPO" --json labels --jq '.labels[].name' | grep -qx paused && { echo "STOP: tracker carries paused (kill switch)"; STOP=1; }
grep -qE '^\| staging isolation \|.*PIPELINE_LABELS_EXCLUDED="[^"]*evolve[^"]*"' "$TMP" || { echo "STOP: staging-isolation attestation missing from tracker ## Runtime (need PIPELINE_LABELS_EXCLUDED=\"…evolve…\")"; STOP=1; }
if [ -n "$STOP" ]; then echo "STOP: gate failed — abort the turn, do not run Step 1"; else
  git -C "$MAIN_REPO" fetch --quiet origin staging
  SYNC_BEFORE=$(git -C "$MAIN_REPO" rev-parse HEAD)
  git -C "$MAIN_REPO" merge-base --is-ancestor origin/staging HEAD || git -C "$MAIN_REPO" merge --no-edit origin/staging   # forward-sync; conflicts → resolve in-session, commit, then git -C "$MAIN_REPO" push origin evolve before continuing to Step 1 (the auto-push below only fires on THIS call's own merge)
  [ "$SYNC_BEFORE" = "$(git -C "$MAIN_REPO" rev-parse HEAD)" ] || git -C "$MAIN_REPO" push origin evolve || { echo "STOP: forward-sync merged locally but the push to origin/evolve failed (diverged remote?) — fetch/resolve and re-push before continuing"; STOP=1; }   # publish a productive forward-sync so cycle worktrees (cut from origin/evolve) see it
fi
```

`HARNESS_ROOT` is the path the harness substituted at load, so a session that skipped `--plugin-dir <clone>` (or lost the substitution) fails closed; the exclusion knob is read only from the tracker `## Runtime` attestation, never the main checkout's `pipeline.config`.

## Usage gate + projection

Run at Step 0 and again before Step 4. `scripts/evolve-projection.sh` (#1287) computes EST5/EST7 — the median of the last three non-negative per-cycle usage deltas from trusted cycle comments, defaulting to 30 / 8 (spec §5) — and folds a `proceed` → `pause-5h` flip into its one-line `PROJECTION …` output, which this fence parses with `sed -nE` (no awk field references, since the harness rewrites `$0`-`$9` at skill load):

```bash
GATE_LINE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh" || true); echo "$GATE_LINE"
PROJ=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/evolve-projection.sh" --tracker "$TRACKER" --gate-line "$GATE_LINE" || true); echo "$PROJ"
DECISION=$(sed -nE 's/.*decision=([a-z0-9-]+).*/\1/p' <<<"$PROJ")
FIVE=$(sed -nE 's/.* five=([0-9]+).*/\1/p' <<<"$PROJ"); SEVEN=$(sed -nE 's/.* seven=([0-9]+).*/\1/p' <<<"$PROJ")
RESUME_AT=$(sed -nE 's/.*resume_at=([^ ]+).*/\1/p' <<<"$PROJ")
```

Branch on `$DECISION` exactly as `skills/fullsend/SKILL.md` `## Usage gate (#969)` prescribes — that section is the single source of truth, do not restate it here:

- `proceed` / `skip` → continue; `skip` NEVER resumes a paused loop (R4).
- `pause-5h` → fence 3 with the current step, then `bash "${CLAUDE_PLUGIN_ROOT}/scripts/arm-usage-resume-cron.sh" --resume-command "/pipeline:evolve resume" --resume-at "$RESUME_AT"` and transcribe its output into exactly ONE recurring `CronCreate` (NEVER `ScheduleWakeup`), then STOP the turn.
  - Under `PIPELINE_HEADLESS=true` (read `${PIPELINE_HEADLESS:-false}`) `pause-5h` instead writes fence 3 with the current step and ENDS the turn with `HEADLESS-DEFAULT: usage-pause decision=exit-for-wrapper reason=wrapper-owns-the-sleep resume_at=<ts>` as the final message — no `arm-usage-resume-cron.sh`, no `CronCreate`. `scripts/evolve-loop.sh` greps that line, sleeps, relaunches. Interactive keeps the cron; `halt-7d` unchanged.
- `halt-7d` → fence 3 with `MODE_NEW=paused`, `--add-label paused`, LOUD report (seven-day %, reset date, `/pipeline:evolve resume` as the manual command); never auto-resume.

`$FIVE` / `$SEVEN` at Step 0 are the cycle's `start` values; at Step 7 they are its `end` values.

## Cycle (steps 1–7)

Each transition calls fence 3.

1. **observe** — `RETRO=$(printf '%s/docs/retros/cycle-%02d.md' "$MAIN_REPO" "$N")`; then `if [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/run-retro.sh" ]; then bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-retro.sh" --cycle "$N" --tracker "$TRACKER" --write "$RETRO"; else echo "run-retro.sh absent (#1272 not merged) — skipping retro"; fi` — `if`/`else`, never `&&`/`||`, which would misreport a non-zero run-retro exit as "absent". Relay the ≤60-line stdout; never paste plan/PR/eval bodies.
2. **diagnose** — dispatch ONE `Agent(subagent_type='general-purpose', description='evolve grade cycle #<N>')` whose prompt carries ONLY: each pending issue's body, its `## Evolve` Metric line, and the Step-1 retro's scorecard rows — inline, never a path. It must NOT see prior dispatch prompts, tracker comments, or `docs/retros/cycle-<N-1>.md`. It returns one `VERDICT: #<n> confirmed|no-effect|regressed — <evidence>` per issue; transcribe verbatim. Rank `## Hypothesis backlog`; pick ≤3 issues, ≤1 PATH C; append `## Diagnose` to `$RETRO`.
3. **file** — one `gh issue create --repo "$PIPELINE_REPO" --label evolve --title "<type>(<scope>): …" --body-file <tmp>` per issue, body = the create-issues template (Context / Scope / Affected areas / Notes) + the mandatory `## Evolve` block (spec §6: Cycle, Hypothesis, Metric · expected delta, Measured by, Prose budget) + `<!-- pipeline:path-hint=A|B|C -->` (D: `<!-- pipeline:path=D -->`). Disallowed content (`tests/test-cage-invariant-*.sh`, auth/credential surfaces, prose-pinning tests) is filed with `--label human` instead of `evolve`; hook source edits themselves are ordinary `evolve` issues. Before filing, `grep -rl <changed token or script> docs/ tests/fixtures/` and list every hit under Affected areas on one line beginning `do not edit — verify only:` — a doc or fixture README pinning the contract is executor scope, not a pr-eval fix. Append `- #<n> — <title>` lines under `Cycle <N> (<ISO8601>) …:` in the tracker `## Cycle issues` (edit `$TMP`, then fence 3 with `ISSUES="#a #b #c"` and `STEP_NEW=3`). Also write `.claude/scratch/evolve-metric-tokens-<N>.txt`, one line per filed issue (`#<n> <token> <token> …`), tokens = the backticked identifiers (≥3 chars) from that issue's `Metric · expected delta` line.
4. **run** — re-run fence 5, then `Skill(skill: "pipeline:fullsend", args: "<the cycle's issue numbers>")`. Explicit numbers only, never bare fullsend. Every dispatch you author carries the fixture-cleanup rule of `skills/evaluate-issue-pr/SKILL.md` `## Executable verification` — recursive removal ONLY on a literal `.claude/scratch/<name>` path, never a variable, never spelled in heredoc prose or commit messages. Before dispatching, write each prompt to a file and run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/evolve-prompt-guard.sh" <N> <prompt-file>`; a `PROMPT-COACHED` hit means rewrite without that token and re-run; never dispatch a rejected prompt.
5. **measure** — same `if [ -x … ]; then … ; else …; fi` guard around `bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-retro.sh" --cycle "$N" --tracker "$TRACKER" --post` → mass + friction verdicts now; its `verdict-candidates:` lines are the cost/latency/escape verdicts, deferred to cycle N+1 step 2 unless the issue's Measured-by line names the calibration run and not `retro` — a hybrid line (`calibration run … and retro (next cycle)`) still lands in `verdict-candidates:`. `--post` first runs `scripts/capture-agent-costs.sh` when `PIPELINE_LOGS_ENABLED=true` (synchronous `Agent` dispatches yield a forward row; the backfill's retroactive row collapses by `agent_id`), then prints one `cost: issue=#N tokens=<M> stages=<k>` row per cycle issue plus `cost: loop-own tokens/issue median`.
6. **decide** — `regressed` → `Skill(skill: "pipeline:hotfix", args: "\"revert #<issue>: <one-line reason>\" --auto-merge")` with the revert commit, re-filing only if the hypothesis still holds. `no-effect` → move the backlog entry to the bottom of `## Hypothesis backlog`. `confirmed` → replace the matching `## Scorecard baseline` row value. Both edits go through `$TMP` + fence 3.
7. **log** — append `## Post` (step 5 output + verdicts) to `$RETRO`; `git -C "$MAIN_REPO" add "$RETRO" && git -C "$MAIN_REPO" commit -m "$(printf 'docs(evolve): cycle %02d retro' "$N")" && git -C "$MAIN_REPO" push origin evolve`; post the cycle comment (shape below) with `gh issue comment "$TRACKER" --repo "$PIPELINE_REPO" --body-file <tmp>`; fence 3 with `STEP_NEW=done`. Diminishing returns: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/evolve-diminishing.sh" --tracker "$TRACKER"` — exit 3 → fence 3 `MODE_NEW=paused`, `--add-label paused`, post `need new hypotheses`, STOP. Else, `CYCLES` not reached (or 0) → `N=$((N+1))` and the next cycle starts at Step 0.

## Cycle comment shape

```
## Cycle <N>
- issues: #a #b #c
- verdicts: #x confirmed · #y no-effect · #z regressed (reverted by PR #p) | pending: #q (retro next cycle)
- usage: start five_hour=<int> seven_day=<int> end five_hour=<int> seven_day=<int>
- retro: docs/retros/cycle-NN.md @ <short sha>
HARNESS-FRICTION: <what the doc/hook said> | <what was true>
```

`run-retro.sh` harvests the `HARNESS-FRICTION:` lines; usage percentages are integers with no `%`. Append every `HARNESS-FRICTION:` line from the fullsend subagent reports VERBATIM, plus the orchestrator's own.

## pause / resume / stop

`pause`: fence 2 first. `STEP` ≤3 → abort (filed issues stay open under `evolve`; comment `aborted at step K; slate carried forward`). `STEP` 4–6 → finish: `Skill(skill: "pipeline:fullsend", args: "<cycle issues still in-progress/pr-open>")` (label-driven, so re-running is idempotent), then steps 5–7. Then forward-sync (fence 4) and the merge-back:

```bash
SINCE=$(gh pr list --repo "$PIPELINE_REPO" --base staging --head evolve --state merged --limit 1 --json mergedAt --jq '.[0].mergedAt // "1970-01-01T00:00:00Z"')
MERGED_PRS=$(gh pr list --repo "$PIPELINE_REPO" --base evolve --state merged --limit 100 --search "merged:>=${SINCE%%T*}" --json number,title --jq '.[] | "- #\(.number) \(.title)"')
SCORECARD_DELTA=$(awk '/^## Post/{p=1} p' "$(ls "$MAIN_REPO"/docs/retros/cycle-*.md 2>/dev/null | tail -1)" 2>/dev/null)
PR=$(gh api "repos/$PIPELINE_REPO/pulls" -f base=staging -f head=evolve -f title="chore(evolve): merge-back through cycle $N" \
  -f body="$(printf '## Merged PRs\n%s\n\n## Scorecard delta\n%s\n' "$MERGED_PRS" "${SCORECARD_DELTA:-n/a (no retro yet)}")" --jq .number)
timeout 590 gh pr checks "$PR" --repo "$PIPELINE_REPO" --watch --interval 30 && gh pr merge "$PR" --repo "$PIPELINE_REPO" --merge \
  || echo "STOP: checks not green within 590s — operator runs: gh pr merge $PR --repo $PIPELINE_REPO --merge"
```

Then fence 3 with `MODE_NEW=paused` and hand back — the release cut stays the manual `docs/release-cadence.md` step and `--delete-branch` is never passed. That REST call is the loop's only cross-base PR: `enforce-base-branch.py` pins `gh pr create --base` to `PIPELINE_BASE_BRANCH=evolve`, correct for every feature PR and wrong only for this deliberate `evolve → staging` merge-back.

`resume`: `gh issue edit "$TRACKER" --repo "$PIPELINE_REPO" --remove-label paused` FIRST (the invocation is the un-pause), then Step 0 in full (fences 2, 4, 5), then continue at `STEP` (`done` → next cycle). `stop`: fence 3 with `MODE_NEW=paused` plus `--add-label paused`, then a one-line report.

## Guardrails

Prose budget is judged by the retro mass row; agent reports stay terse; cycle boundaries are the compaction seam, so everything needed to resume lives on GitHub. Prose-drift sweeps run at most every 5 cycles; the guard-hook surface is frozen (no FP-tuning issues) until the hook-necessity experiment (#12) reports; instrumentation repairs to `run-retro`, `calibration-run`, `capture-agent-costs` and `evolve-loop` go to the hotfix lane, never a slate slot.
