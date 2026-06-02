# Status table — renderer contract + example output

## Source of truth

Rendering is delegated to `scripts/render-status-table.sh`. The renderer is the single source of truth for column widths, ordering, header lines, and footer formats — future tweaks ship as script changes plus golden-file updates, not prompt edits. SKILL.md keeps a compact pointer; the full input-file assembly + invocation contract is here.

## Inputs

This step consumes `TRACKER_ISSUES` from the tracker-filter block in Step 1 (rendered as tracker rows with their open children indented underneath), plus the full open-issue list from Step 1, plus the `RELEASE_PRS` line block from Step 0. The renderer expects three files — capture all three before invoking it:

```bash
# 1) issues.json — verbatim gh issue list payload. Re-fetch here so the
#    renderer reads .body (used by NOTES blocked-by parsing and att lookup);
#    Step 1's ISSUE_LIST_JSON is partition-scoped (--json number,title,labels)
#    and does not carry .body.
ISSUES_JSON=$(mktemp)
gh issue list --repo "$PIPELINE_REPO" --state open \
  --json number,title,labels,body,updatedAt --limit 100 > "$ISSUES_JSON"

# 2) trackers.json — JSON object {"<tracker_number>": "<body string>", ...}.
#    For each tracker in TRACKER_ISSUES, fetch the body and assemble the map.
TRACKERS_JSON=$(mktemp); echo '{}' > "$TRACKERS_JSON"
for tracker in $TRACKER_ISSUES; do
  body=$(gh issue view "$tracker" --repo "$PIPELINE_REPO" --json body --jq .body)
  TRACKERS_JSON_NEXT=$(jq --arg k "$tracker" --arg v "$body" '. + {($k): $v}' "$TRACKERS_JSON")
  printf '%s' "$TRACKERS_JSON_NEXT" > "$TRACKERS_JSON"
done
```

The renderer pipes each tracker body through `${CLAUDE_PLUGIN_ROOT}/scripts/parse-tracker-children.sh` to extract checklist children and intersect them with the open-issue set. Closed children are omitted; children referenced under any tracker are removed from the orphan candidate set.

The third input — `release-prs.txt` — is the verbatim line block emitted by `scripts/list-release-prs.sh` (already captured into `$RELEASE_PRS` in Step 0; one line per release PR: `pr=<num> ci=<pass|fail|pending> title=<title>`). Feed it via bash process substitution; the renderer reads `--release-prs` with `[ -r ]` so a `/dev/fd/N` path works.

## Invocation

Print the renderer's stdout verbatim:

```bash
PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_BASE_BRANCH="$PIPELINE_BASE_BRANCH" \
  PIPELINE_PROJECT_ROOT="$(pwd)" \
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/render-status-table.sh" \
    --issues "$ISSUES_JSON" \
    --trackers "$TRACKERS_JSON" \
    --release-prs <(printf '%s\n' "$RELEASE_PRS")
rm -f "$ISSUES_JSON" "$TRACKERS_JSON"
```

Bash tool stdout is hidden inside a folded tool call, so after invoking the renderer the orchestrator MUST paste the renderer's EXACT stdout verbatim into a single fenced code block in its next assistant message — byte-for-byte, with nothing added or removed around the rows. **Contract violation:** reformatting the table, restating rows in prose, narrating per-row, or substituting a "here's the gist" summary for the rendered output. The renderer stays the single deterministic source of truth (golden-file guaranteed) — do NOT re-render the table from JSON in the model and do NOT route it through a file; paste the renderer's stdout verbatim.

The renderer emits the canonical status table to stdout: a release-PR block (only when the release-prs file is non-empty; Stage column renders as the display-only literal `release-pending`, NOT a real GitHub label), then the dated status header, then a tracker section (with each open child indented, or a placeholder for trackers whose children are all closed), then a flat orphan section sorted by readiness (ready first) then conventional-commit type (chore→docs→fix→feat), then a non-default-metadata block (Target Base / Path / Blocked by / on-disk attachments), then any multi-tracker WARN lines, then a counts footer (`N epics + N children + N orphans = T open`). See `scripts/render-status-table.sh` and `tests/test-render-status-table.sh` for the canonical format and per-rule contract; `att` is sourced from `$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-<N>/` and is populated upstream by `/pipeline:fullsend` step 1a or `/pipeline:plan-issue` step 3b — the run skill does NOT re-fetch attachments at discovery time.

## Example output

A labeled ~10-line ASCII example covering release-PR row, tracker section, orphan section, NOTES block, and counts footer:

### Grouped layout

```
PIPELINE STATUS — <today's date>
================================================================
EPICS
================================================================
 [P1] #120 — feat(install): consumer install hardening
         #144 — feat(doctor): label seeding              (plan-approved)
         #145 — feat(install): CLAUDE.md cleanup         (in-progress)
         #146 — feat(install): settings.json patch       (plan-pending)
 [P2] #131 — feat(observability): self-improve loop
         (all children closed — pending auto-close)
================================================================
ORPHANS
================================================================
    [P2] #999 — chore: bump tooling                                             (ready)
    [P2]  #34 — feat(run): sort status table by scope                           (ready)
    [P1] #133 — feat(run): canonical status table grouped by tracker + scope    (plan-pending)
    [P2] #150 — feat(doctor): settings cleanup patch                            (merged)
================================================================
```

### NOTES footer

```
NOTES (non-default)
================================================================
 Issue  | Target Base | Path | Blocked by | att
----------------------------------------------------------------
 #150   | next        | A    | --         | 0
 #133   | pipeline    | B    | #132       | 3
================================================================
```

### Counts footer

```
5 epics + 19 children + 5 orphans = 29 open
```
