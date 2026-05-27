#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$REPO_ROOT/docs/release-cadence.md"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# #541: with an established STABLE tag in the line, neither the Release-As footer
# NOR the manifest-assertion produces the intended version — release-please
# anchors on the latest stable tag. The doc MUST document the manual git tag +
# gh release create cut as the supported path and MUST NOT promise the footer
# works unconditionally. All greps scoped to docs/release-cadence.md ONLY
# (never CHANGELOG / .git / .claude/logs; no hard-coded version literals).

# 1. The manual-cut path is documented as supported from a stable base.
assert "documents manual git tag cut from a stable base" "grep -qiE 'git tag' '$F'"
assert "documents gh release create for the manual cut" "grep -qE 'gh release create' '$F'"
assert "manual cut marks the prerelease channel (--prerelease flag)" "grep -qE 'gh release create.*--prerelease|--prerelease.*gh release create' '$F'"
assert "names #541 as the reason the footer fails from a stable base" "grep -qE '#541' '$F'"

# 2. The overpromising "LOCKED" / footer-only-from-stable claims are removed/hedged.
#    The footer trigger must NOT be described as unconditionally LOCKED; it is
#    explicitly scoped to the no-stable-tag / in-rc-line cases.
assert "no unqualified 'Trigger (LOCKED)' header remains" "! grep -qE 'Trigger \(LOCKED\)' '$F'"
assert "documents that Release-As footer drops -rc from a stable base" "grep -qiE 'drops the -rc|drops -rc|-rc.*dropped|prerelease component.*discard' '$F'"
assert "documents that the manifest-assertion also reconciles toward the stable tag" "grep -qiE 'manifest.assertion|manifest assertion' '$F'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
