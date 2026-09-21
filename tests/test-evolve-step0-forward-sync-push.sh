#!/bin/bash
set -uo pipefail

# #1281 item 2 — the evolve loop's Step-0 forward-sync must PUBLISH its merge.
# Cycle worktrees are cut from `origin/evolve` (scripts/setup-worktree.sh --base),
# so a merge that only lands in the loop clone is invisible to every worktree the
# cycle then creates.
#
# BEHAVIOUR TEST, NOT PROSE PINNING: this file EXTRACTS the Step-0 bash fence out
# of skills/evolve/SKILL.md and EXECUTES it against a real git sandbox. It never
# greps the skill's prose and never asserts on wording — the only thing it reads
# from the file is the code the loop actually runs.
#
# EXTRACTION CONTRACT (ONE extractor, used by all three cases):
#   anchor = the literal line `## Step 0 — gate`, which MUST occur exactly once
#            (asserted before any extraction; a second occurrence makes "the
#            Step-0 fence" ambiguous and the test refuses to guess).
#   block  = the FIRST fence opened by /^[[:space:]]*```bash[[:space:]]*$/ at or
#            after the anchor, closed by the next /^[[:space:]]*```[[:space:]]*$/.
#
# ENV the extracted fence reads (supplied per case below):
#   MAIN_REPO PIPELINE_BASE_BRANCH PIPELINE_USE_LOCAL_PLUGIN HARNESS_ROOT
#   TRACKER PIPELINE_REPO TMP   plus a `gh` stub first on PATH.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/evolve/SKILL.md"
ANCHOR='## Step 0 — gate'

# shellcheck source=/dev/null
source "$SCRIPT_DIR/_lib/git-sandbox.sh"

PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_case() { echo ""; echo "-- $1 --"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------
inc_case "Extraction: the Step-0 fence is unambiguous and non-empty"

if [ -f "$SKILL" ]; then
  pass_msg "skills/evolve/SKILL.md exists"
else
  fail_msg "skills/evolve/SKILL.md is missing — nothing to extract"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

ANCHOR_COUNT="$(grep -cxF "$ANCHOR" "$SKILL")"
if [ "$ANCHOR_COUNT" = "1" ]; then
  pass_msg "the '$ANCHOR' anchor occurs exactly once (got $ANCHOR_COUNT)"
else
  fail_msg "the '$ANCHOR' anchor occurs $ANCHOR_COUNT times (need exactly 1 — extraction would be ambiguous)"
fi

FENCE="$WORK/step0.sh"
awk -v anchor="$ANCHOR" '
  function is_open(l)  { return l ~ /^[[:space:]]*```bash[[:space:]]*$/ }
  function is_close(l) { return l ~ /^[[:space:]]*```[[:space:]]*$/ }
  !seen { if ($0 == anchor) seen = 1; next }
  !inb  { if (is_open($0)) inb = 1; next }
  is_close($0) { exit }
  { print }
' "$SKILL" > "$FENCE"

if [ -s "$FENCE" ]; then
  pass_msg "extracted a non-empty Step-0 bash fence ($(wc -l < "$FENCE") lines)"
else
  fail_msg "extracted an EMPTY Step-0 bash fence — the anchor or fence grammar drifted"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

# Non-vacuity: the extracted block must be the GATE fence (it is the one that
# runs the forward-sync merge), not some neighbouring fence.
if grep -q 'merge-base --is-ancestor' "$FENCE"; then
  pass_msg "the extracted fence is the forward-sync gate (carries the merge-base guard)"
else
  fail_msg "the extracted fence carries no 'merge-base --is-ancestor' — wrong fence extracted"
fi

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

# new_sandbox <name> -> echoes the sandbox root.
# Layout: <root>/origin.git (bare, branches staging + evolve at the same commit)
#         <root>/clone      (checked out on evolve, local git identity)
#         <root>/bin/gh     (stub: prints labels, never `paused`)
#         <root>/tracker.md ($TMP — carries the staging-isolation attestation row)
new_sandbox() {
  local name="$1"
  local root="$WORK/$name"
  local seed
  rm -rf "$root"; mkdir -p "$root"
  seed="$root/seed"
  mkdir -p "$seed"
  git_init_sandbox "$seed" >/dev/null 2>&1
  git -C "$seed" checkout -q -b staging
  echo "seed" > "$seed/README.md"
  git -C "$seed" add README.md >/dev/null 2>&1
  git -C "$seed" commit -q -m "chore: seed" >/dev/null 2>&1
  git -C "$seed" branch evolve >/dev/null 2>&1
  git init -q --bare "$root/origin.git" >/dev/null 2>&1
  git -C "$seed" remote add origin "$root/origin.git" >/dev/null 2>&1
  git -C "$seed" push -q origin staging evolve >/dev/null 2>&1

  git clone -q "$root/origin.git" "$root/clone" >/dev/null 2>&1
  git -C "$root/clone" config user.email t@t.t
  git -C "$root/clone" config user.name t
  git -C "$root/clone" checkout -q evolve

  mkdir -p "$root/bin"
  cat > "$root/bin/gh" <<'GH'
#!/bin/bash
# gh stub — the Step-0 gate only reads the tracker's label list. It must NOT
# contain `paused`, otherwise the kill-switch check STOPs the gate.
printf '%s\n' evolve tracker
GH
  chmod +x "$root/bin/gh"

  cat > "$root/tracker.md" <<'TRACKER'
## Runtime

| knob | value |
|---|---|
| staging isolation | `PIPELINE_LABELS_EXCLUDED="evolve"` |
TRACKER

  printf '%s' "$root"
}

# commit_on_origin_staging <root> — advance the bare origin's `staging` branch.
commit_on_origin_staging() {
  local root="$1"
  git -C "$root/seed" checkout -q staging
  echo "downstream" >> "$root/seed/README.md"
  git -C "$root/seed" commit -q -am "feat: downstream work on staging" >/dev/null 2>&1
  git -C "$root/seed" push -q origin staging >/dev/null 2>&1
}

origin_evolve() { git -C "$1/origin.git" rev-parse refs/heads/evolve; }
clone_head()    { git -C "$1/clone" rev-parse HEAD; }

# run_fence <root> <harness_root> -> stdout of the extracted fence
run_fence() {
  local root="$1" harness_root="$2"
  ( cd "$root/clone" \
    && PATH="$root/bin:$PATH" \
       MAIN_REPO="$root/clone" \
       PIPELINE_BASE_BRANCH=evolve \
       PIPELINE_USE_LOCAL_PLUGIN=true \
       HARNESS_ROOT="$harness_root" \
       TRACKER=1271 \
       PIPELINE_REPO=rjskene/pipeline \
       TMP="$root/tracker.md" \
       bash "$FENCE" 2>/dev/null )
}

# ---------------------------------------------------------------------------
# Case A: a productive forward-sync must be published to origin/evolve
# ---------------------------------------------------------------------------
inc_case "Case A: productive merge -> origin/evolve advances"

A="$(new_sandbox caseA)"
commit_on_origin_staging "$A"
A_BEFORE_HEAD="$(clone_head "$A")"
A_BEFORE_ORIGIN="$(origin_evolve "$A")"
A_OUT="$(run_fence "$A" "$(git -C "$A/clone" rev-parse --show-toplevel)")"
A_AFTER_HEAD="$(clone_head "$A")"
A_AFTER_ORIGIN="$(origin_evolve "$A")"

# Non-vacuity guards FIRST: if the gate STOPped or the merge did nothing, the
# push assertion below would hold trivially (origin == an unmoved HEAD).
if printf '%s\n' "$A_OUT" | grep -q '^STOP:'; then
  fail_msg "non-vacuity: the gate STOPped on a well-formed sandbox (got: $(printf '%s\n' "$A_OUT" | head -1))"
else
  pass_msg "non-vacuity: the gate passed (no STOP: line)"
fi
if [ "$A_AFTER_HEAD" != "$A_BEFORE_HEAD" ]; then
  pass_msg "non-vacuity: the forward-sync merge was productive (clone HEAD moved)"
else
  fail_msg "non-vacuity: the forward-sync merge did not move the clone's HEAD"
fi

if [ "$A_AFTER_ORIGIN" = "$A_AFTER_HEAD" ]; then
  pass_msg "origin's refs/heads/evolve equals the clone's post-merge HEAD (the merge was pushed)"
else
  fail_msg "origin's refs/heads/evolve is ${A_AFTER_ORIGIN:0:7} but the clone's post-merge HEAD is ${A_AFTER_HEAD:0:7} — the forward-sync merge was never pushed (#1281); cycle worktrees cut from origin/evolve would not see it"
fi
if [ "$A_AFTER_ORIGIN" != "$A_BEFORE_ORIGIN" ]; then
  pass_msg "origin's refs/heads/evolve moved off its pre-merge OID"
else
  fail_msg "origin's refs/heads/evolve is still at its pre-merge OID ${A_BEFORE_ORIGIN:0:7}"
fi

# ---------------------------------------------------------------------------
# Case B (NEGATIVE CONTROL): a no-op merge must not touch the remote
#
# origin/staging is already an ancestor of the clone's HEAD, so the fence's
# `merge-base --is-ancestor` short-circuits and no merge runs. The clone's
# `evolve` is deliberately ONE unrelated local commit ahead of origin's, so an
# UNGUARDED push would advance the remote — that is what this case forbids.
# ---------------------------------------------------------------------------
inc_case "Case B: no-op merge -> origin/evolve unchanged"

B="$(new_sandbox caseB)"
echo "local work" > "$B/clone/local.txt"
git -C "$B/clone" add local.txt >/dev/null 2>&1
git -C "$B/clone" commit -q -m "chore: unrelated local commit" >/dev/null 2>&1
B_BEFORE_ORIGIN="$(origin_evolve "$B")"
B_BEFORE_HEAD="$(clone_head "$B")"
B_OUT="$(run_fence "$B" "$(git -C "$B/clone" rev-parse --show-toplevel)")"
B_AFTER_ORIGIN="$(origin_evolve "$B")"
B_AFTER_HEAD="$(clone_head "$B")"

if printf '%s\n' "$B_OUT" | grep -q '^STOP:'; then
  fail_msg "non-vacuity: the gate STOPped on a well-formed sandbox (got: $(printf '%s\n' "$B_OUT" | head -1))"
else
  pass_msg "non-vacuity: the gate passed (no STOP: line)"
fi
if [ "$B_AFTER_HEAD" = "$B_BEFORE_HEAD" ]; then
  pass_msg "the merge was a no-op (clone HEAD unchanged), which is the case under test"
else
  fail_msg "the merge was NOT a no-op (clone HEAD moved) — the sandbox no longer exercises the guard"
fi
if [ "$B_AFTER_ORIGIN" = "$B_BEFORE_ORIGIN" ]; then
  pass_msg "origin's refs/heads/evolve is unchanged after a no-op forward-sync"
else
  fail_msg "a no-op forward-sync pushed the clone's unrelated local commit to origin/evolve (the push is unguarded)"
fi

# ---------------------------------------------------------------------------
# Case C (NEGATIVE CONTROL): a failed gate must never touch the remote
# ---------------------------------------------------------------------------
inc_case "Case C: failed gate -> STOP: and origin/evolve unchanged"

C="$(new_sandbox caseC)"
commit_on_origin_staging "$C"
C_BEFORE_ORIGIN="$(origin_evolve "$C")"
C_BEFORE_HEAD="$(clone_head "$C")"
UNRELATED="$WORK/unrelated-harness-root"
mkdir -p "$UNRELATED"
C_OUT="$(run_fence "$C" "$UNRELATED")"
C_AFTER_ORIGIN="$(origin_evolve "$C")"
C_AFTER_HEAD="$(clone_head "$C")"

if printf '%s\n' "$C_OUT" | grep -q '^STOP:'; then
  pass_msg "an unrelated HARNESS_ROOT prints a STOP: line on stdout"
else
  fail_msg "an unrelated HARNESS_ROOT printed no STOP: line (got: ${C_OUT:-<no output>})"
fi
if [ "$C_AFTER_HEAD" = "$C_BEFORE_HEAD" ]; then
  pass_msg "a failed gate leaves the clone's HEAD untouched (no merge)"
else
  fail_msg "a failed gate merged anyway (clone HEAD moved)"
fi
if [ "$C_AFTER_ORIGIN" = "$C_BEFORE_ORIGIN" ]; then
  pass_msg "a failed gate leaves origin's refs/heads/evolve unchanged (no push)"
else
  fail_msg "a failed gate pushed to origin/evolve"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
