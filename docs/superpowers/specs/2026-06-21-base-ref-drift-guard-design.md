# Base-ref drift guard — design (#1106)

**Date:** 2026-06-21
**Issue:** #1106 — split-role RED execution moved the orchestrator's local `staging` ref to the RED anchor commit (base-tip corruption).
**Path:** B (multi-file: new script + tests + two skill edits).

## Root cause (diagnosed — no longer `needs-debug`)

During the leg-1 split-role execution of #1098, the `[split-role-red]` anchor commit (`7ca20dd`) was committed **directly onto `staging` in the main orchestrator checkout**, not onto the feature branch in the worktree. The `git reflog staging` is definitive:

```
7ca20dd staging@{4}: commit: test(observability): [split-role-red] failing suite ...
f18a1e1 staging@{5}: commit: docs(tokenomics): cache-read ...
```

and the main-repo `HEAD` reflog shows `HEAD@{9}: 7ca20dd commit:` while HEAD was on `staging`.

**Mechanism.** The Bash tool's working directory resets to the project root (the main checkout, on `staging`) on a fresh invocation unless re-anchored each call. The RED agent's initial `cd <worktree>` did not hold for the later `git commit` call, so the commit landed on `staging`, advancing the shared ref by one commit. RED is uniquely exposed because it *only* commits (no push / no PR) — the single-agent PATH D runs (#1102, #1099) push and open a PR on the feature branch, so they operate on the feature branch and never exhibited the drift. (GREEN later pulled the anchor onto the feature branch via rebase/merge, which is why PR #1104 still contained it.)

The drift surfaced downstream as a spurious `no-red-sha` split-role-gate block (the anchor was excluded from the corrupted `<base>..HEAD` range) and left the RED test files in the orchestrator's main working tree. It was recovered mid-campaign via `git reset --hard origin/staging`.

## Goals

1. **Prevent** an execute/split-role agent from committing onto the base branch (fix the cause at source).
2. **Detect + safely recover** base-ref drift from *any* future cause, without halting an otherwise-healthy autonomous campaign and without ever orphaning committed work.

Non-goal: a global commit-blocking hook (see Rejected alternatives).

## Architecture — two independent layers

### Layer 1 — Prevention (dispatch-prompt contract)

Execute and split-role dispatch prompts gain two directives (dispatch-site, because subagents do not load the skill body — same rationale as the existing `git add <paths>` staging contract):

- **Anchor every git command with `git -C <worktree-abs-path>`** — do not rely on cwd persistence across bash calls.
- **Pre-commit branch assert:** before any commit, `git -C <wt> symbolic-ref --short HEAD` MUST equal the dispatched feature branch; otherwise **STOP and report** (do not commit).

Homes:
- `skills/fullsend/SKILL.md` — Step 6 inline execute dispatch contract (the RED-author, GREEN-implementer, and collapsed-D prompt directives).
- `skills/execute-issue-plan/SKILL.md` — the corresponding split-role RED/GREEN and collapsed-D execution contracts.

### Layer 2 — Cause-agnostic safety net (orchestrator guard)

New `scripts/check-base-ref-drift.sh <base-branch> <expected-sha> [feature-branch...]`.

- Resolves the local base SHA and compares to `<expected-sha>` (snapshotted by the orchestrator immediately before the Step-6 dispatch).
- Emits exactly one token on stdout; **always exits 0** (the verdict rides the token, mirroring `verify-execute-completion.sh` / `*-gate.sh`):
  - `BASE=ok` — local base SHA unchanged.
  - `BASE=recovered` — base drifted, AND every stray commit in `origin/<base>..<local-base>` is reachable from at least one passed feature branch → run `git reset --hard origin/<base>` and report recovery.
  - `BASE=drift-unsafe ORPHANS=<shas>` — at least one stray commit is not reachable from any passed feature branch → **do NOT reset** (resetting would orphan committed work); the orchestrator STOPs and reports for manual recovery.
  - `BASE=error REASON=<...>` — internal failure (unresolvable ref, bad args); advisory, no mutation, orchestrator relays without halting (fail-open).
- Fail-open on its own internal failure — never gate-fatal except the deliberate `drift-unsafe` hard-stop.

**Reachability predicate** ("safe to recover"): a stray commit `C` is safe iff `git merge-base --is-ancestor C <feature-branch>` is true for some passed feature branch. All stray commits must be safe for `BASE=recovered`; otherwise `drift-unsafe`.

**Call sites (orchestrator):**
- `skills/fullsend/SKILL.md` Step 6a — snapshot base SHA before dispatch; after the inline batch returns, call the guard with the wave's feature branches; act on the token (`ok`→continue, `recovered`→continue, `drift-unsafe`→scoped halt + report).
- Campaign leg boundaries — same check after the inter-leg base advance.

## Data flow

```
orchestrator: BASE0 = git rev-parse <base>           (pre-dispatch snapshot)
   → dispatch execute agents (Layer-1-hardened prompts)
   → Step 6a: check-base-ref-drift.sh <base> $BASE0 <feature-branches...>
        BASE=ok          → proceed
        BASE=recovered   → proceed (base reset to origin/<base>)
        BASE=drift-unsafe→ STOP, report ORPHANS for manual recovery
```

## Error handling

- Guard internal error (unresolvable ref, bad args) → non-fatal, emit `BASE=ok` is NOT assumed; emit a `BASE=error REASON=<...>` advisory token and let the orchestrator relay it without halting (fail-open). The only hard stop is `drift-unsafe`.
- Layer-1 assert failure inside an agent → the agent STOPs and reports a FAILED line (standard execute terminal-state contract); the orchestrator's Step-6a completion check then sees the unfinished issue and recovers/redispatches.

## Testing

- `tests/test-check-base-ref-drift.sh` — temp git-repo fixture:
  - (a) no drift → `BASE=ok`, base SHA unchanged.
  - (b) stray commit reachable from a feature branch → `BASE=recovered`, base reset to `origin/<base>` verified, stray commit preserved on the feature branch.
  - (c) orphan stray commit (on no feature branch) → `BASE=drift-unsafe`, base NOT reset, orphan SHA reported.
  - (d) bad args / unresolvable ref → `BASE=error`, exit 0, no mutation.
- Dispatch-contract grep test — assert `skills/fullsend/SKILL.md` and `skills/execute-issue-plan/SKILL.md` carry the `git -C` + branch-assert directive (mirrors the existing dispatch-contract guard tests).

## Rejected alternatives

- **Global PreToolUse hook blocking `git commit` on the base branch.** Would break legitimate orchestrator base-branch commits (spec/doc commits, release back-sync) and cannot be cleanly scoped to "during an execute dispatch." The Layer-1 prompt assert + Layer-2 orchestrator net cover the case without that collateral.
- **Always auto-recover (unconditional reset).** Risks orphaning a stray commit not yet on a feature branch — reintroduces a different data-loss path. Rejected in favor of the reachability-gated recover.
- **Always halt on drift.** Safe but halts an otherwise-healthy autonomous campaign on a recoverable condition (exactly what happened in this campaign). Rejected in favor of recover-when-safe.

## Issue hygiene

Drop the `needs-debug` label from #1106 — the root cause is now pinned (this spec). The issue proceeds as a standard PATH B fix.

## Files

- NEW `scripts/check-base-ref-drift.sh`
- NEW `tests/test-check-base-ref-drift.sh`
- EDIT `skills/fullsend/SKILL.md` (Step 6 dispatch contract; Step 6a guard call; campaign leg-boundary call)
- EDIT `skills/execute-issue-plan/SKILL.md` (split-role RED/GREEN + collapsed-D `git -C` / branch-assert directive)
