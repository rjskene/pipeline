#!/bin/bash
set -uo pipefail

# Tests for scripts/_advisory-text.sh — shared helper that maps pipeline-owned
# hook basenames to their capability-impact annotation strings. Also drift-
# checks the annotation table against .claude-plugin/plugin.json.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/_advisory-text.sh"
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$HELPER" ]; then
  fail_msg "helper exists at scripts/_advisory-text.sh"
  echo "FAIL=$FAIL PASS=$PASS"
  exit 1
fi

# shellcheck source=/dev/null
. "$HELPER"

MANIFEST_HOOKS=(
  block_deletions.py
  enforce-base-branch.py
  check-ci-skip-markers.py
  enforce-path-c-delegation.py
  restrict_paths.py
  enforce-ci-wait.py
)
DOGFOOD_HOOKS=(
  log-tool-use.sh
  log_subagent.py
)

# (a) advisory_for_hook returns non-empty for every known basename.
for b in "${MANIFEST_HOOKS[@]}" "${DOGFOOD_HOOKS[@]}"; do
  out="$(advisory_for_hook "$b" || true)"
  if [ -n "$out" ]; then
    pass_msg "advisory_for_hook $b returns non-empty"
  else
    fail_msg "advisory_for_hook $b returns non-empty"
  fi
done

# Manifest hooks must say "capability preserved"
for b in "${MANIFEST_HOOKS[@]}"; do
  out="$(advisory_for_hook "$b" || true)"
  if [[ "$out" == *"capability preserved"* ]]; then
    pass_msg "$b annotation mentions capability preserved"
  else
    fail_msg "$b annotation mentions capability preserved (got: $out)"
  fi
done

# Dogfood hooks must say "HTS-dogfood-only"
for b in "${DOGFOOD_HOOKS[@]}"; do
  out="$(advisory_for_hook "$b" || true)"
  if [[ "$out" == *"HTS-dogfood-only"* ]]; then
    pass_msg "$b annotation mentions HTS-dogfood-only"
  else
    fail_msg "$b annotation mentions HTS-dogfood-only (got: $out)"
  fi
done

# Unknown basename returns empty with rc=1.
unk_out="$(advisory_for_hook "no-such-hook.py" 2>/dev/null || echo "__RC_NONZERO__")"
if [ "$unk_out" = "__RC_NONZERO__" ] || [ -z "$unk_out" ]; then
  # Confirm rc=1 specifically.
  if advisory_for_hook "no-such-hook.py" >/dev/null 2>&1; then
    fail_msg "advisory_for_hook unknown basename returns rc=1"
  else
    pass_msg "advisory_for_hook unknown basename returns rc=1"
  fi
else
  fail_msg "advisory_for_hook unknown basename returns empty"
fi

# list_pipeline_hook_basenames prints the 8 known basenames.
listing="$(list_pipeline_hook_basenames | sort -u)"
expected="$(printf '%s\n' "${MANIFEST_HOOKS[@]}" "${DOGFOOD_HOOKS[@]}" | sort -u)"
if [ "$listing" = "$expected" ]; then
  pass_msg "list_pipeline_hook_basenames prints the 8 known basenames"
else
  fail_msg "list_pipeline_hook_basenames prints the 8 known basenames (diff follows)"
  diff <(echo "$listing") <(echo "$expected") || true
fi

# (b) drift detection against plugin.json — only if jq is installed.
if ! command -v jq >/dev/null 2>&1; then
  echo "# SKIP: jq not installed for drift-detection portion of test"
  echo "PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" = "0" ]
  exit $?
fi

# Extract every manifest command across ALL hook sections, derive basename.
manifest_basenames="$(
  jq -r '.hooks | to_entries[] | .value[]? | .hooks[]? | .command' "$MANIFEST" \
    | awk '{print $NF}' \
    | awk -F/ '{print $NF}' \
    | sort -u
)"

# Every "capability preserved" basename must appear in the manifest.
for b in "${MANIFEST_HOOKS[@]}"; do
  if echo "$manifest_basenames" | grep -qx "$b"; then
    pass_msg "manifest contains $b (capability preserved)"
  else
    fail_msg "manifest contains $b (capability preserved)"
  fi
done

# Every "HTS-dogfood-only" basename must NOT appear in the manifest.
for b in "${DOGFOOD_HOOKS[@]}"; do
  if echo "$manifest_basenames" | grep -qx "$b"; then
    fail_msg "manifest does NOT contain $b (HTS-dogfood-only)"
  else
    pass_msg "manifest does NOT contain $b (HTS-dogfood-only)"
  fi
done

# ---------------------------------------------------------------------------
# advisory_for_ref_source — six buckets emitted by scan-preservation-refs.sh.
# Every known bucket maps to a non-empty annotation string; unknown buckets
# return rc=1.
# ---------------------------------------------------------------------------
REF_BUCKETS=(
  active-wiring
  falls-away
  consumer-skill-ref
  self-only
  fork
  doc-ref
)
for b in "${REF_BUCKETS[@]}"; do
  out="$(advisory_for_ref_source "$b" 2>/dev/null || true)"
  if [ -n "$out" ]; then
    pass_msg "advisory_for_ref_source $b returns non-empty"
  else
    fail_msg "advisory_for_ref_source $b returns empty"
  fi
done

if advisory_for_ref_source "bogus-bucket" >/dev/null 2>&1; then
  fail_msg "advisory_for_ref_source bogus-bucket rc=1"
else
  pass_msg "advisory_for_ref_source bogus-bucket rc=1"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
