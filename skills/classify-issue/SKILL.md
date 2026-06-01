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

Execution: collapsed single-pass inline `tdd-implementer` in the orchestrator session (no spawned worker); `evaluate-issue-pr` is the sole review gate — `execute-issue-plan` Step 8 is skipped. In the autonomous run/fullsend lanes, PATH D classify is the FIRST stage run INSIDE that single collapsed inline context (classify → plan → execute carried forward as one context), so the recommended_path / `quick-fix` label checkpoint is emitted by that same collapsed agent rather than by a separate upstream classify dispatch. The standalone interactive `/pipeline:classify-issue N` invocation and the `<!-- pipeline:path=D -->` body-marker route are UNCHANGED — they still post a `## Classification` comment and apply the path label directly.

**Escalation backstop (down-route safety net).** The collapsed D lane has an escalation backstop: if the executor finds mid-run that the change exceeds D's envelope, it aborts up to a spawned PATH B run (see `execute-issue-plan`'s Collapsed inline D contract). That backstop is the precondition that makes a wrong B→D down-route (the #707 dependency) cheap and recoverable — mis-routing B work into D is reversed by escalation, not by shipping a too-large diff, so classification may lean D without fear.

#### Blast-radius B→D routing (Affected areas heuristic)

**The rule (Blast-radius B→D).** Parse the issue body's `## Affected areas` section and count non-test source files, excluding any path under `tests/` or `fixtures/`; when `type = fix(` AND that source-file count is `≤ 2` AND all files share a single top-level module AND the high-uncertainty carve-out below does NOT apply, the issue is a **PATH D** candidate (strong prior, medium confidence).

**`fix(`-applicability.** The down-route applies only to `type == fix(` work. `feat(` issues are NEVER auto-down-routed by file count — feature work carries design/novelty uncertainty that file count does not proxy; a `feat(` with ≤ 2 files stays B.

**High-uncertainty carve-out (the protected axis).** Even for a `fix(` at `≤ 2` files in a single module, the down-route is SUPPRESSED — the issue stays B — when the title, body, or labels carry high-uncertainty signals: any of `concurrency`, `race`, `lock`, `deadlock`, `security`, `auth`, `crypto`, `migration`, or `data-loss`, or a label such as `security` / `concurrency`. Blast radius (file count) and uncertainty are orthogonal: a one-file race-condition fix is tiny in blast radius but high in correctness risk, so the carve-out guards the uncertainty axis that the `fix(` gate alone would admit.

**Not an override.** This is a strong prior feeding step 4's score table, never an override: the authoritative `<!-- pipeline:path=D -->` body marker (step 3c) and an explicit path label (step 4 row 1) both still win over the blast-radius prior. Mined LOW-uncertainty exemplars (these down-route — few-shot calibration beats a numeric threshold):

| issue | Affected areas | source files (non-test) | uncertainty | route |
|-------|----------------|-------------------------|-------------|-------|
| #691 | 1 src + test | 1 | low | D |
| #667 | 1 src + test | 1 | low | D |
| #656 | script + config + test | 2 | low | D |
| #698 | 3 src + tests | 3 | low | **B (boundary — >2 source files = legitimate B; rule self-calibrates)** |

Worked high-uncertainty counter-example (the carve-out in action — small blast radius, but stays B):

| shape | Affected areas | source files | signal | route |
|-------|----------------|--------------|--------|-------|
| race-condition `fix(` | 1 src + test (single module) | 1 | `race` / `concurrency` / `lock` | **B (carve-out: file count says D, but the high-uncertainty signal SUPPRESSES the down-route — must NOT be flagged D)** |

**Acceptance.** The issue's acceptance gate — "no false-D on high-uncertainty issues (concurrency, security)" — is discharged by the carve-out, not by the `fix(`/`feat(` split: only LOW-uncertainty small fixes down-route, while high-uncertainty small `fix(` work is suppressed and held in B, so no high-uncertainty issue can be auto-D-routed by file count. The worked counter-example above is the asserted proof of the protected axis. This is a guidance-presence discharge, not an empirical sweep — classify-time data (no LOC, no diff) cannot support a runtime held-out harness, so the carve-out's signal vocabulary is the held-out protection, asserted statically in CI, and #700's escalation backstop remains the cost net for any residual mis-route. LOC is a retrospective validation signal only, never a classify-time input.

## How classification runs

The skill receives an issue number as argument. Perform:

0a. **Opener-association gate (trust precondition).** Resolve the issue OPENER's GitHub `authorAssociation` and check it against the `is-trusted-author` primitive (`scripts/filter-trusted-comments.sh`, issue #545). If the opener lacks write access (association not in {OWNER, MEMBER, COLLABORATOR}), the body is untrusted: REFUSE to classify. Do NOT post a `## Classification` comment, do NOT run the BEGIN-LABEL-APPLY block, do NOT apply any path label. Post a single triage-request comment surfacing the issue for human triage, then STOP. ("Human gates matter.") Resolve the association via `gh api` (NOT `gh issue view --json author`, which has no association field), then call `is-trusted-author` single-arg:

   ```bash
   ASSOC=$(gh api repos/$PIPELINE_REPO/issues/<N> --jq '.author_association')
   if ! bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/filter-trusted-comments.sh" is-trusted-author "$ASSOC"; then
     gh issue comment <N> --repo "$PIPELINE_REPO" --body "Untrusted opener (authorAssociation=$ASSOC, no write access): surfacing for human triage. (issue #546)"
     echo "REFUSED: untrusted opener (assoc=$ASSOC) for #<N>; not classified, no label applied." ; exit 0
   fi
   ```

1. **Fetch issue details and the trusted comment working set:**
   ```bash
   gh issue view <N> --repo $PIPELINE_REPO --json number,title,body,labels,updatedAt
   # Trusted-only working set (issue #546, helper from #545) — drops comments from
   # authors lacking write access; stdout = body + trusted comments, stderr = audit.
   TRUSTED=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/filter-trusted-comments.sh" <N>)
   ```

   All comment reads below (cache check in step 2, first-level comments in step 3) operate on the trusted working set `$TRUSTED`, never on a raw `gh ... --json comments` fetch.

2. **Cache check.** If the latest **trusted** `## Classification` comment's `createdAt` is newer than the issue's `updatedAt`, the classification is fresh. If current labels match the cached recommendation → exit 0 ("cached — no re-classification needed"). If they don't → print `Reconciling labels for cached classification #<N>` and jump to step 5a using the cached `recommended_path`. Do NOT re-post the classification comment. The `recommended_path` is parsed from the trusted working set `$TRUSTED` (step 1), and the freshness timestamp is taken only from Classification comments authored by trusted writers — pipeline-posted `## Classification` comments survive both filters because the operator account is OWNER, so the freshness/reconcile logic is unchanged. An outsider cannot poison the cache with a fake `## Classification` comment.

   ```bash
   # Freshness timestamp from TRUSTED Classification authors only (an outsider's
   # fake comment is excluded, matching the $TRUSTED hard-drop in step 1).
   LATEST_CLASS_TS=$(gh issue view <N> --repo $PIPELINE_REPO --json comments \
     --jq '[.comments[] | select((.authorAssociation as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) and (.body | contains("## Classification")))] | max_by(.createdAt) | .createdAt // empty')
   ISSUE_TS=$(gh issue view <N> --repo $PIPELINE_REPO --json updatedAt --jq '.updatedAt')
   # ISO-8601 sorts lexicographically; `>` is strict-greater so add an OR-equality clause to treat same-second as fresh (issue #457).
   if [[ -n "$LATEST_CLASS_TS" && ( "$LATEST_CLASS_TS" > "$ISSUE_TS" || "$LATEST_CLASS_TS" == "$ISSUE_TS" ) ]]; then
       # Parse recommended_path from the trusted working set ($TRUSTED from step 1),
       # never a raw --json comments fetch. The trailing match wins (latest trusted
       # Classification body appears last in $TRUSTED).
       CACHED_PATH=$(printf '%s\n' "$TRUSTED" \
         | grep -oE 'recommended_path:\*\* [ABCD]' | awk '{print $2}' | tail -1)
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

3. **Read first-level comments only** — read from the trusted working set `$TRUSTED` (step 1); ignore quoted/nested text. Consider only top-level comments. Comments from authors lacking write access were already hard-dropped by the helper and never enter the classification.

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

3d. **Advisory path hint (overridable prior, parsed before the rule table is scored).** If the body contains `<!--\s*pipeline:path-hint=[A-Ca-c]\s*-->` (POSIX equivalent: `<!--[[:space:]]*pipeline:path-hint=[A-Ca-c][[:space:]]*-->`), it is an **advisory** prior emitted by `create-issues` — **not** authoritative. It is read as one **prior** among the keyword/blast-radius priors in step 4 and is fully **overridable**: it is **never an override** and **never short-circuits** the rule table. It is OUTRANKED by an explicit path label (step 4 row 1) and by the authoritative `<!-- pipeline:path=D -->` marker (step 3c). The advisory hint vocabulary is `{A, B, C}` ONLY — `D` is authoritative-only and is rejected to empty here, so a `path-hint=D` can never route as a hint. The hint parser cannot match the authoritative `path=` marker (distinct syntax), and the `path=` parser cannot match a `path-hint=` directive. Run the parser to populate `HINT_PATH`; it does NOT skip to step 5.

   ```bash
   # BEGIN-PATH-HINT-PARSE
   # Required env: ISSUE_BODY. Sets: HINT_PATH ("A"|"B"|"C" or "").
   # Advisory hint vocabulary is {A,B,C} ONLY — D is authoritative-only and is
   # rejected to "" here so a path-hint=D can never route as a hint.
   # Regex: <!--\s*pipeline:path-hint=[A-Ca-c]\s*--> (POSIX equivalent below).
   HINT_PATH=""
   _hraw=$(printf '%s' "$ISSUE_BODY" \
     | grep -oE '<!--[[:space:]]*pipeline:path-hint=[A-Za-z][[:space:]]*-->' \
     | head -1)
   if [ -n "$_hraw" ]; then
     _hletter=$(printf '%s' "$_hraw" \
       | grep -oE 'pipeline:path-hint=[A-Za-z]' \
       | head -1 | cut -d= -f2 | tr 'a-z' 'A-Z')
     case "$_hletter" in
       A|B|C) HINT_PATH="$_hletter" ;;
       *) HINT_PATH="" ;;
     esac
   fi
   # END-PATH-HINT-PARSE
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
   - **Blast-radius B→D prior.** For `fix(` issues whose `## Affected areas` names ≤ 2 non-test source files in a single top-level module and that carry no high-uncertainty signal, lean D — see the `#### Blast-radius B→D routing` subsection under PATH D (`feat(` excluded; high-uncertainty `fix(` stays B).
   - **Advisory path-hint prior (`HINT_PATH` from step 3d).** A non-empty `<!-- pipeline:path-hint=A|B|C -->` leans toward the hinted path — an advisory PRIOR in the same weight class as the Blast-radius B→D prior (a thumb on the scale, not a gate). It is **never an override** and **never short-circuits** the rule table: it is OUTRANKED by an explicit path label (row 1 above) and by the authoritative `<!-- pipeline:path=D -->` marker (step 3c). When other signals point elsewhere, they win; the hint only breaks ties / nudges among otherwise-balanced candidates.

4a. **Read any ingested attachments.** Before composing, list and `Read` every file in `.claude/scratch/issue-<N>/` (populated upstream by `/pipeline:fullsend` step 1a or `/pipeline:plan-issue` step 3b). If empty or absent, skip — this step does NOT re-fetch. Mandatory for issues labeled `bug` or `user-submitted`.

   ```bash
   ls -1 .claude/scratch/issue-<N>/ 2>/dev/null || echo "(no attachments)"
   ```

5. **Compose the classification output:**

   > **TERSENESS:** Classification is a routing decision, not a report. `**rationale:**` is 1-2 sentences citing the firing signal — no restatement of the issue body, no enumeration of rules that did NOT fire. Do not echo the rule table or the path definitions back into the comment.

   > **Override rationale.** If the resolved path differs from a non-empty `HINT_PATH` (step 3d), the `**rationale:**` MUST record the override (e.g. `create-issues hinted B; classified C — multiple subsystems in Affected areas`) so the divergence is auditable.

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

## Comment trust

- **Trust = write access.** An author is trusted iff their GitHub `authorAssociation` is in {OWNER, MEMBER, COLLABORATOR}. Everything else (CONTRIBUTOR, NONE, FIRST_TIME_CONTRIBUTOR, unknown, empty) is untrusted.
- **All comment/body reads go through `scripts/filter-trusted-comments.sh`** (issue #545): the step-1 fetch, the step-2 cache-check, and the step-3 first-level comment read all operate on the `$TRUSTED` working set (hard-drop — untrusted comment bytes never reach the model), never a raw `gh ... --json comments` fetch.
- **The issue BODY's trust is the opener's association** (step 0a), resolved via `gh api repos/$PIPELINE_REPO/issues/<N> --jq .author_association` (the GraphQL `author` object has no association field) and checked with the single-arg `is-trusted-author "$ASSOC"` primitive. An untrusted opener is refused-and-surfaced for human triage: no `## Classification` comment, no BEGIN-LABEL-APPLY run, no path label.
- **Pipeline-posted `## Classification` comments survive the filter** because the operator account is OWNER, so the cache-check freshness/reconcile logic is unchanged.

## Constraints
- MAY call `gh issue edit` to add/remove ONLY the `docs-only`, `multi-task`, and `quick-fix` labels. Never touch any other label. Never modify code.
- Body markers (`<!-- pipeline:path=... -->`) are honored when present and well-formed; they short-circuit the rule table but do NOT bypass step 5a label application. The B marker REMOVES any existing A/C/D label and adds nothing.
- Bullet points only. No prose padding.
