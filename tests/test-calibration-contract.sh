#!/bin/bash
set -uo pipefail
#
# Cross-artifact contract pin for the §8 calibration slate (issue #1280,
# tracker #1271, spec docs/superpowers/specs/2026-09-05-harness-evolve-loop-design.md §8).
#
# The slate ships as four artifacts written by four different leaves:
#   dev/calib/slate/*/          the fixed five-issue workload
#   scripts/calibration-run.sh  the driver + the CALIB emitter
#   scripts/run-retro.sh        the CALIB parser (compute_calib)
#   docs/calibration.md         the operator guide
# Each has its own unit test. NONE of them notices when the four drift apart —
# a sixth slate dir the launch preview never mentions, a flag the doc forgot, a
# renamed CALIB field the retro silently stops parsing. This file is that pin:
# it asserts the artifacts AGREE, deriving both sides of every comparison from
# the artifacts themselves (never from a hardcoded expected list, which would
# just move the drift here).
#
# HERMETIC: the only subprocess is `calibration-run.sh --dry-run` / `--help`,
# both of which short-circuit before any network call or claude launch.
#
# Two exclusions, both deliberate and both asserted rather than assumed:
#   * `--help` is the self-documenting banner flag; it is pinned against the
#     script's OWN usage banner (below), not against the operator guide.
#   * doc flags the script merely FORWARDS to the headless `claude` launch
#     (e.g. --plugin-dir) are the CLI's flags, not calibration-run.sh's. They
#     are excused only on evidence: each must appear in build_launch().
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/calibration-run.sh"
RETRO="$ROOT/scripts/run-retro.sh"
DOC="$ROOT/docs/calibration.md"
SLATE="$ROOT/dev/calib/slate"
FIXTURE_README="$ROOT/tests/fixtures/run-retro/README.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

assert_eq() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass_msg "$1"; else
    fail_msg "$1"
    echo "        expected: [$2]"
    echo "        observed: [$3]"
  fi
}
assert_true() { # <label> <cmd...>
  if "${@:2}" >/dev/null 2>&1; then pass_msg "$1"; else fail_msg "$1"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Extraction helpers — every "expected" value in this file comes from one of
# these, applied to a different artifact than the "observed" one.
# ---------------------------------------------------------------------------

# fields <line> — the ordered `name=` field names on a CALIB-family line, so
# `CALIB issue=%s path=%s ...` and `CALIB issue=<n> path=<X> ...` normalize to
# the same string regardless of whether the value slot is a printf verb, a
# doc placeholder or a real value.
fields() { printf '%s\n' "$1" | grep -oE '[a-z][a-z-]*=' | tr -d '=' | tr '\n' ' ' | sed 's/ $//'; }

# first_line <file> <ERE>
first_line() { grep -m1 -E "$2" "$1" 2>/dev/null; }

# slice <file> <start ERE> <end ERE> — the block between the two, inclusive.
slice() { awk -v s="$2" -v e="$3" 'a && $0 ~ e { print; exit } $0 ~ s { a = 1 } a' "$1"; }

# flags_in — long `--flag` tokens on stdin, sorted + deduped, one line.
flags_in() { grep -oE -- '--[a-z][a-z-]*' | sort -u | tr '\n' ' ' | sed 's/ $//'; }

# set_minus <set> <tokens to drop...>
set_minus() {
  local set_="$1" drop tok out=""
  shift
  for tok in $set_; do
    for drop in "$@"; do [ "$tok" = "$drop" ] && continue 2; done
    out="$out $tok"
  done
  printf '%s' "${out# }"
}

# ---------------------------------------------------------------------------
scenario "Artifacts are present"
# ---------------------------------------------------------------------------
for f in "$RUNNER" "$RETRO" "$DOC" "$FIXTURE_README"; do
  assert_true "exists: ${f#$ROOT/}" test -f "$f"
done
assert_true "exists: dev/calib/slate/" test -d "$SLATE"

# ---------------------------------------------------------------------------
scenario "(a) every slate dir is in the --dry-run issue set"
# ---------------------------------------------------------------------------

SLATE_DIRS="$(find "$SLATE" -mindepth 1 -maxdepth 1 -type d | sort)"
SLATE_COUNT="$(printf '%s\n' "$SLATE_DIRS" | grep -c . )"

if [ "$SLATE_COUNT" -gt 0 ]; then
  pass_msg "slate carries $SLATE_COUNT issue dirs"
else
  fail_msg "slate carries no issue dirs"
fi

# create_slate_issues() SKIPS any dir without title.txt, so a dir missing one
# would silently shrink the created set while the preview kept its old width.
missing=""
while IFS= read -r d; do
  [ -n "$d" ] || continue
  [ -f "$d/title.txt" ] || missing="$missing ${d#$SLATE/}:title.txt"
  [ -f "$d/body.md" ]   || missing="$missing ${d#$SLATE/}:body.md"
done <<< "$SLATE_DIRS"
assert_eq "every slate dir has the title.txt + body.md the driver reads" "" "${missing# }"

DRY_OUT="$(PIPELINE_CALIB_DIR="$TMP/sandbox" PIPELINE_CALIB_TIMEOUT=77 \
  bash "$RUNNER" --dry-run 2>&1)"
DRY_RC=$?
assert_eq "--dry-run exits 0" "0" "$DRY_RC"

LAUNCH="$(printf '%s\n' "$DRY_OUT" | grep -m1 '^CALIB-LAUNCH ')"
if [ -n "$LAUNCH" ]; then pass_msg "--dry-run prints a CALIB-LAUNCH preview line"; else
  fail_msg "--dry-run printed no CALIB-LAUNCH line (got: $DRY_OUT)"
fi

# The issue set is the prompt's argument list, between the slash command and
# the CLI flags that follow it.
launch_ids() { printf '%s\n' "$1" | sed -e 's/.*fullsend //' -e 's/ --plugin-dir.*//'; }

PREVIEW_IDS="$(launch_ids "$LAUNCH")"
assert_eq "the preview issue set has one slot per slate dir" \
  "$SLATE_COUNT" "$(printf '%s\n' $PREVIEW_IDS | grep -c . )"

# With ids pre-resolved (what --reset hands --run), every one must reach the
# launch, in order.
REAL_IDS=""
i=9001
while IFS= read -r d; do
  [ -n "$d" ] || continue
  REAL_IDS="$REAL_IDS $i"
  i=$((i + 1))
done <<< "$SLATE_DIRS"
REAL_IDS="${REAL_IDS# }"

DRY_OUT2="$(PIPELINE_CALIB_DIR="$TMP/sandbox" PIPELINE_CALIB_ISSUE_IDS="$REAL_IDS" \
  bash "$RUNNER" --dry-run 2>&1)"
LAUNCH2="$(printf '%s\n' "$DRY_OUT2" | grep -m1 '^CALIB-LAUNCH ')"
assert_eq "--dry-run launches every resolved slate id, in order" \
  "$REAL_IDS" "$(launch_ids "$LAUNCH2")"

# ---------------------------------------------------------------------------
scenario "(b) the driver reads the three documented knobs"
# ---------------------------------------------------------------------------
for knob in PIPELINE_CALIB_REPO PIPELINE_CALIB_DIR PIPELINE_CALIB_TIMEOUT; do
  assert_true "calibration-run.sh reads \${$knob:-<default>}" \
    grep -qF "\${$knob:-" "$RUNNER"
  assert_true "docs/calibration.md documents $knob" grep -qF "$knob" "$DOC"
done

# Two of the three are observable in the dry-run preview; pin them behaviourally
# so a read that never reaches the launch cannot pass on the grep alone.
assert_true "PIPELINE_CALIB_DIR becomes the launch cwd" \
  grep -qF "cwd=$TMP/sandbox" <<< "$LAUNCH"
assert_true "PIPELINE_CALIB_TIMEOUT becomes the timeout cap" \
  grep -qE '(^| )timeout 77( |$)' <<< "$LAUNCH"

# ---------------------------------------------------------------------------
scenario "(c) doc flag set == script flag set"
# ---------------------------------------------------------------------------

PARSE_BLOCK="$TMP/parse-block"
slice "$RUNNER" '^while ' '^done$' > "$PARSE_BLOCK"
SCRIPT_FLAGS="$(flags_in < "$PARSE_BLOCK")"
if [ -n "$SCRIPT_FLAGS" ]; then pass_msg "arg-parse block yields a flag set"; else
  fail_msg "could not slice calibration-run.sh's arg-parse block"
fi
assert_true "--help is one of them (so it is pinned below, not merely excluded)" \
  grep -qw -- '--help' <<< "$SCRIPT_FLAGS"

LAUNCH_BLOCK="$TMP/launch-block"
slice "$RUNNER" '^build_launch' '^}$' > "$LAUNCH_BLOCK"
LAUNCH_FLAGS="$(flags_in < "$LAUNCH_BLOCK")"

# A flag mentioned in prose is the CLI's, not ours, iff the script forwards it
# to the headless launch and does not parse it itself. Derived, not hardcoded.
FORWARDED="$(set_minus "$LAUNCH_FLAGS" $SCRIPT_FLAGS)"
if [ -n "$FORWARDED" ]; then pass_msg "launch forwards CLI-only flags: $FORWARDED"; else
  fail_msg "build_launch() forwards no CLI-only flags — the exclusion below is stale"
fi

# Third artifact: the script's own --help banner. It must describe exactly the
# flags the parser accepts (--help included; it is the banner's own flag).
HELP_FLAGS="$(set_minus "$(bash "$RUNNER" --help 2>&1 | flags_in)" $FORWARDED)"
assert_eq "--help banner documents exactly the flags the parser accepts" \
  "$SCRIPT_FLAGS" "$HELP_FLAGS"

DOC_FLAGS_RAW="$(grep -oE -- '`--[a-z][a-z-]*' "$DOC" | tr -d '`' | sort -u | tr '\n' ' ' | sed 's/ $//')"
DOC_FLAGS="$(set_minus "$DOC_FLAGS_RAW" $FORWARDED)"
OWN_FLAGS="$(set_minus "$SCRIPT_FLAGS" --help)"

assert_eq "docs/calibration.md documents exactly the driver's own flags" \
  "$OWN_FLAGS" "$DOC_FLAGS"

# ---------------------------------------------------------------------------
scenario "(d) CALIB grammar: doc == emitter == retro header, parser keys ⊆ it"
# ---------------------------------------------------------------------------

DOC_CALIB="$(fields "$(first_line "$DOC" '^CALIB issue=')")"
EMIT_CALIB="$(fields "$(first_line "$RUNNER" "printf 'CALIB issue=")")"
RETRO_CALIB="$(fields "$(first_line "$RETRO" '^#[[:space:]]+CALIB issue=')")"

assert_eq "CALIB fields: emitter matches docs/calibration.md" "$DOC_CALIB" "$EMIT_CALIB"
assert_eq "CALIB fields: run-retro.sh header matches docs/calibration.md" "$DOC_CALIB" "$RETRO_CALIB"
assert_eq "CALIB fields are the seven the slate reports" \
  "issue path cost wall verdicts reftest unexpected-files" "$DOC_CALIB"

DOC_TOTAL="$(fields "$(first_line "$DOC" '^CALIB-TOTAL ')")"
EMIT_TOTAL="$(fields "$(first_line "$RUNNER" "printf 'CALIB-TOTAL ")")"
RETRO_TOTAL="$(fields "$(first_line "$RETRO" '^#[[:space:]]+CALIB-TOTAL ')")"

assert_eq "CALIB-TOTAL fields: emitter matches docs/calibration.md" "$DOC_TOTAL" "$EMIT_TOTAL"
assert_eq "CALIB-TOTAL fields: run-retro.sh header matches docs/calibration.md" \
  "$DOC_TOTAL" "$RETRO_TOTAL"
assert_eq "CALIB-TOTAL fields are the four the slate totals" \
  "cost wall issues reftest-pass" "$DOC_TOTAL"

# The parser reads a SUBSET (it needs three atoms), but every key it looks for
# must be a field the emitter actually emits — a renamed field is a silent
# no-match, never an error.
COMPUTE_BLOCK="$TMP/compute-block"
slice "$RETRO" '^compute_calib' '^}$' > "$COMPUTE_BLOCK"
PARSER_KEYS="$(grep -oE '^[[:space:]]+[a-z][a-z-]*=\*\)' "$COMPUTE_BLOCK" \
  | sed -e 's/[[:space:]]*//' -e 's/=\*)//' | sort -u | tr '\n' ' ' | sed 's/ $//')"

assert_eq "compute_calib() parses the three atoms the retro rows need" \
  "cost path reftest" "$PARSER_KEYS"
unknown=""
for k in $PARSER_KEYS; do
  case " $DOC_CALIB " in *" $k "*) ;; *) unknown="$unknown $k" ;; esac
done
assert_eq "every compute_calib() key is an emitted CALIB field" "" "${unknown# }"

# ---------------------------------------------------------------------------
scenario "(e) the fixture substrate name matches what run-retro.sh reads"
# ---------------------------------------------------------------------------
assert_true "run-retro.sh reads <fixture>/calib.txt" \
  grep -qF 'FIXTURE_DIR/calib.txt' "$RETRO"
assert_true "tests/fixtures/run-retro/README.md lists calib.txt" \
  grep -qF '| `calib.txt` |' "$FIXTURE_README"
FIX_DOC_CALIB="$(fields "$(first_line "$FIXTURE_README" '^CALIB issue=')")"
assert_eq "the fixture README's CALIB grammar matches the emitter" \
  "$EMIT_CALIB" "$FIX_DOC_CALIB"
FIX_DOC_TOTAL="$(fields "$(first_line "$FIXTURE_README" '^CALIB-TOTAL ')")"
assert_eq "the fixture README's CALIB-TOTAL grammar matches the emitter" \
  "$EMIT_TOTAL" "$FIX_DOC_TOTAL"

# ---------------------------------------------------------------------------
echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
