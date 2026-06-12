# restrict_paths: drop the vestigial CLAUDE_PLUGIN_ROOT fail-open — Design

**Issue:** #966 (brainstorm → actionable on approval of this spec)
**Date:** 2026-06-12
**Status:** Approved design, pending implementation plan

## Problem

When `CLAUDE_PLUGIN_ROOT` is unset in the hook's process env,
`hooks/restrict_paths.py` warns on stderr and `sys.exit(0)` — **fail-open**,
silently disabling the *entire* boundary + protected-file guard for that
call. The block was added by #389 as a deliberate recovery for #339
(`CLAUDE_PLUGIN_ROOT` not propagating into Bash subshells). #339 closed
2026-05-21. #966 asked which fail posture should replace it (fail-closed /
fail-open-but-loud / config-gated / resolve-first).

## Evidence: the question is moot

The guard protects a variable the script **does not use**:

- `PLUGIN_ROOT` is read at `hooks/restrict_paths.py:10`, checked at :11–21,
  and **never dereferenced again** anywhere in the file.
- Imports anchor on `Path(__file__).parent` (line 23) — not the env var.
- Project dir comes from `CLAUDE_PROJECT_DIR` (line 31); config reads go
  through `_read_config(..., project_dir=PROJECT_DIR)` (line 37).
- Neither `hooks/_pipeline_config.py` nor `hooks/subagent_log_utils.py`
  reads `CLAUDE_PLUGIN_ROOT`.
- No other hook under `hooks/` carries this guard (repo-wide scan,
  2026-06-12) — `restrict_paths.py` is the only site.

The guard's stated premise ("cannot resolve plugin paths") is false today:
when the script runs, `__file__` is ground truth for the plugin's hooks dir.
The only true `CLAUDE_PLUGIN_ROOT` dependency is the **hook command
template** in `.claude-plugin/plugin.json`
(`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/restrict_paths.py`) — substituted by
the harness *before* launch. If that substitution ever fails, the script
never runs at all; no in-script posture can address it, and that failure
mode is the harness's contract, not this hook's.

## Decision

| # | Decision | Choice |
|---|----------|--------|
| R1 | Fail posture | **None needed — delete the guard.** Remove `hooks/restrict_paths.py:10–21` (the read, the warning, the `sys.exit(0)`). With the dead dependency gone, an unset `CLAUDE_PLUGIN_ROOT` changes nothing: the hook enforces normally. |
| R2 | Rejected alternatives | Fail-closed (`exit 2`): punishes a var the script doesn't need; would re-introduce a #339-shaped hard stop for zero gain. Fail-open-but-loud: keeps a bypass that has no reason to exist. Config-gated flag: a knob for a non-choice. Resolve-don't-trust (port the bash cache-glob resolver): resolves a value nothing consumes. All four treat the guard as load-bearing; it is vestigial. |
| R3 | Regression test | New case(s) in the restrict_paths test substrate invoking the hook with `CLAUDE_PLUGIN_ROOT` **absent** from the env (`env -i PATH=... CLAUDE_PROJECT_DIR=... python3 hooks/restrict_paths.py`): out-of-boundary path → exit 2 + `BLOCKED`; in-boundary path → exit 0. This pins the hardening: unset var can never again mean guard-off. |

## Change

- `hooks/restrict_paths.py` — delete lines 10–21 (the `PLUGIN_ROOT`
  read + fail-open block). Module docstring untouched; no other behavior
  change. Net diff: −12 lines.
- `tests/test-restrict-paths-hook.sh` (or a sibling following its
  `env -i` invocation shape, per `tests/test-restrict-paths-worktree-git.sh`):
  add the unset-`CLAUDE_PLUGIN_ROOT` enforcement cases (R3).

Behavior delta: previously, unset var → warn + allow everything (total
bypass). After: unset var → full enforcement, indistinguishable from the
set-var path. No consumer-visible behavior changes when the var IS set
(the universal case).

## Testing

1. Unset-var + out-of-boundary Write/Bash path → exit 2, `BLOCKED` on stderr.
2. Unset-var + in-boundary path → exit 0, no spurious stderr warning.
3. Existing suites (`tests/test-restrict-paths-hook.sh`,
   `tests/test-restrict-paths-worktree-git.sh`) pass unchanged — they set
   the var explicitly, and the deleted block was upstream of everything
   they assert.

## Out of scope

- `block-private-paths` malformed-stdin fail-open (consumer-side hook) —
  noted in #966 as a parallel posture case; separate issue if pursued.
- The #917 stdin-read fail-open timeout — orthogonal, deliberate, keeps.
- Harness-level `${CLAUDE_PLUGIN_ROOT}` command-template substitution —
  not addressable in-script (see Evidence).

## Issue hygiene

On spec approval: retitle #966 →
`fix(hooks): restrict_paths — remove vestigial CLAUDE_PLUGIN_ROOT fail-open
(unset var disabled the whole guard)`, replace the body with the actionable
shape referencing this spec, drop `brainstorm`.

## Related

- #966 — the brainstorm this spec actions.
- #339 — the closed propagation regression the guard recovered from.
- #389 — added the guard. #964/#965 — the protected-file hardening this
  guard fronts (why a silent total-bypass matters).
