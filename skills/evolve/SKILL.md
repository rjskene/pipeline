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
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
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

Bash-tool shell state does NOT persist between calls, so re-run fences 1+2 at the head of EVERY Bash call that runs a later fence (same-call composition). `HARNESS_ROOT` is therefore captured per call; a later fence run on its own would see it empty and emit a spurious `--plugin-dir` STOP.

The harness rewrites positional-argument tokens in this body with the invocation args, so no bash fence may contain one (`tests/test-skill-fence-positional-args.sh`).

## Subcommands

- `start [--cycles N]` — run cycles from Step 0 until `CYCLES` is reached (when non-zero), the `paused` label appears, or diminishing returns fires.
- `stop` — fence 3 with `MODE_NEW=paused` plus `gh issue edit "$TRACKER" --repo "$PIPELINE_REPO" --add-label paused`; one-line report; never touches an in-flight fullsend.
- `pause` — finish or abort the in-flight cycle, forward-sync, open the merge-back PR, then `paused`.
- `resume` — invoking `resume` IS the un-pause, so it FIRST clears the kill switch with `gh issue edit "$TRACKER" --repo "$PIPELINE_REPO" --remove-label paused`, then runs Step 0 in full, then continues at the recorded step (`done` → next cycle). Without that removal Step 0's `paused` check would STOP every resume.
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

Comments are read ONLY via `bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" "$TRACKER"` — `enforce-comment-trust.py` blocks `--json comments`; `--json body` and `gh issue edit --body-file` are unaffected.

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
  git -C "$MAIN_REPO" merge-base --is-ancestor origin/staging HEAD || git -C "$MAIN_REPO" merge --no-edit origin/staging   # forward-sync; conflicts → resolve in-session, then continue
  [ "$SYNC_BEFORE" = "$(git -C "$MAIN_REPO" rev-parse HEAD)" ] || git -C "$MAIN_REPO" push origin evolve   # publish a productive forward-sync so cycle worktrees (cut from origin/evolve) see it
fi
```

`HARNESS_ROOT` is the path the harness substituted into this skill at load, so a session that loaded the published cache or the main checkout instead of `--plugin-dir <clone>` fails that compare — an unsubstituted or unset token is empty and fails too, which is the fail-closed behaviour we want. The main checkout's `pipeline.config` is outside the clone's `restrict_paths.py` boundary, so the exclusion knob is read as the operator's attestation in the tracker `## Runtime` row `staging isolation`, never as a file read (spec §3.3).

## Usage gate + projection

Run at Step 0 and again before Step 4:

```bash
GATE_LINE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh" || true); echo "$GATE_LINE"
DECISION=$(sed -nE 's/.*decision=([a-z0-9-]+).*/\1/p' <<<"$GATE_LINE")
FIVE=$(sed -nE 's/.*five_hour=([0-9]+)(\.[0-9]+)?%.*/\1/p' <<<"$GATE_LINE"); SEVEN=$(sed -nE 's/.*seven_day=([0-9]+)(\.[0-9]+)?%.*/\1/p' <<<"$GATE_LINE")
THRESH=$(sed -nE 's/.*threshold=([0-9]+).*/\1/p' <<<"$GATE_LINE"); THRESH=${THRESH:-85}
RESUME_AT=$(sed -nE 's/.*resume_at=([^ ]+).*/\1/p' <<<"$GATE_LINE")
# EST5/EST7 = median of the last three non-negative per-cycle deltas from trusted cycle comments; defaults 30 / 8 (spec §5)
DELTAS=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" "$TRACKER" 2>/dev/null \
  | awk '/^- usage: start five_hour=/{gsub(/[a-z_]+=/,""); split($0,f," "); d5=f[7]-f[4]; d7=f[8]-f[5]; if(d5>=0&&d7>=0) print d5, d7}' | tail -3)
MED='{v[NR]=$0} END{if(NR==0)print d; else if(NR%2)print v[(NR+1)/2]; else print int((v[NR/2]+v[NR/2+1]+1)/2)}'
EST5=$(awk 'NF{split($0,f," "); print f[1]}' <<<"$DELTAS" | sort -n | awk -v d=30 "$MED")
EST7=$(awk 'NF{split($0,f," "); print f[2]}' <<<"$DELTAS" | sort -n | awk -v d=8 "$MED")
if [ "$DECISION" = proceed ] && [ -n "$FIVE" ] && [ -n "$SEVEN" ] && { [ $((FIVE+EST5)) -gt "$THRESH" ] || [ $((SEVEN+EST7)) -gt "$THRESH" ]; }; then DECISION=pause-5h; RESUME_AT=$(date -u -d '+5 hours' +%FT%TZ); fi
```

Branch on `$DECISION` exactly as `skills/fullsend/SKILL.md` `## Usage gate (#969)` prescribes — that section is the single source of truth, do not restate it here:

- `proceed` / `skip` → continue; `skip` NEVER resumes a paused loop (R4).
- `pause-5h` → fence 3 with the current step, then `bash "${CLAUDE_PLUGIN_ROOT}/scripts/arm-usage-resume-cron.sh" --resume-command "/pipeline:evolve resume" --resume-at "$RESUME_AT"` and transcribe its output into exactly ONE recurring `CronCreate` (NEVER `ScheduleWakeup`), then STOP the turn.
- `halt-7d` → fence 3 with `MODE_NEW=paused`, `--add-label paused`, LOUD report (seven-day %, reset date, `/pipeline:evolve resume` as the manual command); never auto-resume.

`$FIVE` / `$SEVEN` at Step 0 are the cycle's `start` values; at Step 7 they are its `end` values.

## Cycle (steps 1–7)

Each transition calls fence 3.

1. **observe** — `RETRO=$(printf '%s/docs/retros/cycle-%02d.md' "$MAIN_REPO" "$N")`; then `if [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/run-retro.sh" ]; then bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-retro.sh" --cycle "$N" --tracker "$TRACKER" --write "$RETRO"; else echo "run-retro.sh absent (#1272 not merged) — skipping retro"; fi` — `if`/`else`, never `&&`/`||`, which would misreport a non-zero run-retro exit as "absent". Relay the ≤60-line stdout; never paste plan/PR/eval bodies.
2. **diagnose** — resolve the `pending-verdicts:` issues from cycle N−1 (`confirmed` / `no-effect` / `regressed` per spec §7 thresholds; real-work cost/latency deltas under 30% are `no-effect`); rank the tracker `## Hypothesis backlog`; pick ≤3 issues, ≤1 PATH C; append `## Diagnose` (verdicts + why this slate) to `$RETRO`.
3. **file** — one `gh issue create --repo "$PIPELINE_REPO" --label evolve --title "<type>(<scope>): …" --body-file <tmp>` per issue, body = the create-issues template (Context / Scope / Affected areas / Notes) + the mandatory `## Evolve` block (spec §6: Cycle, Hypothesis, Metric · expected delta, Measured by, Prose budget) + `<!-- pipeline:path-hint=A|B|C|D -->`. Disallowed content (`restrict_paths.py`, `block_deletions.py`, auth/credential surfaces, prose-pinning tests) is filed with `--label human` instead of `evolve`. Append `- #<n> — <title>` lines under `Cycle <N> …:` in the tracker `## Cycle issues` (edit `$TMP`, then fence 3 with `ISSUES="#a #b #c"` and `STEP_NEW=3`).
4. **run** — re-run fence 5, then `Skill(skill: "pipeline:fullsend", args: "<the cycle's issue numbers>")`. Explicit numbers only, never bare fullsend.
5. **measure** — same `if [ -x … ]; then … ; else …; fi` guard around `bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-retro.sh" --cycle "$N" --tracker "$TRACKER" --post` → mass + friction verdicts now; its `verdict-candidates:` lines are the cost/latency/escape verdicts, deferred to cycle N+1 step 2 unless the issue said `Measured by: calibration run`.
6. **decide** — `regressed` → `Skill(skill: "pipeline:hotfix", args: "\"revert #<issue>: <one-line reason>\" --auto-merge")` with the revert commit, re-filing a follow-up only if the hypothesis still holds. `no-effect` → move the backlog entry to the bottom of `## Hypothesis backlog`. `confirmed` → replace the matching `## Scorecard baseline` row value. Both edits go through `$TMP` + fence 3.
7. **log** — append `## Post` (step 5 output + verdicts) to `$RETRO`; `git -C "$MAIN_REPO" add "$RETRO" && git -C "$MAIN_REPO" commit -m "$(printf 'docs(evolve): cycle %02d retro' "$N")" && git -C "$MAIN_REPO" push origin evolve`; post the cycle comment (shape below) with `gh issue comment "$TRACKER" --repo "$PIPELINE_REPO" --body-file <tmp>`; fence 3 with `STEP_NEW=done`. Diminishing returns: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" "$TRACKER" | grep -E '^- verdicts:' | tail -2` — two lines and neither contains `confirmed` → fence 3 `MODE_NEW=paused`, `--add-label paused`, post `need new hypotheses` on the tracker, STOP. Else, `CYCLES` not reached (or 0) → `N=$((N+1))` and the next cycle starts at Step 0.

## Cycle comment shape

```
## Cycle <N>
- issues: #a #b #c
- verdicts: #x confirmed · #y no-effect · #z regressed (reverted by PR #p) | pending: #q (retro next cycle)
- usage: start five_hour=<int> seven_day=<int> end five_hour=<int> seven_day=<int>
- retro: docs/retros/cycle-NN.md @ <short sha>
HARNESS-FRICTION: <what the doc/hook said> | <what was true>
```

`run-retro.sh` (#1272) harvests the `HARNESS-FRICTION:` lines and fence 5 parses the `- usage:` line, so the percentages are integers with no `%`. Every `HARNESS-FRICTION:` line from the fullsend run's subagent reports is appended VERBATIM, plus the orchestrator's own — one per doc, skill or hook claim that disagreed with reality.

## pause / resume / stop

`pause`: fence 2 first. `STEP` ≤3 → abort (filed issues stay open under `evolve`; comment `aborted at step K; slate carried forward`). `STEP` 4–6 → finish: `Skill(skill: "pipeline:fullsend", args: "<cycle issues still in-progress/pr-open>")` (label-driven, so re-running is idempotent), then steps 5–7. Then forward-sync (fence 4) and the merge-back:

```bash
SINCE=$(gh pr list --repo "$PIPELINE_REPO" --base staging --head evolve --state merged --limit 1 --json mergedAt --jq '.[0].mergedAt // "1970-01-01T00:00:00Z"')
MERGED_PRS=$(gh pr list --repo "$PIPELINE_REPO" --base evolve --state merged --search "merged:>=${SINCE%%T*}" --json number,title --jq '.[] | "- #\(.number) \(.title)"')
SCORECARD_DELTA=$(awk '/^## Post/{p=1} p' "$(ls "$MAIN_REPO"/docs/retros/cycle-*.md 2>/dev/null | tail -1)" 2>/dev/null)
PR=$(gh api "repos/$PIPELINE_REPO/pulls" -f base=staging -f head=evolve -f title="chore(evolve): merge-back through cycle $N" \
  -f body="$(printf '## Merged PRs\n%s\n\n## Scorecard delta\n%s\n' "$MERGED_PRS" "${SCORECARD_DELTA:-n/a (no retro yet)}")" --jq .number)
timeout 590 gh pr checks "$PR" --repo "$PIPELINE_REPO" --watch --interval 30 && gh pr merge "$PR" --repo "$PIPELINE_REPO" --merge \
  || echo "STOP: checks not green within 590s — operator runs: gh pr merge $PR --repo $PIPELINE_REPO --merge"
```

Then fence 3 with `MODE_NEW=paused` and hand back — the release cut stays the manual `docs/release-cadence.md` step and `--delete-branch` is never passed. That REST call is the loop's only cross-base PR: `enforce-base-branch.py` pins `gh pr create --base` to `PIPELINE_BASE_BRANCH=evolve`, correct for every feature PR and wrong only for this deliberate `evolve → staging` merge-back.

`resume`: `gh issue edit "$TRACKER" --repo "$PIPELINE_REPO" --remove-label paused` FIRST (the invocation is the un-pause), then Step 0 in full (fences 2, 4, 5), then continue at `STEP` (`done` → next cycle). `stop`: fence 3 with `MODE_NEW=paused` plus `--add-label paused`, then a one-line report.

## Guardrails

≤3 issues per cycle and ≤1 PATH C; no `restrict_paths.py` / `block_deletions.py` / auth edits (those route to `human`); prose budget is judged by the retro mass row; agent reports stay terse; cycle boundaries are the compaction seam, so everything needed to resume lives on GitHub.
