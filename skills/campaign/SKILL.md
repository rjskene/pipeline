---
name: campaign
description: Run a coordinated-leg campaign over the approved slate — the OUTER loop that partitions work into ordered, cap-bounded legs and sequences them so the global rate-limit budget is spent in bounded batches. Equivalent standalone entry to `/pipeline:fullsend --campaign`. Usage: /pipeline:campaign [issue_numbers...] [--manual-merge] [--spawn] [--max-bc=N] [--max-ad=N]
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Agent
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The bash code blocks referenced below resolve `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_CAMPAIGN_MAX_BC`, `PIPELINE_CAMPAIGN_MAX_AD`, etc. from the sourced config — not from envsubst at install time.

## Platform

Skills use Claude Code tool names; on Codex see [references/codex-tools.md](../references/codex-tools.md) for equivalents.

# Campaign — the coordinated-leg entry point

`/pipeline:campaign` runs the coordinated-leg **OUTER loop** over a slate of approved issues: it classifies/plans/eval-plans the ENTIRE set batched-under-caps, approves all up front, partitions the approved set into ordered per-leg batches via `scripts/plan-campaign.sh` (honoring `PIPELINE_CAMPAIGN_MAX_BC` / `PIPELINE_CAMPAIGN_MAX_AD`, overridable per-invocation via `--max-bc=N` / `--max-ad=N`), then runs each leg through the existing wave-by-wave execute → eval-pr → greenlight-merge machinery — advancing the base tip between legs and folding/filing campaign-surfaced bug signals at the end. This spends the global rate-limit budget in bounded batches rather than a single flat blast of the whole set.

## Single source of truth — defer to fullsend's `## Campaign mode`

This skill is a **THIN entry point**: it owns NO leg-loop prose of its own. The campaign machinery — campaign flow (a)→(e), the global-budget rule, the base-advance + usage read-out at each leg boundary, the per-leg two-layer signal dedup, the **End-of-campaign fold wave (#838)**, **End-of-campaign bug filing**, the **scoped halt** (dependency-closure drop), and the **self-mutation callout** — is documented as the **single source of truth** in `skills/fullsend/SKILL.md` `## Campaign mode`.

**Follow that `## Campaign mode` section verbatim** over this skill's slate. `/pipeline:fullsend --campaign` enters the **identical** machinery — the two entry points share one copy of the leg-loop prose, so they can never drift. Carry forward all of that section's contracts by reference:

- **Caps / overrides:** `PIPELINE_CAMPAIGN_MAX_BC` (B/C-pool per-leg cap) and `PIPELINE_CAMPAIGN_MAX_AD` (A/D-pool per-leg cap) from the environment, overridable per-invocation via the `--max-bc=N` / `--max-ad=N` flags forwarded to `scripts/plan-campaign.sh`. `PIPELINE_CAMPAIGN_MAX_FOLD` (default 3) bounds the end-of-campaign fold wave.
- **Partitioner / helpers (reused verbatim, NOT forked):** `scripts/plan-campaign.sh` (partition, `closure`, `aggregate-signals`, `fold-select`) and `scripts/usage-surface.sh` (leg-boundary usage read-out).
- **Autonomy + two-layer dedup (#863):** end-of-campaign filing routes through the deterministic, NON-INTERACTIVE create-issues subset only (never the interactive brainstorming dialogue), and dedups against open issues + the running campaign-filed set both per-leg and at completion.

`--spawn` (reverts PATH C to the legacy `spawn-claude.sh` run-queue transport) and `--manual-merge` compose freely with this skill exactly as they do under `/pipeline:fullsend --campaign`. There is no machinery here to maintain separately — edit the canonical `## Campaign mode` section in `skills/fullsend/SKILL.md` and both entry points pick it up.
