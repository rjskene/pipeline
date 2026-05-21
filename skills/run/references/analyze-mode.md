# Analyze mode (--analyze)

Read-only hygiene pass over the open-issue set. Surfaces likely duplicates and standalones that fit existing trackers so the user can decide whether to close, merge, or re-bucket before the next full send. **No mutations.** Decision-support only — the user reads the digest and runs the suggested `gh` commands manually.

**Trigger.** Parse `--analyze` from any argv position (same pattern as `--manual-merge`). The token must not collide with bare issue numbers, so any token starting with `--` is filtered out of the issue-number list. Parser sketch:

```bash
ANALYZE=0
for arg in "$@"; do
  case "$arg" in
    --analyze) ANALYZE=1 ;;
  esac
done
```

**Branch behavior.** When `ANALYZE=1`, this skill SKIPS classify / plan / execute / eval entirely and exits cleanly after printing the digest. No labels are applied, no comments are posted, no PRs are opened, no worktrees are created. The session is fully read-only.

**Stage 1 — heuristic shortlist.** Run the deterministic shell helper and capture its single-line stdout as the shortlist path:

```bash
SHORTLIST_PATH=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/analyze-issues.sh")
```

The helper writes JSON to `.claude/logs/analyze-shortlist-<ISO>.json` with three keys, `duplicate_pairs`, `tracker_fits`, and `missing_label_candidates`, each capped at 20 entries. The path is the only stdout line.

The `missing_label_candidates` entries are produced purely mechanically — they flag issues lacking a `priority/P*` label, a `docs-only`/`multi-task` path label, or any pipeline-stage/classification label (with a 24h age gate to skip just-filed issues; configurable via `PIPELINE_ANALYZE_MIN_AGE_HOURS`). No subagent confirmation is needed for these — the suggested `gh issue edit` command is rendered directly from the JSON row.

**Stage 2 — subagent dispatch.** Hand the shortlist to a general-purpose subagent which confirms / denies each LLM-required candidate and synthesizes the suggested `gh` command. Verbatim block:

```
Agent(subagent_type='general-purpose',
      description='analyze open-issue hygiene shortlist',
      prompt='Read shortlist at <SHORTLIST_PATH>. The JSON has three keys:
              duplicate_pairs, tracker_fits, missing_label_candidates.

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

              Output ONLY the three markdown tables defined in
              skills/run/SKILL.md analyze-mode section. Omit a table
              entirely if it has zero high|medium findings (for the LLM-
              classified categories) or zero rows (for missing-label).
              No mutations.')
```

Substitute `<SHORTLIST_PATH>` with the path captured in Stage 1.

**Stage 3 — output contract.** The subagent prints up to three markdown tables to the orchestrator conversation. If a category has zero high|medium findings (LLM-classified) or zero rows (missing-label), its table is omitted (no empty noise).

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
```

Omit the `## Issues missing labels` section entirely if `missing_label_candidates` is empty — same convention as the other two tables.

**Constraints.** No mutations. No auto-close, no auto-label, no auto-comment. The pipeline does not run `gh issue close`, `gh issue edit`, or `gh issue comment` from this branch. The user reads the digest and decides what to act on.
