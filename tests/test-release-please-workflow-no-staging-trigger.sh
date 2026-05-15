#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
python3 - <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("  SKIP: PyYAML not installed; skipping workflow trigger guard")
    sys.exit(0)
w = yaml.safe_load(open(".github/workflows/release-please.yml"))
# PyYAML parses bare `on:` as Python True; handle both
on_key = w[True] if True in w else w["on"]
br = on_key["push"]["branches"]
assert "staging" not in br, f"staging in workflow triggers: {br}"
print(f"  PASS: release-please workflow does not trigger on staging (branches={br})")
PY
