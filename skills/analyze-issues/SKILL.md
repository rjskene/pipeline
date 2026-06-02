---
name: analyze-issues
description: Read-only hygiene pass over the open-issue set; surfaces likely duplicates, tracker fits, missing labels, and merged-PR supersession candidates. Usage: /pipeline:analyze-issues
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Agent
---

## Boot

Subagent shells inherit nothing from the orchestrator session — they must source
the config so `PIPELINE_REPO`, `CLAUDE_PLUGIN_ROOT`, and friends are populated.
Prepend this boot block before any shell work in this skill (and pass it into
dispatched subagent prompts that run shell commands):

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

# Analyze mode

Read-only hygiene pass over the open-issue set. Surfaces likely duplicates and standalones that fit existing trackers so the user can decide whether to close, merge, or re-bucket before the next full send. **No mutations.** Decision-support only — the user reads the digest and runs the suggested `gh` commands manually.

**Trigger.** The primary entrypoint is `/pipeline:analyze-issues` (no args) — invoking the skill directly runs the read-only hygiene pass. For back-compat, the `--analyze` argv parser is still documented: parse `--analyze` from any argv position (same pattern as `--manual-merge`). The token must not collide with bare issue numbers, so any token starting with `--` is filtered out of the issue-number list. Parser sketch:

```bash
ANALYZE=0
for arg in "$@"; do
  case "$arg" in
    --analyze) ANALYZE=1 ;;
  esac
done
```

**Branch behavior.** When invoked via `/pipeline:analyze-issues` (or with `ANALYZE=1` on the back-compat path), this skill SKIPS classify / plan / execute / eval entirely and exits cleanly after printing the digest. No labels are applied, no comments are posted, no PRs are opened, no worktrees are created. The session is fully read-only.

**Stage 1 — heuristic shortlist.** Run the deterministic shell helper and capture its single-line stdout as the shortlist path:

```bash
SHORTLIST_PATH=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/analyze-issues.sh")
```

The helper writes JSON to `.claude/logs/analyze-shortlist-<ISO>.json` with four keys, `duplicate_pairs`, `tracker_fits`, `missing_label_candidates`, and `supersession_candidates`, each capped at 20 entries. The path is the only stdout line.

The `missing_label_candidates` entries are produced purely mechanically — they flag issues lacking a `priority/P*` label, a `docs-only`/`multi-task` path label, or any pipeline-stage/classification label (with a 24h age gate to skip just-filed issues; configurable via `PIPELINE_ANALYZE_MIN_AGE_HOURS`). No subagent confirmation is needed for these — the suggested `gh issue edit` command is rendered directly from the JSON row.

The `supersession_candidates` entries pair an open issue with one or more recently-merged PRs whose touched files or title overlap the issue's scope. The shell helper only assembles the candidate pairs mechanically; it does NOT decide whether the issue is actually superseded. That verdict and its confidence are assigned by the LLM subagent in Stage 2.

**Stage 2 — subagent dispatch.** Hand the shortlist to a general-purpose subagent which confirms / denies each LLM-required candidate and synthesizes the suggested `gh` command. Verbatim block:

```
Agent(subagent_type='general-purpose',
      description='analyze open-issue hygiene shortlist',
      prompt='Read shortlist at <SHORTLIST_PATH>. The JSON has four keys:
              duplicate_pairs, tracker_fits, missing_label_candidates,
              supersession_candidates.

              For each duplicate-pair row, run gh issue view <a> --json
              title,body and gh issue view <b> --json title,body;
              confirm/deny duplication, assign confidence (high|medium|low),
              write a one-line rationale, and synthesize the gh command.

              For each tracker-fits row, run gh issue view <issue> and
              gh issue view <tracker>; confirm/deny fit, same fields.

              For each missing_label_candidates row, NO per-issue
              gh issue view confirmation is required — the signal is
              purely label-presence-based. Pass the row straight through
              to the rendered table and synthesize the suggested
              gh issue edit command from the .missing array (e.g.
              `gh issue edit <N> --add-label priority/P2` when "priority"
              appears in .missing).

              For each supersession_candidates row, run
              gh pr view <pr> --json files,body,title and
              gh issue view <issue> --json body,createdAt. Emit a verdict
              {superseded | partially-superseded | unrelated} with a
              {high|medium|low} confidence and a one-line rationale.
              Confidence thresholds (you apply these — they are NOT
              hard-coded in the shell helper):
                - high   if files-overlap >= 50% AND the merged PR title
                         mentions the same scope as the issue;
                - medium if files-overlap >= 1 OR a scope-match alone;
                - low    for weak title-keyword matches only.
              Synthesize the suggested manual command:
                gh issue close <N> --reason completed
                  --comment "Superseded by #<PR>: <rationale>"

              Output ONLY the four markdown tables defined in this
              analyze-issues skill section. Omit a table
              entirely if it has zero high|medium findings (for the LLM-
              classified categories) or zero rows (for missing-label).
              No mutations.')
```

Substitute `<SHORTLIST_PATH>` with the path captured in Stage 1.

**Stage 3 — output contract.** The subagent prints up to four markdown tables to the orchestrator conversation. If a category has zero high|medium findings (LLM-classified) or zero rows (missing-label), its table is omitted (no empty noise).

```
## Duplicate candidates
| Pair | Confidence | Reason | Suggested action |
|------|------------|--------|-------------------|

## Standalones that fit an existing tracker
| Issue | Tracker | Confidence | Reason | Suggested action |
|-------|---------|------------|--------|-------------------|

## Issues missing labels
| Issue | Missing | Suggested action |
|-------|---------|-------------------|

## Possibly superseded by recent commits
| Issue | Superseding PR(s) | Confidence | Reason | Suggested action |
|-------|-------------------|------------|--------|-------------------|
```

Omit the `## Issues missing labels` section entirely if `missing_label_candidates` is empty — same convention as the other tables. Likewise omit the `## Possibly superseded by recent commits` section when it has zero high|medium findings.

**Constraints.** No mutations. No auto-close, no auto-label, no auto-comment. The pipeline does not run `gh issue close`, `gh issue edit`, or `gh issue comment` from this branch. The user reads the digest and decides what to act on. The `scripts/analyze-issues.sh` helper now emits four keys (`duplicate_pairs`, `tracker_fits`, `missing_label_candidates`, `supersession_candidates`).
