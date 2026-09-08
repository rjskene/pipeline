# Operator playbook — dogfood gotchas & recovery

Durable operational lessons for driving the pipeline on the dogfood host. These
are things that bit a real run and the recovery that worked — kept in the repo
(not in per-operator auto-memory) so they survive operator/session turnover.

Related docs: [dogfood-setup.md](dogfood-setup.md) (install + symlink mechanics),
[plugin-architecture.md](plugin-architecture.md) (`CLAUDE_PLUGIN_ROOT` resolution
+ staleness), [release-cadence.md](release-cadence.md) (release gotchas),
[cost-architecture.md](cost-architecture.md) (ceremony-vs-cost framing).

---

## 1. The boundary hook (`hooks/restrict_paths.py`)

The `restrict_paths.py` PreToolUse hook enforces the project boundary. Its
detection is substring-based and naive, so it has a wide false-positive surface.
Known trip-wires and the way around each:

- **Edits to protected files.** It blocks the **Edit/Write tools** on
  `.claude/settings.json`, `.claude/settings.local.json`, and `.claude/hooks/`.
  The check only fires for `tool_name in ("Write","Edit")` — a `Bash` rewrite
  (`awk`/`sed`/`python3`) is not covered (it only hits the boundary check, which
  `.claude/settings.json` passes since it is inside the project). Repo-root
  `hooks/` (where new hook `.py` files live) is **not** protected — only
  `.claude/hooks/` is — so creating a hook file via Write works fine. Routing a
  config change around a security guardrail via a different tool is worth
  surfacing to the operator, not doing silently on plan-approval alone.

- **Path-shaped substrings in prose.** Any tool arg containing the literal
  `../..` is blocked anywhere in any string (PR bodies, issue comments, commit
  messages, code-block examples) — not just real file paths. An absolute-looking
  token is also extracted and resolved: a `gh issue comment` heredoc mentioning
  `skills/run/` was blocked with `path outside project boundary: /run`.
  - Rephrase: use "parent-directory resolver shape" or "legacy
    `cd "$(dirname ...)" && pwd` pattern" instead of the literal `../..`.
  - For `gh` bodies with unavoidable path-like substrings, `Write` the body to
    `.claude/scratch/*.md` and pass `--body-file` so the text stays OUT of the
    Bash command string. (The hook also scans `Write` content, so still rephrase
    obvious offenders.)
  - A `#!/bin/bash` shebang inside Bash *content* (e.g. a `cat <<'EOF'` heredoc
    that writes a script) is extracted as `/bin/bash` and blocked — use an
    `awk`/`sed` rewrite with no shebang instead.
  - **Narrow exception (#1192):** as of #1192, a heredoc **BODY** (the lines
    between `<<'EOF'` and its terminator, when the operator line's command
    word is not an interpreter like `bash`/`sh`/`python`) is masked as stdin
    DATA rather than scanned. This fixes the two RELATIVE cases only:
    script-authoring a `.sh` file whose body contains a `; cd ../..`-shaped
    line, and HTML/prose bodies that merely NAME a relative protected-control
    token (`.claude/hooks/…`). It does **not** cover an ABSOLUTE
    out-of-boundary token — the heredoc mask is deliberately kept off
    `extract_paths()`, so a body naming an absolute path (e.g. `/etc/passwd`,
    or the `skills/run/`-resolving-to-`/run` case above) still blocks with
    `path outside project boundary`. `--body-file` therefore remains the
    workaround for both absolute-token sub-bullets above (the `gh issue
    comment` case and the shebang case) and for any path-like text that is
    NOT inside a heredoc body.
    **Narrowed further by #1194:** the "operator line's command word is not
    an interpreter" check now resolves through a wrapper's own OPTION or
    POSITIONAL argument (`timeout 300 bash <<EOF`, `sudo -u root bash
    <<EOF`, `env -u FOO bash <<EOF`, `nice -n 5 bash <<EOF` all now correctly
    resolve to `bash` and stay scanned — previously the walk terminated on
    the wrapper's own argument and the body was wrongly masked as data). A
    left-shift inside `$(( … ))` or a command-position `(( … ))` (`echo
    $((x << y))`) is also no longer read as a heredoc operator, so it can no
    longer open a phantom heredoc that masks every following line. See the
    module docstring's `Issue #1194` section for the full IN/OUT list.

- **`/tmp` is blocked.** Reads/writes under `/tmp` are outside the boundary.
  Write scratch under `.claude/scratch/` instead. This is the root cause of the
  inline-execute test-wait drop-out in §2.

- **Worktree boundary vs. main-checkout absolute paths.** When a skill runs from
  a feature worktree under `.claude/worktrees/`, the worktree is the project
  boundary — a hardcoded main-checkout absolute path (e.g.
  `/<repo>/scripts/derive-pr-title.sh`) is blocked. Call the worktree-local copy
  (`./scripts/derive-pr-title.sh <N>`); every worktree mirrors `scripts/`.

- **Later hardening sweep.** The hook was tightened along three axes without
  widening the false-positive surface:
  - **Project-root anchoring + write-gated protected-file guard (#1136/#1137).**
    Relative paths are resolved against the project root before the boundary
    comparison, and the protected-file guard fires only on *write* tools — a read
    of a protected path is no longer over-blocked.
  - **Dest-via-flag / interpreter-inline / glued `-t<protected>` write blocks
    (#1138/#1141).** A protected-path write smuggled through a destination flag,
    an inline interpreter invocation, or a glued short flag like `-t<protected>`
    is now caught, closing the routes around the naive substring check.
  - **In-repo `.venv-host/Scripts` admitted (#1135/#1142).** An in-repo
    `.venv-host/Scripts` path (the Windows venv layout) is recognized as inside
    the boundary rather than blocked as a stray absolute-looking token.

## 2. Executor wedge classes & recovery

Dispatched executors (`claude -p` workers and inline `Agent` subagents) wedge in
a few recurring ways. Triage by the **commit count**, not the pane — a frozen
pane alone is not a stall.

- **Healthy `claude -p` looks stalled.** A live headless worker shows
  `STAT Sl+`, `WCHAN ep_poll`, ~5% CPU, and a pane/log frozen at the spawn header
  (`-p` buffers output, no TUI paint). That is API-bound and **healthy**. The
  true progress signal is `git -C <worktree> log <base>..HEAD` advancing. Do NOT
  kill on the `agent-stalled` event for a `-p` worker; re-arm the Monitor.

- **`pgrep`/`grep` self-match spin-loop.** Symptom: `agent-stalled` + process
  tree alive + **no new commits** for many minutes + a `bash → sleep` child whose
  sleep PID increments each check. Cause: the agent improvised a wait-loop like
  `until ! pgrep -f "for t in tests/test"; do sleep 5; done` — `pgrep -f` matches
  the polling shell's OWN command line, so the condition never clears. Inspect
  `cat /proc/<pid>/cmdline | tr '\0' ' '`; if it is a self-match poll loop,
  `kill <bash-pid>` the spin-loop subscript ONLY. Control returns to the
  executor's Bash tool-call and it recovers. Do NOT kill the parent `claude`.

- **Early-hang.** Worker boots, writes its ~200-byte session header, makes one
  `gh` call, then idle-sleeps: `STAT=Sl+`, ~13s CPU over many minutes, log frozen
  at the boot header, **zero commits**, no spin-loop child. The claude turn
  itself stalled (likely API stream stall). Recovery: kill the worker + retry
  once. Distinguish from the benign buffered false-stall by commit count (a
  healthy sibling shows the same blank pane but *advancing* commits).

- **Re-dispatch can DIVERGE, not wedge.** A fresh `claude -p` worker re-reading a
  plan comment can latch onto issue-title phrasing over the plan body and build a
  coherent but **entirely unrelated** feature. Recovery playbook:
  1. **Salvage** the off-plan commits — `git branch <salvage>` at worktree HEAD,
     push, file an issue noting "implementation branch exists for adoption" (the
     build cost is sunk; don't toss coherent work).
  2. **Reset** the issue's branch — pull base, `git reset --hard origin/<base>`.
  3. **Re-execute plan-pinned** — inline `Agent(tdd-implementer)` (the default
     transport since #749/#896) pointed at the worktree, the approved plan
     embedded, plus an **absolute file tripwire**: "you may create/edit ONLY
     these N files; if implementing needs any other file, or you find yourself
     building a feature not described, STOP and report." The orchestrator then
     opens the PR + labels (tdd-implementer is a leaf and won't). The recovery
     emphasis is the plan-pinning + file tripwire — not inline-vs-queue novelty;
     re-running a `--spawn` worker that re-reads the comment is what diverged, so
     keep the re-execute plan-pinned rather than comment-driven.

- **Inline execute narrate-and-yield at the test-wait step.** Inline
  `general-purpose` PATH-B execute agents background a test monitor whose stdout
  lands under `/tmp`, try to `Read` it (boundary-blocked, §1), then yield —
  leaving work committed but unpushed, no PR, issue stuck `in-progress`.
  **Pre-empt it in the dispatch prompt:** "When you reach the test-wait step, run
  the suite SYNCHRONOUSLY (foreground, read its exit code directly) — do NOT
  background a monitor and Read its `/tmp` output; do NOT narrate-and-yield."
  Recovery when it already dropped: inspect the worktree for commits, then
  re-dispatch with an explicit "finish: run suite blocking → push →
  `gh pr create` (base = base branch) → flip `pr-open`" instruction.

  > Also recurring: stray untracked `.claude/migration-cleanup-claudemd.{patch,txt}`
  > get synced into every worktree — tell executors to leave them untracked,
  > never commit them.

## 3. Hand-driving raw scripts

When hand-driving the pipeline (dispatching agents + scripts manually instead of
via `/pipeline:fullsend`, e.g. because the orchestrator session serves stale
cached `Skill()` bodies — see [dogfood-setup.md](dogfood-setup.md)), a bare
`bash scripts/<x>.sh` does NOT get the skill's `## Boot` setup. Export the two
vars by hand:

```bash
source ./pipeline.config
export PIPELINE_REPO=<owner>/<repo>
export CLAUDE_PLUGIN_ROOT=<repo-working-tree>   # in dogfood the repo tree IS the plugin root
```

- `run-queue.sh` hard-fails `exit 1` (`ERROR: CLAUDE_PLUGIN_ROOT unset; cannot
  resolve sibling scripts`) without it — the skill boot's `_resolve-plugin-root.sh`
  only runs inside a `Skill()` invocation, not a bare Bash call.
- `PIPELINE_REPO` does not reliably propagate into subshells; `export` it (also
  bites `post-plan.sh`, `derive-pr-title.sh`, `setup-worktree.sh`,
  `cleanup-worktree.sh`, `auto-merge-gate.sh`).

## 4. Subagent type availability

`skills/execute-issue-plan/SKILL.md` Step 8b (independent reviewer dispatch)
references `Agent(subagent_type: "superpowers:code-reviewer", ...)`, which does
**not** exist in the dogfood environment (`Agent type ... not found`). Dispatch
`Agent(subagent_type: "general-purpose", ...)` instead, with the plan body +
`git diff <base>..HEAD` and the "flag plan-compliance gaps and real bugs; do not
refactor; return LGTM or tagged findings" instructions. Don't burn retries on the
non-existent type. (The `superpowers:requesting-code-review` skill body itself
says to use `general-purpose` with its `code-reviewer.md` template.)

## 5. Standalone `execute-issue-plan` in a worktree

When `/pipeline:execute-issue-plan <N>` is invoked directly inside a feature
worktree (not inherited from `/pipeline:fullsend`), the boot
`source ./pipeline.config` may fail — `pipeline.config` is gitignored +
host-specific and the boundary hook blocks reading the main checkout's copy.
`setup-worktree.sh` now copies `pipeline.config` into each worktree (#529), so
this is largely closed; if vars still resolve empty, derive state instead of
stopping:

- `PIPELINE_REPO` from `git remote -v`.
- `PIPELINE_BASE_BRANCH` from the worktree's `.claude/base-branch` file.
- Test cmd: shell repo, no `package.json` — CI runs
  `scripts/check-no-consumer-claude-writes.sh`, the `tests/test*.sh` loop, and
  `dev/tests/run-all.sh`. No separate typecheck step.
- Pass `PIPELINE_REPO` explicitly to helpers that need it
  (`PIPELINE_REPO=<owner>/<repo> ./scripts/derive-pr-title.sh <N>`).

## 6. PATH C delegation hook namespacing bug (root cause (1) fixed by #1238)

When `/pipeline:execute-issue-plan` runs **in-session** (interactive, not via
spawn-claude) on a PATH C (`multi-task`) issue, `hooks/enforce-path-c-delegation.py`
(PreToolUse) could previously block the `tdd-implementer` subagent's edits to any
**non-allowlisted** file. Root causes: (1) **FIXED by #1238** — the hook used to
hard-match `subagent_type == "tdd-implementer"`, but the plugin-registered agent
dispatches as the namespaced `pipeline:tdd-implementer`, so no directory was ever
authorized; the hook now suffix-matches
(`_stype.rsplit(":", 1)[-1] != "tdd-implementer"`), accepting both the bare and
the namespaced form. The SAME namespacing defect independently hit
`scripts/review-audits.sh`'s PATH C dispatch counter — every real PATH C run
reported a false `tdd-implementer: MISSING (enforcement required since #327)`
because its `[ "$st" = "tdd-implementer" ]` exact-equality check had the
identical bug; it is fixed by the same suffix-match shape (`${st##*:}`). Still
open: (2) `log_subagent.py` writes the dispatch record AFTER the Agent finishes
(PostToolUse timing), so the sentinel never exists during its own edits; (3)
`is_authorized` compares an absolute `file_path` against the sentinel verbatim,
so the sentinel must name an absolute dir.

- **Allowlisted (slip through, no seed needed):** extensions
  `.md .txt .yml .yaml .toml .lock .json`, plus `tests/`, `.github/`,
  `.claude/logs/`, `/tmp/`, `CHANGELOG`.
- **Non-allowlisted (needs the workaround):** `.sh`, `.example`, etc.
- **Workaround:** pre-seed `.claude/logs/subagents/<ts>_*.json` with
  `{"session_id":"<orchestrator session>","subagent_type":"tdd-implementer","prompt":"target=<ABSOLUTE dir>/ ..."}`
  before re-dispatching; verify with
  `echo '<Edit payload>' | python3 hooks/enforce-path-c-delegation.py` (exit 0 =
  authorized). The sample record above still works as-is post-fix — the hook
  now accepts either the bare or the `pipeline:`-namespaced form. Root-level
  files can't use a subdir sentinel (`target=.`/`/`/`./` are trivial-rejected) —
  use the ABSOLUTE WORKTREE ROOT as the sentinel (broadly authorizes the tree;
  acceptable for a config one-off, the edit is still done by a real dispatch).
  The `ALLOW_ORCHESTRATOR_EDIT=true` hatch is worse — it abandons delegation
  rather than enabling it.
- **Real fix candidates (worth filing):** normalize `file_path` against
  `CLAUDE_PROJECT_DIR`. (The `*:tdd-implementer` / `endswith("tdd-implementer")`
  suffix-match candidate is DONE — see root cause (1) above.)

## 7. `doctor.sh` LABEL_TABLE — two test files

Changing the canonical label set in `scripts/doctor.sh` `LABEL_TABLE` requires
updating **two** tests, not one:

1. `tests/test-doctor-fix-labels.sh` — the Case A count literal + append the row
   to the `expected=( ... )` array.
2. `tests/test-doctor-script.sh` — the `ALL_LABELS_JSON` fixture, the Case 5a/5c
   `labels_exist status=pass detail=N/N` assertions, AND the `OVERRIDE_JSON`
   payload in Case 5c. (`doctor.sh`'s own count is dynamic
   `${#LABEL_TABLE[@]}`, so the all-clean case fails when the fixture is stale.)

When planning a LABEL_TABLE change, list BOTH test files.

## 8. Campaign / wave operations

Per-path concurrency caps govern a campaign (`/pipeline:fullsend --campaign`,
#647) — coordinated fullsends run wave-by-wave to merge, dependency-ordered.

- **Two equivalent entry points, one machinery (#904).** A campaign starts via
  either `/pipeline:fullsend --campaign` or the standalone `/pipeline:campaign`
  — they execute the IDENTICAL coordinated-leg loop (same caps, autonomy, and
  two-layer dedup contracts). The leg-loop prose lives ONCE in
  `skills/fullsend/SKILL.md` `## Campaign mode`; `skills/campaign/SKILL.md`
  defers to it, so the two routes can never drift. Neither is deprecated.

- **Caps apply to ALL dispatch stages, not just execute.** The "classify/plan are
  read-only ⇒ a flat parallel blast is free" assumption does NOT hold under a
  rate-limit budget: read-only agents consume the same budget. Batch/serialize
  classify and plan under the same caps as the execute legs. Typical caps: ≤2
  PATH B/C issues per wave, ≤4 PATH A/D per wave; parallelize within a wave by
  default, serialize only on dependency or file-conflict edges.
- **`/compact` at every wave boundary** during multi-wave campaigns. Context
  bloat across waves degrades planning quality and re-introduces earlier
  mistakes. Compact after a wave's PRs merge, before kicking off the next wave —
  the wave boundary is the natural seam (mid-wave compaction risks losing
  in-flight execution state).
- **Usage gate auto-pauses/resumes a campaign near the plan limit.** Wave/leg
  boundaries run `scripts/usage-gate.sh`; see [docs/usage-gate.md](usage-gate.md)
  for the pause/halt decision precedence and recurring re-check resume.

## 9. Dogfood instrumentation — no consumer crud

Self-improvement / measurement / observability work for this repo is built as
**repo-local dogfood**: new `scripts/` + `tests/` + a host-local cron, computing
signals **retroactively** over already-existing substrate (`git`, `gh`,
`.claude/logs/`) where possible — NOT as edits to the published skills/runtime,
and with **zero footprint in consumer repos**. (Plugin install clones the whole
tree into the consumer's plugin *cache*; dogfood scripts referenced by 0 skills
sit inert there, fine — but nothing may write to a consumer's own `.claude/`
working tree.) See CLAUDE.md "Namespace discipline" + "Observability".

A narrow runtime edit is acceptable ONLY when it rides infrastructure that
already exists and is already gated, with zero marginal consumer footprint (e.g.
adding a column to a write that is already wrapped in `if pipeline_logging_enabled`,
default `PIPELINE_LOGS_ENABLED=false` ⇒ logging off ⇒ no line ⇒ no crud). The
test is "does this add a new file / new write path / consumer-visible artifact,"
not "does this touch a shipped file."

## 10. Browser agents under `--spawn` can OOM the 2G cap

The #918 per-agent seatbelt wraps each `--spawn` agent in a transient
`systemd-run --user --scope` with a `MemoryMax=2G` cgroup ceiling. A
`needs-browser` agent launched under `--spawn` runs chromium (via the Playwright
MCP server), and chromium plus a loaded page can exceed 2G — the kernel then
OOM-kills the scope mid-eval. The failure mode is sneaky: the visual-proof loop
reports an `unsatisfied` predicate that **looks like a real predicate failure**
(the page never finished loading because the browser was killed), not like a
resource cap. If a `needs-browser` `--spawn` agent reports a spurious
`unsatisfied` and `journalctl --user -u 'run-*.scope'` (or `dmesg`) shows an OOM
kill on the scope, this is the cause.

Fix (#961): browser agents get a higher cap. `spawn-claude.sh` selects
`PIPELINE_AGENT_MEMORY_MAX_BROWSER` (default **4G**) for the `MemoryMax` ceiling
when the issue carries the `needs-browser` label, instead of the 2G base
`PIPELINE_AGENT_MEMORY_MAX`. The selection happens AFTER label detection, so it
keys off the same `HAS_NEEDS_BROWSER` flag the MCP gating uses.

Tuning:
- Heavy pages still OOM at 4G? Raise `PIPELINE_AGENT_MEMORY_MAX_BROWSER` (e.g.
  `6G`/`8G`) in `pipeline.config`.
- The browser knob is **independent** of the base knob — lowering
  `PIPELINE_AGENT_MEMORY_MAX` for non-browser agents does NOT clamp browser
  agents; they stay at the browser default unless you set the browser knob.
- Non-browser agents are tuned via `PIPELINE_AGENT_MEMORY_MAX` (default 2G).

Scope: **only the `--spawn` transport is affected.** The default inline `Agent`
dispatch path does not invoke `spawn-claude.sh`/`systemd-run`, so it never enters
a cgroup scope and is unaffected (hence the issue's Low severity).

## 11. Windows/MSYS CRLF-jq gotcha

On Windows/MSYS, `jq` emits a trailing carriage return (`\r`) at every
`jq -r` → shell boundary. A value captured with `VAR=$(... | jq -r ...)` then
carries an invisible trailing `\r`, which silently corrupts downstream numeric
comparisons, `case`/`[ = ]` status reads, label matches, and path
concatenations — the failure looks like a logic bug, not an encoding bug, because
the CR is invisible in most output. This bit many scripts across the tree.

- **Convention: strip-CR at every `jq → shell` boundary.** Any value that crosses
  from `jq -r` into a shell variable or `case`/test must be CR-stripped (e.g.
  `tr -d '\r'`, `${VAR%$'\r'}`, or an equivalent) right at the capture site — not
  later, and not only in the one script that happened to fail. The #1158 sweep
  applied this convention across the affected scripts; #1153/#1155/#1161/#1163/#1171
  were the incremental hardening PRs that closed the remaining `jq → shell`
  boundaries one surface at a time.
- **Where it hides.** Numeric/status/label reads are the usual victims: a status
  token that should equal `pass` compares unequal because it is actually
  `pass\r`; a PR-number arithmetic step fails because the number is `123\r`. When
  a comparison that "should" hold fails only on the Windows/MSYS host, suspect a
  CR before suspecting the logic.
