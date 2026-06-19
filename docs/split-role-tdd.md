# Split-Role TDD

Split-role TDD makes test-first an auditable property of the commit graph
instead of an honor-system behavior. It splits test-authorship from
implementation: Opus authors the failing suite, a cheaper implementer greens
it, and an eval-time git invariant proves the locked suite was never tampered
with in between.

Gated by `PIPELINE_PATH_B_SPLIT_ROLE` (default `true`; opt OUT via `=false`). The lane ships
even same-model — structural TDD compliance is valued independent of the model
mix; the implementer model only changes the cost posture, not the compliance
property.

## The lane (red-author / green-implementer)

Two roles, one PATH B worktree, batched per-issue (one red commit, then
test-by-test greens):

1. **Red author (Opus).** Reads the approved plan and authors the *complete*
   failing suite. It runs each test and verifies it fails **for the right
   reason** — an assertion failure, not an import/scaffold error. It commits
   the suite **once**, with the literal substring `[split-role-red]` in the
   commit **subject** line. That commit's SHA is the deterministic anchor the
   eval-time gate resolves against.
2. **Green implementer (cheaper tier).** The implementer model resolves from
   `PIPELINE_PATH_B_MODEL_EXECUTE` (unset → Opus implementer = same-model
   split-role, compliance property only). Running the `tdd-implementer`
   discipline, it greens the suite test-by-test with per-test commits.
   - Implementer test writes are **additive-only**: it MAY add new tests, but
     must **NEVER** modify or delete a locked test.
   - **Escalation valve:** if the implementer concludes a locked test is
     wrong, it **STOPs and reports** (same shape as the PATH D escalation
     backstop) rather than contorting silently. The orchestrator returns the
     test to Opus to adjudicate.

The commit-graph contract: the `[split-role-red]` (Opus) commit strictly
precedes every green commit, so test-first becomes auditable structure. Every
test file that exists at the red SHA is locked — pre-existing tests included —
so any legitimate update to an existing test (golden-file refresh, changed
contract) must be part of the Opus red commit itself; a mid-impl need to touch
one is an escalation-valve case, never an implementer edit.

## The eval-time gate (split-role-gate.sh)

`scripts/split-role-gate.sh` is the W7 enforcement invariant (issue #881). It
is the actual gate — the write-time hook block is defense-in-depth only,
because Bash-level writes can leak, but the git invariant cannot.

What it asserts:

- The red commit exists — the most recent `[split-role-red]` commit on
  `<base-ref>..HEAD`.
- `git diff <red-sha>..HEAD --diff-filter=MD -- <test paths>` is **empty**:
  locked tests were never **M**odified or **D**eleted. Additions
  (`--diff-filter=A`, new test files) are allowed and never flagged.
- The suite is green at HEAD (using `$PIPELINE_TEST_CMD`; unset → no-op pass,
  since a repo with no configured test command cannot be run by the gate). This
  suite-green check is **SECONDARY** — it runs strictly AFTER the PRIMARY
  locked-test invariant above.
  - **CI-trust short-circuit (`PIPELINE_CI_ROLLUP_GREEN`, #1078, precedent
    #957).** When the caller exports `PIPELINE_CI_ROLLUP_GREEN=true` (asserting
    the PR's `statusCheckRollup` is already green — the same #957 trust boundary
    `evaluate-issue-pr` uses to skip its own local re-run), the gate SKIPS the
    secondary `$PIPELINE_TEST_CMD` re-run and emits `additive-ok-ci-green`
    instead of re-running the ~9–11min sweep. Opt-in / default-unset → the gate
    runs its own suite check exactly as before. The signal can ONLY convert the
    SECONDARY suite-green step into a trusted pass; the PRIMARY lock invariant
    runs first and is NEVER bypassed by it. `evaluate-issue-pr` Step 11.2b sets
    it from its already-resolved `$ROLLUP_GREEN`; it is never read from
    `pipeline.config`.

Output contract — exactly one machine-readable line on stdout, and the gate
**ALWAYS exits 0** (the verdict rides the token, mirroring
`auto-merge-gate.sh` / `path-b-execute-eligible.sh`):

```
SPLIT_ROLE=<pass|block> ISSUE=<N> REASON=<token>
```

Token precedence (first failure wins):

```
no-red-sha → locked-test-modified → locked-test-deleted →
(PIPELINE_CI_ROLLUP_GREEN=true ? additive-ok-ci-green : suite-red) → else additive-ok
```

The CI-trust short-circuit (`additive-ok-ci-green`) lives in the SECONDARY
suite-green block, strictly AFTER the PRIMARY locked-test invariant — it never
reorders or bypasses the lock checks above it.

- `no-red-sha` — **fail-closed**: no `[split-role-red]` commit on the branch
  (an unresolvable anchor always blocks; the gate never greenlights without a
  verified anchor).
- `locked-test-modified` — a test file present at the red SHA was changed.
- `locked-test-deleted` — a test file present at the red SHA was deleted.
- `suite-red` — red-SHA + lock checks pass but the suite is not green.
- `additive-ok` — pass: red SHA found, no locked test modified/deleted, suite
  green.
- `additive-ok-ci-green` — pass: red SHA found, no locked test
  modified/deleted, and `PIPELINE_CI_ROLLUP_GREEN=true` (#1078) so the SECONDARY
  suite-green re-run was SKIPPED on a trusted green CI rollup (precedent #957).
  Still `SPLIT_ROLE=pass`; `evaluate-issue-pr` keys greenlight on `pass` (any
  reason), so this needs no call-site parser change.

`evaluate-issue-pr` reads the token: `SPLIT_ROLE=pass` is a necessary
greenlight precondition; any `block-*` token leaves the PR for manual merge.
The gate only **ADDS** a precondition to the green/merge branch — **pr-eval
itself stays Opus in every configuration (W3)**.

## Design provenance

Promoted from the design spec
`docs/superpowers/specs/2026-06-12-sonnet-widen-split-role-tdd-design.md`
(the `## Split-role TDD (Phase 2)` section, decisions W5–W7).
