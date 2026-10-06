# PATH C per-leaf worktrees (the #896 fix)

`skills/execute-issue-plan/SKILL.md` Step 5 points here. Read it on PATH C
(`multi-task`) before dispatching the `tdd-implementer` fan-out; on PATH A/B/D
there is no fan-out and this file is irrelevant.

**Per-leaf worktrees (the #896 fix — eliminates the shared-index race).** Each leaf gets its OWN worktree+branch off the feature-branch worktree HEAD, so concurrent leaves never share a git index. Without this, leaves committing in the same worktree race: transient `index.lock` collisions and one leaf's files swept into another leaf's commit (the #894 c+d collision), breaking per-target commit isolation and the per-PR CHANGELOG granularity contract. Drive it with `scripts/path-c-split-worktree.sh`:
- **Setup** — for each `target=<dir>`: `LEAF=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/path-c-split-worktree.sh" setup <feature-worktree> <target>)`; dispatch that target's leaf with `cd $LEAF` in its prompt.
- **Reassemble** — after ALL leaves report committed: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/path-c-split-worktree.sh" reassemble <feature-worktree> <target> [<target> ...]` cherry-picks each leaf's commits onto the feature branch (disjoint targets ⇒ conflict-free; cherry-pick is a git op so it does NOT trip `enforce-path-c-delegation`). A conflict means the targets were not actually disjoint — the helper aborts and errors; re-plan the overlap rather than forcing it.
- **Teardown** — `bash "${CLAUDE_PLUGIN_ROOT}/scripts/path-c-split-worktree.sh" teardown <feature-worktree> <target> [<target> ...]` removes the leaf worktrees + branches before push.

Because each leaf has an isolated index, **concurrency is bounded only by orchestrator context, not by a git-index cap** — the live branch test (#894/#896) confirmed leaf returns are ~one line each with negligible context cost, so non-overlapping targets may fan out fully concurrently (keep leaf returns terse). **Under `fullsend --spawn`, PATH C reverts to the legacy `spawn-claude.sh` → `tdd-implementer` fan-out** (the reversible escape hatch, #750) — same per-target sentinel + TDD discipline, different transport; the spawned path already isolates per worker so it needs no split-worktree step.
