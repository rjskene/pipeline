---
name: classify-issue
description: Triage a pipeline issue — reads title/body/labels/comments, recommends PATH A (docs-only), B (standard), or C (multi-task), and applies the `docs-only` / `multi-task` label directly. Posts a `## Classification` comment. Usage: /pipeline:classify-issue <issue_number>
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
```

The bash code blocks below reference these variables via `HTS-COLLAB-ORG/claude-pipeline`, `staging`, `for t in tests/test*.sh tests/test_*.sh; do [ -f "$t" ] && bash "$t" || true; done`, `CLAUDE.md`, etc. — they resolve from the sourced config, not from envsubst at install time. When prose refers to a config value by name (e.g., "the base branch is `PIPELINE_BASE_BRANCH`"), look it up in the sourced config.

# Classify Issue

You will receive an issue number as the argument. Perform:

1. **Fetch issue details:**
   ```bash
   gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json number,title,body,labels,updatedAt
   gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json comments --jq '.comments[] | {author: .author.login, createdAt: .createdAt, body: .body}'
   ```

2. **Cache check** — if the latest `## Classification` comment's `createdAt` is newer than the issue's `updatedAt`, the classification is fresh. In that case:
   - If the current labels already match the cached recommendation → exit 0 with "cached — no re-classification needed".
   - If the current labels do NOT match the cached recommendation → a user may have edited labels after the comment was posted. Print `Reconciling labels for cached classification #<N>`, then skip steps 3-6 and jump straight to step 5a (label application) using `recommended_path` pulled from the cached comment. Do NOT re-post the classification comment.

   ```bash
   LATEST_CLASS_TS=$(gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json comments \
     --jq '[.comments[] | select(.body | contains("## Classification"))] | max_by(.createdAt) | .createdAt // empty')
   ISSUE_TS=$(gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json updatedAt --jq '.updatedAt')
   # ISO-8601 timestamps are lexicographically ordered, so bash `[[ > ]]` string
   # comparison is equivalent to chronological comparison. Do NOT switch to `[ > ]`
   # (redirects stdout) or `-gt` (numeric only) — both are wrong for these values.
   if [[ -n "$LATEST_CLASS_TS" && "$LATEST_CLASS_TS" > "$ISSUE_TS" ]]; then
       # Pull recommended_path from the cached comment.
       CACHED_PATH=$(gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json comments \
         --jq '[.comments[] | select(.body | contains("## Classification"))] | max_by(.createdAt) | .body' \
         | grep -oE 'recommended_path:\*\* [ABC]' | awk '{print $2}' | head -1)
       CURRENT_LABELS=$(gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json labels --jq '.labels[].name')
       current_a=0; current_c=0
       printf '%s\n' "$CURRENT_LABELS" | grep -qx docs-only  && current_a=1
       printf '%s\n' "$CURRENT_LABELS" | grep -qx multi-task && current_c=1
       desired_a=0; desired_c=0
       case "$CACHED_PATH" in A) desired_a=1 ;; C) desired_c=1 ;; esac
       if [ "$current_a" = "$desired_a" ] && [ "$current_c" = "$desired_c" ]; then
           echo "Cached classification reused for issue #<N> (last classified at $LATEST_CLASS_TS)."
           exit 0
       fi
       echo "Reconciling labels for cached classification #<N> (path=$CACHED_PATH)."
       # Set vars for step 5a and skip straight there.
       ISSUE_N="<N>"
       RECOMMENDED_PATH="$CACHED_PATH"
       # Then jump to step 5a.
   fi
   ```

3. **Read first-level comments only** — ignore quoted/nested text. Consider only top-level comments.

4. **Score against rule set** (first match wins):

   | Signal | Path | Confidence |
   |--------|------|-----------|
   | Labels include `docs-only` | A | high |
   | Labels include `multi-task` | C | high |
   | Body/title contains `docs-only`, `update README`, `update CLAUDE.md`, "no logic", "documentation only", "rename", "typo" | A | medium |
   | Body has a numbered/bulleted list of 3+ independent tasks OR phrases "for each of", "multiple", "parallel", "batch", "one per" | C | medium |
   | Body mentions schema + API + frontend changes in a single issue | C | low |
   | Otherwise | B | medium |

5. **Compose the classification output:**

   ```markdown
   ## Classification

   - **recommended_path:** A | B | C
   - **confidence:** high | medium | low
   - **rationale:** <one or two sentences citing the signal(s)>

   _Label applied by classify-issue. Override by editing the label directly — the label always wins over the comment recommendation on next classification._
   ```

5a. **Apply the path label.** Set `ISSUE_N=<N>`, `RECOMMENDED_PATH=<A|B|C>`, and `CURRENT_LABELS=$(gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json labels --jq '.labels[].name')`, then run this block directly. It is bounded by sentinel comments that the pipeline test suite extracts.

   ```bash
   # BEGIN-LABEL-APPLY
   # Required env: ISSUE_N (issue number), RECOMMENDED_PATH (A|B|C),
   #   CURRENT_LABELS (newline-separated label names), REPO (owner/name).
   REPO="${REPO:-HTS-COLLAB-ORG/claude-pipeline}"
   _has_label() { printf '%s\n' "$CURRENT_LABELS" | grep -qx "$1"; }
   _safe_label() {
     # Guardrail: this skill may only edit the two path labels.
     case "$1" in
       docs-only|multi-task) return 0 ;;
       *) echo "REFUSED: label '$1' not in allow-set {docs-only|multi-task}" >&2; return 1 ;;
     esac
   }
   current_a=0; current_c=0
   _has_label docs-only  && current_a=1
   _has_label multi-task && current_c=1
   desired_a=0; desired_c=0
   case "$RECOMMENDED_PATH" in A) desired_a=1 ;; C) desired_c=1 ;; esac
   # Remove first, add second — avoids any momentary both-labels-present state
   # that could trip a hook checking label invariants.
   if [ "$current_a" -eq 1 ] && [ "$desired_a" -eq 0 ]; then
     _safe_label docs-only  && gh issue edit "$ISSUE_N" --repo "$REPO" --remove-label docs-only
   fi
   if [ "$current_c" -eq 1 ] && [ "$desired_c" -eq 0 ]; then
     _safe_label multi-task && gh issue edit "$ISSUE_N" --repo "$REPO" --remove-label multi-task
   fi
   if [ "$desired_a" -eq 1 ] && [ "$current_a" -eq 0 ]; then
     _safe_label docs-only  && gh issue edit "$ISSUE_N" --repo "$REPO" --add-label    docs-only
   fi
   if [ "$desired_c" -eq 1 ] && [ "$current_c" -eq 0 ]; then
     _safe_label multi-task && gh issue edit "$ISSUE_N" --repo "$REPO" --add-label    multi-task
   fi
   # END-LABEL-APPLY
   ```

   When reconciling a cached classification (from step 2), run step 5a only and stop. When classifying fresh, proceed to step 6.

6. **Post the classification comment:**
   ```bash
   gh issue comment <N> --repo HTS-COLLAB-ORG/claude-pipeline --body "<classification markdown>"
   ```

7. **Verify post** — count `## Classification` comments; retry once on 0; report FAILED if still 0.
   ```bash
   CLASS_COUNT=$(gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json comments \
     --jq '[.comments[] | select(.body | contains("## Classification"))] | length')
   ```

8. **Report:** "Classification posted to issue #N: <path> (<confidence>). Label applied: <docs-only | multi-task | none>."

## Prompt strategy

- Prefer **recall over precision**: false A→B is mild (plan-issue still works with extra detail), false B→A is disruptive (skips design rigor). Default to B when unsure.
- Existing labels are strong priors but not absolute. Explicit label → confidence=high unless content directly contradicts.
- Keep rationale to 1-2 sentences — human reads it during reconciliation, not a downstream skill.
- If an explicit user label contradicts the content (e.g., `docs-only` on a refactor), still recommend the user-labeled path but set confidence=low and note the conflict in rationale.

## Constraints
- MAY call `gh issue edit` to add/remove ONLY the `docs-only` and `multi-task` labels. Never touch any other label. Never modify code.
- Bullet points only. No prose padding.
