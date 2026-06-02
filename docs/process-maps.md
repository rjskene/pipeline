# Process Maps

System-view reference for the pipeline's runtime behavior. Three ASCII maps,
each self-contained, showing the traversal shape of a different layer:

1. **Full lifecycle map** — issue creation through merge, with label transitions.
2. **PATH dispatch decision tree** — how an issue resolves to PATH A/B/C/D.
3. **Wave-plan flow** — what `fullsend` does across many issues in parallel.

No cross-references to SKILL files. Authoritative definitions live in each
skill's own SKILL.md; this doc only shows the shapes.

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
all paths — only the launch differs.

```
  PATH letter -> transport
    A,B,D -> inline  Agent(subagent_type=...) in orchestrator session
       A -> Agent(general-purpose)
       B -> Agent(general-purpose)
       D -> Agent(tdd-implementer)
    C     -> spawn   spawn-claude.sh -> claude -p
                     (+ run-queue.sh / tmux for multi-issue)
```

Caption: inline `Agent()` is the default transport; spawn
(`spawn-claude.sh` / `run-queue.sh` / tmux) is PATH C only.

| Path | Transport                          | Produces                                |
|------|------------------------------------|-----------------------------------------|
| A    | inline `Agent(general-purpose)`    | Flat edits in the worktree. No TDD cycle.|
| B    | inline `Agent(general-purpose)`    | TDD discipline (red->green->commit) inline; no spawned worker.|
| C    | spawn `spawn-claude.sh` / `run-queue.sh` tmux | One or more `tdd-implementer` subagents, scoped per target dir. A delegation hook blocks orchestrator-side Edit/Write on impl files.|
| D    | inline `Agent(tdd-implementer)`    | Inline `tdd-implementer` in the orchestrator session. Skips the pre-PR review loop in `execute-issue-plan` Step 8.|

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
  | execute           |   B/D: inline Agent() in orchestrator
  |                   |   C:   run-queue.sh / tmux, max 3 concurrent
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

### Campaign mode (`--campaign`)

- Runs `scripts/plan-campaign.sh` to partition the approved set into ordered **legs**.
- Per-leg caps: `PIPELINE_CAMPAIGN_MAX_BC` (default 2 — expensive PATH-B/C issues per leg) and `PIPELINE_CAMPAIGN_MAX_AD` (default 5 — cheap PATH-A/D issues per leg).
- Override per-invocation with `--max-bc=N` / `--max-ad=N`.
- Legs run in order; each leg runs as one wave through the flow above.
- There is NO `PIPELINE_*_LEG_CAP` var — the two caps above are the only knobs.

## Entrypoints

Top-level slash commands that drive the maps above:

- `/pipeline:status` (formerly `/pipeline:run`, retained as a deprecated alias) — orchestrator session: prioritize, group, and dispatch the action queue.
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
  `needs-browser` label routes the executor through inline `Agent()` dispatch
  with the visual-proof preflight in `scripts/visual-proof-server-start.sh`.
- **Evaluator (verdict)** — `evaluate-issue-pr` runs the same sub-skill; any
  `unsatisfied` entry is a blocking verdict finding.

Both callers share one `{satisfied, unsatisfied}` contract. Definition lives in
[skills/visual-proof-from-plan/SKILL.md](../skills/visual-proof-from-plan/SKILL.md).
