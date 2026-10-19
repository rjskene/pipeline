# PATH C per-leaf worktrees

Read on PATH C (`multi-task`) under `PIPELINE_PATH_C_FANOUT=true`, before dispatching the fan-out. With the knob off (default) there is no fan-out.

**Leaf contract.** The orchestrator reads the plan and, per `target=<dir>`, dispatches one `Agent(subagent_type='pipeline:tdd-implementer', description='target=<dir>/ ...', prompt='cd <leaf-worktree>; target=<dir>/ ...')`; it then owns push, `gh pr create` and the label flip (Steps 9–10). It MUST NOT `Edit`/`Write` impl files: `enforce-path-c-delegation` allows only files under a dispatched `target=<dir>` sentinel (a real subdirectory; `target=.`, `./`, `/` are rejected). `tdd-implementer` is a hard leaf — no `Agent` tool, no grandchild dispatch — and applies red→green→commit itself.

**Per-leaf worktrees.** Each leaf gets its own worktree+branch off the feature worktree HEAD, so leaves never share a git index. Drive it with `scripts/path-c-split-worktree.sh`:
- **Setup** — per target: `LEAF=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/path-c-split-worktree.sh" setup <feature-worktree> <target>)`; put `cd $LEAF` in that leaf's prompt.
- **Reassemble** — after ALL leaves commit: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/path-c-split-worktree.sh" reassemble <feature-worktree> <target> [<target> ...]` cherry-picks each leaf's commits onto the feature branch. A conflict means the targets overlap: the helper aborts; re-plan, never force.
- **Teardown** — `bash "${CLAUDE_PLUGIN_ROOT}/scripts/path-c-split-worktree.sh" teardown <feature-worktree> <target> [<target> ...]` before push.

Non-overlapping targets may fan out fully concurrently; keep leaf returns terse. `fullsend --spawn` changes only the transport: the spawned session honors `PIPELINE_PATH_C_FANOUT` and needs no split-worktree step.
