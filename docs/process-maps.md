# Process Maps

System-view reference for the pipeline's runtime behavior. Three self-contained
ASCII maps, each showing the traversal shape of a different layer:

1. **Full lifecycle map** — issue creation through merge, with label transitions.
2. **PATH dispatch decision tree** — how an issue resolves to PATH A/B/C/D.
3. **Wave-plan flow** — what `fullsend` does across many issues in parallel.

Authoritative definitions live in each skill's own SKILL.md; this doc only
shows the shapes.

## Full lifecycle map

How a single issue moves from filed to merged. Label is shown on each edge.

```
                  +---------+
                  |  filed  |   (ready, no pipeline label)
                  +----+----+
                       |
                       v
                  +----+----+
                  |classify |   applies one of:
                  | -issue  |    docs-only / multi-task / quick-fix / (none)
                  +----+----+
                       |
                       v
                  +----+----+
                  |  plan-  |   adds: plan-pending
                  |  issue  |
                  +----+----+
                       |
                       v
              +--------+---------+
              | evaluate-issue-  |  Approved -> plan-reviewed
              |      plan        |  Revise   -> plan-pending (loop, max 3)
              +--------+---------+
                       |
                       v
                  +----+----+
                  |  human  |   manual gate
                  | approve |   plan-reviewed -> plan-approved
                  +----+----+
                       |
                       v
              +--------+---------+
              | execute-issue-   |   plan-approved -> in-progress
              |      plan        |   then        -> pr-open
              +--------+---------+
                       |
                       v
              +--------+---------+
              | evaluate-issue-  |   Approved + greenlight -> auto-merge
              |       pr         |   block-*               -> manual merge
              +--------+---------+
                       |
                       v
                  +----+----+
                  | merged  |   in-progress / pr-open -> merged (issue closed)
                  +---------+
```

Caption: edges show label transitions; revise loops re-enter `evaluate-issue-plan`
until a verdict sticks or the iteration budget (3) is exhausted.

## PATH dispatch decision tree

How `classify-issue` resolves an issue to one of PATH A/B/C/D. The body marker
short-circuits; otherwise label, then heuristics.

```
                       +---------------------+
                       |  Issue body has     |
                       |  pipeline:path=X    |
                       |  marker?            |
                       +----+----------+-----+
                            | yes      | no
                            v          v
                  +---------+--+   +---+----------------+
                  | PATH = X   |   | Labels include     |
                  | (high conf)|   | docs-only/multi-   |
                  +------------+   | task/quick-fix?    |
                                   +---+----------+-----+
                                       | yes      | no
                                       v          v
                                 +-----+---+   +--+-----------+
                                 | A / C / D|   | heuristics  |
                                 | per label|   | (rule table)|
                                 +----------+   +-----+-------+
                                                      |
                                                      v
                                                +-----+-------+
                                                | A / B / C / |
                                                | D / default |
                                                | (B)         |
                                                +-------------+
```

Caption: marker is authoritative; otherwise label is authoritative; heuristics
are the unmarked-untagged fallback (default = B).

## Dispatch transport

Once PATH is resolved, the transport (how the execute/eval agent launches) keys
off the PATH letter. Worktree creation (`setup-worktree.sh`) is identical across
all paths — only the launch differs. Inline `Agent(subagent_type=...)` in the
orchestrator session is the default transport for ALL paths; the
`spawn-claude.sh` → `claude -p` run-queue / tmux transport is the `--spawn`
legacy escape hatch (formerly C-only).

| Path | Transport                          | Produces                                |
|------|------------------------------------|-----------------------------------------|
| A    | inline `Agent(general-purpose)`    | Flat edits in the worktree. No TDD cycle.|
| B    | inline `Agent(general-purpose)`    | TDD discipline (red->green->commit) inline; no spawned worker.|
| C    | inline `Agent(tdd-implementer)` per `target=<dir>` leaf, each in its own per-leaf worktree + cherry-pick reassemble (#896); `--spawn` = legacy run-queue | One or more `tdd-implementer` subagents, scoped per target dir. A delegation hook blocks orchestrator-side Edit/Write on impl files.|
| D    | inline `Agent(tdd-implementer)`    | Inline `tdd-implementer` in the orchestrator session. Skips the pre-PR review loop in `execute-issue-plan` Step 8.|

## Pre-PR guards

Before `gh pr create`, execute runs a set of fast, diff-independent repo-invariant
guards so CI is never the first to surface a cross-cutting break. These run
regardless of PATH and regardless of whether the diff touched the guarded surface
(the #1128 "only touched tests" miss class).

- **Cross-cutting guards aggregator (#1132/#1143).** `scripts/check-cross-cutting-guards.sh`
  is the always-run floor — it bundles config-drift, namespace-discipline,
  golden-seed, and README-anchor invariants and runs in seconds. It is wired
  pre-PR in `execute-issue-plan` (Step 9) and also into the `evaluate-issue-pr`
  and `fullsend` dispatch paths, so the same invariant floor is enforced at both
  execute-time and eval-time.
- **Config-drift pre-PR guard (#1103).** `scripts/check-config-drift.sh` catches
  any new `PIPELINE_*` variable introduced on the branch that is not yet
  documented in `pipeline.config.example` (and vice-versa) at execute-time, so an
  undocumented knob is fixed in-session rather than as a CI-fail → re-watch loop.
  The aggregator above already includes this guard; the standalone call is the
  in-leaf early check.

## Wave-plan flow

What `fullsend` does across a slate of issues — file-conflict serialization,
wave-by-wave parallelism, CI-fix retry, greenlight auto-merge.

```
  fullsend <issues...> [--manual-merge] [--spawn] [--campaign]
           |
           v
  +--------+----------+
  | fetch attachments |   issue + comment images -> .claude/scratch/issue-<N>/
  +--------+----------+
           |
           v
  +--------+----------+
  | plan-waves.sh     |   group issues into waves by:
  |  --stage=classify |    - file-conflict (path overlap)
  +--------+----------+    - blocked-by graph
           |
           v
  +--------+---------------+
  | for each wave (parallel) |
  |   classify-issue        |
  |   plan-issue            |
  +--------+---------------+
           |
           v
  +--------+----------+
  | evaluate-issue-   |   Revise loop (max 3 iterations / issue)
  |      plan         |   Approved -> plan-reviewed
  +--------+----------+
           |
           v
  +--------+----------+
  | auto-approve      |   plan-reviewed -> plan-approved
  +--------+----------+
           |
           v
  +--------+----------+
  | setup-worktree.sh |   one feature/<slug> worktree per issue
  +--------+----------+
           |
           v
  +--------+----------+
  | execute           |   A/B/D: inline Agent() in orchestrator
  |                   |   C: inline tdd-implementer per leaf,
  |                   |      per-leaf worktree, max 3 concurrent
  +--------+----------+
           |
           v
  +--------+----------+
  | check-ci-fix-loop |   green / pending / red-retry /
  |      .sh          |   red-budget-exhausted
  +--------+----------+
           |
           v
  +--------+----------+
  | evaluate-issue-pr |
  +--------+----------+
           |
           v
  +--------+--------------+
  | auto-merge-gate.sh   |   four conditions (all must hold):
  |                      |    1. Verdict: Approved
  |                      |    2. CI rollup SUCCESS or empty
  |                      |    3. mergeable == MERGEABLE
  |                      |    4. mergeStateStatus == CLEAN
  +--------+--------------+
           |
   +-------+-------+
   | yes           | no
   v               v
 merge-commit   manual merge (block-* reason posted)
 + close issue
```

Caption: `--manual-merge` opt-out (flag or `manual-merge` label) stops short of
the auto-merge gate even when all four greenlight conditions hold.

Campaign mode (`/pipeline:fullsend --campaign`, or the equivalent standalone `/pipeline:campaign` — same machinery, neither deprecated): `scripts/plan-campaign.sh` partitions the approved set into ordered **legs**, each run **in order** as one wave through the flow above (leg N completes before leg N+1 starts; inside each leg the wave-plan parallelism above still applies). Per-leg caps are `PIPELINE_CAMPAIGN_MAX_BC` (default 2 — expensive PATH-B/C) and `PIPELINE_CAMPAIGN_MAX_AD` (default 5 — cheap PATH-A/D), overridable via `--max-bc=N` / `--max-ad=N`. These two are the only knobs (no `PIPELINE_*_LEG_CAP` var). The canonical leg-loop machinery is documented once in `skills/fullsend/SKILL.md` `## Campaign mode`; `skills/campaign/SKILL.md` is a thin entry that defers to it.

## Entrypoints

Top-level slash commands that drive the maps above:

- `/pipeline:status` (formerly `/pipeline:run`, retained as a deprecated alias) — orchestrator session: prioritize, group, and dispatch the action queue. It also renders an **UNMERGED PRs advisory ledger** (#1168/#1172) — a full open-PR view sourced from `scripts/list-open-prs.sh` and emitted by a dedicated renderer section, so open PRs that are not tied to a queued action are still visible at a glance.
- `/pipeline:fullsend` — wave-plan flow across a slate of issues (the map above).
- `/pipeline:analyze-issues` — read-only hygiene pass over the open-issue set; see [skills/analyze-issues/SKILL.md](../skills/analyze-issues/SKILL.md). `/pipeline:status --analyze` delegates to `/pipeline:analyze-issues` for back-compat.

`analyze-issues` surfaces four detection categories (no mutations): duplicate candidates, standalones that fit an existing tracker, issues with missing labels, and merged-PR supersession candidates.

See [docs/superpowers-integration.md](superpowers-integration.md) for the per-stage map of which superpowers each pipeline skill invokes.

## Visual proof sub-skill (needs-browser lane)

`needs-browser` issues carry a UI acceptance criterion unit tests can't cover.
The `visual-proof-from-plan` sub-skill emits a `{satisfied, unsatisfied}` result
and has two callers (the **two-caller pattern**):

- **Executor (TDD loop)** — `execute-issue-plan` runs it inside red->green; an
  `unsatisfied` entry behaves like a failing test (iterate until satisfied). The
  `needs-browser` label routes the executor through inline `Agent()` dispatch with
  the visual-proof preflight in `scripts/visual-proof-server-start.sh`.
- **Evaluator (verdict)** — `evaluate-issue-pr` runs the same sub-skill; any
  `unsatisfied` entry is a blocking verdict finding.

Both callers share one `{satisfied, unsatisfied}` contract. Definition lives in
[skills/visual-proof-from-plan/SKILL.md](../skills/visual-proof-from-plan/SKILL.md).

**Assigner (#1015).** `needs-browser` now has an assigner — closing the
"consumers but no assigner" gap: `create-issues` carries a filing-time advisory
(default-no operator prompt) and `classify-issue` carries an autonomous
comment-path backstop for externally-filed issues, both gated by the same
browser-UI conjunction + suppressors (pure-logic/server-side/docs).
