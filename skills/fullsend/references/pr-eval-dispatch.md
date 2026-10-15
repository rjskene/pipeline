# PR-eval dispatch — the orchestrator's contract

Read this from `skills/fullsend/SKILL.md` Step 7 when assembling an
`evaluate-issue-pr` dispatch. This section is the ORCHESTRATOR's
contract, not the evaluator's — a `general-purpose` subagent never loads
`skills/evaluate-issue-pr/SKILL.md`, so the dispatch SITE is the binding copy
(#1444 moved it out of the evaluator's body for that reason).

## Invocation mode

Two dispatch shapes; every step below is identical, only CWD differs:

1. **Inline `Agent(...)` dispatch (PATH A, docs-only; PATH B, standard).** Worktree absolute path + issue number in the prompt. You are NOT in the worktree CWD — `cd <worktree-absolute-path>` before any step. (Per #748 PATH B PR-eval dispatches inline here, alongside PATH A — the inline B execute Agent and inline B PR-eval Agent are SEPARATE inline contexts for evaluator independence.)
2. **PATH C (multi-task) PR-eval — inline `Agent(...)` by default (#749/#891/#896); `${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh` / `claude -p` dispatch only under `--spawn` and explicit requests.** Already in the feature worktree; no `cd`.

For PATH A and PATH B (both inline) the orchestrator threads the manual-merge opt-out by including `MANUAL_MERGE=1` in the prompt (mirroring `spawn-claude.sh --manual-merge`). Inline token and env var are equivalent — both suppress the orchestrator's greenlight gate.
