# Classification procedure (shared, #1485)

The single home of the issue-classification procedure. Two readers:

- **`/pipeline:plan-issue` step 3a** runs it INLINE (consume a fresh trusted `## Classification`, or produce one + apply the path label) — the fullsend lane no longer dispatches a separate classify agent.
- **`/pipeline:classify-issue`** (standalone/optional triage) runs it after its own trust gate + cache check.

Required env: `ISSUE_N` (issue number), `ISSUE_BODY` (issue body markdown), `CURRENT_LABELS` (newline-separated label names), `TRUSTED` (the caller's `filter-trusted-comments.sh <N>` working set — every comment read here, freshness and first-level comments alike, uses `$TRUSTED`, never a raw `gh ... --json comments` fetch; read top-level comments only, ignore quoted/nested text), `PIPELINE_REPO`.

Decision order (pinned by tests/test-plan-issue-classifies-inline.sh): marker ⇒ hint ⇒ fresh comment ⇒ rule table ⇒ B

- An EVALUATION order, executed mechanically by the `BEGIN-PATH-DECIDE` block (`### Decide`). The body marker (3c) short-circuits — authoritative.
- The hint (3d) is PARSED second but stays an advisory prior: it never short-circuits, is outranked by an explicit path label (step 4 row 1) and the marker, and only DECIDES when no fresh comment, no label and no table row fired (it beats the bare `B` default).
- A fresh trusted `## Classification` (`createdAt >= issue.updatedAt`) is consumed and never re-posted.
- The rule table's row 1 is the explicit label. `PATH_SOURCE=` records which source fired, for the plan log.

## Paths

The pipeline dispatches on one of four paths; this reference owns their definitions.

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

Execution: collapsed single-pass inline `tdd-implementer` in the orchestrator session (no spawned worker); `evaluate-issue-pr` is the sole review gate — `execute-issue-plan` Step 8 is skipped. Classification runs inline for every path; on PATH D the same collapsed agent carries classify → plan → execute forward in one context. The standalone interactive `/pipeline:classify-issue N` invocation and the `<!-- pipeline:path=D -->` body-marker route are UNCHANGED — they still post a `## Classification` comment and apply the path label directly.

**Escalation backstop (down-route safety net).** The collapsed D lane has an escalation backstop: if the executor finds mid-run that the change exceeds D's envelope, it aborts up to a spawned PATH B run (see `execute-issue-plan`'s Collapsed inline D contract). That backstop is the precondition that makes a wrong B→D down-route (the #707 dependency) cheap and recoverable — mis-routing B work into D is reversed by escalation, not by shipping a too-large diff, so classification may lean D without fear.

#### Blast-radius B→D routing (Affected areas heuristic)

**The rule (Blast-radius B→D).** Parse the issue body's `## Affected areas` section and count non-test source files, excluding any path under `tests/` or `fixtures/`; when `type = fix(` AND that source-file count is `≤ 2` AND all files share a single top-level module AND the high-uncertainty carve-out below does NOT apply, the issue is a **PATH D** candidate (strong prior, medium confidence).

**`fix(`-applicability.** The down-route applies only to `type == fix(` work. `feat(` issues are NEVER auto-down-routed by file count — feature work carries design/novelty uncertainty that file count does not proxy; a `feat(` with ≤ 2 files stays B.

**High-uncertainty carve-out (the protected axis).** Even for a `fix(` at `≤ 2` files in a single module, the down-route is SUPPRESSED — the issue stays B — when the title, body, or labels carry high-uncertainty signals: any of `concurrency`, `race`, `lock`, `deadlock`, `security`, `auth`, `crypto`, `migration`, or `data-loss`, or a label such as `security` / `concurrency`. Blast radius (file count) and uncertainty are orthogonal: a one-file race-condition fix is tiny in blast radius but high in correctness risk, so the carve-out guards the uncertainty axis that the `fix(` gate alone would admit. **Applied as a SEMANTIC model judgment, NOT a substring `grep` (#1039):** you read the words and decide whether the issue genuinely concerns authentication / locking / a data race — `authoring` is not `auth`, `block` is not `lock`, `trace` is not `race`. The mechanical call sites (`scripts/path-b-execute-eligible.sh`, `scripts/plan-campaign.sh`) enforce the same vocabulary via the word-bound shared regex in `scripts/_high-uncertainty-match.sh`; this prose carve-out must never be read as endorsing raw substring matching.

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

Step numbers and sentinel names match the historical classify-issue numbering (tests slice by them).

### Freshness check

Run before anything else. A trusted `## Classification` whose `createdAt >= issue.updatedAt` is FRESH: consume its `recommended_path` (`CACHED_PATH`) and do NOT re-post. Freshness is taken only from trusted Classification authors and `CACHED_PATH` is parsed from `$TRUSTED`, so an outsider cannot poison the cache; pipeline-posted comments survive because the operator account is OWNER.

   ```bash
   # BEGIN-CLASS-FRESHNESS
   # Required env: TRUSTED (trusted working set). Prints CLASS_FRESH=true|false and CACHED_PATH=<A|B|C|D or empty>.
   CLASS_FRESH=false; CACHED_PATH=""
   # Freshness timestamp from TRUSTED Classification authors only (--json already hard-drops outsiders).
   LATEST_CLASS_TS=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" --json <N> \
     | jq -r '[.comments[] | select((.authorAssociation as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) and (.body | contains("## Classification")))] | max_by(.createdAt) | .createdAt // empty')
   ISSUE_TS=$(gh issue view <N> --repo $PIPELINE_REPO --json updatedAt --jq '.updatedAt')
   # ISO-8601 sorts lexicographically; `>` is strict-greater so add an OR-equality clause to treat same-second as fresh (issue #457).
   if [[ -n "$LATEST_CLASS_TS" && ( "$LATEST_CLASS_TS" > "$ISSUE_TS" || "$LATEST_CLASS_TS" == "$ISSUE_TS" ) ]]; then
       CACHED_PATH=$(printf '%s\n' "$TRUSTED" \
         | grep -oE 'recommended_path:\*\* [ABCD]' | awk '{print $NF}' | tail -1)
       case "$CACHED_PATH" in A|B|C|D) CLASS_FRESH=true ;; *) CACHED_PATH="" ;; esac
   fi
   echo "CLASS_FRESH=$CLASS_FRESH"
   echo "CACHED_PATH=$CACHED_PATH"
   # END-CLASS-FRESHNESS
   ```

3c. **Body marker — primary route (evaluated before the rule table).** See "## PATH D" above for when to add the marker. If the issue body contains `<!--\s*pipeline:path=[A-Da-d]\s*-->` (POSIX equivalent: `<!--[[:space:]]*pipeline:path=[A-Za-z][[:space:]]*-->`), the claim is authoritative: path = marker letter uppercased (A/B/C/D); confidence = high; rationale = "user-claimed path via body marker". First marker wins; malformed letters fall through to step 4. Run the parser; if `MARKER_PATH` is non-empty, set `RECOMMENDED_PATH=$MARKER_PATH` and skip to step 5. The B-marker case still runs step 5a so any prior `docs-only`/`multi-task`/`quick-fix` label is removed.

   ```bash
   # BEGIN-PATH-MARKER-PARSE
   # Required env: ISSUE_BODY (issue body markdown, may be multi-line), CLAUDE_PLUGIN_ROOT.
   # Sets: MARKER_PATH ("A"|"B"|"C"|"D" or empty string).
   # Regex: <!--\s*pipeline:path=[A-Da-d]\s*--> (POSIX equivalent below).
   MARKER_PATH=""
   _raw=$(printf '%s\n' "$ISSUE_BODY" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/strip-code-spans.sh" \
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

3d. **Advisory path hint (overridable prior, parsed before the rule table is scored).** If the body contains `<!-- pipeline:path-hint=[A-Ca-c] -->`, it is an **advisory** prior emitted by `create-issues` — **not** authoritative. Run the parser below to populate `HINT_PATH`; it does NOT skip to step 5. The hint is read as one prior in step 4, is fully **overridable**, **never short-circuits** the rule table, and is OUTRANKED by an explicit path label (step 4 row 1) and the authoritative `<!-- pipeline:path=D -->` marker (step 3c). Vocabulary is `{A, B, C}` ONLY — `D` is authoritative-only and rejected to empty here. The hint and `path=` parsers have distinct syntax and cannot cross-match.

   Pinned regex: `<!--\s*pipeline:path-hint=[A-Ca-c]\s*-->` (POSIX equivalent: `<!--[[:space:]]*pipeline:path-hint=[A-Ca-c][[:space:]]*-->`).

   ```bash
   # BEGIN-PATH-HINT-PARSE  (env: ISSUE_BODY, CLAUDE_PLUGIN_ROOT; sets HINT_PATH = A|B|C or "". D rejected to "".)
   HINT_PATH=$(printf '%s\n' "$ISSUE_BODY" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/strip-code-spans.sh" \
     | grep -oE '<!--[[:space:]]*pipeline:path-hint=[A-Za-z][[:space:]]*-->' | head -1 \
     | grep -oE '=[A-Za-z]' | tr -d '=' | tr 'a-z' 'A-Z')
   case "$HINT_PATH" in A|B|C) ;; *) HINT_PATH="" ;; esac
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
   - **Advisory path-hint prior (`HINT_PATH` from step 3d).** A non-empty hint leans toward the hinted path — a PRIOR in the same weight class as the Blast-radius B→D prior (a thumb on the scale, not a gate). When other signals point elsewhere, they win; the hint only breaks ties / nudges among otherwise-balanced candidates.

4a. **Read any ingested attachments.** Before composing, list and `Read` every file in `.claude/scratch/issue-<N>/` (populated upstream by `/pipeline:fullsend` step 1a or `/pipeline:plan-issue` step 3b). If empty or absent, skip — this step does NOT re-fetch. Mandatory for issues labeled `bug` or `user-submitted`.

   ```bash
   ls -1 .claude/scratch/issue-<N>/ 2>/dev/null || echo "(no attachments)"
   ```

### Decide

Set `TABLE_PATH` to the step-4 row that fired (score the table as model judgment, with `HINT_PATH` as the prior) — or empty when only `Otherwise` matched — then run the block below and set `RECOMMENDED_PATH=$PATH_LETTER` for steps 5/5a.

   ```bash
   # BEGIN-PATH-DECIDE
   # Required env: MARKER_PATH, HINT_PATH (3c/3d), CLASS_FRESH, CACHED_PATH (freshness check),
   #   CURRENT_LABELS (newline-separated), TABLE_PATH (step-4 row that fired, or empty).
   # Prints PATH_LETTER=<A|B|C|D> and PATH_SOURCE=<marker|cached|label|table|hint|default>.
   _lbl()  { printf '%s\n' "${CURRENT_LABELS:-}" | grep -qx "${*}"; }
   _abcd() { printf '%s\n' "${*}" | grep -qx '[ABCD]'; }
   PATH_LETTER=B; PATH_SOURCE=default
   if _abcd "${MARKER_PATH:-}"; then PATH_LETTER="$MARKER_PATH"; PATH_SOURCE=marker
   elif [ "${CLASS_FRESH:-}" = true ] && _abcd "${CACHED_PATH:-}"; then PATH_LETTER="$CACHED_PATH"; PATH_SOURCE=cached
   elif _lbl docs-only;  then PATH_LETTER=A; PATH_SOURCE=label
   elif _lbl multi-task; then PATH_LETTER=C; PATH_SOURCE=label
   elif _lbl quick-fix;  then PATH_LETTER=D; PATH_SOURCE=label
   elif _abcd "${TABLE_PATH:-}"; then PATH_LETTER="$TABLE_PATH"; PATH_SOURCE=table
   elif printf '%s\n' "${HINT_PATH:-}" | grep -qx '[ABC]'; then PATH_LETTER="$HINT_PATH"; PATH_SOURCE=hint
   fi
   echo "PATH_LETTER=$PATH_LETTER"
   echo "PATH_SOURCE=$PATH_SOURCE"
   # END-PATH-DECIDE
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
   _has_label() { printf '%s\n' "$CURRENT_LABELS" | grep -qx "${*}"; }
   _safe_label() {
     # Guardrail: this skill may only edit the three path labels.
     case "${*}" in
       docs-only|multi-task|quick-fix) return 0 ;;
       *) echo "REFUSED: label '${*}' not in allow-set {docs-only|multi-task|quick-fix}" >&2; return 1 ;;
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

   When reconciling a cached classification (classify-issue step 2 prints `Reconciling labels for cached classification #<N>`), run step 5a only and stop. When classifying fresh, proceed to step 6.

6. **Post the classification comment:**
   ```bash
   gh issue comment <N> --repo $PIPELINE_REPO --body "<classification markdown>"
   ```

7. **Verify post** — count `## Classification` comments; retry once on 0; report FAILED if still 0.
   ```bash
   CLASS_COUNT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" --json <N> \
     | jq '[.comments[] | select(.body | contains("## Classification"))] | length')
   ```

## Prompt strategy

- Prefer **recall over precision**: false A→B is mild, false B→A is disruptive — default to B when unsure.
- Existing labels are strong priors; explicit label → confidence=high unless content directly contradicts.
- Keep rationale to 1-2 sentences.
- Label contradicts content (e.g., `docs-only` on a refactor): recommend the labeled path with confidence=low; note the conflict in rationale.

## Constraints

- MAY call `gh issue edit` to add/remove ONLY the `docs-only`, `multi-task`, and `quick-fix` labels (step 5a). Never touch any other label. Never modify code.
