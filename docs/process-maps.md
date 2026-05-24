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

| Path | Produces                                                            |
|------|---------------------------------------------------------------------|
| A    | Flat edits in the worktree. No TDD cycle.                           |
| B    | TDD discipline (red->green->commit) in a spawned worker session.    |
| C    | One or more `tdd-implementer` subagents, scoped per target dir.     |
|      | A delegation hook blocks orchestrator-side Edit/Write on impl files.|
| D    | Inline `tdd-implementer` in the orchestrator session. Skips the     |
|      | pre-PR review loop in `execute-issue-plan` Step 8.                  |

## Wave-plan flow

What `fullsend` does across a slate of issues — file-conflict serialization,
wave-by-wave parallelism, CI-fix retry, greenlight auto-merge.

```
  fullsend <issues...> [--manual-merge]
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
  | run-queue.sh      |   tmux, max 3 workers concurrent
  |  (execute)        |
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
 squash-merge   manual merge (block-* reason posted)
 + close issue
```

Caption: `--manual-merge` opt-out (flag or `manual-merge` label) stops short of
the auto-merge gate even when all four greenlight conditions hold.

## Entrypoints

Top-level slash commands that drive the maps above:

- `/pipeline:run` — orchestrator session: prioritize, group, and dispatch the action queue.
- `/pipeline:fullsend` — wave-plan flow across a slate of issues (the map above).
- `/pipeline:analyze-issues` — read-only hygiene pass over the open-issue set; see [skills/analyze-issues/SKILL.md](../skills/analyze-issues/SKILL.md). `/pipeline:run --analyze` delegates to `/pipeline:analyze-issues` for back-compat.

`analyze-issues` surfaces four detection categories (no mutations): duplicate candidates, standalones that fit an existing tracker, issues with missing labels, and merged-PR supersession candidates.

See [docs/superpowers-integration.md](superpowers-integration.md) for the per-stage map of which superpowers each pipeline skill invokes.

## Visual proof sub-skill (needs-browser lane)

Issues labelled `needs-browser` carry a UI/visual acceptance criterion that
cannot be verified by unit tests alone. For those issues the pipeline runs the
visual-proof-from-plan sub-skill ([skills/visual-proof-from-plan/SKILL.md](../skills/visual-proof-from-plan/SKILL.md)),
which emits a structured `{satisfied, unsatisfied}` result describing which
plan-derived visual criteria are met.

The sub-skill has two callers — the **two-caller pattern**:

- **Executor (TDD loop)** — `execute-issue-plan` invokes visual-proof-from-plan
  inside the red→green loop, treating an `unsatisfied` entry like a failing
  test: keep iterating until the visual criteria are satisfied. Because the
  proof needs a real browser, a `needs-browser` issue routes `execute-issue-plan`
  through `--container-mode` even when the static `PIPELINE_CONTAINER_SKILLS`
  allowlist omits it. The label gate lives in `spawn-claude.sh` (issue #368);
  see the `PIPELINE_CONTAINER_SKILLS` section of `pipeline.config.example`.
- **Evaluator (verdict)** — `evaluate-issue-pr` invokes the same sub-skill to
  produce its merge verdict: any `unsatisfied` visual criterion is a blocking
  finding, mirroring how a failing test blocks the eval gate.

Both callers consume the identical `{satisfied, unsatisfied}` contract, so the
executor's exit condition and the evaluator's verdict stay aligned on one source
of visual truth.
