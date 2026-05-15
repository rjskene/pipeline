#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
python3 - <<'PY'
import json, sys
m = json.load(open(".claude-plugin/marketplace-dev.json"))
p = json.load(open(".claude-plugin/plugin.json"))
m_meta = m["metadata"]["version"]
m_plug = m["plugins"][0]["version"]
pj_ver = p["version"]
assert m_meta == m_plug, f"marketplace-dev metadata.version ({m_meta}) != plugins[0].version ({m_plug})"
assert m_meta == pj_ver, f"marketplace-dev versions ({m_meta}) != plugin.json version ({pj_ver})"
print(f"  PASS: marketplace-dev versions agree across files ({m_meta})")
PY
