# Classification procedure (shared)

Shared by `/pipeline:plan-issue` step 3a (inline) and standalone `/pipeline:classify-issue`.

Required env: `ISSUE_N`, `ISSUE_BODY`, `CURRENT_LABELS` (newline-separated), `TRUSTED` (the caller's `filter-trusted-comments.sh <N>` working set — never a raw `gh ... --json comments` fetch), `PIPELINE_REPO`. Each shell step is one `scripts/plan-issue-classify.sh` subcommand; unset inputs are fetched.

Decision order (pinned by tests/test-plan-issue-classifies-inline.sh): marker ⇒ hint ⇒ fresh comment ⇒ rule table ⇒ B

- Executed by `BEGIN-PATH-DECIDE` (`### Decide`); the marker (3c) short-circuits. The hint (3d) only decides when no fresh comment, label or table row fired. `PATH_SOURCE=` records the source.

## Paths

| Path | Label | Dispatcher | Discipline |
|------|-------|------------|-----------|
| A | `docs-only` | direct edits in worktree | flat edit → commit; no test cycle |
| B | (no path label) | spawned worker session | red → green → commit (TDD) |
| C | `multi-task` | `tdd-implementer` subagents per target dir | hook-enforced delegation; orchestrator may not Edit impl files |
| D | `quick-fix` | inline `tdd-implementer` in orchestrator | red → green → commit inline; `execute-issue-plan` Step 8 skipped |

### PATH D (quick-fix)

Body-marker primary route: declare `<!-- pipeline:path=D -->` for a one-line, single-precedent fix (precedent mirror, config flip, byte-identical dogfood mirror, one new assertion, obvious one-liner).

Execution: collapsed single-pass inline `tdd-implementer`; `evaluate-issue-pr` is the sole review gate.

**Escalation backstop (down-route safety net).** If the executor finds mid-run that the change exceeds D's envelope, it aborts up to a spawned PATH B run (`execute-issue-plan`'s Collapsed inline D contract). That makes a wrong B→D down-route cheap and recoverable, so classification may lean D.

#### Blast-radius B→D routing (Affected areas heuristic)

**The rule (Blast-radius B→D).** Parse the issue body's `## Affected areas` and count non-test source files, excluding paths under `tests/` or `fixtures/`; when `type = fix(` AND that count is `≤ 2` AND all files share a single top-level module AND the carve-out below does NOT apply, the issue is a **PATH D** candidate (strong prior, medium confidence).

**`fix(`-applicability.** Only `fix(` work down-routes. `feat(` issues are NEVER auto-down-routed by file count; a `feat(` with ≤ 2 files stays B.

**High-uncertainty carve-out.** Even a `fix(` at `≤ 2` files in one module stays B — the down-route is SUPPRESSED — when title, body or labels carry `concurrency`, `race`, `lock`, `deadlock`, `security`, `auth`, `crypto`, `migration` or `data-loss`, or a label such as `security` / `concurrency`. Applied as a SEMANTIC model judgment, NOT a substring `grep`: `authoring` is not `auth`, `block` is not `lock`, `trace` is not `race`. (The mechanical callers use the word-bound regex in `scripts/_high-uncertainty-match.sh`.)

**Not an override.** A strong prior feeding step 4, never an override: the `<!-- pipeline:path=D -->` marker (3c) and an explicit path label (step 4 row 1) both win. Low-uncertainty exemplars:

| Affected areas | source files (non-test) | uncertainty | route |
|----------------|-------------------------|-------------|-------|
| 1 src + test | 1 | low | D |
| script + config + test | 2 | low | D |
| 3 src + tests | 3 | low | **B (boundary — >2 source files = legitimate B)** |
| race-condition `fix(`, 1 src + test (single module) | 1 | `race` / `concurrency` | **B (carve-out SUPPRESSES the down-route — NOT D)** |

**Acceptance.** "No false-D on high-uncertainty issues" is discharged by the carve-out: high-uncertainty small `fix(` work is suppressed and held in B.

## How classification runs

### Freshness check

Run first: `freshness` (`BEGIN-CLASS-FRESHNESS`). A trusted `## Classification` with `createdAt >= issue.updatedAt` is FRESH: consume its `recommended_path` (`CACHED_PATH`), do NOT re-post.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-issue-classify.sh" freshness <N>
   ```

3c. **Body marker — primary route (evaluated before the rule table).** `BEGIN-PATH-MARKER-PARSE` sets `MARKER_PATH` from `<!--\s*pipeline:path=[A-Da-d]\s*-->` (POSIX: `<!--[[:space:]]*pipeline:path=[A-Za-z][[:space:]]*-->`) outside code spans. Authoritative: confidence high, rationale "user-claimed path via body marker"; first marker wins; malformed letters fall through to step 4. A B marker still runs step 5a.

3d. **Advisory path hint.** `<!-- pipeline:path-hint=[A-Ca-c] -->` from `create-issues` is an advisory, overridable prior — never short-circuits, outranked by an explicit path label (row 1) and the `<!-- pipeline:path=D -->` marker. `D` is rejected to empty.

   Pinned regex: `<!--\s*pipeline:path-hint=[A-Ca-c]\s*-->` (POSIX equivalent: `<!--[[:space:]]*pipeline:path-hint=[A-Ca-c][[:space:]]*-->`).

   ```bash
   # BEGIN-PATH-HINT-PARSE  (env: ISSUE_BODY, CLAUDE_PLUGIN_ROOT; sets HINT_PATH = A|B|C or "". D rejected to "".)
   HINT_PATH=$(printf '%s\n' "$ISSUE_BODY" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/strip-code-spans.sh" | grep -oE '<!--[[:space:]]*pipeline:path-hint=[A-Za-z][[:space:]]*-->' | head -1 | grep -oE '=[A-Za-z]' | tr -d '=' | tr 'a-z' 'A-Z' | grep -x '[ABC]' || true)
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

   - **Alternative-bullet rule.** Lists of alternatives — `options:`, `either`, `choose one`, `pick one` — count as one work item with design ambiguity, not N tasks; lean B (not C).
   - **Acceptance-criteria skip.** Bullets under `Acceptance`, `Acceptance Criteria` or `Out of scope` are verification scope or non-goals — skip them; do not count them as work items.
   - **Generic-keyword tightening for D triggers.** `flip` and `swap` fire D only with a code-shaped token (path with `/`+extension, function name in parens, or a backticked `code` token); bare "flip the wording" does NOT. `tweak`, `obvious`, `minimal` match broadly.
   - **Blast-radius B→D prior** — see `#### Blast-radius B→D routing` (`feat(` excluded; high-uncertainty `fix(` stays B).
   - **Advisory path-hint prior.** A non-empty `HINT_PATH` only breaks ties.

4a. **Read any ingested attachments.** `Read` every file in `.claude/scratch/issue-<N>/` (populated by `/pipeline:fullsend` step 1a or `/pipeline:plan-issue` step 3b); absent ⇒ skip, never re-fetch. Mandatory for `bug` / `user-submitted`.

   ```bash
   ls -1 .claude/scratch/issue-<N>/ 2>/dev/null || echo "(no attachments)"
   ```

### Decide

Pass the step-4 row that fired as `--table` (omit when only `Otherwise` matched); `decide` runs freshness, marker, hint and `BEGIN-PATH-DECIDE`, printing `PATH_LETTER=` and `PATH_SOURCE=<marker|cached|label|table|hint|default>`. Set `RECOMMENDED_PATH=$PATH_LETTER`.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-issue-classify.sh" decide <N> --table <A|B|C|D or omit>
   ```

5. **Compose the classification output:**

   > **TERSENESS:** Classification is a routing decision, not a report. `**rationale:**` is 1-2 sentences citing the firing signal — no restatement of the issue body, no list of rules that did NOT fire, no echo of the rule table.

   > **Override rationale.** If the resolved path differs from a non-empty `HINT_PATH`, the `**rationale:**` MUST record the override (e.g. `create-issues hinted B; classified C — multiple subsystems in Affected areas`).

   ```markdown
   ## Classification
   - **recommended_path:** A | B | C | D
   - **confidence:** high | medium | low
   - **rationale:** <one or two sentences citing the signal(s)>

   _Label applied by classify-issue; override by editing the label directly — the label always wins over the comment on next classification._
   ```

5a. **Apply the path label.** `label-apply` runs the `BEGIN-LABEL-APPLY` block: remove first, add second; only the allow-set `{docs-only|multi-task|quick-fix}` — any other label is `REFUSED:`.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-issue-classify.sh" label-apply <N> <RECOMMENDED_PATH>
   ```

   When reconciling a cached classification (classify-issue step 2 prints `Reconciling labels for cached classification #<N>`), run step 5a only and stop. When classifying fresh, proceed to step 6.

6. **Post the classification comment:**
   ```bash
   gh issue comment <N> --repo $PIPELINE_REPO --body "<classification markdown>"
   ```

7. **Verify post** — `verify-post` prints `CLASS_COUNT=` and exits 1 on 0; retry the post once, then report FAILED.
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-issue-classify.sh" verify-post <N>
   ```

## Prompt strategy

- Prefer **recall over precision**: false A→B is mild, false B→A is disruptive — default to B when unsure.
- Existing labels are strong priors; explicit label → confidence=high unless content directly contradicts.
- Keep rationale to 1-2 sentences.
- Label contradicts content (e.g., `docs-only` on a refactor): recommend the labeled path with confidence=low; note the conflict in rationale.

## Constraints

- MAY call `gh issue edit` to add/remove ONLY the `docs-only`, `multi-task`, and `quick-fix` labels (step 5a). Never touch any other label. Never modify code.
