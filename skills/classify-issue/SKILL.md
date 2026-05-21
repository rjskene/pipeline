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
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The bash code blocks below reference these variables via `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_TEST_CMD`, `PIPELINE_CONTEXT_FILES`, etc. — they resolve from the sourced config, not from envsubst at install time. When prose refers to a config value by name (e.g., "the base branch is `PIPELINE_BASE_BRANCH`"), look it up in the sourced config.

# Classify Issue

You will receive an issue number as the argument. Perform:

1. **Fetch issue details:**
   ```bash
   gh issue view <N> --repo $PIPELINE_REPO --json number,title,body,labels,updatedAt
   gh issue view <N> --repo $PIPELINE_REPO --json comments --jq '.comments[] | {author: .author.login, createdAt: .createdAt, body: .body}'
   ```

2. **Cache check** — if the latest `## Classification` comment's `createdAt` is newer than the issue's `updatedAt`, the classification is fresh. In that case:
   - If the current labels already match the cached recommendation → exit 0 with "cached — no re-classification needed".
   - If the current labels do NOT match the cached recommendation → a user may have edited labels after the comment was posted. Print `Reconciling labels for cached classification #<N>`, then skip steps 3-6 and jump straight to step 5a (label application) using `recommended_path` pulled from the cached comment. Do NOT re-post the classification comment.

   ```bash
   LATEST_CLASS_TS=$(gh issue view <N> --repo $PIPELINE_REPO --json comments \
     --jq '[.comments[] | select(.body | contains("## Classification"))] | max_by(.createdAt) | .createdAt // empty')
   ISSUE_TS=$(gh issue view <N> --repo $PIPELINE_REPO --json updatedAt --jq '.updatedAt')
   # ISO-8601 timestamps are lexicographically ordered, so bash `[[ > ]]` string
   # comparison is equivalent to chronological comparison. Do NOT switch to `[ > ]`
   # (redirects stdout) or `-gt` (numeric only) — both are wrong for these values.
   if [[ -n "$LATEST_CLASS_TS" && "$LATEST_CLASS_TS" > "$ISSUE_TS" ]]; then
       # Pull recommended_path from the cached comment.
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
       # Set vars for step 5a and skip straight there.
       ISSUE_N="<N>"
       RECOMMENDED_PATH="$CACHED_PATH"
       # Then jump to step 5a.
   fi
   ```

3. **Read first-level comments only** — ignore quoted/nested text. Consider only top-level comments.

3c. **Body marker — documented primary route for PATH D (and the other paths) (evaluated before the rule table).** When you know an issue is PATH D (precedent-mirror fix, one-line flip, dogfood mirror, guard-test addition, etc.), put `<!-- pipeline:path=D -->` in the body at filing time. This is the authoritative, deterministic route to PATH D. The phrase heuristics in the rule table below are a best-effort fallback for unmarked issues — they will not reliably flip a B-shaped body to D no matter how many trigger words are present.

   If the issue body contains an HTML comment of the form `<!--\s*pipeline:path=[A-Da-d]\s*-->` (POSIX equivalent: `<!--[[:space:]]*pipeline:path=[A-Za-z][[:space:]]*-->`), that claim is authoritative. Path = the marker letter normalized to uppercase (one of A/B/C/D); confidence = high; rationale = "user-claimed path via body marker". If multiple markers appear, the FIRST one (document order) wins. If the marker letter is not one of A/B/C/D, the marker is malformed and ignored — fall through to step 4 keyword scoring (the rule table below). Run the parser block below; if `MARKER_PATH` is non-empty, set `RECOMMENDED_PATH=$MARKER_PATH` and skip directly to step 5 (compose) and 5a (apply label). The B-marker case still runs step 5a so that any prior `docs-only`/`multi-task`/`quick-fix` label is removed (B is the unlabeled default).

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

   **Authoring guide for PATH D candidates.** If you are authoring a PATH D candidate, include the marker — these are the shapes that consistently miss the phrase heuristic in step 4 despite being unambiguous one-line fixes:

   - Precedent-mirror fixes (`same shape as merged PR #X`, `same path-math family as #277`).
   - One-line config flips (flip a flag in `pipeline.config`, repoint a path constant).
   - Dogfood-mirror byte-identical edits (copy a fix from one settings file to a sibling).
   - Guard-test additions to an existing test file (one new assertion, no new file).
   - One-bullet bug reports with a quoted error message and an obvious one-line fix.

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

   - **Alternative-bullet rule.** A bulleted list whose items are alternatives — introduced by `options:`, `either`, `choose one`, `pick one`, `A or B or C`, etc. — counts as one work item with design ambiguity, not N tasks. Lean B (not C) when an issue presents 3+ alternatives to a single design decision.
   - **Acceptance-criteria skip.** Bullets nested under a heading `Acceptance`, `Acceptance Criteria`, or `Out of scope` are verification scope or non-goals for a single change, not parallel tasks. Skip those lists when counting "3+ independent tasks" — do not count them as work items.
   - **Generic-keyword tightening for D triggers.** The words `flip` and `swap` fire D only when they co-occur with a code-shaped token in the same bullet/sentence: a file path (contains `/` and an extension), a function name (camelCase or snake_case ending in parens), or a backticked `code` token. Bare "flip the wording" / "swap the diagram" does NOT trigger D. The generic words `tweak`, `obvious`, and `minimal` retain a broad match; a one-time reclassify sweep after merge is the documented mitigation for any false-D fires.

4a. **Read any ingested attachments.** Before composing the classification output, list and `Read` every file present in `.claude/scratch/issue-<N>/`. These were populated upstream by `/pipeline:fullsend` step 1a (autonomous mode) or `/pipeline:plan-issue` step 3b (interactive mode). If the directory is empty or absent, skip — this step does NOT itself re-fetch attachments.

   ```bash
   ls -1 .claude/scratch/issue-<N>/ 2>/dev/null || echo "(no attachments)"
   ```

   **For each file printed by `ls -1`, invoke the `Read` tool exactly once before composing the output.** Mandatory for issues labeled `bug` or `user-submitted`; recommended for others. Placement after step 2's cache short-circuit guarantees zero token cost on cache-hit runs.

5. **Compose the classification output:**

   ```markdown
   ## Classification

   - **recommended_path:** A | B | C | D
   - **confidence:** high | medium | low
   - **rationale:** <one or two sentences citing the signal(s)>

   _Label applied by classify-issue. Override by editing the label directly — the label always wins over the comment recommendation on next classification._
   ```

5a. **Apply the path label.** Set `ISSUE_N=<N>`, `RECOMMENDED_PATH=<A|B|C|D>`, and `CURRENT_LABELS=$(gh issue view <N> --repo $PIPELINE_REPO --json labels --jq '.labels[].name')`, then run this block directly. It is bounded by sentinel comments that the pipeline test suite extracts.

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

   When reconciling a cached classification (from step 2), run step 5a only and stop. When classifying fresh, proceed to step 6.

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

- Prefer **recall over precision**: false A→B is mild (plan-issue still works with extra detail), false B→A is disruptive (skips design rigor). Default to B when unsure.
- Existing labels are strong priors but not absolute. Explicit label → confidence=high unless content directly contradicts.
- Keep rationale to 1-2 sentences — human reads it during reconciliation, not a downstream skill.
- If an explicit user label contradicts the content (e.g., `docs-only` on a refactor), still recommend the user-labeled path but set confidence=low and note the conflict in rationale.

## Constraints
- MAY call `gh issue edit` to add/remove ONLY the `docs-only`, `multi-task`, and `quick-fix` labels. Never touch any other label. Never modify code.
- Body markers (`<!-- pipeline:path=... -->`) are honored when present and well-formed; they short-circuit the rule table but do NOT bypass step 5a label application. The B marker REMOVES any existing A/C/D label and adds nothing.
- Bullet points only. No prose padding.
