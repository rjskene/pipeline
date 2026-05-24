---
name: classify-issue
description: Triage a pipeline issue — reads title/body/labels/comments, recommends PATH A (docs-only), B (standard), C (multi-task), or D (quick-fix), and applies the `docs-only` / `multi-task` / `quick-fix` label directly. Posts a `## Classification` comment. Usage: /pipeline:classify-issue <issue_number>
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

# Classify Issue

## Paths

The pipeline dispatches on one of four paths; this SKILL owns their definitions.

| Path | Label | Dispatcher | Discipline |
|------|-------|------------|-----------|
| A | `docs-only` | direct edits in worktree | flat edit → commit; no test cycle |
| B | (no path label) | spawned worker session | red → green → commit (TDD) |
| C | `multi-task` | `tdd-implementer` subagents per target dir | hook-enforced delegation; orchestrator may not Edit impl files |
| D | `quick-fix` | inline `tdd-implementer` in orchestrator | red → green → commit inline; `execute-issue-plan` Step 8 skipped |

### PATH D (quick-fix)

PATH D is the body-marker primary route: declare `<!-- pipeline:path=D -->` in the issue body when the work is a one-line, single-precedent fix. Recurring shapes:

- Precedent-mirror fix (`same shape as merged PR #X`).
- One-line config flip (toggle a flag in `pipeline.config`; repoint a path constant).
- Dogfood-mirror byte-identical edit (copy a fix from one settings file to a sibling).
- Guard-test addition to an existing test file (one new assertion; no new file).
- One-bullet bug report with a quoted error and an obvious one-liner.

Execution: inline `tdd-implementer` in the orchestrator session (no spawned worker); `evaluate-issue-pr` is the sole review gate — `execute-issue-plan` Step 8 is skipped.

## How classification runs

The skill receives an issue number as argument. Perform:

1. **Fetch issue details:**
   ```bash
   gh issue view <N> --repo $PIPELINE_REPO --json number,title,body,labels,updatedAt
   gh issue view <N> --repo $PIPELINE_REPO --json comments --jq '.comments[] | {author: .author.login, createdAt: .createdAt, body: .body}'
   ```

2. **Cache check.** If the latest `## Classification` comment's `createdAt` is newer than the issue's `updatedAt`, the classification is fresh. If current labels match the cached recommendation → exit 0 ("cached — no re-classification needed"). If they don't → print `Reconciling labels for cached classification #<N>` and jump to step 5a using the cached `recommended_path`. Do NOT re-post the classification comment.

   ```bash
   LATEST_CLASS_TS=$(gh issue view <N> --repo $PIPELINE_REPO --json comments \
     --jq '[.comments[] | select(.body | contains("## Classification"))] | max_by(.createdAt) | .createdAt // empty')
   ISSUE_TS=$(gh issue view <N> --repo $PIPELINE_REPO --json updatedAt --jq '.updatedAt')
   # ISO-8601 sorts lexicographically; `>` is strict-greater so add an OR-equality clause to treat same-second as fresh (issue #457).
   if [[ -n "$LATEST_CLASS_TS" && ( "$LATEST_CLASS_TS" > "$ISSUE_TS" || "$LATEST_CLASS_TS" == "$ISSUE_TS" ) ]]; then
       CACHED_PATH=$(gh issue view <N> --repo $PIPELINE_REPO --json comments \
         --jq '[.comments[] | select(.body | contains("## Classification"))] | max_by(.createdAt) | .body' \
         | grep -oE 'recommended_path:\*\* [ABCD]' | awk '{print $2}' | head -1)
       CURRENT_LABELS=$(gh issue view <N> --repo $PIPELINE_REPO --json labels --jq '.labels[].name')
       current_a=0; current_c=0; current_d=0
       printf '%s\n' "$CURRENT_LABELS" | grep -qx docs-only  && current_a=1
       printf '%s\n' "$CURRENT_LABELS" | grep -qx multi-task && current_c=1
       printf '%s\n' "$CURRENT_LABELS" | grep -qx quick-fix  && current_d=1
       desired_a=0; desired_c=0; desired_d=0
       case "$CACHED_PATH" in A) desired_a=1 ;; C) desired_c=1 ;; D) desired_d=1 ;; esac
       if [ "$current_a" = "$desired_a" ] && [ "$current_c" = "$desired_c" ] && [ "$current_d" = "$desired_d" ]; then
           echo "Cached classification reused for issue #<N> (last classified at $LATEST_CLASS_TS)."
           exit 0
       fi
       echo "Reconciling labels for cached classification #<N> (path=$CACHED_PATH)."
       ISSUE_N="<N>"
       RECOMMENDED_PATH="$CACHED_PATH"
       # Jump to step 5a.
   fi
   ```

3. **Read first-level comments only** — ignore quoted/nested text. Consider only top-level comments.

3c. **Body marker — primary route (evaluated before the rule table).** See "## PATH D" above for when to add the marker. If the issue body contains `<!--\s*pipeline:path=[A-Da-d]\s*-->` (POSIX equivalent: `<!--[[:space:]]*pipeline:path=[A-Za-z][[:space:]]*-->`), the claim is authoritative: path = marker letter uppercased (A/B/C/D); confidence = high; rationale = "user-claimed path via body marker". First marker wins; malformed letters fall through to step 4. Run the parser; if `MARKER_PATH` is non-empty, set `RECOMMENDED_PATH=$MARKER_PATH` and skip to step 5. The B-marker case still runs step 5a so any prior `docs-only`/`multi-task`/`quick-fix` label is removed.

   ```bash
   # BEGIN-PATH-MARKER-PARSE
   # Required env: ISSUE_BODY (issue body markdown, may be multi-line).
   # Sets: MARKER_PATH ("A"|"B"|"C"|"D" or empty string).
   # Regex: <!--\s*pipeline:path=[A-Da-d]\s*--> (POSIX equivalent below).
   MARKER_PATH=""
   _raw=$(printf '%s' "$ISSUE_BODY" \
     | grep -oE '<!--[[:space:]]*pipeline:path=[A-Za-z][[:space:]]*-->' \
     | head -1)
   if [ -n "$_raw" ]; then
     _letter=$(printf '%s' "$_raw" \
       | grep -oE 'pipeline:path=[A-Za-z]' \
       | head -1 \
       | cut -d= -f2 \
       | tr 'a-z' 'A-Z')
     case "$_letter" in
       A|B|C|D) MARKER_PATH="$_letter" ;;
       *) MARKER_PATH="" ;;
     esac
   fi
   # END-PATH-MARKER-PARSE
   ```

4. **Score against rule set** (first match wins):

   | Signal | Path | Confidence |
   |--------|------|-----------|
   | Labels include `docs-only` | A | high |
   | Labels include `multi-task` | C | high |
   | Labels include `quick-fix` | D | high |
   | Body/title contains `docs-only`, `update README`, `update CLAUDE.md`, "no logic", "documentation only", "rename", "typo" | A | medium |
   | Implied patch size: one file + ≤ ~20 LOC source → lean D; ≤ 3 files + ≤ ~40 LOC → lean B (estimate from the change described, NOT the issue body length) | D or B | medium |
   | Body/title contains `one-line`, `single-line`, `single-file`, `single-subsystem`, `narrow fix`, `minimal`, `trivial`, `obvious`, `~N LOC` (N ≤ 30), `no design choice`, `single condition`, `one regex`, `flip`, `swap`, `repoint`, `toggle`, `rename`, `typo`, `add guard`, `small bug`, `tweak`, or labels include `quick-fix` | D | medium |
   | Body has a numbered/bulleted list of 3+ **independent** tasks (see alternative-bullet rule below) OR phrases `for each of`, `multiple`, `parallel`, `batch`, `one per` | C | medium |
   | Body mentions schema + API + frontend changes in a single issue | C | low |
   | Otherwise | B | medium |

   - **Alternative-bullet rule.** Lists of alternatives — `options:`, `either`, `choose one`, `pick one` — count as one work item with design ambiguity, not N tasks; lean B (not C) on 3+ alternatives to one decision.
   - **Acceptance-criteria skip.** Bullets nested under `Acceptance`, `Acceptance Criteria`, or `Out of scope` are verification scope or non-goals — skip them; do not count them as work items.
   - **Generic-keyword tightening for D triggers.** `flip` and `swap` fire D only when they co-occur with a code-shaped token (file path with `/`+extension, function name in parens, or a backticked `code` token); bare "flip the wording" does NOT trigger D. `tweak`, `obvious`, `minimal` retain broad match.

4a. **Read any ingested attachments.** Before composing, list and `Read` every file in `.claude/scratch/issue-<N>/` (populated upstream by `/pipeline:fullsend` step 1a or `/pipeline:plan-issue` step 3b). If empty or absent, skip — this step does NOT re-fetch. Mandatory for issues labeled `bug` or `user-submitted`.

   ```bash
   ls -1 .claude/scratch/issue-<N>/ 2>/dev/null || echo "(no attachments)"
   ```

5. **Compose the classification output:**

   ```markdown
   ## Classification
   - **recommended_path:** A | B | C | D
   - **confidence:** high | medium | low
   - **rationale:** <one or two sentences citing the signal(s)>

   _Label applied by classify-issue; override by editing the label directly — the label always wins over the comment on next classification._
   ```

5a. **Apply the path label.** Set `ISSUE_N=<N>`, `RECOMMENDED_PATH=<A|B|C|D>`, and `CURRENT_LABELS=$(gh issue view <N> --repo $PIPELINE_REPO --json labels --jq '.labels[].name')`, then run the sentinel-bounded block below. (Preserve byte-for-byte: pipeline tests extract it by sentinel and run it under stub `gh`.)

   ```bash
   # BEGIN-LABEL-APPLY
   # Required env: ISSUE_N (issue number), RECOMMENDED_PATH (A|B|C|D),
   #   CURRENT_LABELS (newline-separated label names), REPO (owner/name).
   REPO="${REPO:-$PIPELINE_REPO}"
   _has_label() { printf '%s\n' "$CURRENT_LABELS" | grep -qx "$1"; }
   _safe_label() {
     # Guardrail: this skill may only edit the three path labels.
     case "$1" in
       docs-only|multi-task|quick-fix) return 0 ;;
       *) echo "REFUSED: label '$1' not in allow-set {docs-only|multi-task|quick-fix}" >&2; return 1 ;;
     esac
   }
   current_a=0; current_c=0; current_d=0
   _has_label docs-only  && current_a=1
   _has_label multi-task && current_c=1
   _has_label quick-fix  && current_d=1
   desired_a=0; desired_c=0; desired_d=0
   case "$RECOMMENDED_PATH" in A) desired_a=1 ;; C) desired_c=1 ;; D) desired_d=1 ;; esac
   # Remove first, add second — avoids any momentary both-labels-present state
   # that could trip a hook checking label invariants.
   if [ "$current_a" -eq 1 ] && [ "$desired_a" -eq 0 ]; then
     _safe_label docs-only  && gh issue edit "$ISSUE_N" --repo "$REPO" --remove-label docs-only
   fi
   if [ "$current_c" -eq 1 ] && [ "$desired_c" -eq 0 ]; then
     _safe_label multi-task && gh issue edit "$ISSUE_N" --repo "$REPO" --remove-label multi-task
   fi
   if [ "$current_d" -eq 1 ] && [ "$desired_d" -eq 0 ]; then
     _safe_label quick-fix  && gh issue edit "$ISSUE_N" --repo "$REPO" --remove-label quick-fix
   fi
   if [ "$desired_a" -eq 1 ] && [ "$current_a" -eq 0 ]; then
     _safe_label docs-only  && gh issue edit "$ISSUE_N" --repo "$REPO" --add-label    docs-only
   fi
   if [ "$desired_c" -eq 1 ] && [ "$current_c" -eq 0 ]; then
     _safe_label multi-task && gh issue edit "$ISSUE_N" --repo "$REPO" --add-label    multi-task
   fi
   if [ "$desired_d" -eq 1 ] && [ "$current_d" -eq 0 ]; then
     _safe_label quick-fix  && gh issue edit "$ISSUE_N" --repo "$REPO" --add-label    quick-fix
   fi
   # END-LABEL-APPLY
   ```

   When reconciling a cached classification (step 2), run step 5a only and stop. When classifying fresh, proceed to step 6.

6. **Post the classification comment:**
   ```bash
   gh issue comment <N> --repo $PIPELINE_REPO --body "<classification markdown>"
   ```

7. **Verify post** — count `## Classification` comments; retry once on 0; report FAILED if still 0.
   ```bash
   CLASS_COUNT=$(gh issue view <N> --repo $PIPELINE_REPO --json comments \
     --jq '[.comments[] | select(.body | contains("## Classification"))] | length')
   ```

8. **Report:** "Classification posted to issue #N: <path> (<confidence>). Label applied: <docs-only | multi-task | quick-fix | none>."

## Prompt strategy

- Prefer **recall over precision**: false A→B is mild, false B→A is disruptive — default to B when unsure.
- Existing labels are strong priors; explicit label → confidence=high unless content directly contradicts.
- Keep rationale to 1-2 sentences.
- Label contradicts content (e.g., `docs-only` on a refactor): recommend the labeled path with confidence=low; note the conflict in rationale.

## Constraints
- MAY call `gh issue edit` to add/remove ONLY the `docs-only`, `multi-task`, and `quick-fix` labels. Never touch any other label. Never modify code.
- Body markers (`<!-- pipeline:path=... -->`) are honored when present and well-formed; they short-circuit the rule table but do NOT bypass step 5a label application. The B marker REMOVES any existing A/C/D label and adds nothing.
- Bullet points only. No prose padding.
