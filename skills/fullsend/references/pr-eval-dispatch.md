# PR-eval dispatch — the orchestrator's contract

Read this from `skills/fullsend/SKILL.md` Step 7 when assembling an
`evaluate-issue-pr` dispatch. These three sections are the ORCHESTRATOR's
contract, not the evaluator's — a `general-purpose` subagent never loads
`skills/evaluate-issue-pr/SKILL.md`, so the dispatch SITE is the binding copy
(#1444 moved them out of the evaluator's body for that reason).

## Invocation mode

Three dispatch shapes; every step below is identical, only CWD + visual-proof setup differs:

1. **Inline `Agent(...)` dispatch (PATH A, docs-only; PATH B, standard).** Worktree absolute path + issue number in the prompt. You are NOT in the worktree CWD — `cd <worktree-absolute-path>` before any step. (Per #748 PATH B PR-eval dispatches inline here, alongside PATH A — the inline B execute Agent and inline B PR-eval Agent are SEPARATE inline contexts for evaluator independence.)
2. **PATH C (multi-task) PR-eval — inline `Agent(...)` by default (#749/#891/#896); `${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh` / `claude -p` dispatch only under `--spawn` and explicit requests.** Already in the feature worktree; no `cd`.
3. **Inline Agent dispatch (browser-eval; triggered by the `needs-browser` label).** Worktree absolute path + issue number + PR + port + target-dir-abs + auto-merge-gate token are pre-resolved by the orchestrator; you `cd <worktree-abs>` and start the loopback HTTP server before any other step. The dispatch path is in-process `Agent()` triggered by the `needs-browser` label on the PR's source issue. Visual proof for these PRs reads from `http://127.0.0.1:$PORT/` against the durable URL substring `raw.githubusercontent.com/<owner>/<repo>/<merge-sha>/.eval-screenshots/` once step 3 of [auto-merge-gate.md](auto-merge-gate.md) rewrites the eval comment — branch-pinned URLs apply during the review window only. See `skills/evaluate-issue-pr/references/visual-validation.md` for the loopback server setup, and [auto-merge-gate.md](auto-merge-gate.md) for the auto-merge gate — which the ORCHESTRATOR fires at Step 7 after the evaluator returns, not the evaluator.

For PATH A and PATH B (both inline) the orchestrator threads the manual-merge opt-out by including `MANUAL_MERGE=1` in the prompt (mirroring `spawn-claude.sh --manual-merge`). Inline token and env var are equivalent — both suppress the orchestrator's greenlight gate.

## Canonical Agent prompt template (assembled by orchestrator)

The inline Agent dispatch (mode #3 above) is launched by the orchestrator with the following prompt body. Fields are pre-resolved by the orchestrator — the subagent does NOT re-derive them:

```
You are dispatched to run /pipeline:evaluate-issue-pr <N> inline.
Context (pre-resolved by orchestrator — do not re-derive):
  - Worktree:   <abs-path>
  - PR:         <PR-num>
  - Target dir: <PIPELINE_VISUAL_PROOF_TARGET_DIR resolved abs-path>
  - Port:       <P>  (advisory; the helper re-allocates via the broker, --bind 127.0.0.1)
  - Auto-merge: <gated|allowed>  (per manual-merge label check)
Setup: cd <worktree>;
       SERVER_LINE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/visual-proof-server-start.sh" "${SLATE_INDEX:-0}" "$TARGET_DIR" 2>&1) || { echo "$SERVER_LINE"; exit 1; };
       PORT=$(printf '%s\n' "$SERVER_LINE" | sed -n 's/^SERVER: .*port=\([0-9]*\) .*/\1/p');
       SERVER_PID=$(printf '%s\n' "$SERVER_LINE" | sed -n 's/^SERVER: pid=\([0-9]*\) .*/\1/p');
       trap 'kill "$SERVER_PID" 2>/dev/null' EXIT
Then: follow skills/evaluate-issue-pr/SKILL.md verbatim against http://127.0.0.1:$PORT.
Terminal state: post `## Evaluation` comment via gh with an explicit `**Verdict:**` line; report the verdict. The ORCHESTRATOR fires the auto-merge gate afterwards.
```

Field semantics:
- **Worktree** — absolute path to the feature worktree; subagent `cd`s here before any other step.
- **PR** — PR number; threaded as `$PR_NUM` for the rest of the skill.
- **Target dir** — absolute path under the worktree served by `python3 -m http.server`; resolved from `PIPELINE_VISUAL_PROOF_TARGET_DIR`.
- **Port** — advisory only. `scripts/visual-proof-server-start.sh` re-allocates the port via the broker (`scripts/visual-proof-port-broker.sh <slate_index>`) at start time and emits the actual `port=` on its `SERVER:` line; the Setup block parses `$PORT` from there. The single-issue orchestrator path (#527) does not pre-resolve this field at all.
- **Auto-merge** — gate token threaded through to the orchestrator's gate; `gated` mirrors `--manual-merge` / `MANUAL_MERGE=1`, `allowed` lets the greenlight matrix decide.

## Migration warning (issue #517 — owner: `scripts/run-queue.sh launch_agent()`)

When a PR carries the `needs-browser` label but `PIPELINE_VISUAL_PROOF_TARGET_DIR` is unset on the operator's `pipeline.config`, the orchestrator (in `scripts/run-queue.sh launch_agent()`, NOT this skill) emits a **one-time stderr warning** plus a Notes column entry on the status table. Evaluation proceeds **without visual proof** — the warning is non-blocking and never blocks the verdict. This is the documented consumer-migration story for operators upgrading from 0.17.x to a release that defaults the inline browser-eval path; set `PIPELINE_VISUAL_PROOF_TARGET_DIR` to opt into inline visual proof; otherwise evaluation proceeds without it (non-blocking). The warning surface lives in `run-queue.sh launch_agent()` so it fires once per dispatch — this skill only documents the contract.
