# Dispatch routing by path tier

The per-path dispatch contract for the autonomous flow. `/pipeline:status` is read-only; fullsend owns all dispatch.

**Cost attribution key — every dispatch description carries the literal `#<N>`.** Binding on every orchestrator dispatch (classify, plan, plan-eval, execute, PATH C leaf, pr-eval, closing review): a bare integer attributes to nothing and its cost vanishes from that issue's row. Canonical shapes: `classify-issue #<N>`, `plan-issue #<N>`, `evaluate-issue-plan #<N>`, `execute-issue-plan #<N>`, `execute-issue-plan #<N> target=<dir>/`, `evaluate-issue-pr #<N>`, `code review #<N>`. Suffixes are append-only (`(PATH B inline)`, `(PATH D collapsed inline tdd)`, `target=<dir>/`), and the description MUST BEGIN with its canonical stage token — `plan evaluation for #<N>` parses as `stage=plan`.

**Agent `subagent_type` namespacing convention.** One axis decides the prefix: **built-in vs plugin-provided**.

- **Harness built-ins are BARE**: `general-purpose`, `Explore`, `Plan`, `statusline-setup`. Do NOT namespace them.
- **Plugin-provided agents are NAMESPACED** `<plugin manifest \`name\`>:<agent frontmatter \`name\`>` — here `pipeline:tdd-implementer`. The bare form is absent from the registry and hard-fails at dispatch time.
- **Third-party plugin agents obey the same rule** (`<plugin>:<agent>`).
- **Resolution rule — DERIVE, never guess**: the namespace from the plugin's `.claude-plugin/plugin.json` `name`, the agent from its frontmatter `name:`. It is not host-dependent.
- **Guard:** `tests/test-dispatch-namespace-convention.sh` (forbidden set derived from the manifest's `agents[]`) and `tests/test-subagent-type-namespace.sh`.

**For PR evaluation (pr-open → evaluated).** The worktree already exists; route by tier. **Every** shape carries `model=$MODEL` from `bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stage-model.sh" <N> pr-eval` (`PIPELINE_STAGE_MODEL_PR_EVAL`, unset ⇒ `opus`):
   - **PATH A** (`docs-only`): dispatch inline — no `spawn-claude.sh`, no `claude -p`, no tmux:
     ```
     Agent(subagent_type='general-purpose',
           model='<resolved-pr-eval-model>',
           description='evaluate-issue-pr #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/evaluate-issue-pr/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. MANUAL_MERGE=<0|1>')
     ```
   - **PATH B** (standard): dispatch inline — No spawn-claude.sh, no run-queue.sh, no tmux:
     ```
     Agent(subagent_type='general-purpose',
           model='<resolved-pr-eval-model>',
           description='evaluate-issue-pr #<N> (PATH B inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/evaluate-issue-pr/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. MANUAL_MERGE=<0|1>')
     ```
     The execute Agent and the PR-eval Agent are SEPARATE inline contexts — an agent must not evaluate its own work.
   - **PATH C** (`multi-task`): inline `Agent(subagent_type='general-purpose', ...)` as PATH B by default; under `--spawn`, the `spawn-claude.sh` / `run-queue.sh` launch flow.
   - **PATH D**: PR evaluation stays `general-purpose` (NOT `tdd-implementer`) — `Agent(subagent_type='general-purpose', ...)`, shape identical to PATH A.

**For execution (plan-approved → worktree setup).** After the worktree is set up, route by tier:
   - **PATH A** (`docs-only`): dispatch inline — no `spawn-claude.sh`, no `claude -p`, no tmux; `model=$MODEL` from `scripts/resolve-execute-dispatch.sh <N> A` (`PIPELINE_PATH_A_MODEL_EXECUTE`, unset ⇒ `opus`):
     ```
     Agent(subagent_type='general-purpose',
           model='<resolved-model>',
           description='execute-issue-plan #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. PRE_PR_REVIEW=<on|off>')
     ```
   - **PATH B** (standard): dispatch inline — resolver-driven via `scripts/resolve-execute-dispatch.sh`. No spawn-claude.sh, no run-queue.sh, no tmux. ONE execute agent (see **Per-path execute MODEL routing** below):
     ```
     Agent(subagent_type='general-purpose',
           model='<resolved-model>',
           description='execute-issue-plan #<N> (PATH B inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. PRE_PR_REVIEW=<on|off>')
     ```
     It applies the `tdd-implementer` discipline per plan task, completes ALL plan deliverables, and runs the FULL local suite green before `gh pr create`. `model=` defaults to `opus` when `PIPELINE_PATH_B_MODEL_EXECUTE` is unset. `PIPELINE_PATH_B_ELIGIBLE_SCOPE` defaults to `all`; a W2 carve-out always pins opus (`model=opus`).
   - **PATH C** (`multi-task`): dispatch inline by DEFAULT — resolve ONCE via `scripts/resolve-execute-dispatch.sh <N> C` and branch on the `DISPATCH` line's `PATH_C_FANOUT=` token. **`PATH_C_FANOUT=off` (default):** ONE `Agent(subagent_type='general-purpose', model=$MODEL, description='execute-issue-plan #<N> (PATH C inline)', prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. PRE_PR_REVIEW=<on|off> PATH_C_FANOUT=off')` exactly as PATH B (`PIPELINE_PATH_C_MODEL_EXECUTE`, unset ⇒ `opus`); it runs the `target=<dir>` tasks sequentially and owns Step 8, push, `gh pr create` and labels; no `path-c-split-worktree.sh`, delegation hook inert. **`PATH_C_FANOUT=on`:** every leaf gets the same `model=$MODEL`; the orchestrator fans out one `Agent(subagent_type='pipeline:tdd-implementer', model='<resolved-model>', description='execute-issue-plan #<N> target=<dir>/ ...', prompt: 'cd <leaf-worktree>; target=<dir>/ ...')` per `target=<dir>`, **each in its OWN per-leaf worktree** (`scripts/path-c-split-worktree.sh setup`) so leaves never share a git index, up to the **max-3 foreground bound**. Then `path-c-split-worktree.sh reassemble <feature-worktree> <target>...` (cherry-pick; a conflict signals non-disjoint targets), `teardown`, push, `gh pr create`, labels. The orchestrator runs Step 8 itself per `PRE_PR_REVIEW=` (`off` ⇒ log `PRE-PR-REVIEW: skipped reason=knob`) — never as a leaf, since `tdd-implementer` has no `Skill` tool. **Cost attribution — dispatch descriptions are the attribution key:** every leaf is described `execute-issue-plan #<N> target=<dir>/ …`. The orchestrator MUST NOT `Edit`/`Write` impl files (`enforce-path-c-delegation` blocks it). **Under `--spawn`, `--spawn` forces the legacy `spawn-claude.sh` / `run-queue.sh` → `claude -p` TRANSPORT**; the spawned session honors `PIPELINE_PATH_C_FANOUT`.
   - **PATH D** (`quick-fix`): dispatch inline via `Agent(subagent_type='pipeline:tdd-implementer', description='execute-issue-plan #<N> (PATH D collapsed inline tdd)', prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>.')`. No spawn-claude.sh, no tmux, no run-queue.sh. The bare `tdd-implementer` does NOT resolve.

     **Collapsed-D ceremony.** **One collapsed inline `Agent`** doing **classify+plan+execute** in one carried-forward context — NOT three separate dispatches. pr-eval stays a SEPARATE inline agent (evaluator independence). Bound at **max 3 concurrent inline** D agents. Consume-or-produce: upstream `## Classification` / `## Implementation Plan` comments are read when present, produced only when absent.

   - **Per-path execute MODEL routing — SINGLE-SOURCE resolver.** Before any PATH A/B/C/D **execute** `Agent` (every PATH C leaf carries the SAME model), do **NOT** hand-apply the model decision; consume the resolver's tokens **verbatim**. One wave call (`scripts/fullsend-dispatch-specs.sh <N>...`) derives the PATH from the label (`docs-only`→A, `multi-task`→C, `quick-fix`→D, else B) and prints one `DISPATCH issue=#<N>` line of `scripts/resolve-execute-dispatch.sh` tokens: `MODEL=`, `PRE_PR_REVIEW=`, `PATH_C_FANOUT=` (PATH C only), plus advisory `ELIGIBLE=`/`SCOPE=`/`REASON=` (it always exits 0).
     - **ALWAYS pass `model=$MODEL`** on the execute `Agent(...)` — the resolver always emits a named model; an unpinned dispatch inherits the session model.
     - **One execute agent** in the worktree, described `execute-issue-plan #<N>`.
     - **Relay `PRE_PR_REVIEW=` verbatim into the A/B (and PATH C PATH_C_FANOUT=off) execute prompt** — the agent keys Step 8 off it, never off env.
     - **Relay `ELIGIBLE=`/`SCOPE=`/`REASON=` in the run log.**
     - **Trust profile:** log one `TRUST-PROFILE: profile=<p> issue=#N plan_eval=<run|skip> plan_gate=<full|single|none> plan_rounds=<k>` line per issue — `profile` is `PIPELINE_TRUST_PROFILE` (unset ⇒ `strict`), `plan_eval=skip` iff Step 2 skipped it, `plan_gate` the resolved `GATE=`, `k` the evaluate dispatches made.

     The resolver folds the per-path knobs (`PIPELINE_PATH_A_MODEL_EXECUTE`, `PIPELINE_PATH_B_MODEL_EXECUTE`, `PIPELINE_PATH_C_MODEL_EXECUTE`, `PIPELINE_PATH_D_MODEL_EXECUTE`) into one spec; each knob unset or empty defaults to `opus` (`REASON=default-opus`), and an explicit value (e.g. `=sonnet`) is honored verbatim. `PIPELINE_PATH_B_ELIGIBLE_SCOPE`, when unset or empty, defaults to `all` (opt-out `=low-blast`). For PATH D the W2 check is unconditional. Carve-outs reuse `scripts/path-b-execute-eligible.sh` + `scripts/_high-uncertainty-match.sh`:
     - **W2 high-uncertainty → Opus.** A PATH B `high-uncertainty` REASON, or a PATH D issue matching `HIGH_UNCERTAINTY_RE` (`concurrency`/`auth`/`lock`/`race`/`deadlock`/`security`/`crypto`/`migration`/`data-loss`), resolves `MODEL=opus`.
     - **PATH B `low-blast` lane.** `ELIGIBLE=<low-blast|high-blast>` is a dispatch-time estimate. Under `SCOPE=low-blast`, a `high-blast` PATH B pins opus (`model=opus`); under `SCOPE=all` the verdict is advisory.

     **pr-eval is NEVER defaulted to Sonnet.** The pr-eval dispatch is never gated by these execute knobs: it is pinned `opus` via `PIPELINE_STAGE_MODEL_PR_EVAL` (`resolve-stage-model.sh <N> pr-eval`). The execute resolver rejects stage words (exit 2), so it cannot emit a pr-eval model.
