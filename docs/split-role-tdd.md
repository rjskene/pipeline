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
- `git diff <red-sha>..HEAD --diff-filter=MD -- <test paths>` is **empty** over
  the **locked-test scope** — every file under `<test paths>` whose basename
  matches the discoverable-test glob set (`$PIPELINE_TEST_FILE_GLOBS`, #1201;
  see below): locked tests were never **M**odified or **D**eleted. A data
  fixture/golden/schema under a test root that does not match the glob set is
  not locked. Additions (`--diff-filter=A`, new test files) are allowed and
  never flagged.
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

### Shared-tests exemption (#1089/#1096)

The additive-only lock is absolute by default: the green implementer touches
NOTHING under `tests/`. The one sanctioned exception is a plan-authorized
**shared test** — a test file the green role must legitimately edit to green the
suite (a shared fixture, a contract test whose golden the plan changes).

- The approved plan declares these in a `**Shared tests (split-role):**` section
  that threads exact repo-relative paths into `PIPELINE_SPLIT_ROLE_SHARED_TESTS`.
- The carve-out is **exact-path match only** — no globs, no directory prefixes —
  and **modify-only**: a listed file may be `M`odified, but **deleting** a listed
  file still blocks with `locked-test-deleted`.
- The trust anchor is plan approval: only an OWNER/MEMBER/COLLABORATOR-approved
  plan can widen the lock, so the exemption inherits the human plan-gate rather
  than being self-declared by the implementer.

**Plan-time producer of the declaration (#1200).** Everything above is the
*consumption* side — the W7 gate reads a declaration someone already wrote. The
producer is `scripts/exact-match-guard-sweep.sh`, a mechanical sweep run by
`plan-issue` (Step 4, at authoring time) and re-run by `evaluate-issue-plan`
(Step 3 Phase 1, as a check on the author). It scans the roots resolved from
`PIPELINE_TEST_ROOTS` and emits one `EXACT_MATCH_GUARD=` line per exact-match
assertion — `keyset` (`assertEqual(set(x), {...})`) and `literal`
(`assertEqual(x, [...])` / `{...}`) — with `FILE`, `LINE`, `SYMBOL` and
`SUBJECT`. Any hit the planned change would break must be listed under
`**Shared tests (split-role):**`; otherwise the green implementer meets a
contradiction it cannot legally resolve and stops mid-leg. The sweep exits 3
with `REASON=no-test-root` / `no-test-files` rather than passing vacuously, so a
misconfigured test root is surfaced as a **Revise** instead of a silent clean
sweep (the #1182 lesson). Before #1200 no such sweep existed and each evaluator
improvised its own grep, which caught keysets but missed literals.

### Test-file lock scope (#1201)

The W7 gate originally compared the RED anchor to HEAD over **every path**
under the resolved test roots, not just the test files themselves. A GREEN
commit whose only testing-root delta was a plan-sanctioned **data fixture
regen** (observed live: a JSON schema fixture under a `subagents/*/testing/`
root, a 1-line-added / 1-line-removed diff) tripped
`SPLIT_ROLE=block REASON=locked-test-modified` even though every RED-locked
`test_*.py` file was byte-identical. CI was green and the auto-merge gate was
green — the false positive forced a manual-merge override.

The fix narrows the locked set to **discoverable test files**: a basename
classifier matches each modified/deleted path under the test roots against a
default glob set (`test_*.py *_test.py conftest.py test*.sh *_test.sh
*_test.go *.test.{js,jsx,ts,tsx} *.spec.{js,jsx,ts,tsx} test_*.rb *_spec.rb
*Test.java`); only matches are locked. `conftest.py` stays in the default set
deliberately — it is an executable fixture module that can neuter assertions,
not inert data.

`$PIPELINE_TEST_FILE_GLOBS` (space-separated, matched against the basename
only) **replaces** the built-in default set wholesale when set — it is not
additive. Unset or empty falls back to the default. `evaluate-issue-pr`
threads it into the gate invocation the same way it threads
`PIPELINE_TEST_ROOTS` (#1182); the gate never reads `pipeline.config` itself.
`pipeline.config.example` declares the knob (commented) next to
`PIPELINE_TEST_ROOTS`.

**Residual risk:** loosening a tamper-detection gate is not free — a
golden/expected-output file under a test root is no longer locked by default,
so a green implementer could in principle regenerate one to match buggy
output. This is mitigated by the suite still needing to be green, by
`evaluate-issue-pr` (Opus) reviewing the diff regardless, and by the knob
itself: a repo whose goldens **are** its assertions should name them in
`PIPELINE_TEST_FILE_GLOBS` (e.g. `PIPELINE_TEST_FILE_GLOBS="test_*.py
*.golden.json"`) to keep them locked.

### Full-suite green before the PR (#1111)

Before opening the PR, the green role runs the FULL local suite green — not just
the locked `[split-role-red]` files — so a green-introduced break in a
non-locked test is caught locally, not in CI. The CI-green-rollup fast-path
(`PIPELINE_CI_ROLLUP_GREEN`, #1078, described above) is the only way the
SECONDARY suite-green step is skipped, and only on an already-green CI rollup.

### Execute-time base-ref drift guard (#1106/#1110)

During execute dispatch the split-role gate resolves `<base-ref>..HEAD` against
the branch the executor actually committed on. A base-ref that drifted (e.g. a
RED commit that landed on `staging` because an initial `cd <worktree>` did not
hold across Bash calls) is caught by the git-anchoring + branch-assert contract
in `execute-issue-plan`, so the red-anchor resolves against the correct feature
branch rather than a stale base.

### False-positive fixes (#1124)

Two legitimate patterns that the naive lock check flagged and no longer do:

- **Multi-commit RED.** The red author's suite may span more than one commit; the
  gate resolves the most recent `[split-role-red]` commit as the anchor and
  diffs from there, so a multi-commit red authorship is not misread as a locked
  modification.
- **Plan-authorized green test edit.** A green edit to a file listed under
  `**Shared tests (split-role):**` (the exemption above) is a sanctioned
  modification, not a `locked-test-modified` block.

## Design provenance

Promoted from the design spec
`docs/superpowers/specs/2026-06-12-sonnet-widen-split-role-tdd-design.md`
(the `## Split-role TDD (Phase 2)` section, decisions W5–W7).
