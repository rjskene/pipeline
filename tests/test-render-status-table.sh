#!/bin/bash
set -uo pipefail

# Tests for scripts/render-status-table.sh — the deterministic, hermetic
# renderer that consumes (issues.json, trackers.json, release-prs.txt) and
# writes the canonical pipeline status table to stdout.
#
# The renderer makes ZERO live `gh` calls. All inputs are passed as files,
# which is what makes this testable in shell.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/render-status-table.sh"
FIXTURES="$SCRIPT_DIR/fixtures/render-status-table"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); echo "    $2"; }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

# ----------------------------------------------------------------------
# Task 1: skeleton + arg parsing
# ----------------------------------------------------------------------

# Scenario 1.1: no arguments → exit 2 + usage to stderr
inc
out=$(bash "$HELPER" 2>"$TMP/err" || true)
rc=$?
err=$(cat "$TMP/err")
if bash "$HELPER" >/dev/null 2>"$TMP/err"; rc=$?; [ "$rc" -eq 2 ] && grep -q -i 'usage' "$TMP/err"; then
  pass_msg "no args → exit 2 + usage on stderr"
else
  fail_msg "no args → exit 2 + usage on stderr" "rc=$rc, stderr=$(cat "$TMP/err")"
fi

# Scenario 1.2: --issues pointing at a nonexistent file → exit 2 + error
inc
bash "$HELPER" --issues "$TMP/does-not-exist.json" >/dev/null 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 2 ] && grep -q "does-not-exist.json" "$TMP/err"; then
  pass_msg "missing --issues file → exit 2 + error mentions file"
else
  fail_msg "missing --issues file → exit 2 + error mentions file" "rc=$rc, stderr=$(cat "$TMP/err")"
fi

# Scenario 1.3: --issues with a valid empty file (just '[]') exits 0
inc
echo '[]' > "$TMP/empty-issues.json"
bash "$HELPER" --issues "$TMP/empty-issues.json" --today 2026-05-21 >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "empty issues array → exit 0"
else
  fail_msg "empty issues array → exit 0" "rc=$rc, stderr=$(cat "$TMP/err"), stdout=$(cat "$TMP/out")"
fi

# Scenario 1.4: --trackers pointing at a JSON array (wrong shape) → exit 2
# + stderr says `--trackers must be a JSON object`. The orchestrator hit this
# live (issue #416) when it fed `[issue, issue, ...]` instead of the
# documented `{"<num>": "<body>", ...}` map, causing every tracker to
# silently fall through to the "all children closed" placeholder.
inc
echo '[{"number":42,"body":"x"}]' > "$TMP/array-trackers.json"
bash "$HELPER" \
  --issues "$TMP/empty-issues.json" \
  --trackers "$TMP/array-trackers.json" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 2 ] && grep -q -F -- '--trackers must be a JSON object' "$TMP/err"; then
  pass_msg "wrong-shape --trackers (array) → exit 2 + error mentions JSON object"
else
  fail_msg "wrong-shape --trackers (array) → exit 2 + error mentions JSON object" \
    "rc=$rc, stderr=$(cat "$TMP/err")"
fi

# ----------------------------------------------------------------------
# Task 2: ORPHANS section — flat ready/cc-type sort + stage
# ----------------------------------------------------------------------

# Scenario 2.1: 5 orphans render as a single flat list (no scope buckets),
# sorted by (orphan_stage_rank, cc_type_rank, priority_tier, number). The
# first-level key is a stage ordinal: in-flight(-1) → ready(0) → human(1) →
# brainstorm(2) → later(3). Within a bucket the #871 tiebreak holds
# (cc_type_rank → priority_tier → number). Given the orphans-issues.json
# fixture (#133 feat/plan-pending/P1, #34 feat/ready/P2, #150 feat/merged/P2,
# #999 chore/ready/P2, #555 feat/human/P0) the flat order is
# #133 < #150 < #999 < #34 < #555:
#   in-flight bucket: #133 (plan-pending, P1) < #150 (merged, P2)
#   ready bucket:     #999 (chore) < #34 (feat)
#   human bucket:     #555
# Each row uses `[Pn] #N — <title>  (stage)`.
inc
bash "$HELPER" \
  --issues "$FIXTURES/orphans-issues.json" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
out=$(cat "$TMP/out")
if [ "$rc" -ne 0 ]; then
  fail_msg "orphans render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
else
  # ORPHANS header exists
  if grep -q '^ORPHANS' "$TMP/out"; then
    pass_msg "orphans render emits ORPHANS header"
  else
    fail_msg "orphans render emits ORPHANS header" "$out"
  fi

  inc
  # flat order by line number: #133 < #150 < #999 < #34 < #555
  p999_line=$(grep -n '#999' "$TMP/out" | head -1 | cut -d: -f1)
  p34_line=$(grep -n '#34 ' "$TMP/out" | head -1 | cut -d: -f1)
  p133_line=$(grep -n '#133' "$TMP/out" | head -1 | cut -d: -f1)
  p150_line=$(grep -n '#150' "$TMP/out" | head -1 | cut -d: -f1)
  p555_line=$(grep -n '#555' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$p999_line" ] && [ -n "$p34_line" ] && [ -n "$p133_line" ] \
     && [ -n "$p150_line" ] && [ -n "$p555_line" ] \
     && [ "$p133_line" -lt "$p150_line" ] && [ "$p150_line" -lt "$p999_line" ] \
     && [ "$p999_line" -lt "$p34_line" ] && [ "$p34_line" -lt "$p555_line" ]; then
    pass_msg "flat orphan order: #133 < #150 < #999 < #34 < #555"
  else
    fail_msg "flat orphan order: #133 < #150 < #999 < #34 < #555" \
      "p133=$p133_line p150=$p150_line p999=$p999_line p34=$p34_line p555=$p555_line"
  fi

  inc
  # row format: `[P1] #133 — feat(run): ... (plan-pending)` with stage
  if grep -qE '^[[:space:]]+\[P1\][[:space:]]+#133[[:space:]]+—.*\(plan-pending\)' "$TMP/out"; then
    pass_msg "row format includes [Pn], em-dash, and (stage)"
  else
    fail_msg "row format includes [Pn], em-dash, and (stage)" "$(grep '#133' "$TMP/out")"
  fi

  inc
  # #150 stage resolves to (merged) from the merged label
  if grep -qE '#150.*\(merged\)' "$TMP/out"; then
    pass_msg "stage label resolves merged label for #150"
  else
    fail_msg "stage label resolves merged label for #150" "$(grep '#150' "$TMP/out")"
  fi

  inc
  # #34 has no pipeline-stage label, so renders as (ready)
  if grep -qE '#34[[:space:]].*\(ready\)' "$TMP/out"; then
    pass_msg "no-stage-label issue #34 renders as (ready)"
  else
    fail_msg "no-stage-label issue #34 renders as (ready)" "$(grep '#34 ' "$TMP/out")"
  fi

  inc
  # #999 (chore) sorts first among ready orphans (chore cc_type_rank=0 < feat=3)
  if [ -n "$p999_line" ] && [ -n "$p34_line" ] && [ "$p999_line" -lt "$p34_line" ]; then
    pass_msg "#999 (chore) sorts first among ready orphans (#999 < #34)"
  else
    fail_msg "#999 (chore) sorts first among ready orphans (#999 < #34)" \
      "p999=$p999_line p34=$p34_line"
  fi

  inc
  # stage-ordinal first-level key: human bucket (#555) sorts AFTER the ready
  # bucket (#34/#999) regardless of #555's higher priority (P0). This is the
  # behavior change vs the old binary ready_rank, where the not-ready group
  # would only tiebreak by tier — never by a per-stage ordinal.
  if [ -n "$p34_line" ] && [ -n "$p555_line" ] && [ "$p34_line" -lt "$p555_line" ]; then
    pass_msg "human-stage #555 sorts after ready bucket (ready → human)"
  else
    fail_msg "human-stage #555 sorts after ready bucket (ready → human)" \
      "p34=$p34_line p555=$p555_line"
  fi

  inc
  # #555 renders with its (human) stage
  if grep -qE '#555[[:space:]].*\(human\)' "$TMP/out"; then
    pass_msg "human-stage issue #555 renders as (human)"
  else
    fail_msg "human-stage issue #555 renders as (human)" "$(grep '#555' "$TMP/out")"
  fi
fi

# ----------------------------------------------------------------------
# Task 3: EPICS section + tracker child rollup + ORPHANS dedup
# ----------------------------------------------------------------------

inc
bash "$HELPER" \
  --issues "$FIXTURES/epics-issues.json" \
  --trackers "$FIXTURES/epics-trackers.json" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "epics render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
else
  pass_msg "epics render exits 0"

  inc
  epics_line=$(grep -n '^EPICS' "$TMP/out" | head -1 | cut -d: -f1)
  orphans_line=$(grep -n '^ORPHANS' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$epics_line" ] && [ -n "$orphans_line" ] && [ "$epics_line" -lt "$orphans_line" ]; then
    pass_msg "EPICS section renders above ORPHANS"
  else
    fail_msg "EPICS section renders above ORPHANS" "epics=$epics_line orphans=$orphans_line"
  fi

  inc
  # tracker row uses [Pn] #N — title format (no stage in parens)
  if grep -qE '^[[:space:]]+\[P1\][[:space:]]+#120[[:space:]]+—' "$TMP/out"; then
    pass_msg "tracker #120 row uses [Pn] #N — title"
  else
    fail_msg "tracker #120 row uses [Pn] #N — title" "$(grep '#120' "$TMP/out")"
  fi

  inc
  # children indented 8 spaces, with right-padded stage in parens
  if grep -qE '^        #144[[:space:]]+—.*\(plan-approved\)' "$TMP/out"; then
    pass_msg "child #144 indented 8 spaces with stage"
  else
    fail_msg "child #144 indented 8 spaces with stage" "$(grep '#144' "$TMP/out")"
  fi

  inc
  # children appear in their tracker's section, BELOW the tracker line
  t120_line=$(grep -n '#120' "$TMP/out" | head -1 | cut -d: -f1)
  c144_line=$(grep -n '#144' "$TMP/out" | head -1 | cut -d: -f1)
  c146_line=$(grep -n '#146' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$t120_line" ] && [ -n "$c144_line" ] && [ "$t120_line" -lt "$c144_line" ] && [ "$c144_line" -lt "$c146_line" ]; then
    pass_msg "tracker #120 followed by children #144, #146"
  else
    fail_msg "tracker #120 followed by children #144, #146" "t120=$t120_line c144=$c144_line c146=$c146_line"
  fi

  inc
  # tracker with no open children collapses to placeholder
  if grep -qE 'all children closed' "$TMP/out"; then
    pass_msg "tracker with no open children renders placeholder"
  else
    fail_msg "tracker with no open children renders placeholder" "$(grep -A1 '#131' "$TMP/out")"
  fi

  inc
  # children NOT included in ORPHANS — count of #144 lines must equal 1
  c144_count=$(grep -c '#144' "$TMP/out")
  if [ "$c144_count" -eq 1 ]; then
    pass_msg "child #144 deduplicated (only appears once, in EPICS)"
  else
    fail_msg "child #144 deduplicated (only appears once, in EPICS)" "count=$c144_count"
  fi

  inc
  # orphan #999 still appears in the flat ORPHANS list
  if grep -qE '#999[[:space:]]+—.*\(ready\)' "$TMP/out"; then
    pass_msg "orphan #999 still appears in flat ORPHANS list"
  else
    fail_msg "orphan #999 still appears in flat ORPHANS list" "$(grep '#999' "$TMP/out")"
  fi
fi

# ----------------------------------------------------------------------
# Task 4: NOTES footer + conditional att column
# ----------------------------------------------------------------------

# Scenario 4.1 — non-default metadata renders, att column present (one
# issue has scratch attachments, others do not).
inc
PROJ_ROOT=$(mktemp -d)
# Issue 133 has 3 attachments; #150 and #34 have none.
mkdir -p "$PROJ_ROOT/.claude/scratch/issue-133"
touch "$PROJ_ROOT/.claude/scratch/issue-133/a.png" \
      "$PROJ_ROOT/.claude/scratch/issue-133/b.png" \
      "$PROJ_ROOT/.claude/scratch/issue-133/c.txt"

PIPELINE_PROJECT_ROOT="$PROJ_ROOT" bash "$HELPER" \
  --issues "$FIXTURES/notes-issues.json" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "notes render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
else
  pass_msg "notes render exits 0"

  inc
  if grep -qE '^NOTES \(non-default\)' "$TMP/out"; then
    pass_msg "NOTES section header rendered"
  else
    fail_msg "NOTES section header rendered" "$(cat "$TMP/out")"
  fi

  inc
  # #150 row: Target Base = next (non-default), Path = A (non-default)
  if grep -qE '#150[[:space:]]*\|[[:space:]]*next[[:space:]]*\|[[:space:]]*A' "$TMP/out"; then
    pass_msg "#150 NOTES row: Target Base=next, Path=A"
  else
    fail_msg "#150 NOTES row: Target Base=next, Path=A" "$(grep '#150' "$TMP/out")"
  fi

  inc
  # #133 row: Blocked by = #99 from body
  if grep -qE '#133.*#99' "$TMP/out"; then
    pass_msg "#133 NOTES row: Blocked by = #99"
  else
    fail_msg "#133 NOTES row: Blocked by = #99" "$(grep '#133' "$TMP/out")"
  fi

  inc
  # att column present (header trailing column is "att")
  if grep -qE '\|[[:space:]]*att[[:space:]]*$' "$TMP/out"; then
    pass_msg "att column rendered when at least one row has att>0"
  else
    fail_msg "att column rendered when at least one row has att>0" "$(grep -A1 'NOTES' "$TMP/out")"
  fi

  inc
  # Dbg column header present, positioned after "Blocked by", before "att" (#997).
  if grep -qE 'Blocked by[[:space:]]*\|[[:space:]]*Dbg[[:space:]]*\|[[:space:]]*att' "$TMP/out"; then
    pass_msg "NOTES header includes Dbg column (after Blocked by, before att)"
  else
    fail_msg "NOTES header includes Dbg column (after Blocked by, before att)" "$(grep -A1 'NOTES' "$TMP/out")"
  fi

  inc
  # #133 row: att=3
  if grep -qE '#133.*\|[[:space:]]*3' "$TMP/out"; then
    pass_msg "#133 NOTES row: att=3"
  else
    fail_msg "#133 NOTES row: att=3" "$(grep '#133' "$TMP/out")"
  fi

  inc
  # #34 now carries the needs-debug label, so it APPEARS in NOTES with Dbg=yes
  # (#997). Its other metadata is all-default (Target Base=staging, Path=B,
  # Blocked by=--, att=0) — needs-debug is the SOLE reason it surfaces, which
  # exercises the `.needs_debug` clause of the renderer's non-default predicate.
  notes_anchor=$(grep -n '^NOTES' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$notes_anchor" ]; then
    notes_section=$(awk -v start="$notes_anchor" 'NR >= start' "$TMP/out")
    # Row shape: #34 | staging | B | -- | yes | 0  (Dbg column = yes)
    if echo "$notes_section" | grep -qE '#34[[:space:]]*\|[[:space:]]*staging[[:space:]]*\|[[:space:]]*B[[:space:]]*\|[[:space:]]*--[[:space:]]*\|[[:space:]]*yes[[:space:]]*\|'; then
      pass_msg "#34 (needs-debug, else all-default) APPEARS in NOTES with Dbg=yes"
    else
      fail_msg "#34 (needs-debug, else all-default) APPEARS in NOTES with Dbg=yes" "$(echo "$notes_section" | grep '#34')"
    fi

    inc
    # Non-needs-debug rows (#133, #150) render Dbg = -- in the Dbg column.
    # #133: #133 | staging | B | #99 | -- | 3
    if echo "$notes_section" | grep -qE '#133[[:space:]]*\|[[:space:]]*staging[[:space:]]*\|[[:space:]]*B[[:space:]]*\|[[:space:]]*#99[[:space:]]*\|[[:space:]]*--[[:space:]]*\|'; then
      pass_msg "#133 (not needs-debug) renders Dbg = --"
    else
      fail_msg "#133 (not needs-debug) renders Dbg = --" "$(echo "$notes_section" | grep '#133')"
    fi

    inc
    # #150: #150 | next | A | -- | -- | 0  — Blocked-by '--' then Dbg '--'.
    if echo "$notes_section" | grep -qE '#150[[:space:]]*\|[[:space:]]*next[[:space:]]*\|[[:space:]]*A[[:space:]]*\|[[:space:]]*--[[:space:]]*\|[[:space:]]*--[[:space:]]*\|'; then
      pass_msg "#150 (not needs-debug) renders Dbg = --"
    else
      fail_msg "#150 (not needs-debug) renders Dbg = --" "$(echo "$notes_section" | grep '#150')"
    fi
  else
    fail_msg "#34 (needs-debug) APPEARS in NOTES with Dbg=yes" "no NOTES section to scan"
  fi
fi
rm -rf "$PROJ_ROOT"

# Scenario 4.2 — all-defaults fixture: NOTES section MUST NOT render at all.
inc
PROJ_ROOT2=$(mktemp -d)
PIPELINE_PROJECT_ROOT="$PROJ_ROOT2" bash "$HELPER" \
  --issues "$FIXTURES/all-defaults-issues.json" \
  --today 2026-05-21 \
  >"$TMP/out2" 2>"$TMP/err2"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "all-defaults render exits 0" "rc=$rc, stderr=$(cat "$TMP/err2")"
elif grep -q '^NOTES' "$TMP/out2"; then
  fail_msg "all-defaults render OMITS NOTES section" "$(cat "$TMP/out2")"
else
  pass_msg "all-defaults render OMITS NOTES section"
fi

inc
# Same scenario: att column must NOT be rendered when all rows have att=0
# (also covered by the omission above, but call it out explicitly for clarity).
if grep -qE 'att' "$TMP/out2"; then
  fail_msg "att column SUPPRESSED when no row has att>0" "$(cat "$TMP/out2")"
else
  pass_msg "att column SUPPRESSED when no row has att>0"
fi
rm -rf "$PROJ_ROOT2"

# ----------------------------------------------------------------------
# Task 5: counts footer + multi-tracker WARN line
# ----------------------------------------------------------------------

# Scenario 5.1 — counts footer: 2 epics + 3 children + 2 orphans = 7 open.
inc
bash "$HELPER" \
  --issues "$FIXTURES/counts-issues.json" \
  --trackers "$FIXTURES/counts-trackers.json" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "counts render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
else
  pass_msg "counts render exits 0"
  inc
  if grep -qE '^2 epics \+ 3 children \+ 2 orphans = 7 open$' "$TMP/out"; then
    pass_msg "counts footer: 2 epics + 3 children + 2 orphans = 7 open"
  else
    fail_msg "counts footer: 2 epics + 3 children + 2 orphans = 7 open" \
      "$(grep -E 'epics' "$TMP/out" || echo '<no counts line>')"
  fi
fi

# Scenario 5.2 — multi-tracker child triggers WARN line and counts as 1.
inc
bash "$HELPER" \
  --issues "$FIXTURES/multi-tracker-issues.json" \
  --trackers "$FIXTURES/multi-tracker.json" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "multi-tracker render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
else
  pass_msg "multi-tracker render exits 0"

  inc
  if grep -qE '^WARN: #50 listed under multiple trackers: #10, #20$' "$TMP/out"; then
    pass_msg "WARN line emitted for #50 under multiple trackers"
  else
    fail_msg "WARN line emitted for #50 under multiple trackers" \
      "$(grep -i 'WARN' "$TMP/out" || echo '<no WARN line>')"
  fi

  inc
  if grep -qE '^2 epics \+ 1 children \+ 0 orphans = 3 open$' "$TMP/out"; then
    pass_msg "duplicate child #50 counted once: 2+1+0=3"
  else
    fail_msg "duplicate child #50 counted once: 2+1+0=3" \
      "$(grep -E 'epics' "$TMP/out" || echo '<no counts line>')"
  fi

  inc
  warn_line=$(grep -n '^WARN' "$TMP/out" | head -1 | cut -d: -f1)
  counts_line=$(grep -n 'epics' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$warn_line" ] && [ -n "$counts_line" ] && [ "$warn_line" -lt "$counts_line" ]; then
    pass_msg "WARN line appears above counts footer"
  else
    fail_msg "WARN line appears above counts footer" "warn=$warn_line counts=$counts_line"
  fi
fi

# ----------------------------------------------------------------------
# Task 6: RELEASE PRs table above pipeline status
# ----------------------------------------------------------------------

# Scenario 6.1 — release-prs.txt with two rows renders ABOVE
# `PIPELINE STATUS — <date>`, with the canonical columns.
inc
bash "$HELPER" \
  --issues "$FIXTURES/all-defaults-issues.json" \
  --release-prs "$FIXTURES/release-prs.txt" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "release-prs render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
else
  pass_msg "release-prs render exits 0"

  inc
  rel_line=$(grep -n '^RELEASE PRs' "$TMP/out" | head -1 | cut -d: -f1)
  pipe_line=$(grep -n '^PIPELINE STATUS' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$rel_line" ] && [ -n "$pipe_line" ] && [ "$rel_line" -lt "$pipe_line" ]; then
    pass_msg "RELEASE PRs section appears above PIPELINE STATUS"
  else
    fail_msg "RELEASE PRs section appears above PIPELINE STATUS" "rel=$rel_line pipe=$pipe_line"
  fi

  inc
  if grep -qE '#201.*release 1\.2\.3.*release-pending.*pass' "$TMP/out"; then
    pass_msg "release PR #201 row: title, stage, ci=pass"
  else
    fail_msg "release PR #201 row: title, stage, ci=pass" "$(grep '#201' "$TMP/out")"
  fi

  inc
  if grep -qE '#202.*release 1\.3\.0.*release-pending.*fail' "$TMP/out"; then
    pass_msg "release PR #202 row: title, stage, ci=fail"
  else
    fail_msg "release PR #202 row: title, stage, ci=fail" "$(grep '#202' "$TMP/out")"
  fi
fi

# Scenario 6.2 — empty release-prs.txt → NO RELEASE PRs section rendered.
inc
bash "$HELPER" \
  --issues "$FIXTURES/all-defaults-issues.json" \
  --release-prs "$FIXTURES/release-prs-empty.txt" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "empty release-prs render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
elif grep -q '^RELEASE PRs' "$TMP/out"; then
  fail_msg "empty release-prs render OMITS RELEASE PRs section" "$(cat "$TMP/out")"
else
  pass_msg "empty release-prs render OMITS RELEASE PRs section"
fi

# ----------------------------------------------------------------------
# Fix-review: hardening surfaced by code review of #343
# ----------------------------------------------------------------------

# 1) The canonical SKILL.md invocation feeds --release-prs via bash process
#    substitution (e.g. <(printf '%s\n' "$RELEASE_PRS")). That resolves to
#    /dev/fd/N which is NOT a regular file. The renderer must accept it.
inc
bash "$HELPER" \
  --issues "$FIXTURES/all-defaults-issues.json" \
  --release-prs <(printf 'pr=301 ci=pass title=chore(main): release 9.9.9\n') \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q '#301' "$TMP/out"; then
  pass_msg "process substitution accepted for --release-prs"
else
  fail_msg "process substitution accepted for --release-prs" \
    "rc=$rc, stderr=$(cat "$TMP/err"), stdout=$(cat "$TMP/out")"
fi

# 2) Issues with no .labels field (null) must not crash the renderer.
inc
cat >"$TMP/null-labels.json" <<'JSON'
[{"number": 555, "title": "feat(run): issue with null labels", "labels": null, "body": "", "updatedAt": "2026-05-21T00:00:00Z"}]
JSON
bash "$HELPER" --issues "$TMP/null-labels.json" --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q '#555' "$TMP/out"; then
  pass_msg "null labels field tolerated"
else
  fail_msg "null labels field tolerated" \
    "rc=$rc, stderr=$(cat "$TMP/err"), stdout=$(cat "$TMP/out")"
fi

# ----------------------------------------------------------------------
# Issue #430: stage_rank — ready issues float above later/human/brainstorm
# (within bucket, across buckets, and inside epic children).
# ----------------------------------------------------------------------

# S.1 — row-level: in a single bucket, a `ready` low-priority row outranks
# a `later` high-priority row.
inc
bash "$HELPER" \
  --issues "$FIXTURES/stage-rank-rows-issues.json" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "S.1 stage-rank rows render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
else
  p701_line=$(grep -n '#701' "$TMP/out" | head -1 | cut -d: -f1)
  p702_line=$(grep -n '#702' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$p701_line" ] && [ -n "$p702_line" ] && [ "$p702_line" -lt "$p701_line" ]; then
    pass_msg "S.1 ready #702 sorts above later #701 within (run) bucket"
  else
    fail_msg "S.1 ready #702 sorts above later #701 within (run) bucket" \
      "p702=$p702_line p701=$p701_line"
  fi
fi

# S.2 — flat ready-rank dominance: in the single flat orphan list, the
# ready row (#711) floats above the not-ready (later) row (#710) regardless
# of what used to be separate scope buckets. Same fixture, same intent:
# ready_rank dominates the sort.
inc
bash "$HELPER" \
  --issues "$FIXTURES/stage-rank-buckets-issues.json" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "S.2 stage-rank buckets render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
else
  p711_line=$(grep -n '#711' "$TMP/out" | head -1 | cut -d: -f1)
  p710_line=$(grep -n '#710' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$p711_line" ] && [ -n "$p710_line" ] && [ "$p711_line" -lt "$p710_line" ]; then
    pass_msg "S.2 ready #711 sorts above not-ready (later) #710 in flat list"
  else
    fail_msg "S.2 ready #711 sorts above not-ready (later) #710 in flat list" \
      "p711=$p711_line p710=$p710_line"
  fi
fi

# S.3 — epic-child re-sort: under tracker #720, the ready child #722 must
# print before the later child #721 even though the tracker body lists
# #721 first.
inc
bash "$HELPER" \
  --issues "$FIXTURES/stage-rank-epic-issues.json" \
  --trackers "$FIXTURES/stage-rank-epic-trackers.json" \
  --today 2026-05-21 \
  >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "S.3 stage-rank epic render exits 0" "rc=$rc, stderr=$(cat "$TMP/err")"
else
  t720_line=$(grep -n '#720' "$TMP/out" | head -1 | cut -d: -f1)
  c722_line=$(grep -n '#722' "$TMP/out" | head -1 | cut -d: -f1)
  c721_line=$(grep -n '#721' "$TMP/out" | head -1 | cut -d: -f1)
  if [ -n "$t720_line" ] && [ -n "$c722_line" ] && [ -n "$c721_line" ] \
     && [ "$t720_line" -lt "$c722_line" ] && [ "$c722_line" -lt "$c721_line" ]; then
    pass_msg "S.3 under tracker #720, ready child #722 above later child #721"
  else
    fail_msg "S.3 under tracker #720, ready child #722 above later child #721" \
      "t720=$t720_line c722=$c722_line c721=$c721_line"
  fi
fi

# ----------------------------------------------------------------------
# Issue #1128: next-branch routing — configurable PIPELINE_NEXT_LABEL /
# PIPELINE_NEXT_BRANCH with the legacy `next-major-release` alias retained.
# ----------------------------------------------------------------------

# N.1 — default knobs: an issue carrying the `next` label renders Target Base
# = `next` (default PIPELINE_NEXT_BRANCH), and the legacy `next-major-release`
# alias still routes to `next`. Both appear in the NOTES (non-default) block
# because their Target Base differs from PIPELINE_BASE_BRANCH (staging).
inc
PROJ_ROOT_N=$(mktemp -d)
PIPELINE_PROJECT_ROOT="$PROJ_ROOT_N" bash "$HELPER" \
  --issues "$FIXTURES/next-label-issues.json" \
  --today 2026-05-21 \
  >"$TMP/outN" 2>"$TMP/errN"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "N.1 next-label render exits 0" "rc=$rc, stderr=$(cat "$TMP/errN")"
else
  pass_msg "N.1 next-label render exits 0"

  inc
  # #700 carries the configurable `next` label → Target Base = next.
  if grep -qE '#700[[:space:]]*\|[[:space:]]*next[[:space:]]*\|' "$TMP/outN"; then
    pass_msg "N.1 #700 (next label) NOTES row: Target Base = next"
  else
    fail_msg "N.1 #700 (next label) NOTES row: Target Base = next" "$(grep '#700' "$TMP/outN")"
  fi

  inc
  # #701 carries the legacy `next-major-release` alias → still Target Base = next.
  if grep -qE '#701[[:space:]]*\|[[:space:]]*next[[:space:]]*\|' "$TMP/outN"; then
    pass_msg "N.1 #701 (legacy alias) NOTES row: Target Base = next"
  else
    fail_msg "N.1 #701 (legacy alias) NOTES row: Target Base = next" "$(grep '#701' "$TMP/outN")"
  fi
fi
rm -rf "$PROJ_ROOT_N"

# N.2 — branch override: with PIPELINE_NEXT_BRANCH=integration in env, a
# next-labelled issue renders Target Base = integration, NOT the literal `next`.
inc
PROJ_ROOT_N2=$(mktemp -d)
PIPELINE_PROJECT_ROOT="$PROJ_ROOT_N2" PIPELINE_NEXT_BRANCH=integration bash "$HELPER" \
  --issues "$FIXTURES/next-label-issues.json" \
  --today 2026-05-21 \
  >"$TMP/outN2" 2>"$TMP/errN2"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "N.2 override render exits 0" "rc=$rc, stderr=$(cat "$TMP/errN2")"
else
  inc
  if grep -qE '#700[[:space:]]*\|[[:space:]]*integration[[:space:]]*\|' "$TMP/outN2"; then
    pass_msg "N.2 PIPELINE_NEXT_BRANCH=integration overrides the literal next for #700"
  else
    fail_msg "N.2 PIPELINE_NEXT_BRANCH=integration overrides the literal next for #700" "$(grep '#700' "$TMP/outN2")"
  fi

  inc
  # The override must replace `next` entirely for the next-labelled rows — the
  # literal `next` must not leak as a Target Base value.
  if grep -qE '#700[[:space:]]*\|[[:space:]]*next[[:space:]]*\|' "$TMP/outN2"; then
    fail_msg "N.2 literal next must not leak as Target Base under override" "$(grep '#700' "$TMP/outN2")"
  else
    pass_msg "N.2 literal next does NOT leak as Target Base under override"
  fi
fi
rm -rf "$PROJ_ROOT_N2"

# N.3 — label override: with PIPELINE_NEXT_LABEL=ship-next, an issue carrying
# `ship-next` routes to next, while the legacy `next-major-release` alias is
# STILL honored (union, not replacement).
inc
cat >"$TMP/next-custom-label.json" <<'JSON'
[
  {"number": 800, "title": "feat(core): custom next label", "labels": [{"name": "priority/P1"}, {"name": "ship-next"}], "body": "", "updatedAt": "2026-05-21T00:00:00Z"},
  {"number": 801, "title": "feat(core): legacy alias under custom label", "labels": [{"name": "priority/P2"}, {"name": "next-major-release"}], "body": "", "updatedAt": "2026-05-21T00:00:00Z"}
]
JSON
PROJ_ROOT_N3=$(mktemp -d)
PIPELINE_PROJECT_ROOT="$PROJ_ROOT_N3" PIPELINE_NEXT_LABEL=ship-next bash "$HELPER" \
  --issues "$TMP/next-custom-label.json" \
  --today 2026-05-21 \
  >"$TMP/outN3" 2>"$TMP/errN3"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "N.3 custom-label render exits 0" "rc=$rc, stderr=$(cat "$TMP/errN3")"
else
  inc
  if grep -qE '#800[[:space:]]*\|[[:space:]]*next[[:space:]]*\|' "$TMP/outN3"; then
    pass_msg "N.3 PIPELINE_NEXT_LABEL=ship-next routes #800 to next"
  else
    fail_msg "N.3 PIPELINE_NEXT_LABEL=ship-next routes #800 to next" "$(grep '#800' "$TMP/outN3")"
  fi

  inc
  if grep -qE '#801[[:space:]]*\|[[:space:]]*next[[:space:]]*\|' "$TMP/outN3"; then
    pass_msg "N.3 legacy next-major-release alias still honored under custom label"
  else
    fail_msg "N.3 legacy next-major-release alias still honored under custom label" "$(grep '#801' "$TMP/outN3")"
  fi
fi
rm -rf "$PROJ_ROOT_N3"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "TOTAL: $TESTS  PASS: $PASS  FAIL: $FAIL"
echo "=========================================================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
